"""ComboLab profile merging, shared by the hub and the sync agent.

Same rules as Profile:merge in reframework/autorun/combolab/profile.lua:
  * samples are unioned by id (sample "u"; older samples get an id from their
    content), sorted by time and trimmed to the newest MAX_SAMPLES per step;
  * counters and learned action ids take the larger value from either side;
  * a reset (reset_at) on either side drops everything recorded before it.
These rules make merging repeatable: merging the same data twice, or in a
different order, gives the same result.
"""
import copy

MAX_SAMPLES = 300
COUNTERS = ("attempts", "successes", "train_attempts", "train_successes", "seq")


def _num(v):
    if v is None:
        return "-"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def sample_uid(k, s):
    """k is the 1-based step index, like the Lua side."""
    if s.get("u") is not None:
        return str(s["u"])
    return "L%d:%s:%s:%s:%s" % (k, _num(s.get("a")), _num(s.get("p")), _num(s.get("q")), s.get("res") or "-")


def _list(v):
    if isinstance(v, list):
        return v
    if isinstance(v, dict):  # Lua writes an empty table as {}
        try:
            return [v[k] for k in sorted(v, key=lambda x: int(x))]
        except (TypeError, ValueError):
            return []
    return []


def _map(v):
    if isinstance(v, dict):
        return v
    if isinstance(v, list):  # an empty Lua table may come back as []
        return {str(i + 1): x for i, x in enumerate(v) if x}
    return {}


def _f(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def _intify(v):
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def merge(a, b, max_samples=MAX_SAMPLES):
    """Merge profile b into a copy of profile a. Both must be the same combo
    version (combo_id and combo_hash); returns (merged, samples_added_from_b)."""
    if a is None:
        a = {"combo_id": b.get("combo_id"), "combo_hash": b.get("combo_hash"), "steps": []}
    out = copy.deepcopy(a)
    out.pop("windows", None)
    out.pop("reset", None)
    out.pop("shared_rev", None)
    ra, rb = _f(a.get("reset_at")), _f(b.get("reset_at"))
    R = max(ra, rb)
    a_full, b_full = ra == R, rb == R
    if not a_full:
        for f in COUNTERS:
            out[f] = 0
        out["neutral"] = {}
    if b_full:
        for f in COUNTERS:
            out[f] = _intify(max(_f(out.get(f)), _f(b.get(f))))
        nb = _map(b.get("neutral"))
        if nb:
            n = _map(out.get("neutral"))
            for k in nb:
                n[str(k)] = True
            out["neutral"] = n
    if R > 0:
        out["reset_at"] = _intify(R)
    for f in ("fighter_id",):
        if out.get(f) is None and b.get(f) is not None:
            out[f] = b[f]
    sa, sb = _list(a.get("steps")), _list(b.get("steps"))
    steps = []
    added = 0
    for i in range(max(len(sa), len(sb))):
        k = i + 1
        da = sa[i] if i < len(sa) and isinstance(sa[i], dict) else {}
        db = sb[i] if i < len(sb) and isinstance(sb[i], dict) else {}
        st = {"label": da.get("label", db.get("label"))}
        for f in ("ids", "tail"):
            m = dict(_map(da.get(f))) if a_full else {}
            if b_full:
                for key, n in _map(db.get(f)).items():
                    m[str(key)] = _intify(max(_f(m.get(str(key))), _f(n)))
            st[f] = m
        facts = da.get("facts") if isinstance(da.get("facts"), dict) else db.get("facts")
        if isinstance(facts, dict):
            st["facts"] = facts
        seen, samples = set(), []

        def take(s, mine):
            nonlocal added
            if not isinstance(s, dict):
                return
            if R > 0 and _f(s.get("t")) < R:
                return
            u = sample_uid(k, s)
            if u in seen:
                return
            seen.add(u)
            s = {key: _intify(v) for key, v in s.items()}
            s["u"] = u
            samples.append(s)
            if not mine:
                added += 1

        for s in _list(da.get("samples")):
            take(s, True)
        for s in _list(db.get("samples")):
            take(s, False)
        samples.sort(key=lambda s: (_f(s.get("t")), _f(s.get("a")), s["u"]))
        st["samples"] = samples[-max_samples:] if max_samples else samples
        steps.append(st)
    out["steps"] = steps
    return out, added


def sample_count(p):
    return sum(len(_list(st.get("samples"))) for st in _list(p.get("steps")) if isinstance(st, dict))


def origins(p):
    """Distinct machine tags among a profile's samples ("legacy" for old ones)."""
    seen = set()
    for st in _list(p.get("steps")):
        if isinstance(st, dict):
            for s in _list(st.get("samples")):
                u = str(s.get("u") or "")
                seen.add("legacy" if (not u or u.startswith("L")) else u.split("-")[0])
    return sorted(seen)
