#!/usr/bin/env python3
# Compares the exports of two kernels (vmlinux.symvers: CRC, symbol, module, export type, namespace) and says
# which of our modules import a changed one.
#   crc-compare.py <base vmlinux.symvers> <variant vmlinux.symvers> <report> [dir with *.ko ...]
# Report lines: CHANGED <sym> <base crc> <new crc> | MISSING <sym> | NEW <sym> | IMPORT <module.ko> <sym>
# A module's imports are read from its __versions section (CRC + name records of 64 bytes).
import os
import struct
import sys


def load(p):
    d = {}
    for l in open(p):
        f = l.rstrip('\n').split('\t')
        d[f[1]] = (f[0], f[3], f[4] if len(f) > 4 else '')
    return d


def imports(ko):
    d = open(ko, 'rb').read()
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    sec = [struct.unpack_from('<IIQQQQ', d, shoff + i * shentsize) for i in range(shnum)]
    stro = sec[shstrndx][4]
    out = {}
    for name, _, _, _, off, size in sec:
        if d[stro + name:d.index(b'\0', stro + name)] != b'__versions':
            continue
        for i in range(off, off + size - 63, 64):
            crc, = struct.unpack_from('<Q', d, i)
            out[d[i + 8:i + 64].split(b'\0', 1)[0].decode()] = '0x%08x' % crc
    return out


base, var = load(sys.argv[1]), load(sys.argv[2])
rep = []
bad = set()
for s in sorted(base):
    if s not in var:
        rep.append('MISSING %s' % s)
        bad.add(s)
    elif var[s] != base[s]:
        rep.append('CHANGED %s %s %s' % (s, base[s][0], var[s][0]))
        bad.add(s)
new = sorted(set(var) - set(base))
rep += ['NEW %s' % s for s in new]
nmod = nimp = 0
hit = {}
for d in sys.argv[4:]:
    for root, _, files in os.walk(d):
        for f in sorted(files):
            if not f.endswith('.ko'):
                continue
            nmod += 1
            imp = imports(os.path.join(root, f))
            for s, crc in imp.items():
                nimp += 1
                if s in bad:
                    hit.setdefault(f, []).append(s)
                elif s in var and var[s][0] != crc:
                    hit.setdefault(f, []).append(s + ' (module has %s, variant %s)' % (crc, var[s][0]))
for m in sorted(hit):
    rep += ['IMPORT %s %s' % (m, s) for s in hit[m]]
open(sys.argv[3], 'w').write('\n'.join(rep) + ('\n' if rep else ''))
print('exports: base %d, variant %d; changed/missing %d, new %d' % (len(base), len(var), len(bad), len(new)))
if sys.argv[4:]:
    print('modules checked: %d (%d imported symbols); modules with a mismatching import: %d' % (nmod, nimp, len(hit)))
