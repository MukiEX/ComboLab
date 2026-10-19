#!/usr/bin/env python3
"""ComboLab hub: one home for combos and timing profiles from every machine.

Each gaming PC runs the sync agent (combolab_sync.py, started by
run_server.bat). The hub merges every machine's samples into one profile per
combo version and hands the result back. Run it behind your HTTPS reverse
proxy (nginx, Caddy, ...); it listens on localhost by default.

    python combolab_hub.py add-machine gaming-pc    # prints that machine's token
    python combolab_hub.py serve                    # 127.0.0.1:8770, data in ./data
    python combolab_hub.py list-machines
    python combolab_hub.py remove-machine gaming-pc
    python combolab_hub.py export ./backup          # everything as plain JSON files

Standard library only (Python 3.8+). Data lives in one SQLite file.
"""
import argparse
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
for p in (HERE, os.path.join(HERE, "..", "reframework", "data", "ComboLab")):
    if os.path.isfile(os.path.join(p, "combolab_merge.py")):
        sys.path.insert(0, p)
        break
import combolab_merge  # noqa: E402

HUB_VERSION = "1.7.0"
MAX_BODY = 16 * 1024 * 1024
BACKUP_KINDS = ("sessions", "bot")


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha(obj):
    return hashlib.sha256(canon(obj)).hexdigest()


def token_hash(tok):
    return hashlib.sha256(tok.encode("utf-8")).hexdigest()


def valid_id(s):
    return bool(s) and len(s) <= 200 and all(c.isalnum() or c in "-_." for c in s) and s not in (".", "..")


class Store:
    def __init__(self, path):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.lock = threading.Lock()
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS machines (name TEXT PRIMARY KEY, token_sha TEXT UNIQUE, created INTEGER,
                last_seen INTEGER, agent TEXT, addr TEXT, mod_id TEXT);
            CREATE TABLE IF NOT EXISTS combos (id TEXT PRIMARY KEY, rev INTEGER, sha TEXT, data TEXT,
                updated INTEGER, by TEXT);
            CREATE TABLE IF NOT EXISTS profiles (id TEXT, hash TEXT, rev INTEGER, data TEXT, samples INTEGER,
                origins TEXT, updated INTEGER, by TEXT, PRIMARY KEY (id, hash));
            CREATE TABLE IF NOT EXISTS backups (machine TEXT, kind TEXT, id TEXT, data TEXT, sha TEXT,
                updated INTEGER, PRIMARY KEY (machine, kind, id));
        """)

    def q(self, sql, args=()):
        with self.lock:
            return self.db.execute(sql, args).fetchall()

    def _next_rev(self):
        row = self.db.execute("SELECT v FROM meta WHERE k='rev'").fetchone()
        rev = int(row[0]) + 1 if row else 1
        self.db.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('rev', ?)", (str(rev),))
        return rev

    # ---------------------------------------------------------------- machines
    def add_machine(self, name):
        tok = secrets.token_urlsafe(32)
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO machines (name, token_sha, created) VALUES (?, ?, ?)",
                            (name, token_hash(tok), int(time.time())))
        return tok

    def machine_for(self, tok):
        if not tok:
            return None
        h = token_hash(tok)
        for name, th in self.q("SELECT name, token_sha FROM machines"):
            if hmac.compare_digest(th, h):
                return name
        return None

    def seen(self, name, agent, addr, mod_id=None):
        with self.lock:
            self.db.execute("UPDATE machines SET last_seen=?, agent=?, addr=? WHERE name=?",
                            (int(time.time()), agent, addr, name))
            if mod_id and valid_id(mod_id):
                self.db.execute("UPDATE machines SET mod_id=? WHERE name=?", (mod_id, name))

    # ---------------------------------------------------------------- combos
    def put_combo(self, cid, data, by):
        h = sha(data)
        with self.lock:
            row = self.db.execute("SELECT rev, sha FROM combos WHERE id=?", (cid,)).fetchone()
            if row and row[1] == h:
                return row[0]
            self.db.execute("BEGIN")
            rev = self._next_rev()
            self.db.execute("INSERT OR REPLACE INTO combos (id, rev, sha, data, updated, by) VALUES (?, ?, ?, ?, ?, ?)",
                            (cid, rev, h, json.dumps(data), int(time.time()), by))
            self.db.execute("COMMIT")
            return rev

    # ---------------------------------------------------------------- profiles
    def merge_profile(self, cid, h, data, by):
        data = dict(data)
        data["combo_id"], data["combo_hash"] = cid, h
        with self.lock:
            row = self.db.execute("SELECT rev, data FROM profiles WHERE id=? AND hash=?", (cid, h)).fetchone()
            cur = json.loads(row[1]) if row else None
            merged, added = combolab_merge.merge(cur, data)
            if row and canon(merged) == canon(cur):
                return row[0], cur, 0
            self.db.execute("BEGIN")
            rev = self._next_rev()
            self.db.execute(
                "INSERT OR REPLACE INTO profiles (id, hash, rev, data, samples, origins, updated, by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (cid, h, rev, json.dumps(merged), combolab_merge.sample_count(merged),
                 json.dumps(combolab_merge.origins(merged)), int(time.time()), by))
            self.db.execute("COMMIT")
            return rev, merged, added

    def put_backup(self, machine, kind, bid, data):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO backups (machine, kind, id, data, sha, updated) VALUES (?, ?, ?, ?, ?, ?)",
                            (machine, kind, bid, json.dumps(data), sha(data), int(time.time())))


STORE = None


class Handler(BaseHTTPRequestHandler):
    server_version = "ComboLabHub/" + HUB_VERSION

    def log_message(self, fmt, *args):
        if os.environ.get("COMBOLAB_HUB_QUIET") != "1":
            sys.stderr.write("%s %s\n" % (self.client_ip(), fmt % args))

    def client_ip(self):
        fwd = self.headers.get("X-Forwarded-For") if self.headers else None
        return (fwd.split(",")[0].strip() if fwd else self.client_address[0])

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode("utf-8"))

    def _auth(self):
        a = self.headers.get("Authorization", "")
        tok = a[7:].strip() if a.lower().startswith("bearer ") else ""
        name = STORE.machine_for(tok)
        if not name:
            time.sleep(0.5)  # slow down guessing
            self._json(401, {"error": "unknown or missing token"})
            return None
        ua = self.headers.get("User-Agent", "")
        if ua.startswith("ComboLab-sync/"):  # a browser viewing the overview isn't a sync
            STORE.seen(name, ua, self.client_ip(), self.headers.get("X-ComboLab-Machine-Id"))
        return name

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > MAX_BODY:
            raise ValueError("too large")
        obj = json.loads(self.rfile.read(n).decode("utf-8"))
        if not isinstance(obj, dict):
            raise ValueError("expected a JSON object")
        return obj

    def _route(self):
        u = urlparse(self.path)
        parts = [unquote(p) for p in u.path.split("/") if p]
        return parts, {k: v[0] for k, v in parse_qs(u.query).items()}

    # ---------------------------------------------------------------- GET
    def do_GET(self):
        parts, q = self._route()
        if not parts or parts == ["index.html"]:
            with open(os.path.join(HERE, "hub.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if parts == ["healthz"]:
            return self._json(200, {"ok": True, "version": HUB_VERSION})
        if parts[:2] != ["api", "v1"]:
            return self._json(404, {"error": "not found"})
        me = self._auth()
        if not me:
            return
        p = parts[2:]
        if p == ["index"]:
            combos = {cid: {"rev": rev, "sha": h} for cid, rev, h in STORE.q("SELECT id, rev, sha FROM combos")}
            profiles = {}
            for cid, h, rev in STORE.q("SELECT id, hash, rev FROM profiles"):
                profiles.setdefault(cid, {})[h] = rev
            return self._json(200, {"machine": me, "version": HUB_VERSION, "combos": combos, "profiles": profiles})
        if len(p) == 2 and p[0] == "combos":
            row = STORE.q("SELECT rev, data FROM combos WHERE id=?", (p[1],))
            if not row:
                return self._json(404, {"error": "no such combo"})
            return self._json(200, {"rev": row[0][0], "data": json.loads(row[0][1])})
        if len(p) == 3 and p[0] == "profiles":
            row = STORE.q("SELECT rev, data FROM profiles WHERE id=? AND hash=?", (p[1], p[2]))
            if not row:
                return self._json(404, {"error": "no such profile"})
            return self._json(200, {"rev": row[0][0], "data": json.loads(row[0][1])})
        if p == ["backups"]:
            m = q.get("machine") or me
            rows = STORE.q("SELECT machine, kind, id, updated FROM backups WHERE machine=? ORDER BY kind, id", (m,))
            return self._json(200, {"items": [{"machine": a, "kind": b, "id": c, "updated": d} for a, b, c, d in rows]})
        if len(p) == 3 and p[0] == "backups":
            m = q.get("machine") or me
            row = STORE.q("SELECT data, updated FROM backups WHERE machine=? AND kind=? AND id=?", (m, p[1], p[2]))
            if not row:
                return self._json(404, {"error": "no such backup"})
            return self._json(200, {"data": json.loads(row[0][0]), "updated": row[0][1]})
        if p == ["overview"]:
            return self._json(200, overview(me))
        if p == ["export"]:
            return self._json(200, export_all())
        return self._json(404, {"error": "not found"})

    # ---------------------------------------------------------------- writes
    def do_PUT(self):
        self._write("PUT")

    def do_POST(self):
        self._write("POST")

    def _write(self, verb):
        parts, q = self._route()
        if parts[:2] != ["api", "v1"]:
            return self._json(404, {"error": "not found"})
        me = self._auth()
        if not me:
            return
        p = parts[2:]
        try:
            body = self._body()
        except (ValueError, UnicodeDecodeError) as e:
            return self._json(400, {"error": "bad body: %s" % e})
        if verb == "PUT" and len(p) == 2 and p[0] == "combos" and valid_id(p[1]):
            if not isinstance(body.get("steps"), list) or not body.get("steps"):
                return self._json(400, {"error": "not a combo"})
            return self._json(200, {"rev": STORE.put_combo(p[1], body, me)})
        if verb == "POST" and len(p) == 3 and p[0] == "profiles" and valid_id(p[1]) and p[2]:
            rev, merged, added = STORE.merge_profile(p[1], p[2], body, me)
            return self._json(200, {"rev": rev, "data": merged, "added": added})
        if verb == "PUT" and len(p) == 3 and p[0] == "backups" and p[1] in BACKUP_KINDS and valid_id(p[2]):
            STORE.put_backup(me, p[1], p[2], body)
            return self._json(200, {"ok": True})
        return self._json(404, {"error": "not found"})


def overview(me):
    machines, names = [], {}
    for n, ls, ag, cr, mid in STORE.q("SELECT name, last_seen, agent, created, mod_id FROM machines ORDER BY name"):
        machines.append({"name": n, "last_seen": ls, "agent": ag, "created": cr})
        if mid:
            names[mid] = n
    combos = {}
    for cid, rev, data, updated, by in STORE.q("SELECT id, rev, data, updated, by FROM combos"):
        c = json.loads(data)
        combos[cid] = {"id": cid, "name": c.get("name") or cid, "fighter": c.get("fighter") or "",
                       "hash": str(c.get("hash", c.get("version", "0"))), "steps": len(c.get("steps") or []),
                       "notation": c.get("notation") or "", "updated": updated, "by": by, "profiles": []}
    for cid, h, rev, samples, origins, updated, by in STORE.q(
            "SELECT id, hash, rev, samples, origins, updated, by FROM profiles"):
        e = combos.setdefault(cid, {"id": cid, "name": cid, "fighter": "", "hash": None, "steps": 0, "profiles": []})
        named = [names.get(o, "earlier data" if o == "legacy" else o) for o in json.loads(origins or "[]")]
        e["profiles"].append({"hash": h, "rev": rev, "samples": samples, "origins": sorted(set(named)),
                              "updated": updated, "by": by, "current": h == e.get("hash")})
    backups = [{"machine": m, "kind": k, "count": n}
               for m, k, n in STORE.q("SELECT machine, kind, COUNT(*) FROM backups GROUP BY machine, kind")]
    return {"me": me, "version": HUB_VERSION, "machines": machines,
            "combos": sorted(combos.values(), key=lambda c: (c["fighter"], c["name"])), "backups": backups}


def export_all():
    return {
        "exported": int(time.time()), "version": HUB_VERSION,
        "combos": {cid: json.loads(d) for cid, d in STORE.q("SELECT id, data FROM combos")},
        "profiles": [json.loads(d) for (d,) in STORE.q("SELECT data FROM profiles")],
        "backups": [{"machine": m, "kind": k, "id": i, "data": json.loads(d)}
                    for m, k, i, d in STORE.q("SELECT machine, kind, id, data FROM backups")],
    }


def main():
    global STORE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["serve", "add-machine", "list-machines", "remove-machine", "export"])
    ap.add_argument("name", nargs="?", help="machine name, or folder for export")
    ap.add_argument("--data", default=os.environ.get("COMBOLAB_HUB_DATA", os.path.join(HERE, "data")),
                    help="data folder (default ./data or $COMBOLAB_HUB_DATA)")
    ap.add_argument("--host", default=os.environ.get("COMBOLAB_HUB_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("COMBOLAB_HUB_PORT", "8770")))
    a = ap.parse_args()
    STORE = Store(os.path.join(a.data, "hub.sqlite3"))
    if a.command == "add-machine":
        if not a.name or not valid_id(a.name):
            ap.error("add-machine needs a name (letters, digits, - _ .)")
        tok = STORE.add_machine(a.name)
        print("Machine '%s' added. Its token (shown once; adding the same name again replaces it):\n\n  %s\n" % (a.name, tok))
        print("On that PC, in reframework\\data\\ComboLab:\n  run_sync.bat setup https://YOUR-HUB %s" % tok)
        return
    if a.command == "list-machines":
        for n, ls, ag in STORE.q("SELECT name, last_seen, agent FROM machines ORDER BY name"):
            print("%-20s last seen %s  %s" % (n, time.strftime("%Y-%m-%d %H:%M", time.localtime(ls)) if ls else "never", ag or ""))
        return
    if a.command == "remove-machine":
        STORE.q("DELETE FROM machines WHERE name=?", (a.name,))
        print("Removed %s (its samples stay in the merged profiles)." % a.name)
        return
    if a.command == "export":
        out = os.path.abspath(a.name or "combolab-export")
        data = export_all()
        for cid, c in data["combos"].items():
            os.makedirs(os.path.join(out, "combos"), exist_ok=True)
            with open(os.path.join(out, "combos", cid + ".json"), "w", encoding="utf-8") as f:
                json.dump(c, f, indent=1)
        for p in data["profiles"]:
            os.makedirs(os.path.join(out, "profiles"), exist_ok=True)
            with open(os.path.join(out, "profiles", "%s@%s.json" % (p["combo_id"], p["combo_hash"])), "w", encoding="utf-8") as f:
                json.dump(p, f)
        for b in data["backups"]:
            d = os.path.join(out, "backups", b["machine"], b["kind"])
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, b["id"] + ".json"), "w", encoding="utf-8") as f:
                json.dump(b["data"], f)
        print("Exported to %s" % out)
        return
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    n = len(STORE.q("SELECT name FROM machines"))
    print("ComboLab hub %s on http://%s:%d  (data: %s, %d machine%s)" % (
        HUB_VERSION, a.host, a.port, os.path.abspath(a.data), n, "" if n == 1 else "s"))
    if n == 0:
        print("No machines yet: python combolab_hub.py add-machine <name>")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
