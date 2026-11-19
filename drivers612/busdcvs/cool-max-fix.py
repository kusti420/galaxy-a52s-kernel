#!/usr/bin/env python3
# Prints "<node path> <cells...>" for every cooling-maps entry whose cooling-device uses Qualcomm's 5.4-only
# THERMAL_MAX_LIMIT (0xfffffffe = "go straight to the device's max state"), with those cells replaced by
# THERMAL_NO_LIMIT (0xffffffff: lower -> 0, upper -> max_state), which 6.12's thermal core accepts.
# 6.12 rejects -2 with "binding cdev ... to trip N failed: -22", so PMIC-temp/BCL zones never throttled kgsl/cdsp.
# Usage: cool-max-fix.py <decompiled dts>   (dt-fix.sh applies the output with fdtput)
import re, sys
path = []
for line in open(sys.argv[1]):
    s = line.strip()
    m = re.match(r'^(?:[\w,.-]+:\s*)*([^\s{]+)\s*\{$', s)
    if m:
        path.append('' if m.group(1) == '/' else m.group(1)); continue
    if s.startswith('};'):
        path.pop(); continue
    m = re.match(r'^cooling-device = <(.*)>;$', s)
    if m and '0xfffffffe' in m.group(1):
        cells = m.group(1).split()
        if len(cells) % 3: sys.exit('cooling-device not in phandle/lower/upper triples: ' + '/'.join(path))
        out = [c if (i % 3 == 0 or c != '0xfffffffe') else '0xffffffff' for i, c in enumerate(cells)]
        print('/'.join(path) or '/', ' '.join(out))
