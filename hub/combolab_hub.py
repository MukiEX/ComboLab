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
import base64
import getpass
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
import combolab_update  # noqa: E402
sys.path.insert(0, HERE)
import hub_auth  # noqa: E402

HUB_VERSION = "1.14.0"
MAX_BODY = 16 * 1024 * 1024
BACKUP_KINDS = ("sessions", "bot")
EXPORT_NAMESPACE = "combolab-export"
NONCE_TTL = 120


# Program files the hub hands out to PCs updating themselves: the copy it was
# built from (Docker: /app/client), or the repo it runs from.
def client_dir():
    for d in (os.environ.get("COMBOLAB_CLIENT_DIR"), os.path.join(HERE, "client"), os.path.join(HERE, "..")):
        if d and os.path.isfile(os.path.join(d, "reframework", "autorun", "ComboLab.lua")):
            return os.path.abspath(d)
    return None
SESSION_COOKIE = "combolab_admin"
SESSION_TTL = 12 * 3600
MAX_PENDING_KEYS = 50


def export_message(nonce):
    """What an exporting viewer signs (raw Ed25519, or via ssh-keygen -Y sign)."""
    return ("combolab-export\n%s\n" % nonce).encode("utf-8")


def clean_name(s):
    s = " ".join(str(s or "").split())[:40]
    return "".join(c for c in s if c.isprintable())


class Expiring:
    """Small in-memory token store (admin sessions, export challenges)."""

    def __init__(self, ttl, cap):
        self.ttl, self.cap, self.items, self.lock = ttl, cap, {}, threading.Lock()

    def _purge(self, now):
        for k in [k for k, t in self.items.items() if t < now]:
            del self.items[k]

    def new(self):
        tok = secrets.token_urlsafe(24)
        now = time.time()
        with self.lock:
            self._purge(now)
            if len(self.items) >= self.cap:
                del self.items[min(self.items, key=self.items.get)]
            self.items[tok] = now + self.ttl
        return tok

    def valid(self, tok):
        with self.lock:
            return bool(tok) and self.items.get(tok, 0) > time.time()

    def take(self, tok):
        with self.lock:
            ok = bool(tok) and self.items.get(tok, 0) > time.time()
            self.items.pop(tok, None)
            return ok

    def drop(self, tok):
        with self.lock:
            self.items.pop(tok, None)

    def clear(self):
        with self.lock:
            self.items.clear()


class RateLimit:
    def __init__(self, limit, window, block):
        self.limit, self.window, self.block = limit, window, block
        self.hits, self.lock = {}, threading.Lock()

    def _recent(self, ip, now):
        h = [t for t in self.hits.get(ip, []) if t > now - self.window]
        self.hits[ip] = h
        return h

    def blocked(self, ip):
        now = time.time()
        with self.lock:
            h = self._recent(ip, now)
            if len(h) >= self.limit:
                return int(h[-1] + self.block - now) if h[-1] + self.block > now else 0
            return 0

    def fail(self, ip):
        with self.lock:
            self.hits.setdefault(ip, []).append(time.time())

    def clear(self, ip):
        with self.lock:
            self.hits.pop(ip, None)

    def allow(self, ip):
        if self.blocked(ip):
            return False
        self.fail(ip)
        return True


SESSIONS = Expiring(SESSION_TTL, 50)
NONCES = Expiring(NONCE_TTL, 500)
LOGIN_LIMIT = RateLimit(5, 900, 900)       # 5 wrong passwords in 15 min -> 15 min lockout
REQUEST_LIMIT = RateLimit(10, 3600, 3600)  # 10 key / join requests per hour per address


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
            CREATE TABLE IF NOT EXISTS machines (id TEXT PRIMARY KEY, name TEXT UNIQUE, token_sha TEXT UNIQUE,
                created INTEGER, last_seen INTEGER, agent TEXT, addr TEXT, mod_id TEXT);
            CREATE TABLE IF NOT EXISTS combos (id TEXT PRIMARY KEY, rev INTEGER, sha TEXT, data TEXT,
                updated INTEGER, by TEXT);
            CREATE TABLE IF NOT EXISTS profiles (id TEXT, hash TEXT, rev INTEGER, data TEXT, samples INTEGER,
                origins TEXT, updated INTEGER, by TEXT, PRIMARY KEY (id, hash));
            CREATE TABLE IF NOT EXISTS backups (machine TEXT, kind TEXT, id TEXT, data TEXT, sha TEXT,
                updated INTEGER, PRIMARY KEY (machine, kind, id));
            CREATE TABLE IF NOT EXISTS viewer_keys (key TEXT PRIMARY KEY, name TEXT, added INTEGER, last_export INTEGER);
            CREATE TABLE IF NOT EXISTS key_requests (key TEXT PRIMARY KEY, name TEXT, requested INTEGER, addr TEXT);
            CREATE TABLE IF NOT EXISTS machine_requests (name TEXT PRIMARY KEY, token_sha TEXT UNIQUE, requested INTEGER, addr TEXT);
        """)
        self._migrate_machine_ids()

    def _migrate_machine_ids(self):
        """Hubs before 1.12 keyed machines by name. Give each one a permanent
        hidden id and point combos / profiles / backups at it."""
        cols = [r[1] for r in self.db.execute("PRAGMA table_info(machines)").fetchall()]
        if "id" in cols:
            return
        with self.lock:
            self.db.execute("BEGIN")
            self.db.execute("ALTER TABLE machines RENAME TO machines_old")
            self.db.execute("""CREATE TABLE machines (id TEXT PRIMARY KEY, name TEXT UNIQUE, token_sha TEXT UNIQUE,
                created INTEGER, last_seen INTEGER, agent TEXT, addr TEXT, mod_id TEXT)""")
            for name, tsha, cr, ls, ag, ad, mid in self.db.execute(
                    "SELECT name, token_sha, created, last_seen, agent, addr, mod_id FROM machines_old").fetchall():
                new_id = secrets.token_hex(8)
                self.db.execute("INSERT INTO machines (id, name, token_sha, created, last_seen, agent, addr, mod_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                (new_id, name, tsha, cr, ls, ag, ad, mid))
                self.db.execute("UPDATE combos SET by=? WHERE by=?", (new_id, name))
                self.db.execute("UPDATE profiles SET by=? WHERE by=?", (new_id, name))
                self.db.execute("UPDATE backups SET machine=? WHERE machine=?", (new_id, name))
            self.db.execute("DROP TABLE machines_old")
            self.db.execute("COMMIT")

    def q(self, sql, args=()):
        with self.lock:
            return self.db.execute(sql, args).fetchall()

    def _next_rev(self):
        row = self.db.execute("SELECT v FROM meta WHERE k='rev'").fetchone()
        rev = int(row[0]) + 1 if row else 1
        self.db.execute("INSERT OR REPLACE INTO meta (k, v) VALUES ('rev', ?)", (str(rev),))
        return rev

    # ---------------------------------------------------------------- settings
    def meta(self, k):
        row = self.q("SELECT v FROM meta WHERE k=?", (k,))
        return row[0][0] if row else None

    def set_meta(self, k, v):
        self.q("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", (k, v))

    # ---------------------------------------------------------------- viewer keys
    @staticmethod
    def _k(raw):
        return hub_auth.format_public_key(raw)

    def key_name(self, raw):
        row = self.q("SELECT name FROM viewer_keys WHERE key=?", (self._k(raw),))
        return row[0][0] if row else None

    def key_used(self, raw):
        self.q("UPDATE viewer_keys SET last_export=? WHERE key=?", (int(time.time()), self._k(raw)))

    def allow_key(self, raw, name):
        self.q("INSERT OR REPLACE INTO viewer_keys (key, name, added) VALUES (?, ?, ?)", (self._k(raw), name, int(time.time())))
        self.q("DELETE FROM key_requests WHERE key=?", (self._k(raw),))

    def remove_key(self, raw):
        self.q("DELETE FROM viewer_keys WHERE key=?", (self._k(raw),))

    def request_key(self, raw, name, addr):
        if self.q("SELECT 1 FROM key_requests WHERE key=?", (self._k(raw),)):
            self.q("UPDATE key_requests SET name=?, requested=?, addr=? WHERE key=?", (name, int(time.time()), addr, self._k(raw)))
            return True
        if self.q("SELECT COUNT(*) FROM key_requests")[0][0] >= MAX_PENDING_KEYS:
            return False
        self.q("INSERT INTO key_requests (key, name, requested, addr) VALUES (?, ?, ?, ?)", (self._k(raw), name, int(time.time()), addr))
        return True

    def request_name(self, raw):
        row = self.q("SELECT name FROM key_requests WHERE key=?", (self._k(raw),))
        return row[0][0] if row else None

    def drop_request(self, raw):
        self.q("DELETE FROM key_requests WHERE key=?", (self._k(raw),))

    # ---------------------------------------------------------------- machines
    # Each machine has a permanent hidden id; its name is only a label it can change.
    def add_machine(self, name):
        """New machine, or a new token for an existing one (same id). Returns the token."""
        tok = secrets.token_urlsafe(32)
        with self.lock:
            row = self.db.execute("SELECT id FROM machines WHERE name=?", (name,)).fetchone()
            if row:
                self.db.execute("UPDATE machines SET token_sha=? WHERE id=?", (token_hash(tok), row[0]))
            else:
                self.db.execute("INSERT INTO machines (id, name, token_sha, created) VALUES (?, ?, ?, ?)",
                                (secrets.token_hex(8), name, token_hash(tok), int(time.time())))
        return tok

    def machine_for(self, tok):
        """Token -> machine id (or None)."""
        if not tok:
            return None
        h = token_hash(tok)
        for mid, th in self.q("SELECT id, token_sha FROM machines"):
            if hmac.compare_digest(th, h):
                return mid
        return None

    def name_of(self, mid):
        row = self.q("SELECT name FROM machines WHERE id=?", (mid,))
        return row[0][0] if row else None

    def id_of(self, name_or_id):
        row = self.q("SELECT id FROM machines WHERE name=? OR id=?", (name_or_id, name_or_id))
        return row[0][0] if row else None

    def names(self):
        return {mid: n for mid, n in self.q("SELECT id, name FROM machines")}

    # ---------------------------------------------------------------- PCs asking to join
    def request_machine(self, name, token_sha, addr):
        """A PC asks to sync under `name`, proving later that it holds the token
        whose hash it sent. Returns "pending", "taken" or "full"."""
        if self.q("SELECT 1 FROM machines WHERE name=?", (name,)):
            return "taken"
        self.q("DELETE FROM machine_requests WHERE token_sha=? AND name<>?", (token_sha, name))
        if not self.q("SELECT 1 FROM machine_requests WHERE name=?", (name,)) and \
                self.q("SELECT COUNT(*) FROM machine_requests")[0][0] >= MAX_PENDING_KEYS:
            return "full"
        self.q("INSERT OR REPLACE INTO machine_requests (name, token_sha, requested, addr) VALUES (?, ?, ?, ?)",
               (name, token_sha, int(time.time()), addr))
        return "pending"

    def pending_machine(self, tok):
        if not tok:
            return None
        row = self.q("SELECT name FROM machine_requests WHERE token_sha=?", (token_hash(tok),))
        return row[0][0] if row else None

    def approve_machine(self, name):
        row = self.q("SELECT token_sha FROM machine_requests WHERE name=?", (name,))
        if not row or self.q("SELECT 1 FROM machines WHERE name=?", (name,)):
            return False
        with self.lock:
            self.db.execute("INSERT INTO machines (id, name, token_sha, created) VALUES (?, ?, ?, ?)",
                            (secrets.token_hex(8), name, row[0][0], int(time.time())))
            self.db.execute("DELETE FROM machine_requests WHERE name=?", (name,))
        return True

    def rename_machine(self, mid, new):
        """Only the label changes; everything the hub records points at the id."""
        row = self.q("SELECT id FROM machines WHERE name=?", (new,))
        if (row and row[0][0] != mid) or self.q("SELECT 1 FROM machine_requests WHERE name=?", (new,)):
            return False
        self.q("UPDATE machines SET name=? WHERE id=?", (new, mid))
        return True

    def remove_machine(self, name_or_id):
        mid = self.id_of(name_or_id)
        if mid:
            self.q("DELETE FROM machines WHERE id=?", (mid,))
        return mid

    def seen(self, mid, agent, addr, mod_id=None):
        with self.lock:
            self.db.execute("UPDATE machines SET last_seen=?, agent=?, addr=? WHERE id=?",
                            (int(time.time()), agent, addr, mid))
            if mod_id and valid_id(mod_id):
                self.db.execute("UPDATE machines SET mod_id=? WHERE id=?", (mod_id, mid))

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

    def _send(self, code, body=b"", ctype="application/json", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (headers or []):
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj, headers=None):
        self._send(code, json.dumps(obj).encode("utf-8"), headers=headers)

    # ---------------------------------------------------------------- who is asking
    def _machine(self):
        """Sync agents: per-machine bearer token."""
        a = self.headers.get("Authorization", "")
        tok = a[7:].strip() if a.lower().startswith("bearer ") else ""
        mid = STORE.machine_for(tok)
        if not mid:
            pending = STORE.pending_machine(tok)
            if pending:
                self._json(401, {"error": "waiting for the hub's admin to approve '%s'" % pending, "pending": pending})
                return None
            time.sleep(0.5)  # slow down guessing
            self._json(401, {"error": "unknown or missing token"})
            return None
        ua = self.headers.get("User-Agent", "")
        if ua.startswith("ComboLab-sync/"):  # only count real syncs as activity
            STORE.seen(mid, ua, self.client_ip(), self.headers.get("X-ComboLab-Machine-Id"))
        return mid

    def _cookie(self, name):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return None

    def _admin(self, write=False):
        """Admin web page: session cookie from the password login. Writes also
        need the X-ComboLab-Admin header, which other sites can't send."""
        if write and self.headers.get("X-ComboLab-Admin") != "1":
            self._json(403, {"error": "missing admin header"})
            return False
        if not SESSIONS.valid(self._cookie(SESSION_COOKIE)):
            self._json(401, {"error": "sign in as admin"})
            return False
        return True

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
        if not parts or parts in (["index.html"], ["admin"]):
            with open(os.path.join(HERE, "hub.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8", headers=[
                    ("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'")])
        if parts == ["healthz"]:
            return self._json(200, {"ok": True, "version": HUB_VERSION})
        if parts[:2] != ["api", "v1"]:
            return self._json(404, {"error": "not found"})
        p = parts[2:]
        # public
        if p == ["overview"]:
            return self._json(200, overview())
        if p[:1] == ["client"]:
            root = client_dir()
            if not root:
                return self._json(404, {"error": "this hub has no client files to hand out"})
            if p == ["client", "manifest"]:
                return self._json(200, combolab_update.build_manifest(root))
            if p == ["client", "file"]:
                rel = q.get("path", "")
                if not combolab_update.is_client_path(rel):
                    return self._json(404, {"error": "not a client file"})
                full = os.path.join(root, *rel.split("/"))
                if not os.path.isfile(full):
                    return self._json(404, {"error": "missing"})
                with open(full, "rb") as f:
                    return self._send(200, f.read(), "application/octet-stream")
            return self._json(404, {"error": "not found"})
        if p == ["challenge"]:
            return self._json(200, {"nonce": NONCES.new(), "ttl": NONCE_TTL, "namespace": EXPORT_NAMESPACE})
        # admin
        if p == ["admin", "state"]:
            if not self._admin():
                return
            return self._json(200, admin_state())
        # sync agents
        me = self._machine()
        if not me:
            return
        if p == ["index"]:
            combos = {cid: {"rev": rev, "sha": h} for cid, rev, h in STORE.q("SELECT id, rev, sha FROM combos")}
            profiles = {}
            for cid, h, rev in STORE.q("SELECT id, hash, rev FROM profiles"):
                profiles.setdefault(cid, {})[h] = rev
            return self._json(200, {"machine": STORE.name_of(me), "version": HUB_VERSION, "combos": combos, "profiles": profiles})
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
            m = STORE.id_of(q["machine"]) if q.get("machine") else me
            rows = STORE.q("SELECT kind, id, updated FROM backups WHERE machine=? ORDER BY kind, id", (m,))
            nm = STORE.name_of(m) or m
            return self._json(200, {"items": [{"machine": nm, "kind": b, "id": c, "updated": d} for b, c, d in rows]})
        if len(p) == 3 and p[0] == "backups":
            m = STORE.id_of(q["machine"]) if q.get("machine") else me
            row = STORE.q("SELECT data, updated FROM backups WHERE machine=? AND kind=? AND id=?", (m, p[1], p[2]))
            if not row:
                return self._json(404, {"error": "no such backup"})
            return self._json(200, {"data": json.loads(row[0][0]), "updated": row[0][1]})
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
        p = parts[2:]
        try:
            body = self._body()
        except (ValueError, UnicodeDecodeError) as e:
            return self._json(400, {"error": "bad body: %s" % e})
        if verb == "POST" and p == ["export"]:
            return self._export(body)
        if verb == "POST" and p == ["key-requests"]:
            return self._key_request(body)
        if verb == "POST" and p == ["join"]:
            name, tsha = str(body.get("name") or ""), str(body.get("token_sha") or "").lower()
            if not valid_id(name) or len(name) > 60:
                return self._json(400, {"error": "names use letters, digits, - _ . (up to 60)"})
            if len(tsha) != 64 or any(c not in "0123456789abcdef" for c in tsha):
                return self._json(400, {"error": "bad token hash"})
            if not REQUEST_LIMIT.allow(self.client_ip()):
                return self._json(429, {"error": "too many requests; try later"})
            r = STORE.request_machine(name, tsha, self.client_ip())
            if r == "taken":
                return self._json(409, {"error": "the hub already has a machine called '%s'; pick another name" % name})
            if r == "full":
                return self._json(429, {"error": "the hub has too many pending requests"})
            return self._json(200, {"status": "pending", "name": name})
        if p[:1] == ["admin"] and verb == "POST":
            return self._admin_post(p[1:], body)
        me = self._machine()
        if not me:
            return
        if verb == "POST" and p == ["rename"]:
            new = str(body.get("name") or "")
            if not valid_id(new) or len(new) > 60:
                return self._json(400, {"error": "names use letters, digits, - _ . (up to 60)"})
            if not STORE.rename_machine(me, new):
                return self._json(409, {"error": "the hub already has a machine called '%s'" % new})
            return self._json(200, {"machine": new})
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

    # ---------------------------------------------------------------- export (signed)
    def _export(self, body):
        """Export needs a signature over a fresh challenge from an approved key:
        {pubkey, nonce, sig, format: "raw" (browser) | "sshsig" (ssh-keygen -Y sign)}."""
        try:
            raw = hub_auth.parse_public_key(body.get("pubkey", ""))
        except ValueError as e:
            return self._json(400, {"error": str(e)})
        nonce = str(body.get("nonce") or "")
        if not NONCES.take(nonce):
            return self._json(400, {"error": "challenge expired or already used; try again"})
        msg = export_message(nonce)
        fmt = body.get("format", "raw")
        try:
            if fmt == "sshsig":
                ok = hub_auth.verify_sshsig(str(body.get("sig") or ""), raw, msg, EXPORT_NAMESPACE)
            else:
                ok = hub_auth.ed25519_verify(raw, msg, base64.b64decode(str(body.get("sig") or ""), validate=True))
        except (ValueError, TypeError):
            ok = False
        if not ok:
            time.sleep(0.5)
            return self._json(403, {"error": "signature doesn't check out"})
        name = STORE.key_name(raw)
        if not name:
            return self._json(403, {"error": "this key isn't approved on the hub yet", "fingerprint": hub_auth.fingerprint(raw)})
        STORE.key_used(raw)
        return self._json(200, export_all())

    def _key_request(self, body):
        try:
            raw = hub_auth.parse_public_key(body.get("pubkey", ""))
        except ValueError as e:
            return self._json(400, {"error": str(e)})
        name = clean_name(body.get("name"))
        if not name:
            return self._json(400, {"error": "give your key a name (who or which device it is)"})
        if STORE.key_name(raw):
            return self._json(200, {"status": "approved", "fingerprint": hub_auth.fingerprint(raw)})
        if not REQUEST_LIMIT.allow(self.client_ip()):
            return self._json(429, {"error": "too many requests; try later"})
        if not STORE.request_key(raw, name, self.client_ip()):
            return self._json(429, {"error": "the hub has too many pending requests"})
        return self._json(200, {"status": "pending", "fingerprint": hub_auth.fingerprint(raw)})

    # ---------------------------------------------------------------- admin
    def _admin_post(self, p, body):
        if p == ["login"]:
            ip = self.client_ip()
            wait = LOGIN_LIMIT.blocked(ip)
            if wait:
                return self._json(429, {"error": "too many attempts; wait %d minutes" % max(1, wait // 60)})
            stored = STORE.meta("admin_pw")
            if not stored:
                return self._json(409, {"error": "no admin password set; on the server run: combolab_hub.py set-admin-password"})
            if not hub_auth.check_password(str(body.get("password") or ""), stored):
                LOGIN_LIMIT.fail(ip)
                time.sleep(1.0)
                return self._json(401, {"error": "wrong password"})
            LOGIN_LIMIT.clear(ip)
            tok = SESSIONS.new()
            secure = "; Secure" if self.headers.get("X-Forwarded-Proto", "") == "https" else ""
            return self._json(200, {"ok": True}, headers=[("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=%d%s"
                                                            % (SESSION_COOKIE, tok, SESSION_TTL, secure))])
        if p == ["logout"]:
            SESSIONS.drop(self._cookie(SESSION_COOKIE))
            return self._json(200, {"ok": True}, headers=[("Set-Cookie", "%s=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" % SESSION_COOKIE)])
        if not self._admin(write=True):
            return
        action = body.get("action")
        if p == ["keys"]:
            try:
                raw = hub_auth.parse_public_key(body.get("pubkey", ""))
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            if action in ("approve", "add"):
                name = clean_name(body.get("name")) or STORE.request_name(raw)
                if not name:
                    return self._json(400, {"error": "name the key"})
                STORE.allow_key(raw, name)
            elif action == "remove":
                STORE.remove_key(raw)
            elif action == "reject":
                STORE.drop_request(raw)
            else:
                return self._json(400, {"error": "unknown action"})
            return self._json(200, admin_state())
        if p == ["machines"]:
            name = str(body.get("name") or "")
            if not valid_id(name):
                return self._json(400, {"error": "machine names use letters, digits, - _ ."})
            if action == "add":
                tok = STORE.add_machine(name)
                st = admin_state()
                st["new_token"] = {"name": name, "token": tok}
                return self._json(200, st)
            if action == "remove":
                STORE.remove_machine(str(body.get("id") or name))
                return self._json(200, admin_state())
            if action == "approve":
                if not STORE.approve_machine(name):
                    return self._json(404, {"error": "no request from '%s'" % name})
                return self._json(200, admin_state())
            if action == "reject":
                STORE.q("DELETE FROM machine_requests WHERE name=?", (name,))
                return self._json(200, admin_state())
            return self._json(400, {"error": "unknown action"})
        if p == ["password"]:
            if not hub_auth.check_password(str(body.get("current") or ""), STORE.meta("admin_pw") or ""):
                time.sleep(1.0)
                return self._json(401, {"error": "current password is wrong"})
            new = str(body.get("new") or "")
            if len(new) < 10:
                return self._json(400, {"error": "use at least 10 characters"})
            STORE.set_meta("admin_pw", hub_auth.hash_password(new))
            SESSIONS.clear()
            return self._json(200, {"ok": True})
        return self._json(404, {"error": "not found"})


def overview():
    machines, names = [], {}
    who = STORE.names()
    by_name = lambda b: who.get(b, "a removed machine" if b else None)
    for n, ls, ag, cr, mod in STORE.q("SELECT name, last_seen, agent, created, mod_id FROM machines ORDER BY name"):
        machines.append({"name": n, "last_seen": ls, "agent": ag, "created": cr})
        if mod:
            names[mod] = n
    combos = {}
    for cid, rev, data, updated, by in STORE.q("SELECT id, rev, data, updated, by FROM combos"):
        c = json.loads(data)
        combos[cid] = {"id": cid, "name": c.get("name") or cid, "fighter": c.get("fighter") or "",
                       "hash": str(c.get("hash", c.get("version", "0"))), "steps": len(c.get("steps") or []),
                       "notation": c.get("notation") or "", "updated": updated, "by": by_name(by), "profiles": []}
    for cid, h, rev, samples, origins, updated, by in STORE.q(
            "SELECT id, hash, rev, samples, origins, updated, by FROM profiles"):
        e = combos.setdefault(cid, {"id": cid, "name": cid, "fighter": "", "hash": None, "steps": 0, "profiles": []})
        named = [names.get(o, "earlier data" if o == "legacy" else o) for o in json.loads(origins or "[]")]
        e["profiles"].append({"hash": h, "rev": rev, "samples": samples, "origins": sorted(set(named)),
                              "updated": updated, "by": by_name(by), "current": h == e.get("hash")})
    backups = [{"machine": by_name(m), "kind": k, "count": n}
               for m, k, n in STORE.q("SELECT machine, kind, COUNT(*) FROM backups GROUP BY machine, kind")]
    return {"version": HUB_VERSION, "machines": machines,
            "combos": sorted(combos.values(), key=lambda c: (c["fighter"], c["name"])), "backups": backups}


def admin_state():
    def fp(k):
        try:
            return hub_auth.fingerprint(hub_auth.parse_public_key(k))
        except ValueError:
            return "?"
    return {
        "password_set": bool(STORE.meta("admin_pw")),
        "keys": [{"key": k, "name": n, "fingerprint": fp(k), "added": a, "last_export": le}
                 for k, n, a, le in STORE.q("SELECT key, name, added, last_export FROM viewer_keys ORDER BY name")],
        "requests": [{"key": k, "name": n, "fingerprint": fp(k), "requested": r, "addr": ad}
                     for k, n, r, ad in STORE.q("SELECT key, name, requested, addr FROM key_requests ORDER BY requested DESC")],
        "machines": [{"id": mid, "name": n, "last_seen": ls, "agent": ag, "created": cr, "addr": ad}
                     for mid, n, ls, ag, cr, ad in STORE.q("SELECT id, name, last_seen, agent, created, addr FROM machines ORDER BY name")],
        "machine_requests": [{"name": n, "requested": r, "addr": ad}
                             for n, r, ad in STORE.q("SELECT name, requested, addr FROM machine_requests ORDER BY requested DESC")],
    }


def export_all():
    return {
        "exported": int(time.time()), "version": HUB_VERSION,
        "combos": {cid: json.loads(d) for cid, d in STORE.q("SELECT id, data FROM combos")},
        "profiles": [json.loads(d) for (d,) in STORE.q("SELECT data FROM profiles")],
        "backups": [{"machine": STORE.name_of(m) or m, "kind": k, "id": i, "data": json.loads(d)}
                    for m, k, i, d in STORE.q("SELECT machine, kind, id, data FROM backups")],
    }


def main():
    global STORE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["serve", "add-machine", "list-machines", "remove-machine", "export",
                                        "set-admin-password", "allow-key", "list-keys", "remove-key"])
    ap.add_argument("name", nargs="?", help="machine or key name, or folder for export")
    ap.add_argument("key", nargs="?", help="allow-key / remove-key: the ssh-ed25519 public key")
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
    if a.command == "set-admin-password":
        pw = os.environ.get("COMBOLAB_HUB_ADMIN_PASSWORD")
        if not pw:
            pw = getpass.getpass("New admin password: ")
            if pw != getpass.getpass("Again: "):
                sys.exit("Passwords don't match.")
        if len(pw) < 10:
            sys.exit("Use at least 10 characters.")
        STORE.set_meta("admin_pw", hub_auth.hash_password(pw))
        print("Admin password set. Sign in at https://YOUR-HUB/admin")
        return
    if a.command in ("allow-key", "remove-key"):
        try:
            raw = hub_auth.parse_public_key(a.key or "")
        except ValueError as e:
            sys.exit("%s (quote the whole 'ssh-ed25519 AAAA...' line)" % e)
        if a.command == "allow-key":
            STORE.allow_key(raw, clean_name(a.name) or "key")
            print("Allowed %s (%s) to export." % (a.name, hub_auth.fingerprint(raw)))
        else:
            STORE.remove_key(raw)
            print("Removed %s." % hub_auth.fingerprint(raw))
        return
    if a.command == "list-keys":
        st = admin_state()
        for k in st["keys"]:
            print("allowed  %-20s %s" % (k["name"], k["fingerprint"]))
        for k in st["requests"]:
            print("pending  %-20s %s  from %s" % (k["name"], k["fingerprint"], k["addr"]))
        return
    if a.command == "list-machines":
        for n, ls, ag in STORE.q("SELECT name, last_seen, agent FROM machines ORDER BY name"):
            print("%-20s last seen %s  %s" % (n, time.strftime("%Y-%m-%d %H:%M", time.localtime(ls)) if ls else "never", ag or ""))
        return
    if a.command == "remove-machine":
        if not STORE.remove_machine(a.name or ""):
            sys.exit("No machine called %s." % a.name)
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
        print("No machines yet: python combolab_hub.py add-machine <name> (or in the admin page)")
    if not STORE.meta("admin_pw"):
        print("No admin password yet: python combolab_hub.py set-admin-password")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
