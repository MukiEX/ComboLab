#!/usr/bin/env python3
"""ComboLab sync agent: keeps this PC's combos and timing profiles in step with
a ComboLab hub (combolab_hub.py) so several machines build one profile per combo.

Set up once with the URL and the token the hub gave this machine:

    python combolab_sync.py setup https://combolab.example.com <token>

After that, combolab_server.py (run_server.bat) runs the agent in the
background whenever sync.json exists. It can also run on its own:

    python combolab_sync.py            # loop
    python combolab_sync.py --once     # one pass
    python combolab_sync.py restore    # fetch this machine's backed-up sessions

What moves where:
  combos/      pushed when edited here, pulled when edited elsewhere
  profiles/    pushed to the hub, which merges every machine's samples; the
               merged copy comes back as shared/<id>.json and the game merges
               it into profiles/ itself (it is the only writer of profiles/)
  sessions/, bot/   backed up to the hub per machine (restore brings them back)
Standard library only (Python 3.8+).
"""
import argparse
import hashlib
import json
import os
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import combolab_merge  # noqa: E402

AGENT_VERSION = "1.11.0"


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha(obj):
    return hashlib.sha256(canon(obj)).hexdigest()


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=indent)
    os.replace(tmp, path)


def combo_hash(c):
    # same as normalize_combo in ComboLab.lua
    h = c.get("hash")
    if h is None:
        h = c.get("version")
    if h is None:
        return "0"
    if isinstance(h, float) and h.is_integer():
        h = int(h)
    return str(h)


class HubError(Exception):
    def __init__(self, msg, code=None, data=None):
        Exception.__init__(self, msg)
        self.code, self.data = code, data or {}


def config_path(root):
    return os.path.join(root, "sync.json")


def disconnect(root):
    """Forget the hub: sync settings, sync state and status. Merged profiles the
    game already took in stay in profiles/."""
    for p in (config_path(root), os.path.join(root, "shared", "_sync_state.json"), os.path.join(root, "shared", "_status.json")):
        try:
            os.remove(p)
        except OSError:
            pass


def save_config(root, hub, token, name=None, interval=20, joined=False):
    old = {}
    if os.path.isfile(config_path(root)):
        try:
            old = read_json(config_path(root))
        except (ValueError, OSError):
            old = {}
    if old.get("hub") and old.get("hub").rstrip("/") != hub.rstrip("/"):
        # a different hub: start its sync state fresh
        for p in (os.path.join(root, "shared", "_sync_state.json"), os.path.join(root, "shared", "_status.json")):
            try:
                os.remove(p)
            except OSError:
                pass
    write_json(config_path(root), {"hub": hub.rstrip("/"), "token": token, "name": name, "interval": interval, "joined": joined}, indent=1)


class Agent:
    def __init__(self, root=HERE, hub=None, token=None, interval=20, log=print):
        self.root = root
        cfg = {}
        p = os.path.join(root, "sync.json")
        if os.path.isfile(p):
            cfg = read_json(p)
        self.hub = (hub or cfg.get("hub") or "").rstrip("/")
        self.token = token or cfg.get("token") or ""
        self.interval = max(5, int(cfg.get("interval", interval)))
        self.log = log
        self.state_path = os.path.join(root, "shared", "_sync_state.json")
        self.status_path = os.path.join(root, "shared", "_status.json")
        self.ctx = ssl.create_default_context()
        self.stop = threading.Event()
        self.wake = threading.Event()
        self.name = cfg.get("name")
        self.state = {"combos": {}, "profiles": {}, "backups": {}, "combos_rev": 0}
        if os.path.isfile(self.state_path):
            try:
                self.state.update(read_json(self.state_path))
            except (ValueError, OSError):
                pass
        self.machine = None
        self.mod_id = None
        try:  # the id the game tags this PC's samples with (config.json)
            self.mod_id = read_json(os.path.join(root, "config.json")).get("machine_id")
        except (ValueError, OSError, AttributeError):
            pass

    # ---------------------------------------------------------------- http
    def call(self, method, path, body=None):
        url = self.hub + path
        data = canon(body) if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("User-Agent", "ComboLab-sync/" + AGENT_VERSION)
        if self.mod_id:
            req.add_header("X-ComboLab-Machine-Id", self.mod_id)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30, context=self.ctx if url.startswith("https") else None) as r:
                return json.loads(r.read().decode("utf-8") or "null")
        except urllib.error.HTTPError as e:
            body_text = ""
            try:
                body_text = e.read().decode("utf-8")
                msg = json.loads(body_text).get("error")
            except Exception:
                msg = None
            data = {}
            try:
                data = json.loads(body_text) if body_text else {}
            except ValueError:
                pass
            if e.code == 401 and data.get("pending"):
                raise HubError("waiting for the hub's admin to approve '%s'" % data["pending"], 401, data)
            raise HubError("%s %s: HTTP %d %s" % (method, path, e.code, msg or e.reason), e.code, data)
        except (urllib.error.URLError, OSError) as e:
            raise HubError("can't reach %s (%s)" % (self.hub, getattr(e, "reason", e)))

    @staticmethod
    def q(s):
        return urllib.parse.quote(str(s), safe="")

    # ---------------------------------------------------------------- files
    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def local_json(self, d):
        out = {}
        folder = self.path(d)
        if not os.path.isdir(folder):
            return out
        for n in sorted(os.listdir(folder)):
            if n.endswith(".json"):
                try:
                    out[n[:-5]] = read_json(os.path.join(folder, n))
                except (ValueError, OSError):
                    out[n[:-5]] = None  # being written; try next pass
        return out

    def save_state(self):
        write_json(self.state_path, self.state, indent=1)

    # ---------------------------------------------------------------- one pass
    def sync_once(self):
        if not self.hub or not self.token:
            raise HubError("not set up: run  python combolab_sync.py setup <hub url> <token>")
        idx = self.call("GET", "/api/v1/index")
        self.machine = idx.get("machine")
        stats = {"pushed": 0, "pulled": 0}
        local_combos = self.sync_combos(idx, stats)
        shared = self.sync_profiles(idx, local_combos, stats)
        self.sync_backups(stats)
        self.save_state()
        self.write_status(True, None, shared, stats)
        return stats

    def sync_combos(self, idx, stats):
        hub = idx.get("combos", {})
        st = self.state["combos"]
        local = {}
        changed = False
        for name, c in self.local_json("combos").items():
            if not isinstance(c, dict):
                continue
            cid = str(c.get("id") or name)
            local[cid] = c
            h = sha(c)
            mine = st.get(cid)
            remote = hub.get(cid)
            if mine is None and remote and remote["sha"] == h:
                st[cid] = {"sha": h, "rev": remote["rev"]}
            elif mine is None or mine.get("sha") != h:
                r = self.call("PUT", "/api/v1/combos/" + self.q(cid), c)
                st[cid] = {"sha": h, "rev": r["rev"]}
                stats["pushed"] += 1
            elif remote and remote["rev"] > mine.get("rev", 0) and remote["sha"] != h:
                r = self.call("GET", "/api/v1/combos/" + self.q(cid))
                write_json(self.path("combos", cid + ".json"), r["data"], indent=1)
                local[cid] = r["data"]
                st[cid] = {"sha": sha(r["data"]), "rev": r["rev"]}
                stats["pulled"] += 1
                changed = True
        for cid, remote in hub.items():
            if cid in local:
                continue
            if cid in st:
                st[cid]["deleted"] = True  # removed on this PC: leave it removed
                continue
            r = self.call("GET", "/api/v1/combos/" + self.q(cid))
            write_json(self.path("combos", cid + ".json"), r["data"], indent=1)
            local[cid] = r["data"]
            st[cid] = {"sha": sha(r["data"]), "rev": r["rev"]}
            stats["pulled"] += 1
            changed = True
        if changed:
            self.state["combos_rev"] = int(self.state.get("combos_rev", 0)) + 1
        return local

    def sync_profiles(self, idx, combos, stats):
        hub = idx.get("profiles", {})
        st = self.state["profiles"]
        shared = {}
        for cid, c in combos.items():
            h = combo_hash(c)
            pfile = self.path("profiles", cid + ".json")
            mine = st.get(cid) or {}
            if mine.get("hash") != h:
                mine = {"hash": h}
            rev = mine.get("shared_rev")
            if os.path.isfile(pfile):
                try:
                    p = read_json(pfile)
                except (ValueError, OSError):
                    p = None
                if isinstance(p, dict):
                    if p.get("reset"):
                        p = {"combo_id": cid, "combo_hash": h, "reset_at": p.get("reset_at") or int(time.time()), "steps": []}
                    fsha = sha(p)
                    if p.get("combo_hash") == h and mine.get("sha") != fsha:
                        body = dict(p)
                        body.pop("windows", None)
                        r = self.call("POST", "/api/v1/profiles/%s/%s" % (self.q(cid), self.q(h)), body)
                        mine["sha"] = fsha
                        stats["pushed"] += 1
                        if r["rev"] != rev:
                            write_json(self.path("shared", cid + ".json"), r["data"])
                            rev = r["rev"]
            remote = (hub.get(cid) or {}).get(h)
            if remote is not None and remote != rev:
                r = self.call("GET", "/api/v1/profiles/%s/%s" % (self.q(cid), self.q(h)))
                write_json(self.path("shared", cid + ".json"), r["data"])
                rev = r["rev"]
                stats["pulled"] += 1
            if rev is not None:
                mine["shared_rev"] = rev
                shared[cid] = rev
            st[cid] = mine
        return shared

    def sync_backups(self, stats):
        st = self.state["backups"]
        for kind in ("sessions", "bot"):
            for name, data in self.local_json(kind).items():
                if data is None:
                    continue
                key = kind + "/" + name
                h = sha(data)
                if st.get(key) != h:
                    self.call("PUT", "/api/v1/backups/%s/%s" % (kind, self.q(name)), data)
                    st[key] = h
                    stats["pushed"] += 1

    def write_status(self, ok, err, shared=None, stats=None, pending=False):
        prev = {}
        if os.path.isfile(self.status_path):
            try:
                prev = read_json(self.status_path)
            except (ValueError, OSError):
                prev = {}
        st = {
            "hub": self.hub, "machine": self.machine or self.name, "ok": ok, "error": err, "pending": pending,
            "last_sync": int(time.time()), "agent": AGENT_VERSION,
            "combos_rev": self.state.get("combos_rev", 0),
            "shared": shared if shared is not None else prev.get("shared", {}),
            "last_ok": int(time.time()) if ok else prev.get("last_ok"),
        }
        if stats:
            st["last_counts"] = stats
        write_json(self.status_path, st, indent=1)

    # ---------------------------------------------------------------- loop
    def run_forever(self):
        self.log("ComboLab sync: hub %s every %ds" % (self.hub, self.interval))
        while not self.stop.is_set():
            try:
                s = self.sync_once()
                if s["pushed"] or s["pulled"]:
                    self.log("ComboLab sync: sent %d, received %d" % (s["pushed"], s["pulled"]))
            except HubError as e:
                self.log("ComboLab sync: %s" % e)
                try:
                    self.write_status(False, str(e), pending=bool(e.data.get("pending")))
                except OSError:
                    pass
            except Exception as e:  # keep the loop alive
                self.log("ComboLab sync error: %r" % e)
                try:
                    self.write_status(False, repr(e))
                except OSError:
                    pass
            self.wake.wait(self.interval)
            self.wake.clear()

    def poke(self):
        """Sync now instead of at the next interval."""
        self.wake.set()

    def halt(self):
        self.stop.set()
        self.wake.set()

    # ---------------------------------------------------------------- joining
    def join(self, name):
        """Ask the hub to let this PC sync as `name`. The PC makes its own token
        and sends only its hash; the admin approves the request on /admin."""
        import secrets
        tok = secrets.token_urlsafe(32)
        th = hashlib.sha256(tok.encode("utf-8")).hexdigest()
        saved, self.token = self.token, ""
        try:
            r = self.call("POST", "/api/v1/join", {"name": name, "token_sha": th})
        except HubError:
            self.token = saved
            raise
        self.token, self.name = tok, r.get("name", name)
        return r

    def rename(self, name):
        r = self.call("POST", "/api/v1/rename", {"name": name})
        self.name = self.machine = r.get("machine", name)
        return r

    def restore(self, machine=None, force=False):
        lst = self.call("GET", "/api/v1/backups" + ("?machine=" + self.q(machine) if machine else ""))
        n = 0
        for item in lst.get("items", []):
            kind, name = item["kind"], item["id"]
            dst = self.path(kind, name + ".json")
            if os.path.isfile(dst) and not force:
                continue
            r = self.call("GET", "/api/v1/backups/%s/%s?machine=%s" % (kind, self.q(name), self.q(item["machine"])))
            write_json(dst, r["data"], indent=1)
            n += 1
        return n


def main():
    ap = argparse.ArgumentParser(description="ComboLab hub sync agent")
    ap.add_argument("action", nargs="*", help="setup <hub url> <token> | restore [machine]")
    ap.add_argument("--root", default=HERE, help="ComboLab data folder (default: this script's folder)")
    ap.add_argument("--once", action="store_true", help="one pass, then exit")
    ap.add_argument("--interval", type=int, default=20)
    ap.add_argument("--force", action="store_true", help="restore: overwrite existing files")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    if a.action[:1] == ["setup"]:
        if len(a.action) != 3:
            ap.error("usage: setup <hub url> <token>")
        cfg = {"hub": a.action[1].rstrip("/"), "token": a.action[2], "interval": a.interval}
        ag = Agent(root, cfg["hub"], cfg["token"])
        try:
            idx = ag.call("GET", "/api/v1/index")
        except HubError as e:
            sys.exit("Could not connect: %s" % e)
        write_json(os.path.join(root, "sync.json"), cfg, indent=1)
        print("Connected to %s as '%s'. Saved sync.json; run_server.bat will now sync in the background."
              % (cfg["hub"], idx.get("machine")))
        return
    ag = Agent(root, interval=a.interval)
    if a.action[:1] == ["restore"]:
        n = ag.restore(a.action[1] if len(a.action) > 1 else None, a.force)
        print("Restored %d files." % n)
        return
    if a.once:
        print(ag.sync_once())
        return
    try:
        ag.run_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
