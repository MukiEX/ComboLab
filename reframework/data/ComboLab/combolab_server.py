#!/usr/bin/env python3
"""ComboLab server: serves ComboLab.html and its data folder over the LAN so the
setup page can run on another screen, phone or tablet.

    python combolab_server.py              # http://<this-pc>:8765
    python combolab_server.py --port 9000 --token secret

Standard library only (Python 3.8+). The game side keeps reading and writing the
same files, so the page and the overlay talk exactly as they do locally.
"""
import argparse
import json
import os
import socket
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.abspath(__file__))
TOKEN = None
ALLOWED_DIRS = ("", "combos", "profiles", "sessions", "shared", "bot")


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
            return self._json(200, {"name": "ComboLab", "root": os.path.basename(ROOT), "token": bool(TOKEN)})
        if path == "/api/list":
            d = safe_path(q.get("dir", ""))
            if d is None:
                return self._json(400, {"error": "bad dir"})
            os.makedirs(d, exist_ok=True)
            names = sorted(n for n in os.listdir(d) if n.endswith(".json") and os.path.isfile(os.path.join(d, n)))
            return self._json(200, {"files": names})
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
    global ROOT, TOKEN
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0", help="interface to listen on (default: all; use 127.0.0.1 for this PC only)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--token", default=None, help="optional shared secret; the page asks for it once")
    ap.add_argument("--root", default=ROOT, help="ComboLab data folder (default: this script's folder)")
    ap.add_argument("--no-sync", action="store_true", help="don't run the hub sync agent even if sync.json exists")
    a = ap.parse_args()
    ROOT = os.path.abspath(a.root)
    TOKEN = a.token
    for d in ("combos", "profiles", "sessions"):
        os.makedirs(os.path.join(ROOT, d), exist_ok=True)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print("ComboLab server serving %s" % ROOT)
    print("  this PC:      http://localhost:%d" % a.port)
    if a.host in ("0.0.0.0", ""):
        for ip in lan_addresses():
            print("  other device: http://%s:%d" % (ip, a.port))
    if TOKEN:
        print("  token required: %s" % TOKEN)
    if not a.no_sync and os.path.isfile(os.path.join(ROOT, "sync.json")):
        import threading
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import combolab_sync
        agent = combolab_sync.Agent(ROOT)
        threading.Thread(target=agent.run_forever, daemon=True).start()
        print("  hub sync:     %s" % agent.hub)
    print("Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
