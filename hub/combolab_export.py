#!/usr/bin/env python3
"""Download everything from a ComboLab hub, signing with your SSH key.

The hub only exports to keys its admin has approved. Use an ed25519 key
(ssh-keygen -t ed25519 makes one) and OpenSSH's ssh-keygen 8.1 or newer, which
Windows 10/11, macOS and Linux all ship.

    python combolab_export.py https://hub.example.com --request "my laptop"   # ask for access once
    python combolab_export.py https://hub.example.com                         # -> combolab-hub-YYYY-MM-DD.json
    python combolab_export.py https://hub.example.com --key ~/.ssh/other_key -o backup.json

Standard library only (Python 3.8+).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

NAMESPACE = "combolab-export"


def call(url, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                 headers={"Content-Type": "application/json", "User-Agent": "ComboLab-export/1.9.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode("utf-8"))
        except ValueError:
            msg = {"error": e.reason}
        sys.exit("Hub said: %s%s" % (msg.get("error"), ("\nYour key: " + msg["fingerprint"]) if msg.get("fingerprint") else ""))
    except urllib.error.URLError as e:
        sys.exit("Can't reach the hub: %s" % e.reason)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hub", help="hub address, e.g. https://combolab.example.com")
    ap.add_argument("--key", default=os.path.join(os.path.expanduser("~"), ".ssh", "id_ed25519"),
                    help="private key file (its .pub must sit next to it)")
    ap.add_argument("--request", metavar="NAME", help="ask the hub's admin to approve this key, under this name")
    ap.add_argument("-o", "--out", help="output file (default combolab-hub-<date>.json)")
    a = ap.parse_args()
    hub = a.hub.rstrip("/")
    pub_path = a.key + ".pub"
    if not os.path.isfile(pub_path):
        sys.exit("No public key at %s (make one with: ssh-keygen -t ed25519)" % pub_path)
    pub = open(pub_path, encoding="utf-8").read().strip()
    if not pub.startswith("ssh-ed25519 "):
        sys.exit("The hub needs an ed25519 key; %s is %s" % (pub_path, pub.split()[0]))

    if a.request:
        r = call(hub + "/api/v1/key-requests", {"name": a.request, "pubkey": pub})
        if r.get("status") == "approved":
            print("This key is already approved (%s)." % r["fingerprint"])
        else:
            print("Requested. Ask the hub's admin to approve %s (%s) at %s/admin" % (a.request, r["fingerprint"], hub))
        return

    if not shutil.which("ssh-keygen"):
        sys.exit("ssh-keygen not found; install OpenSSH (8.1 or newer)")
    ch = call(hub + "/api/v1/challenge")
    tmp = tempfile.mkdtemp()
    try:
        msg_path = os.path.join(tmp, "challenge")
        with open(msg_path, "wb") as f:
            f.write(("combolab-export\n%s\n" % ch["nonce"]).encode("utf-8"))
        r = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", a.key, "-n", NAMESPACE, msg_path])
        if r.returncode != 0:
            sys.exit("ssh-keygen couldn't sign (wrong passphrase, or OpenSSH older than 8.1?)")
        with open(msg_path + ".sig", encoding="utf-8") as f:
            sig = f.read()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    data = call(hub + "/api/v1/export", {"pubkey": pub, "nonce": ch["nonce"], "sig": sig, "format": "sshsig"})
    out = a.out or "combolab-hub-%s.json" % time.strftime("%Y-%m-%d")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f)
    print("Saved %s: %d combos, %d profiles, %d backups." % (out, len(data["combos"]), len(data["profiles"]), len(data["backups"])))


if __name__ == "__main__":
    main()
