#!/usr/bin/env python3
"""build-realboot.sh WALT=1: a52sxq_dsp_boot.c (work copy, in place) + the walt governor guard.
  mk-walt-source.py <work a52sxq_dsp_boot.c> <a52sxq_walt_guard.inc>
Three insertions at fixed anchors; fails if an anchor is missing or not unique."""
import sys
p, inc = sys.argv[1], sys.argv[2]
s = open(p).read(); g = open(inc).read()
def ins(s, anchor, text):
    if s.count(anchor) != 1: sys.exit("mk-walt-source.py: anchor not unique/missing: %r" % anchor[:60])
    return s.replace(anchor, anchor + text)
if "walt_guard_fn" in s: sys.exit("mk-walt-source.py: already patched")
s = ins(s, 'applied (kernfs store, no VFS)\\n", ok, ARRAY_SIZE(a52_tunables));\n}\n', g)
s = ins(s, '\tif (tunables)\n\t\ttunables_write();\n',
        '\tif (tunables && walt_guard_s) {\n\t\twalt_guard_end = jiffies + walt_guard_s * HZ;\n\t\tschedule_delayed_work(&walt_guard_work, 10 * HZ);\n\t}\n')
s = ins(s, '\tcancel_delayed_work_sync(&walt_boost_work);\n', '#ifdef A52_TUNABLES\n\tcancel_delayed_work_sync(&walt_guard_work);\n#endif\n')
open(p, "w").write(s)
