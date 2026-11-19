#!/usr/bin/env python3
"""compare.py <a/results.json> <b/results.json> [min_pct=5]: status changes and numeric deltas between two bench runs."""
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
minpct = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
ta = {t["id"]: t for t in a.get("tests", [])}; tb = {t["id"]: t for t in b.get("tests", [])}
print("A: kernel %s   B: kernel %s" % (a.get("device", {}).get("kernel"), b.get("device", {}).get("kernel")))
worse = 0
for i in list(ta) + [k for k in tb if k not in ta]:
    x, y = ta.get(i), tb.get(i)
    if x is None or y is None:
        print("%-16s only in %s (%s)" % (i, "A" if y is None else "B", (x or y)["status"])); continue
    if x["status"] != y["status"]:
        print("%-16s %s -> %s   %s" % (i, x["status"], y["status"], y.get("reason", "")[:120]))
        worse += y["status"] == "FAIL"
    nx, ny = x.get("numbers", {}), y.get("numbers", {})
    for k in sorted(set(nx) | set(ny)):
        u, v = nx.get(k), ny.get(k)
        if not isinstance(u, (int, float)) or not isinstance(v, (int, float)):
            if u != v: print("  %-14s %-28s %s -> %s" % (i, k, u, v))
            continue
        if u == v: continue
        pct = (v - u) / abs(u) * 100 if u else float("inf")
        if abs(pct) >= minpct: print("  %-14s %-28s %12g -> %-12g %+.1f%%" % (i, k, u, v, pct))
sys.exit(1 if worse else 0)
