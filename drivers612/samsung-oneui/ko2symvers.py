#!/usr/bin/env python3
"""ko2symvers.py OUT.symvers MOD.ko...: Module.symvers lines (crc, symbol, module, export type) read from
built modules' __kcrctab*/__crc_* symbols, so an external module can link against soc-repo module exports
with modversions (the dist .ko files carry their CRCs; no soc-repo Module.symvers is kept for them)."""
import os, subprocess, sys
NM = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-readelf')
def secs(ko):
    out = subprocess.run([NM, '-SW', ko], capture_output=True, text=True, check=True).stdout
    s = {}
    for l in out.splitlines():
        l = l.strip()
        if l.startswith('[') and l[1:].split(']')[0].strip().isdigit():
            p = l.split(']', 1)[1].split()
            if len(p) >= 5: s[p[0]] = int(p[3], 16)   # name -> file offset
    return s
def syms(ko):
    out = subprocess.run([NM, '-sW', ko], capture_output=True, text=True, check=True).stdout
    secidx = {}
    for l in subprocess.run([NM, '-SW', ko], capture_output=True, text=True, check=True).stdout.splitlines():
        l = l.strip()
        if l.startswith('[') and l[1:].split(']')[0].strip().isdigit():
            n, rest = l[1:].split(']', 1); p = rest.split()
            if p: secidx[n.strip()] = p[0]
    r = []
    for l in out.splitlines():
        p = l.split()
        if len(p) >= 8 and p[7].startswith('__crc_'):
            r.append((p[7][6:], int(p[1], 16), secidx.get(p[6])))
    return r
lines = []
for ko in sys.argv[2:]:
    data = open(ko, 'rb').read(); s = secs(ko); mod = os.path.basename(ko)[:-3]
    for name, val, sec in syms(ko):
        crc = int.from_bytes(data[s[sec] + val:s[sec] + val + 4], 'little')
        typ = 'EXPORT_SYMBOL_GPL' if sec.endswith('_gpl') else 'EXPORT_SYMBOL'
        lines.append('0x%08x\t%s\t%s\t%s\t' % (crc, name, mod, typ))
open(sys.argv[1], 'w').write('\n'.join(lines) + '\n')
print('%s: %d symbols' % (sys.argv[1], len(lines)))
