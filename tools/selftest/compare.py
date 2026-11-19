#!/usr/bin/env python3
"""tools/selftest/compare.py <baseline> <new> [--tol 15]: compare two self-test runs.

Each argument is a run directory (logs/selftest/<serial>-<time>; results.json is (re)built from it when
missing) or a results.json. Prints test status changes (PASS->FAIL = REGRESSION, FAIL->PASS = FIXED, new and
removed tests) and metrics that moved more than --tol percent. The direction comes from the metric name:
lower is better for names containing fail, black, janky, oom, bad, crash, restarts, _ms, max_c, underrun,
kills; higher is better for kbs, iops, fps, hz, frames, mbit, snr, devices, ok, delivering; other metrics are
only reported. Exit status 1 when there is any regression (status or metric), else 0."""
import json, os, sys

LOWER = ("fail", "black", "janky", "oom", "bad", "crash", "restarts", "_ms", "max_c", "underrun", "kills")
HIGHER = ("kbs", "iops", "fps", "hz", "frames", "mbit", "snr", "devices", "ok", "delivering")


def load(arg):
    if os.path.isdir(arg):
        path = os.path.join(arg, "results.json")
        if not os.path.exists(path):
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import mkjson
            return mkjson.build(arg)
    else:
        path = arg
    with open(path) as f:
        return json.load(f)


def direction(name):
    n = name.lower()
    if any(k in n for k in LOWER):
        return -1
    if any(k in n for k in HIGHER):
        return 1
    return 0


def main():
    args = sys.argv[1:]
    tol = 15.0
    if "--tol" in args:
        i = args.index("--tol")
        try:
            tol = float(args[i + 1])
        except (IndexError, ValueError):
            print("--tol needs a number", file=sys.stderr)
            return 2
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    try:
        base, new = load(args[0]), load(args[1])
    except (OSError, ValueError) as e:
        print("cannot load: %s" % e, file=sys.stderr)
        return 2
    for tag, r in (("baseline", base), ("new", new)):
        print("%-8s %s  %s  kernel %s  quick=%s root=%s" % (tag, r.get("serial"), r.get("time"), r.get("kernel"),
                                                           r.get("quick"), r.get("root")))
    if base.get("quick") != new.get("quick"):
        print("NOTE: one run is --quick and the other is not: durations and loads differ")
    reg = 0
    bt, nt = base.get("tests", {}), new.get("tests", {})
    print("\nTEST STATUS CHANGES")
    changed = 0
    for tid in list(bt) + [t for t in nt if t not in bt]:
        b = bt.get(tid, {}).get("status")
        n = nt.get(tid, {}).get("status")
        if b == n:
            continue
        changed += 1
        if b is None:
            kind = "NEW"
            if n == "FAIL":
                kind = "NEW FAIL (REGRESSION)"
                reg += 1
        elif n is None:
            kind = "REMOVED"
        elif n == "FAIL":
            kind = "REGRESSION"
            reg += 1
        elif b == "FAIL" and n == "PASS":
            kind = "FIXED"
        elif b == "PASS" and n == "SKIP":
            kind = "LOST COVERAGE"
        else:
            kind = "changed"
        print("  %-22s %-14s %s -> %s  %s" % (kind, tid, b or "-", n or "-",
                                             (nt.get(tid) or bt.get(tid)).get("detail", "")[:140]))
    if not changed:
        print("  none")
    bm, nm = base.get("metrics", {}), new.get("metrics", {})
    print("\nMETRIC CHANGES (beyond %.0f %%)" % tol)
    shown = 0
    for k in sorted(set(bm) | set(nm)):
        b, n = bm.get(k), nm.get(k)
        if b is None or n is None:
            print("  %-12s %-34s %s -> %s" % ("new" if b is None else "removed", k, b, n))
            shown += 1
            continue
        if not isinstance(b, (int, float)) or not isinstance(n, (int, float)):
            if b != n:
                print("  %-12s %-34s %s -> %s" % ("changed", k, b, n))
                shown += 1
            continue
        if b == n:
            continue
        d = direction(k)
        if b == 0:
            pct = float("inf")  # from zero: any change counts
        else:
            pct = (n - b) * 100.0 / abs(b)
        if abs(pct) <= tol:
            continue
        worse = (d == -1 and n > b) or (d == 1 and n < b)
        better = (d == -1 and n < b) or (d == 1 and n > b)
        kind = "REGRESSION" if worse else "better" if better else "changed"
        if worse:
            reg += 1
        ptxt = "from 0" if pct == float("inf") else "%+.0f %%" % pct
        print("  %-12s %-34s %s -> %s  (%s)" % (kind, k, b, n, ptxt))
        shown += 1
    if not shown:
        print("  none")
    print("\n%d regression(s)" % reg)
    return 1 if reg else 0


if __name__ == "__main__":
    sys.exit(main())
