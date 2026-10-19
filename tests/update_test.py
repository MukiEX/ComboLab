#!/usr/bin/env python3
"""Updater test: a PC with an old/edited install updates itself from a hub
serving this repo's files, and from the repo over git.   python3 tests/update_test.py"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "reframework", "data", "ComboLab"))
import combolab_update as U  # noqa: E402

fails = 0


def check(c, m):
    global fails
    if not c:
        fails += 1
        print("FAIL: " + m)


tmp = tempfile.mkdtemp()
game = os.path.join(tmp, "game")
shutil.copytree(os.path.join(REPO, "reframework"), os.path.join(game, "reframework"),
                ignore=shutil.ignore_patterns("combos", "__pycache__", ".update", "update.json", "sync.json"))
data = os.path.join(game, "reframework", "data", "ComboLab")
# user data that must survive
os.makedirs(os.path.join(data, "profiles"))
with open(os.path.join(data, "profiles", "x.json"), "w") as f:
    f.write('{"keep": 1}')
with open(os.path.join(data, "config.json"), "w") as f:
    f.write('{"mine": true}')
# an outdated mod file, a missing one and an edited bat
with open(os.path.join(game, "reframework/autorun/combolab/motion.lua"), "a") as f:
    f.write("\n-- old\n")
os.remove(os.path.join(game, "reframework/autorun/combolab/predict.lua"))
with open(os.path.join(data, "run_sync.bat"), "a") as f:
    f.write("rem old\r\n")

s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
hub = subprocess.Popen([sys.executable, os.path.join(REPO, "hub", "combolab_hub.py"), "serve", "--port", str(port),
                        "--data", os.path.join(tmp, "hubdata")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=dict(os.environ, COMBOLAB_CLIENT_DIR=REPO))
try:
    for _ in range(50):
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/healthz" % port, timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    with open(os.path.join(data, "sync.json"), "w") as f:
        json.dump({"hub": "http://127.0.0.1:%d" % port, "token": "t"}, f)
    # the hub only hands out program files
    for bad in ("../hub/hub_auth.py", "reframework/data/ComboLab/sync.json",
                "reframework/data/ComboLab/../../../hub/combolab_hub.py"):
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/api/v1/client/file?path=%s" % (port, bad))
            check(False, "served " + bad)
        except urllib.error.HTTPError as e:
            check(e.code == 404, "refused " + bad)
    r, _, _ = U.check(data)
    check("reframework/autorun/combolab/motion.lua" in r["changed"], "outdated file found")
    check("reframework/autorun/combolab/predict.lua" in r["added"], "missing file found")
    a = U.apply(data)
    check(not a["restart"] and a["mod_changed"], "mod changed, server scripts unchanged")
    check(a["side_by_side"] == ["reframework/data/ComboLab/run_sync.bat"], "bat delivered as .new")
    check(U.sha256_file(os.path.join(game, "reframework/autorun/combolab/motion.lua")) ==
          U.sha256_file(os.path.join(REPO, "reframework/autorun/combolab/motion.lua")), "file replaced")
    check(os.path.isfile(os.path.join(a["backup"], "reframework", "autorun", "combolab", "motion.lua")), "backup kept")
    r2, _, _ = U.check(data)
    check(r2["up_to_date"] and r2["waiting"] == ["reframework/data/ComboLab/run_sync.bat"], "up to date afterwards (bat waiting)")
    with open(os.path.join(data, "profiles", "x.json")) as f:
        check(json.load(f) == {"keep": 1}, "profiles untouched")
    with open(os.path.join(data, "config.json")) as f:
        check(json.load(f) == {"mine": True}, "config untouched")
    # git source (committed files only)
    if shutil.which("git") and os.path.isdir(os.path.join(REPO, ".git")):
        with open(os.path.join(game, "reframework/autorun/combolab/motion.lua"), "a") as f:
            f.write("\n-- old again\n")
        U.save_settings(data, {"source": "git", "git_url": "file://" + REPO})
        r3, _, _ = U.check(data)
        check("reframework/autorun/combolab/motion.lua" in r3["changed"] and r3.get("commit"), "git source sees the change")
        U.apply(data)
        r4, _, _ = U.check(data)
        check("reframework/autorun/combolab/motion.lua" not in r4["changed"], "git source applied")
finally:
    hub.terminate()
    shutil.rmtree(tmp, ignore_errors=True)
print("update OK" if not fails else "%d failed" % fails)
sys.exit(1 if fails else 0)
