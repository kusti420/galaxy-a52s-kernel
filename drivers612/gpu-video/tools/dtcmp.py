#!/usr/bin/env python3
"""Compare device-tree nodes of two dtbs property by property, with phandles resolved.
usage: dtcmp.py new.dtb phone.dtb NEWPATH[=PHONEPATH] ...
Phandle-carrying properties are printed as 'target-node-name args...' so trees with different
phandle numbers compare; specifier arguments (clock ids ...) are compared as numbers."""
import sys, struct, libfdt
PH = {'clocks': '#clock-cells', 'iommus': '#iommu-cells', 'interconnects': '#interconnect-cells',
      'mboxes': '#mbox-cells', 'nvmem-cells': None, 'memory-region': None, 'power-domains': '#power-domain-cells',
      'resets': '#reset-cells', 'qcom,msm-bus,vectors-KBps': None}
def load(p):
    f = libfdt.Fdt(open(p, 'rb').read()); ph = {}
    def walk(off, path):
        try: ph[f.get_phandle(off)] = (off, path)
        except Exception: pass
        try: sub = f.first_subnode(off)
        except libfdt.FdtException: return
        while True:
            walk(sub, path + '/' + f.get_name(sub))
            try: sub = f.next_subnode(sub)
            except libfdt.FdtException: break
    walk(0, ''); return f, ph
def props(f, off):
    d = {}
    try: p = f.first_property_offset(off)
    except libfdt.FdtException: return d
    while True:
        pr = f.get_property_by_offset(p); d[pr.name] = bytes(pr)
        try: p = f.next_property_offset(p)
        except libfdt.FdtException: break
    return d
def cells(b): return list(struct.unpack('>%dI' % (len(b) // 4), b[:len(b) // 4 * 4]))
def norm(f, ph, name, b):
    if name in ('phandle', 'linux,phandle'): return None
    if name.endswith('-supply') or (name in PH and PH[name] is None and name != 'qcom,msm-bus,vectors-KBps'):
        return ' '.join(ph.get(c, (0, '?%x' % c))[1].rsplit('/', 1)[-1] for c in cells(b))
    if name in PH and PH[name]:
        c = cells(b); out = []; i = 0
        while i < len(c):
            off, path = ph.get(c[i], (None, '?%x' % c[i])); n = 0
            if off is not None:
                try: n = cells(bytes(f.getprop(off, PH[name])))[0]
                except libfdt.FdtException: n = 0
            out.append(path.rsplit('/', 1)[-1] + ''.join(' %#x' % x for x in c[i + 1:i + 1 + n])); i += 1 + n
        return ' | '.join(out)
    if b and b[-1] == 0 and all(32 <= x < 127 or x == 0 for x in b) and b[0] != 0: return repr(b[:-1].decode().split('\0'))
    if len(b) % 4 == 0: return ' '.join('%#x' % x for x in cells(b))
    return b.hex()
def cmp(fa, pa, fb, pb, patha, pathb, st):
    try: oa = fa.path_offset(patha)
    except libfdt.FdtException: print('MISSING in new:', patha); st[1] += 1; return
    try: ob = fb.path_offset(pathb)
    except libfdt.FdtException: print('only in new (node):', patha); st[2] += 1; return
    A, B = props(fa, oa), props(fb, ob)
    for k in sorted(set(A) | set(B)):
        a = norm(fa, pa, k, A[k]) if k in A else None; b = norm(fb, pb, k, B[k]) if k in B else None
        if k in ('phandle', 'linux,phandle'): continue
        if a == b: st[0] += 1
        elif a is None: print('only in PHONE  %s : %s = %s' % (pathb, k, b)); st[1] += 1
        elif b is None: print('only in NEW    %s : %s = %s' % (patha, k, a)); st[2] += 1
        else: print('DIFF  %s : %s\n   new:   %s\n   phone: %s' % (patha, k, a, b)); st[3] += 1
    def subs(f, o):
        r = []
        try: s = f.first_subnode(o)
        except libfdt.FdtException: return r
        while True:
            r.append(f.get_name(s))
            try: s = f.next_subnode(s)
            except libfdt.FdtException: break
        return r
    sa, sb = subs(fa, oa), subs(fb, ob)
    for n in sa:
        if n in sb: cmp(fa, pa, fb, pb, patha + '/' + n, pathb + '/' + n, st)
        else: print('only in NEW (node)   ', patha + '/' + n); st[2] += 1
    for n in sb:
        if n not in sa: print('only in PHONE (node) ', pathb + '/' + n); st[1] += 1
fa, pa = load(sys.argv[1]); fb, pb = load(sys.argv[2]); st = [0, 0, 0, 0]
for spec in sys.argv[3:]:
    a, _, b = spec.partition('='); cmp(fa, pa, fb, pb, a, b or a, st)
print('SUMMARY: %d properties identical, %d only in phone, %d only in new, %d differ' % tuple(st))
