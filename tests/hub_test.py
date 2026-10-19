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

        ov = combolab_hub.overview("pc-a")
        check(len(ov["machines"]) == 2 and ov["combos"][0]["name"] == "Mai X (edited)", "overview lists machines and combos")
        srv.shutdown()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    test_merge_rules()
    test_lua_parity()
    test_end_to_end()
    print("hub OK" if not FAILS else "%d failures" % len(FAILS))
    sys.exit(1 if FAILS else 0)
