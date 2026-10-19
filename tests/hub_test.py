"""Hub sync tests: merge rules, Lua/Python merge parity, and a two-machine run
against a real hub on localhost.  Run from the repository root:

    python3 tests/hub_test.py
"""
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "reframework", "data", "ComboLab"))
sys.path.insert(0, os.path.join(ROOT, "hub"))
os.environ["COMBOLAB_HUB_QUIET"] = "1"
import combolab_merge as M  # noqa: E402
import combolab_sync  # noqa: E402
import combolab_hub  # noqa: E402

FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("FAIL", msg)


def mk_profile(cid, h, machine, n_steps=3, n=20, t0=1000, legacy=False, seed=1):
    rnd = random.Random(seed)
    p = {"combo_id": cid, "combo_hash": h, "attempts": n, "successes": n // 2, "train_attempts": 0,
         "train_successes": 0, "seq": n, "neutral": {"100": True}, "steps": [], "windows": [{"n": 0}]}
    for k in range(1, n_steps + 1):
        st = {"label": "s%d" % k, "ids": {str(500 + k): n}, "tail": {}, "samples": []}
        if k >= 2:
            for a in range(1, n + 1):
                s = {"p": rnd.randint(3, 12), "q": rnd.randint(5, 14), "res": rnd.choice(["ok", "ok", "late"]),
                     "spam": 0, "mode": "develop", "a": a, "full": 0}
                if not legacy:
                    s["t"] = t0 + a
                    s["u"] = "%s-%d-%d" % (machine, t0 + a, a)
                st["samples"].append(s)
        p["steps"].append(st)
    return p


def uids(p):
    return [[s["u"] for s in st["samples"]] for st in p["steps"]]


# ------------------------------------------------------------------ merge rules
def test_merge_rules():
    a = mk_profile("c", "h", "aaa", seed=1)
    b = mk_profile("c", "h", "bbb", t0=5000, seed=2)
    ab, added = M.merge(a, b)
    ba, _ = M.merge(b, a)
    check(added == 40, "added counts b's new samples (got %d)" % added)
    check(uids(ab) == uids(ba), "merge order doesn't matter")
    check(M.merge(ab, b)[0] == ab and M.merge(ab, ab)[0] == ab, "merging again changes nothing")
    check(M.sample_count(ab) == 80, "union of samples")
    check(ab["steps"][1]["ids"]["502"] == 20, "learned ids take the max")
    # legacy samples get the same id wherever they're merged
    la = mk_profile("c", "h", "x", legacy=True, seed=3)
    m1, _ = M.merge(la, la)
    check(M.sample_count(m1) == 40, "legacy copies dedupe")
    # a reset drops older data from the other side
    r = {"combo_id": "c", "combo_hash": "h", "reset_at": 3000, "steps": []}
    after = mk_profile("c", "h", "bbb", t0=4000, n=5, seed=4)
    m2, _ = M.merge(M.merge(a, r)[0], after)
    check(M.sample_count(m2) == 10 and m2["reset_at"] == 3000, "reset keeps only newer samples")
    check(m2.get("attempts", 0) == 0, "counters from a side that missed the reset are ignored")
    m3, _ = M.merge(m2, a)
    check(M.sample_count(m3) == 10, "old samples can't come back after a reset")
    # trimming keeps the newest
    big = mk_profile("c", "h", "z", n=400, seed=5)
    check(len(M.merge(big, big)[0]["steps"][1]["samples"]) == 300, "trimmed to 300")


# ------------------------------------------------------------------ Lua parity
def lua_lit(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{" + ",".join(lua_lit(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[%s]=%s" % (json.dumps(str(k)), lua_lit(x)) for k, x in v.items()) + "}"
    return "nil"


def test_lua_parity():
    a = mk_profile("c", "h", "aaa", seed=7, legacy=True)
    b = mk_profile("c", "h", "bbb", t0=900, seed=8)
    b["reset_at"] = 950
    b["attempts"] = 99
    py, _ = M.merge(a, b)
    combo = {"id": "c", "hash": "h", "steps": [{"label": "s1"}, {"label": "s2"}, {"label": "s3"}]}
    script = """
package.path = "reframework/autorun/?.lua;" .. package.path
local Profile = require("combolab.profile")
local A, B, C = %s, %s, %s
local p = Profile.from_table(A, C)
p:merge(B)
local out = {}
out[#out + 1] = "attempts=" .. tostring(p.attempts) .. " reset=" .. tostring(p.reset_at)
for k, st in ipairs(p.steps) do
  local u = {}
  for _, s in ipairs(st.samples) do u[#u + 1] = s.u end
  local ids = {}
  for a, n in pairs(st.ids) do ids[#ids + 1] = a .. "=" .. tostring(n) end
  table.sort(ids)
  out[#out + 1] = k .. ":" .. table.concat(u, ",") .. "|" .. table.concat(ids, ",")
end
print(table.concat(out, "\\n"))
""" % (lua_lit(a), lua_lit(b), lua_lit(combo))
    r = subprocess.run(["lua", "-"], input=script, capture_output=True, text=True, cwd=ROOT)
    check(r.returncode == 0, "lua merge ran: " + r.stderr)
    want = ["attempts=%d reset=%d" % (py.get("attempts", 0), py["reset_at"])]
    for k, st in enumerate(py["steps"], 1):
        ids = sorted("%s=%d" % (a, n) for a, n in st["ids"].items())
        want.append("%d:%s|%s" % (k, ",".join(s["u"] for s in st["samples"]), ",".join(ids)))
    got = r.stdout.strip().split("\n")
    check(got == want, "Lua and Python merges agree\n  lua: %s\n  py:  %s" % (got[:2], want[:2]))


# ------------------------------------------------------------------ access rules
def http(url, path, body=None, headers=None, cookie=None):
    import urllib.request, urllib.error
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url + path, data=data, method="POST" if data is not None else "GET")
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"null"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null"), e.headers


def test_access(url):
    import base64
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    import hub_auth
    combolab_hub.LOGIN_LIMIT.hits.clear()
    # public: overview yes, export / admin / sync data no
    code, ov, _ = http(url, "/api/v1/overview")
    check(code == 200 and ov["combos"], "overview is public")
    check(http(url, "/api/v1/admin/state")[0] == 401, "admin state needs sign-in")
    check(http(url, "/api/v1/index")[0] == 401, "sync API still needs a machine token")
    check(http(url, "/api/v1/export")[0] in (401, 404), "no unsigned GET export")

    key = Ed25519PrivateKey.generate()
    pub = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()

    def export(fmt="raw", k=key, p=None, nonce=None, tamper=False):
        n = nonce or http(url, "/api/v1/challenge")[1]["nonce"]
        msg = combolab_hub.export_message(n) + (b"x" if tamper else b"")
        if fmt == "raw":
            sig = base64.b64encode(k.sign(msg)).decode()
        else:  # build what ssh-keygen -Y sign writes
            S = hub_auth._string
            raw = k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            import hashlib
            signed = b"SSHSIG" + S(b"combolab-export") + S(b"") + S(b"sha512") + S(hashlib.sha512(msg).digest())
            blob = (b"SSHSIG" + b"\x00\x00\x00\x01" + S(S(b"ssh-ed25519") + S(raw)) + S(b"combolab-export") + S(b"")
                    + S(b"sha512") + S(S(b"ssh-ed25519") + S(k.sign(signed))))
            sig = "-----BEGIN SSH SIGNATURE-----\n" + base64.b64encode(blob).decode() + "\n-----END SSH SIGNATURE-----\n"
        return http(url, "/api/v1/export", {"pubkey": p or pub, "nonce": n, "sig": sig, "format": fmt}), n

    (code, d, _), _ = export()
    check(code == 403 and "approved" in d["error"], "unapproved key can't export")
    # viewer asks for access
    code, d, _ = http(url, "/api/v1/key-requests", {"name": "Lab laptop", "pubkey": pub})
    check(code == 200 and d["status"] == "pending", "key request recorded")
    check(http(url, "/api/v1/key-requests", {"name": "x", "pubkey": "ssh-rsa AAAA"})[0] == 400, "only ed25519 keys")

    # admin: no password yet, then wrong, then right
    code, d, _ = http(url, "/api/v1/admin/login", {"password": "whatever"})
    check(code == 409, "login refused until a password is set")
    combolab_hub.STORE.set_meta("admin_pw", hub_auth.hash_password("correct horse battery"))
    check(http(url, "/api/v1/admin/login", {"password": "nope"})[0] == 401, "wrong password refused")
    code, d, h = http(url, "/api/v1/admin/login", {"password": "correct horse battery"})
    cookie = h["Set-Cookie"].split(";")[0]
    check(code == 200 and "HttpOnly" in h["Set-Cookie"] and "SameSite=Strict" in h["Set-Cookie"], "session cookie set")
    code, st, _ = http(url, "/api/v1/admin/state", cookie=cookie)
    check(code == 200 and len(st["requests"]) == 1 and st["requests"][0]["name"] == "Lab laptop", "admin sees the request")
    # writes need the admin header (blocks cross-site form posts)
    check(http(url, "/api/v1/admin/keys", {"action": "approve", "pubkey": pub}, cookie=cookie)[0] == 403, "admin writes need the header")
    code, st, _ = http(url, "/api/v1/admin/keys", {"action": "approve", "pubkey": pub}, {"X-ComboLab-Admin": "1"}, cookie)
    check(code == 200 and st["keys"][0]["name"] == "Lab laptop" and not st["requests"], "approved")

    (code, d, _), n = export()
    check(code == 200 and "combos" in d and d["combos"], "approved key exports (browser signature)")
    (code, d, _), _ = export(nonce=n)
    check(code == 400, "a challenge can't be reused")
    (code, d, _), _ = export(fmt="sshsig")
    check(code == 200 and d["combos"], "approved key exports (ssh-keygen signature)")
    (code, d, _), _ = export(tamper=True)
    check(code == 403, "bad signature refused")
    other = Ed25519PrivateKey.generate()
    (code, d, _), _ = export(k=other)
    check(code == 403, "someone else's signature for my key refused")
    # admin adds a machine from the page; the token works for sync
    code, st, _ = http(url, "/api/v1/admin/machines", {"action": "add", "name": "pc-c"}, {"X-ComboLab-Admin": "1"}, cookie)
    tok = st["new_token"]["token"]
    check(http(url, "/api/v1/index", headers={"Authorization": "Bearer " + tok})[0] == 200, "machine added from the admin page syncs")
    # remove the key: exports stop
    http(url, "/api/v1/admin/keys", {"action": "remove", "pubkey": pub}, {"X-ComboLab-Admin": "1"}, cookie)
    (code, d, _), _ = export()
    check(code == 403, "removed key can't export")
    # sign out
    http(url, "/api/v1/admin/logout", {}, cookie=cookie)
    check(http(url, "/api/v1/admin/state", cookie=cookie)[0] == 401, "signed out")
    # lockout after repeated wrong passwords
    codes = [http(url, "/api/v1/admin/login", {"password": "bad"})[0] for _ in range(6)]
    check(codes[-1] == 429, "locked out after 5 wrong passwords")


def test_join_from_page(url):
    """The ComboLab page's Hub tab: a PC asks to join under its own name, the
    admin approves, it syncs; then rename, name clash and disconnect."""
    import combolab_server
    root = tempfile.mkdtemp()
    try:
        combolab_server.ROOT = root
        combolab_server.NO_SYNC = False
        srv = combolab_server.ThreadingHTTPServer(("127.0.0.1", 0), combolab_server.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        local = "http://127.0.0.1:%d" % srv.server_address[1]
        code, h, _ = http(local, "/api/hub")
        check(code == 200 and not h["configured"] and h["hostname"], "page sees an unconnected server")
        code, h, _ = http(local, "/api/hub", {"action": "join", "hub": url, "name": "pc-new"})
        check(code == 200 and h["configured"] and h["name"] == "pc-new", "join request sent")
        cfg = combolab_sync.read_json(os.path.join(root, "sync.json"))
        check(len(cfg["token"]) > 30 and not combolab_hub.STORE.machine_for(cfg["token"]), "PC holds its own token; not active yet")

        def wait(pred, secs=6):
            t = time.time()
            while time.time() - t < secs:
                h = http(local, "/api/hub")[1]
                if pred(h):
                    return h
                time.sleep(0.2)
            return http(local, "/api/hub")[1]
        h = wait(lambda h: h["status"].get("pending"))
        check(h["status"].get("pending"), "status says waiting for approval")
        st = combolab_hub.admin_state()
        check([m["name"] for m in st["machine_requests"]] == ["pc-new"], "admin sees the join request")
        combolab_hub.STORE.approve_machine("pc-new")
        http(local, "/api/hub", {"action": "sync"})
        h = wait(lambda h: h["status"].get("ok"))
        check(h["status"].get("ok") and h["status"].get("machine") == "pc-new", "approved PC syncs")
        code, h, _ = http(local, "/api/hub", {"action": "rename", "name": "pc-renamed"})
        mid = combolab_hub.STORE.machine_for(cfg["token"])
        check(code == 200 and combolab_hub.STORE.name_of(mid) == "pc-renamed", "PC renamed itself")
        check(mid and mid != "pc-renamed" and mid == combolab_hub.STORE.id_of("pc-renamed"), "its hidden id didn't change")
        ov = combolab_hub.overview()
        check(all("id" not in m for m in ov["machines"]), "ids aren't shown on the public overview")
        # another PC can't take that name
        root2 = tempfile.mkdtemp()
        combolab_server.ROOT = root2
        code, d, _ = http(local, "/api/hub", {"action": "join", "hub": url, "name": "pc-renamed"})
        check(code == 400 and "already has" in d["error"], "name clash refused")
        combolab_server.ROOT = root
        code, h, _ = http(local, "/api/hub", {"action": "disconnect"})
        check(code == 200 and not h["configured"] and not os.path.exists(os.path.join(root, "sync.json")), "disconnected")
        srv.shutdown()
    finally:
        combolab_server.SYNC.stop()
        shutil.rmtree(root, ignore_errors=True)


def test_migration():
    """A hub database from before 1.12 (machines keyed by name) gets hidden ids."""
    import sqlite3
    tmp = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp, "hub.sqlite3")
        db = sqlite3.connect(path)
        db.executescript("""
            CREATE TABLE machines (name TEXT PRIMARY KEY, token_sha TEXT UNIQUE, created INTEGER, last_seen INTEGER, agent TEXT, addr TEXT, mod_id TEXT);
            CREATE TABLE combos (id TEXT PRIMARY KEY, rev INTEGER, sha TEXT, data TEXT, updated INTEGER, by TEXT);
            CREATE TABLE profiles (id TEXT, hash TEXT, rev INTEGER, data TEXT, samples INTEGER, origins TEXT, updated INTEGER, by TEXT, PRIMARY KEY (id, hash));
            CREATE TABLE backups (machine TEXT, kind TEXT, id TEXT, data TEXT, sha TEXT, updated INTEGER, PRIMARY KEY (machine, kind, id));
        """)
        db.execute("INSERT INTO machines (name, token_sha, created) VALUES ('old-pc', ?, 1)", (combolab_hub.token_hash("tok-old"),))
        db.execute("INSERT INTO combos VALUES ('c1', 1, 'x', '{}', 1, 'old-pc')")
        db.execute("INSERT INTO profiles VALUES ('c1', 'h', 2, '{}', 0, '[]', 1, 'old-pc')")
        db.execute("INSERT INTO backups VALUES ('old-pc', 'sessions', 'c1', '{}', 'x', 1)")
        db.commit(); db.close()
        st = combolab_hub.Store(path)
        mid = st.machine_for("tok-old")
        check(mid and mid != "old-pc" and st.name_of(mid) == "old-pc", "old machine got a hidden id, kept its token")
        check(st.q("SELECT by FROM combos")[0][0] == mid and st.q("SELECT by FROM profiles")[0][0] == mid
              and st.q("SELECT machine FROM backups")[0][0] == mid, "records point at the id")
        st.rename_machine(mid, "new-name")
        check(st.q("SELECT by FROM combos")[0][0] == mid and st.machine_for("tok-old") == mid, "rename only changes the label")
        combolab_hub.Store(path)   # opening again is a no-op
        check(st.name_of(mid) == "new-name", "migration runs once")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_sshsig_vector():
    import hub_auth
    d = os.path.join(ROOT, "tests", "testdata", "sshsig")
    raw = hub_auth.parse_public_key(open(os.path.join(d, "ed25519.pub")).read())
    msg = open(os.path.join(d, "signed-data"), "rb").read()
    sig = open(os.path.join(d, "ed25519.sig")).read()
    ns = open(os.path.join(d, "namespace")).read().strip()
    check(hub_auth.verify_sshsig(sig, raw, msg, ns), "OpenSSH's own signature verifies")
    check(not hub_auth.verify_sshsig(sig, raw, msg + b"!", ns), "tampered message refused")


# ------------------------------------------------------------------ end to end
def test_end_to_end():
    tmp = tempfile.mkdtemp()
    try:
        combolab_hub.STORE = combolab_hub.Store(os.path.join(tmp, "hub", "hub.sqlite3"))
        srv = combolab_hub.ThreadingHTTPServer(("127.0.0.1", 0), combolab_hub.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = "http://127.0.0.1:%d" % srv.server_address[1]
        ta = combolab_hub.STORE.add_machine("pc-a")
        tb = combolab_hub.STORE.add_machine("pc-b")
        ra, rb = os.path.join(tmp, "a"), os.path.join(tmp, "b")
        combo = {"format": "combolab.combo/1", "id": "mai-x", "name": "Mai X", "fighter": "Mai", "hash": "h1",
                 "steps": [{"label": "2LP"}, {"label": "5LP"}, {"label": "236LK"}]}
        for r, mid in ((ra, "aaa"), (rb, "bbb")):
            combolab_sync.write_json(os.path.join(r, "config.json"), {"machine_id": mid})
        combolab_sync.write_json(os.path.join(ra, "combos", "mai-x.json"), combo)
        combolab_sync.write_json(os.path.join(ra, "profiles", "mai-x.json"), mk_profile("mai-x", "h1", "aaa", seed=11))
        A = combolab_sync.Agent(ra, url, ta, log=lambda *x: None)
        B = combolab_sync.Agent(rb, url, tb, log=lambda *x: None)

        # bad token is refused
        bad = combolab_sync.Agent(rb, url, "nope", log=lambda *x: None)
        try:
            bad.sync_once()
            check(False, "bad token should fail")
        except combolab_sync.HubError as e:
            check("401" in str(e), "bad token gives 401")

        A.sync_once()
        B.sync_once()
        check(os.path.isfile(os.path.join(rb, "combos", "mai-x.json")), "B received the combo")
        shared_b = combolab_sync.read_json(os.path.join(rb, "shared", "mai-x.json"))
        check(M.sample_count(shared_b) == 40, "B received A's samples")
        st = combolab_sync.read_json(os.path.join(rb, "shared", "_status.json"))
        check(st["ok"] and "mai-x" in st["shared"] and st["combos_rev"] == 1, "B status lists the shared profile")

        # B's game merges, records its own samples, syncs; A gets everything
        local_b, _ = M.merge(None, shared_b)
        local_b, _ = M.merge(local_b, mk_profile("mai-x", "h1", "bbb", t0=9000, seed=12))
        combolab_sync.write_json(os.path.join(rb, "profiles", "mai-x.json"), local_b)
        B.sync_once()
        A.sync_once()
        shared_a = combolab_sync.read_json(os.path.join(ra, "shared", "mai-x.json"))
        check(M.sample_count(shared_a) == 80, "A got B's samples too (%d)" % M.sample_count(shared_a))
        # a pass with nothing new doesn't bump revisions
        rev = combolab_sync.read_json(os.path.join(ra, "shared", "_status.json"))["shared"]["mai-x"]
        a_local, _ = M.merge(combolab_sync.read_json(os.path.join(ra, "profiles", "mai-x.json")), shared_a)
        combolab_sync.write_json(os.path.join(ra, "profiles", "mai-x.json"), a_local)
        A.sync_once()
        check(combolab_sync.read_json(os.path.join(ra, "shared", "_status.json"))["shared"]["mai-x"] == rev,
              "re-pushing merged data doesn't change the revision")

        # reset on A wins over B's older samples
        combolab_sync.write_json(os.path.join(ra, "profiles", "mai-x.json"),
                                 {"reset": True, "reset_at": int(time.time()), "combo_id": "mai-x"})
        A.sync_once()
        B.sync_once()
        shared_b = combolab_sync.read_json(os.path.join(rb, "shared", "mai-x.json"))
        check(M.sample_count(shared_b) == 0 and shared_b.get("reset_at"), "reset reached B")

        # backups + restore
        combolab_sync.write_json(os.path.join(ra, "sessions", "mai-x.json"), {"combo_id": "mai-x", "attempts": [{"ok": True}]})
        A.sync_once()
        os.remove(os.path.join(ra, "sessions", "mai-x.json"))
        check(A.restore() == 1 and os.path.isfile(os.path.join(ra, "sessions", "mai-x.json")), "session restored")

        # combo edited on B flows to A
        c2 = dict(combo, name="Mai X (edited)")
        combolab_sync.write_json(os.path.join(rb, "combos", "mai-x.json"), c2)
        B.sync_once()
        A.sync_once()
        check(combolab_sync.read_json(os.path.join(ra, "combos", "mai-x.json"))["name"] == "Mai X (edited)", "combo edit propagated")

        ov = combolab_hub.overview()
        check(len(ov["machines"]) == 2 and ov["combos"][0]["name"] == "Mai X (edited)", "overview lists machines and combos")
        test_access(url)
        test_join_from_page(url)
        srv.shutdown()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    test_merge_rules()
    test_sshsig_vector()
    test_migration()
    test_lua_parity()
    test_end_to_end()
    print("hub OK" if not FAILS else "%d failures" % len(FAILS))
    sys.exit(1 if FAILS else 0)
