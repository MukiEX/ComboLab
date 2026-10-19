"""ComboLab hub: viewer keys and admin password (standard library only).

* Ed25519 signature verification (RFC 8032, verify only; no secrets touched).
* OpenSSH public keys ("ssh-ed25519 AAAA... comment") and SSH signatures made
  with  ssh-keygen -Y sign -n combolab-export  (the SSHSIG format).
* Admin password hashing with PBKDF2-SHA256.
"""
import base64
import hashlib
import hmac
import os
import struct

# ---------------------------------------------------------------- Ed25519
_p = 2 ** 255 - 19
_q = 2 ** 252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, _p - 2, _p)


_d = -121665 * _inv(121666) % _p
_sqrt_m1 = pow(2, (_p - 1) // 4, _p)


def _recover_x(y, sign):
    if y >= _p:
        return None
    x2 = (y * y - 1) * _inv(_d * y * y + 1)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_p + 3) // 8, _p)
    if (x * x - x2) % _p != 0:
        x = x * _sqrt_m1 % _p
    if (x * x - x2) % _p != 0:
        return None
    if (x & 1) != sign:
        x = _p - x
    return x


def _add(P, Q):
    A = (P[1] - P[0]) * (Q[1] - Q[0]) % _p
    B = (P[1] + P[0]) * (Q[1] + Q[0]) % _p
    C = 2 * P[3] * Q[3] * _d % _p
    D = 2 * P[2] * Q[2] % _p
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F, G * H, F * G, E * H)


def _mul(s, P):
    Q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            Q = _add(Q, P)
        P = _add(P, P)
        s >>= 1
    return Q


def _equal(P, Q):
    return (P[0] * Q[2] - Q[0] * P[2]) % _p == 0 and (P[1] * Q[2] - Q[1] * P[2]) % _p == 0


_gy = 4 * _inv(5) % _p
_gx = _recover_x(_gy, 0)
_G = (_gx, _gy, 1, _gx * _gy % _p)


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % _p)


def ed25519_verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    A = _decompress(public)
    R = _decompress(sig[:32])
    if A is None or R is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _q:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + public + msg).digest(), "little") % _q
    return _equal(_mul(s, _G), _add(R, _mul(h, A)))


# ---------------------------------------------------------------- SSH wire format
def _string(b):
    return struct.pack(">I", len(b)) + b


def _read_string(buf, i):
    if i + 4 > len(buf):
        raise ValueError("truncated")
    n = struct.unpack(">I", buf[i:i + 4])[0]
    if i + 4 + n > len(buf):
        raise ValueError("truncated")
    return buf[i + 4:i + 4 + n], i + 4 + n


def parse_public_key(text):
    """'ssh-ed25519 AAAA... [comment]' -> 32-byte key. Raises ValueError."""
    parts = (text or "").strip().split()
    if len(parts) < 2 or parts[0] != "ssh-ed25519":
        raise ValueError("expected an ssh-ed25519 public key")
    blob = base64.b64decode(parts[1], validate=True)
    kt, i = _read_string(blob, 0)
    key, i = _read_string(blob, i)
    if kt != b"ssh-ed25519" or len(key) != 32 or i != len(blob):
        raise ValueError("not an ed25519 key")
    return key


def format_public_key(raw, comment=""):
    blob = _string(b"ssh-ed25519") + _string(raw)
    s = "ssh-ed25519 " + base64.b64encode(blob).decode("ascii")
    return s + (" " + comment if comment else "")


def fingerprint(raw):
    """OpenSSH-style SHA256 fingerprint, as ssh-keygen -l shows it."""
    blob = _string(b"ssh-ed25519") + _string(raw)
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode("ascii").rstrip("=")


def verify_sshsig(armored, raw_key, msg, namespace):
    """Checks an 'SSH SIGNATURE' made by ssh-keygen -Y sign with this key."""
    body = "".join(l.strip() for l in armored.strip().splitlines()
                   if l.strip() and not l.startswith("-----"))
    blob = base64.b64decode(body)
    if blob[:6] != b"SSHSIG":
        return False
    if struct.unpack(">I", blob[6:10])[0] != 1:
        return False
    i = 10
    pub, i = _read_string(blob, i)
    ns, i = _read_string(blob, i)
    reserved, i = _read_string(blob, i)
    halg, i = _read_string(blob, i)
    sigblob, i = _read_string(blob, i)
    kt, j = _read_string(pub, 0)
    key, j = _read_string(pub, j)
    if kt != b"ssh-ed25519" or key != raw_key or ns != namespace.encode():
        return False
    if halg == b"sha512":
        h = hashlib.sha512(msg).digest()
    elif halg == b"sha256":
        h = hashlib.sha256(msg).digest()
    else:
        return False
    st, j = _read_string(sigblob, 0)
    sig, j = _read_string(sigblob, j)
    if st != b"ssh-ed25519":
        return False
    signed = b"SSHSIG" + _string(ns) + _string(reserved) + _string(halg) + _string(h)
    return ed25519_verify(raw_key, signed, sig)


# ---------------------------------------------------------------- admin password
PBKDF2_ROUNDS = 600000


def hash_password(pw):
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), salt, PBKDF2_ROUNDS)
    return "pbkdf2_sha256$%d$%s$%s" % (PBKDF2_ROUNDS, salt.hex(), h.hex())


def check_password(pw, stored):
    try:
        algo, rounds, salt, h = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        got = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt), int(rounds))
        return hmac.compare_digest(got.hex(), h)
    except (ValueError, AttributeError):
        return False
