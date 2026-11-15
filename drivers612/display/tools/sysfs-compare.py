#!/usr/bin/env python3
"""Compare the sysfs attributes userspace touches between the 5.4 Samsung display framework
and the S23 (5.15) one: presence, mode, and whether the show/store bodies are textually the same.
Usage: sysfs-compare.py <5.4 samsung dir> <S23 samsung dir> <attr list file (class/name per line)>"""
import sys, re
def load(d):
    r = {}
    for f, cls in (('ss_dsi_panel_sysfs.c', None), ('ss_dsi_mdnie_lite_common.c', 'mdnie')):
        t = open(d + '/' + f, errors='replace').read()
        funcs = {}
        for m in re.finditer(r'\nstatic ssize_t (\w+)\s*\(', t):
            i = t.index('{', m.end()); dpt = 0; j = i
            while True:
                c = t[j]
                dpt += (c == '{') - (c == '}'); j += 1
                if dpt == 0: break
            funcs[m.group(1)] = re.sub(r'\s+', ' ', t[i:j])
        for m in re.finditer(r'DEVICE_ATTR\(\s*(\w+)\s*,\s*([^,]+?)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)', t):
            n, mode, sh, st = m.groups()
            # which group does it land in? backlight attrs are named in a bl array
            r.setdefault(n, []).append(dict(file=f, mode=re.sub(r'\s+', '', mode), show=funcs.get(sh), store=funcs.get(st), shn=sh, stn=st))
        for m in re.finditer(r'DEVICE_ATTR_(RO|RW|WO)\(\s*(\w+)\s*\)', t):
            n = m.group(2)
            r.setdefault(n, []).append(dict(file=f, mode=m.group(1), show=funcs.get(n + '_show'), store=funcs.get(n + '_store'), shn=n+'_show', stn=n+'_store'))
    return r
a, b = load(sys.argv[1]), load(sys.argv[2])
for line in open(sys.argv[3]):
    cls, n = line.split()
    want = 'ss_dsi_mdnie_lite_common.c' if cls == 'mdnie' else 'ss_dsi_panel_sysfs.c'
    ea = [e for e in a.get(n, []) if e['file'] == want]; eb = [e for e in b.get(n, []) if e['file'] == want]
    if not ea and not eb: print('%-8s %-24s ABSENT in both' % (cls, n)); continue
    if not ea: print('%-8s %-24s not in 5.4, present in S23' % (cls, n)); continue
    if not eb: print('%-8s %-24s MISSING in S23 (5.4 mode %s)' % (cls, n, ea[0]['mode'])); continue
    ea, eb = ea[0], eb[0]; notes = []
    if ea['mode'] != eb['mode']: notes.append('mode %s -> %s' % (ea['mode'], eb['mode']))
    for k in ('show', 'store'):
        if (ea[k] is None) != (eb[k] is None): notes.append('%s %s' % (k, 'added' if ea[k] is None else 'REMOVED'))
        elif ea[k] != eb[k]:
            # the user-visible format: sscanf/kstrto input formats and snprintf/sprintf/scnprintf/sysfs_emit output formats
            fmt = lambda body: sorted(set(re.findall(r'(?:sscanf|s?c?n?printf|sysfs_emit(?:_at)?|kstrto\w+)\s*\((?:[^;"]*?)("(?:[^"\\]|\\.)*"|\b\d+\b)', body)))
            fa, fb = fmt(ea[k]), fmt(eb[k])
            if fa != fb: notes.append('%s FORMAT differs: 5.4 %s | S23 %s' % (k, ' '.join(fa), ' '.join(fb)))
            else: notes.append('%s body differs, same formats' % k)
    print('%-8s %-24s %s' % (cls, n, '; '.join(notes) or 'identical'))
