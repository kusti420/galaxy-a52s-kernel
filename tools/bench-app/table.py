#!/usr/bin/env python3
"""Prints the result table of a results.json; exit 1 when any test FAILed or the file is missing/incomplete."""
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("no readable results.json:", e); sys.exit(1)
dev = d.get("device", {})
print("A52 Kernel Bench  %s  kernel %s  sdk %s" % (dev.get("model"), dev.get("kernel"), dev.get("sdk")))
bad = 0
for t in d.get("tests", []):
    nums = t.get("numbers", {})
    ns = " ".join("%s=%s" % (k, v) for k, v in list(nums.items())[:8])
    print("%-5s %-16s %6.1fs  %s" % (t["status"], t["id"], t.get("seconds", 0), t.get("reason", "")[:150]))
    if ns: print("      %s%s" % (ns[:190], " ..." if len(nums) > 8 else ""))
    bad += t["status"] == "FAIL"
if "finished_ms" not in d:
    print("INCOMPLETE: the run did not finish (last entry is the test that was running)"); bad += 1
else:
    print("pass=%s fail=%s skip=%s" % (d.get("pass"), d.get("fail"), d.get("skip")))
sys.exit(1 if bad else 0)
