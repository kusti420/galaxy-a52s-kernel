#!/usr/bin/env python3
"""attrtable.py <sec-battery.ko>: print the oneui_attrs[] device_attribute table (name, mode, show, store)
resolved from the module's relocations (proof the attributes are compiled in with the 5.4 names/modes)."""
import os
import subprocess, sys, struct
RE = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-readelf')
ko = sys.argv[1]; d = open(ko, 'rb').read()
def run(*a): return subprocess.run([RE, *a, ko], capture_output=True, text=True, check=True).stdout
off, idx = {}, {}
for l in run('-SW').splitlines():
    l = l.strip()
    if l.startswith('[') and l[1:].split(']')[0].strip().isdigit():
        n, rest = l[1:].split(']', 1); p = rest.split()
        if len(p) > 4: off[p[0]] = int(p[3], 16); idx[n.strip()] = p[0]
syms, objs = {}, {}
for l in run('-sW').splitlines():
    p = l.split()
    if len(p) >= 8 and p[3] == 'FUNC': syms[(idx.get(p[6]), int(p[1], 16))] = p[7]
    if len(p) >= 8 and p[3] == 'OBJECT' and p[7] == 'oneui_attrs': objs = (idx[p[6]], int(p[1], 16), int(p[2]))
sec, base, size = objs
rel = {}
cur = None
for l in run('-rW').splitlines():
    if l.startswith('Relocation section'): cur = l.split("'")[1]; continue
    p = l.split()
    if cur == '.rela' + sec and len(p) >= 7 and p[2] == 'R_AARCH64_ABS64':
        rel[int(p[0], 16)] = (p[4], int(p[6], 16))
def cstr(o): return d[o:d.index(b'\0', o)].decode()
for i in range(size // 32):
    e = base + i * 32
    ns, no = rel[e]; mode = struct.unpack_from('<H', d, off[sec] + e + 8)[0]
    show = syms.get(rel[e + 16]); store = syms.get(rel[e + 24])
    print('oneui_attrs[%d]: name=%-17s mode=0%o show=%s store=%s' % (i, cstr(off[ns] + no), mode, show, store))
