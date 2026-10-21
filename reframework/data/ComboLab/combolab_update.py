#!/usr/bin/env python3
"""ComboLab updater: brings this PC's mod and page files up to date from the
hub (which serves the files it was built from) or straight from a git repo.

    python combolab_update.py check            # what would change
    python combolab_update.py apply            # update (backs up the old files first)
    python combolab_update.py source hub
    python combolab_update.py source git https://github.com/you/ComboLab.git [branch]

The ComboLab server runs the same code from its Hub Sync tab. Only program
files are touched: combos, profiles, sessions, config and sync settings never are.
Standard library only (git must be installed for the git source).
"""
import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

UPDATER_VERSION = "1.23.0"

# Program files, relative to the game folder (the repo root has the same layout).
CLIENT_PATTERNS = [
    re.compile(r"^reframework/autorun/ComboLab\.lua$"),
    re.compile(r"^reframework/autorun/combolab/[A-Za-z0-9_]+\.lua$"),
    re.compile(r"^reframework/data/ComboLab/ComboLab\.html$"),
    re.compile(r"^reframework/data/ComboLab/combolab_[a-z_]+\.py$"),
    re.compile(r"^reframework/data/ComboLab/run_[a-z_]+\.bat$"),
    re.compile(r"^reframework/fonts/ComboLab[-A-Za-z0-9_.]*\.(ttf|txt)$"),
]
# A running .bat file is read by cmd.exe as it goes, so rewriting one under it
# breaks it: a changed .bat goes next to the original as .new instead.
SIDE_BY_SIDE = re.compile(r"\.bat$")


def is_client_path(rel):
    return any(p.match(rel) for p in CLIENT_PATTERNS)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def lua_version(text):
    m = re.search(r'local VERSION = "([^"]+)"', text)
    return m.group(1) if m else None


def version_key(v):
    """'1.22.3' -> (1, 22, 3); None when there's no version to compare."""
    nums = re.findall(r"\d+", str(v or ""))
    return tuple(int(n) for n in nums) if nums else None


def build_manifest(root):
    """Manifest of the program files under `root` (a game folder or a repo checkout)."""
    files = {}
    for base in ("reframework/autorun", "reframework/data/ComboLab", "reframework/fonts"):
        d = os.path.join(root, base)
        if not os.path.isdir(d):
            continue
        walk = os.walk(d) if base == "reframework/autorun" else [(d, [], os.listdir(d))]
        for dirpath, _dirs, names in walk:
            for n in names:
                full = os.path.join(dirpath, n)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                if is_client_path(rel) and os.path.isfile(full):
                    files[rel] = {"sha256": sha256_file(full), "size": os.path.getsize(full)}
    version = None
    lua = os.path.join(root, "reframework/autorun/ComboLab.lua")
    if os.path.isfile(lua):
        with open(lua, encoding="utf-8", errors="replace") as f:
            version = lua_version(f.read())
    return {"format": "combolab.client/1", "version": version, "files": files}


def game_root(data_root):
    """reframework/data/ComboLab -> the game folder."""
    return os.path.abspath(os.path.join(data_root, "..", "..", ".."))


# ---------------------------------------------------------------- settings
def settings_path(data_root):
    return os.path.join(data_root, "update.json")


def load_settings(data_root):
    s = {"source": "hub", "git_url": "", "git_branch": ""}
    try:
        with open(settings_path(data_root), encoding="utf-8") as f:
            s.update(json.load(f))
    except (OSError, ValueError):
        pass
    return s


def save_settings(data_root, s):
    cur = load_settings(data_root)
    if any(k in s and s[k] != cur.get(k) for k in ("source", "git_url", "git_branch")):
        cur.pop("last_check", None)          # a check against another source doesn't count
    cur.update({k: v for k, v in s.items() if k in ("source", "git_url", "git_branch", "last_check", "last_update")})
    tmp = settings_path(data_root) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cur, f, indent=1)
    os.replace(tmp, settings_path(data_root))
    return cur


# ---------------------------------------------------------------- sources
class UpdateError(Exception):
    pass


class HubSource:
    """The hub serves the program files it was built from (public, read-only)."""

    def __init__(self, hub):
        if not hub:
            raise UpdateError("not connected to a hub (set one up on the Hub Sync tab, or use a git repo)")
        self.hub = hub.rstrip("/")
        self.ctx = ssl.create_default_context()
        self.label = self.hub

    def _get(self, path):
        url = self.hub + path
        req = urllib.request.Request(url, headers={"User-Agent": "ComboLab-update/" + UPDATER_VERSION})
        try:
            with urllib.request.urlopen(req, timeout=30, context=self.ctx if url.startswith("https") else None) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            # a hub older than 1.14 has no update routes: it answers 404, or
            # 401 (it takes the path for a sync call that needs a token)
            if e.code in (401, 404) and "/client/" in path:
                raise UpdateError("the hub%s doesn't hand out updates yet: rebuild it from the repo (needs 1.14 or newer), or pick \"A git repo\" for now" % self._version_note())
            raise UpdateError("hub said %s" % e.code)
        except (urllib.error.URLError, OSError) as e:
            raise UpdateError("can't reach the hub: %s" % getattr(e, "reason", e))

    def _version_note(self):
        try:
            req = urllib.request.Request(self.hub + "/healthz", headers={"User-Agent": "ComboLab-update/" + UPDATER_VERSION})
            with urllib.request.urlopen(req, timeout=10, context=self.ctx if self.hub.startswith("https") else None) as r:
                v = json.loads(r.read()).get("version")
            return " (version %s)" % v if v else ""
        except Exception:
            return ""

    def manifest(self):
        try:
            m = json.loads(self._get("/api/v1/client/manifest"))
        except ValueError:
            raise UpdateError("the hub's update list isn't valid JSON")
        if m.get("format") != "combolab.client/1":
            raise UpdateError("the hub's update list has an unknown format")
        return m

    def fetch(self, rel):
        return self._get("/api/v1/client/file?path=" + urllib.parse.quote(rel))

    def close(self):
        pass


class GitSource:
    """A shallow clone of a git repo, kept in .update/repo and refreshed each check."""

    def __init__(self, data_root, url, branch=""):
        if not url:
            raise UpdateError("no git repo address set")
        self.git = shutil.which("git")
        if not self.git:
            raise UpdateError("git isn't installed on this PC (https://git-scm.com), or use the hub as the source")
        self.url, self.branch = url, branch or ""
        self.dir = os.path.join(data_root, ".update", "repo")
        self.label = url + (" (" + branch + ")" if branch else "")

    def _run(self, *args, cwd=None):
        try:
            r = subprocess.run([self.git] + list(args), cwd=cwd, capture_output=True, text=True, timeout=180,
                               env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
        except subprocess.TimeoutExpired:
            raise UpdateError("git timed out")
        if r.returncode != 0:
            lines = (r.stderr or r.stdout or "").strip().splitlines()
            raise UpdateError("git %s failed: %s" % (args[0], lines[-1] if lines else "exit %d" % r.returncode))
        return r.stdout

    def manifest(self):
        if os.path.isdir(os.path.join(self.dir, ".git")):
            remote = self._run("remote", "get-url", "origin", cwd=self.dir).strip()
            if remote != self.url:
                shutil.rmtree(self.dir, ignore_errors=True)
        if not os.path.isdir(os.path.join(self.dir, ".git")):
            os.makedirs(os.path.dirname(self.dir), exist_ok=True)
            args = ["clone", "--depth", "1"] + (["--branch", self.branch] if self.branch else []) + [self.url, self.dir]
            self._run(*args)
        else:
            self._run("fetch", "--depth", "1", "origin", self.branch or "HEAD", cwd=self.dir)
            self._run("reset", "--hard", "FETCH_HEAD", cwd=self.dir)
        m = build_manifest(self.dir)
        m["commit"] = self._run("rev-parse", "--short", "HEAD", cwd=self.dir).strip()
        if not m["files"]:
            raise UpdateError("that repo has no ComboLab files at reframework/...")
        return m

    def fetch(self, rel):
        with open(os.path.join(self.dir, rel), "rb") as f:
            return f.read()

    def close(self):
        pass


def make_source(data_root, settings=None, hub=None):
    s = settings or load_settings(data_root)
    if s.get("source") == "git":
        return GitSource(data_root, s.get("git_url", ""), s.get("git_branch", ""))
    if hub is None:
        try:
            with open(os.path.join(data_root, "sync.json"), encoding="utf-8") as f:
                hub = json.load(f).get("hub")
        except (OSError, ValueError):
            hub = None
    return HubSource(hub)


# ---------------------------------------------------------------- check / apply
def check(data_root, source=None):
    src = source or make_source(data_root)
    remote = src.manifest()
    here = build_manifest(game_root(data_root))
    changed, added, waiting = [], [], []
    game = game_root(data_root)
    for rel, info in sorted(remote["files"].items()):
        if not is_client_path(rel):
            continue
        mine = here["files"].get(rel)
        new = os.path.join(game, rel.replace("/", os.sep)) + ".new"
        if mine and mine["sha256"] != info["sha256"] and SIDE_BY_SIDE.search(rel) and os.path.isfile(new) \
                and sha256_file(new) == info["sha256"]:
            waiting.append(rel)          # already delivered as .new, waiting to be swapped in by hand
        elif mine is None:
            added.append(rel)
        elif mine["sha256"] != info["sha256"]:
            changed.append(rel)
    lk, rk = version_key(here["version"]), version_key(remote.get("version"))
    older = bool(lk and rk and rk < lk)       # the source is behind this PC: never go back by accident
    res = {
        "source": src.label, "local_version": here["version"], "remote_version": remote.get("version"),
        "commit": remote.get("commit"), "changed": [] if older else changed, "added": [] if older else added,
        "waiting": waiting, "older": older,
        "up_to_date": older or (not changed and not added), "time": int(time.time()),
    }
    save_settings(data_root, {"last_check": res})
    return res, remote, src


def apply(data_root, source=None, force=False):
    """Downloads every changed file, checks it against the manifest, backs up
    the current ones to .update/backup/<time>/ and swaps them in. Refuses to
    go back to an older version unless forced."""
    res, remote, src = check(data_root, source)
    if res.get("older"):
        if not force:
            raise UpdateError("%s has %s, older than this PC's %s: not going back (update the hub or the repo first)"
                              % (src.label, res["remote_version"], res["local_version"]))
        here = build_manifest(game_root(data_root))
        res["changed"] = [r for r, i in remote["files"].items() if is_client_path(r) and r in here["files"] and here["files"][r]["sha256"] != i["sha256"]]
        res["added"] = [r for r in remote["files"] if is_client_path(r) and r not in here["files"]]
    todo = res["changed"] + res["added"]
    if not todo:
        return dict(res, written=[], side_by_side=[], restart=False)
    game = game_root(data_root)
    staged = {}
    for rel in todo:
        data = src.fetch(rel)
        if hashlib.sha256(data).hexdigest() != remote["files"][rel]["sha256"]:
            raise UpdateError("%s didn't match the update list (download damaged?); nothing was changed" % rel)
        staged[rel] = data
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(data_root, ".update", "backup", "%s-%s" % (stamp, res["local_version"] or "old"))
    written, side = [], []
    for rel, data in staged.items():
        dst = os.path.join(game, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.isfile(dst):
            b = os.path.join(backup, rel.replace("/", os.sep))
            os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.copy2(dst, b)
        if SIDE_BY_SIDE.search(rel) and os.path.isfile(dst):
            dst = dst + ".new"
            side.append(rel)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".upd-")
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, dst)
        written.append(rel)
    out = dict(res, written=written, side_by_side=side, backup=backup,
               restart=any(r.endswith(".py") for r in written),
               mod_changed=any(r.endswith(".lua") for r in written),
               page_changed=any(r.endswith(".html") for r in written))
    save_settings(data_root, {"last_update": {"time": int(time.time()), "from": res["local_version"],
                                              "to": res["remote_version"], "files": len(written)}})
    return out


def main(argv):
    data_root = os.path.dirname(os.path.abspath(__file__))
    if len(argv) >= 2 and argv[0] == "source":
        s = {"source": argv[1]}
        if argv[1] == "git":
            if len(argv) < 3:
                print("usage: combolab_update.py source git <url> [branch]")
                return 2
            s.update(git_url=argv[2], git_branch=argv[3] if len(argv) > 3 else "")
        print(json.dumps(save_settings(data_root, s), indent=1))
        return 0
    try:
        if argv[:1] == ["apply"]:
            r = apply(data_root, force=("force" in argv[1:]))
            if not r["written"]:
                print("Already up to date (%s)." % r["local_version"])
            else:
                print("Updated %s -> %s: %d file(s). Old files in %s" % (r["local_version"], r["remote_version"], len(r["written"]), r["backup"]))
                for rel in r["side_by_side"]:
                    print("  %s changed: the new one is next to it as %s.new" % (rel, os.path.basename(rel)))
                if r["mod_changed"]:
                    print("In game: REFramework menu (Insert) > ScriptRunner > Reset scripts.")
                if r["restart"]:
                    print("Restart the ComboLab server.")
        else:
            r, _, _ = check(data_root)
            print("This PC: %s   %s: %s%s" % (r["local_version"], r["source"], r["remote_version"], " @" + r["commit"] if r.get("commit") else ""))
            for rel in r["changed"]:
                print("  changed  " + rel)
            for rel in r["added"]:
                print("  new      " + rel)
            if r["up_to_date"]:
                print("Up to date.")
    except UpdateError as e:
        print("Update: %s" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
