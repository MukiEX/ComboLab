#!/usr/bin/env python3
"""ComboLab server: serves ComboLab.html and its data folder over the LAN so the
setup page can run on another screen, phone or tablet.

    python combolab_server.py              # http://<this-pc>:41236
    python combolab_server.py --port 9000 --token secret

Standard library only (Python 3.8+). The game side keeps reading and writing the
same files, so the page and the overlay talk exactly as they do locally.
"""
import argparse
import json
import os
import re
import socket
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
TOKEN = None
NO_SYNC = False
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class SyncRunner:
    """The hub sync agent, run in the background; restartable from the page."""

    def __init__(self):
        import threading
        self.lock = threading.Lock()
        self.agent = None

    def start(self):
        import threading
        import combolab_sync
        with self.lock:
            if self.agent:
                self.agent.halt()
                self.agent = None
            if NO_SYNC or not os.path.isfile(combolab_sync.config_path(ROOT)):
                return None
            self.agent = combolab_sync.Agent(ROOT)
            threading.Thread(target=self.agent.run_forever, daemon=True).start()
            return self.agent

    def stop(self):
        with self.lock:
            if self.agent:
                self.agent.halt()
                self.agent = None


SYNC = SyncRunner()


def hub_info():
    import combolab_sync
    cfg, st = {}, {}
    try:
        cfg = combolab_sync.read_json(combolab_sync.config_path(ROOT))
    except (ValueError, OSError):
        pass
    try:
        st = combolab_sync.read_json(os.path.join(ROOT, "shared", "_status.json"))
    except (ValueError, OSError):
        pass
    return {"configured": bool(cfg.get("hub")), "hub": cfg.get("hub"), "name": cfg.get("name"),
            "running": SYNC.agent is not None, "no_sync": NO_SYNC, "hostname": socket.gethostname(),
            "status": st}


def hub_action(body):
    """Hub settings from the page: join (pick a name), token (paste one from the
    admin page), rename, sync (now), disconnect."""
    import combolab_sync
    act = body.get("action")
    if act == "disconnect":
        SYNC.stop()
        combolab_sync.disconnect(ROOT)
        return 200, hub_info()
    if act == "sync":
        if SYNC.agent:
            SYNC.agent.poke()
        return 200, hub_info()
    if act in ("join", "token"):
        hub = str(body.get("hub") or "").strip().rstrip("/")
        if not hub.startswith(("https://", "http://")):
            return 400, {"error": "the hub address starts with https://"}
        ag = combolab_sync.Agent(ROOT, hub, "x")
        try:
            if act == "join":
                name = str(body.get("name") or "").strip()
                ag.join(name)
                combolab_sync.save_config(ROOT, hub, ag.token, ag.name)
            else:
                tok = str(body.get("token") or "").strip()
                ag.token = tok
                idx = ag.call("GET", "/api/v1/index")
                combolab_sync.save_config(ROOT, hub, tok, idx.get("machine"), joined=True)
        except combolab_sync.HubError as e:
            if act == "token" and e.data.get("pending"):
                combolab_sync.save_config(ROOT, hub, ag.token, e.data["pending"])
            else:
                return 400, {"error": str(e.data.get("error") or e)}
        SYNC.start()
        return 200, hub_info()
    if act == "rename":
        if not SYNC.agent:
            return 400, {"error": "not connected to a hub"}
        try:
            SYNC.agent.rename(str(body.get("name") or "").strip())
        except combolab_sync.HubError as e:
            if e.code == 404:
                return 400, {"error": "this hub is older than 1.11 and can't rename machines yet; update the hub"}
            return 400, {"error": str(e.data.get("error") or e)}
        cfg = combolab_sync.read_json(combolab_sync.config_path(ROOT))
        combolab_sync.save_config(ROOT, cfg["hub"], cfg["token"], SYNC.agent.name, joined=True)
        SYNC.agent.poke()
        return 200, hub_info()
    return 400, {"error": "unknown action"}
ALLOWED_DIRS = ("", "combos", "profiles", "sessions", "shared", "bot")


# ---------------------------------------------------------------- updates
SERVER = None


def update_allowed(handler):
    """Updates run code on this PC, so only this PC (or a page that knows the
    server's --token) may start one or change where they come from."""
    host = handler.client_address[0]
    return host in ("127.0.0.1", "::1", "::ffff:127.0.0.1") or bool(TOKEN)


def update_info():
    import combolab_update as U
    s = U.load_settings(ROOT)
    here = U.build_manifest(U.game_root(ROOT))
    try:
        import combolab_sync
        with open(combolab_sync.config_path(ROOT), encoding="utf-8") as f:
            hub = json.load(f).get("hub")
    except (OSError, ValueError, ImportError):
        hub = None
    return {"settings": {k: s.get(k) for k in ("source", "git_url", "git_branch")}, "last_check": s.get("last_check"),
            "last_update": s.get("last_update"), "local_version": here["version"], "hub": hub,
            "git": bool(__import__("shutil").which("git"))}


DEFAULT_PORT = 41236


def restart_soon():
    """Starts a fresh server process (new code) and ends this one."""
    import subprocess
    import threading

    def go():
        import time
        time.sleep(1.0)
        SYNC.stop()
        if SERVER:
            SERVER.server_close()
        args = [sys.executable, os.path.abspath(__file__)] + sys.argv[1:]
        # keep the port this server is on, so the page that asked for the update
        # reconnects (e.g. 8765 from before the default changed)
        if SERVER and not any(x == "--port" or x.startswith("--port=") for x in sys.argv[1:]):
            args += ["--port", str(SERVER.server_address[1])]
        kw = {"cwd": ROOT}
        if os.name == "nt":
            kw["creationflags"] = getattr(subprocess, "CREATE_NEW_CONSOLE", 0x10)
        subprocess.Popen(args, **kw)
        os._exit(0)
    threading.Thread(target=go, daemon=True).start()


def update_action(handler, body):
    import combolab_update as U
    act = body.get("action")
    if not update_allowed(handler):
        return 403, {"error": "updates can only be started from this PC (open http://localhost:%d there), or start the server with --token" % handler.server.server_address[1]}
    try:
        if act == "settings":
            src = body.get("source")
            if src not in ("hub", "git"):
                return 400, {"error": "source must be hub or git"}
            url = str(body.get("git_url") or "").strip()
            if src == "git" and not re.match(r"^(https://|ssh://|git@|file://|[A-Za-z]:\\|/)", url):
                return 400, {"error": "that doesn't look like a git address"}
            U.save_settings(ROOT, {"source": src, "git_url": url, "git_branch": str(body.get("git_branch") or "").strip()})
            return 200, update_info()
        if act == "check":
            res, _, _ = U.check(ROOT)
            return 200, res
        if act == "apply":
            res = U.apply(ROOT)
            if res.get("restart"):
                restart_soon()
            return 200, res
    except U.UpdateError as e:
        return 409, {"error": str(e)}
    return 400, {"error": "unknown action"}


def safe_path(rel):
    """Map a page path like 'combos/x.json' into ROOT, refusing anything else."""
    rel = (rel or "").replace("\\", "/").strip("/")
    parts = [p for p in rel.split("/") if p]
    if any(p in (".", "..") or ":" in p for p in parts):
        return None
    if len(parts) > 2 or (len(parts) == 2 and parts[0] not in ALLOWED_DIRS):
        return None
    if parts and not parts[-1].endswith(".json") and len(parts) != 1:
        return None
    full = os.path.normpath(os.path.join(ROOT, *parts))
    if not full.startswith(ROOT):
        return None
    return full


class Handler(BaseHTTPRequestHandler):
    server_version = "ComboLab/1.0"

    def log_message(self, fmt, *args):
        if self.command != "GET" or "/api/" not in self.path:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -------------------------------------------------------------- helpers
    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode("utf-8"))

    def _authed(self):
        if not TOKEN:
            return True
        q = parse_qs(urlparse(self.path).query)
        return self.headers.get("X-ComboLab-Token") == TOKEN or q.get("token", [""])[0] == TOKEN

    def _query(self):
        u = urlparse(self.path)
        return u.path, {k: v[0] for k, v in parse_qs(u.query).items()}

    # -------------------------------------------------------------- verbs
    def do_GET(self):
        path, q = self._query()
        if path in ("/", "/index.html", "/ComboLab.html"):
            with open(os.path.join(ROOT, "ComboLab.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if not path.startswith("/api/"):
            return self._send(404, b"not found", "text/plain")
        if not self._authed():
            return self._json(401, {"error": "token required"})
        if path == "/api/info":
            return self._json(200, {"name": "ComboLab", "root": os.path.basename(ROOT), "token": bool(TOKEN), "hub_ui": True})
        if path == "/api/hub":
            return self._json(200, hub_info())
        if path == "/api/update":
            info = update_info()
            info["allowed"] = update_allowed(self)
            return self._json(200, info)
        if path == "/api/list":
            d = safe_path(q.get("dir", ""))
            if d is None:
                return self._json(400, {"error": "bad dir"})
            os.makedirs(d, exist_ok=True)
            names = sorted(n for n in os.listdir(d) if n.endswith(".json") and os.path.isfile(os.path.join(d, n)))
            mtimes = {}
            for n in names:
                try:
                    mtimes[n] = int(os.path.getmtime(os.path.join(d, n)) * 1000)
                except OSError:
                    pass
            return self._json(200, {"files": names, "mtimes": mtimes})
        if path == "/api/file":
            p = safe_path(q.get("path"))
            if p is None:
                return self._json(400, {"error": "bad path"})
            if not os.path.isfile(p):
                return self._json(404, {"error": "missing"})
            try:
                with open(p, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (ValueError, OSError):
                return self._json(409, {"error": "unreadable (being written?)"})
            return self._json(200, {"mtime": int(os.path.getmtime(p) * 1000), "data": data})
        return self._send(404, b"not found", "text/plain")

    def do_PUT(self):
        path, q = self._query()
        if path != "/api/file":
            return self._send(404, b"", "text/plain")
        if not self._authed():
            return self._json(401, {"error": "token required"})
        p = safe_path(q.get("path"))
        if p is None or not p.endswith(".json"):
            return self._json(400, {"error": "bad path"})
        n = int(self.headers.get("Content-Length", "0"))
        if n > 4 * 1024 * 1024:
            return self._json(413, {"error": "too large"})
        body = self.rfile.read(n)
        try:
            obj = json.loads(body.decode("utf-8"))
        except ValueError:
            return self._json(400, {"error": "not json"})
        os.makedirs(os.path.dirname(p), exist_ok=True)
        # write-then-rename so the game never reads a half-written file
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=1)
        os.replace(tmp, p)
        return self._json(200, {"ok": True})

    def do_POST(self):
        path, q = self._query()
        if path not in ("/api/hub", "/api/update"):
            return self._send(404, b"", "text/plain")
        if not self._authed():
            return self._json(401, {"error": "token required"})
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            body = json.loads(self.rfile.read(min(n, 65536)).decode("utf-8") or "{}")
        except ValueError:
            return self._json(400, {"error": "not json"})
        body = body if isinstance(body, dict) else {}
        code, out = update_action(self, body) if path == "/api/update" else hub_action(body)
        return self._json(code, out)

    def do_DELETE(self):
        path, q = self._query()
        if path != "/api/file" or not self._authed():
            return self._json(401 if path == "/api/file" else 404, {"error": "no"})
        p = safe_path(q.get("path"))
        if p is None or not p.endswith(".json"):
            return self._json(400, {"error": "bad path"})
        if os.path.isfile(p):
            os.remove(p)
        return self._json(200, {"ok": True})


def lan_addresses():
    addrs = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        addrs.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    return sorted(a for a in addrs if not a.startswith("127."))


def main():
    global ROOT, TOKEN, NO_SYNC
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0", help="interface to listen on (default: all; use 127.0.0.1 for this PC only)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="default %d (41236: the half-circle forward motion)" % DEFAULT_PORT)
    ap.add_argument("--token", default=None, help="optional shared secret; the page asks for it once")
    ap.add_argument("--root", default=ROOT, help="ComboLab data folder (default: this script's folder)")
    ap.add_argument("--no-sync", action="store_true", help="don't run the hub sync agent even if sync.json exists")
    a = ap.parse_args()
    ROOT = os.path.abspath(a.root)
    TOKEN = a.token
    for d in ("combos", "profiles", "sessions"):
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)
    global SERVER
    srv = None
    for attempt in range(40):          # after an update the old server may still be letting go of the port
        try:
            srv = ThreadingHTTPServer((a.host, a.port), Handler)
            break
        except OSError:
            if attempt == 39:
                raise
            import time
            time.sleep(0.5)
    SERVER = srv
    print("ComboLab server serving %s" % ROOT)
    print("  this PC:      http://localhost:%d" % a.port)
    if a.host in ("0.0.0.0", ""):
        for ip in lan_addresses():
            print("  other device: http://%s:%d" % (ip, a.port))
    if TOKEN:
        print("  token required: %s" % TOKEN)
    NO_SYNC = a.no_sync
    agent = SYNC.start()
    if agent:
        print("  hub sync:     %s" % agent.hub)
    elif not NO_SYNC:
        print("  hub sync:     off (connect to a hub in the page's Hub tab)")
    print("Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
