#!/usr/bin/env python3
"""Print the insmod order (paths) for the given 6.12 BSP modules and their dependencies,
leaving out what the bring-up ramdisk has already loaded (bsp612/out/bringup/load.list).
Usage: modorder.py <module name or .ko path> ...   (names without .ko; '-' and '_' are equal)"""
import os, sys, glob
top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
moddir = glob.glob(top + '/bsp612/out/dist/lib/modules/*')[0]
norm = lambda n: os.path.basename(n).replace('.ko', '').replace('-', '_')
dep = {}
for line in open(moddir + '/modules.dep'):
    k, v = line.split(':', 1)
    dep[norm(k)] = (os.path.join(moddir, k), [norm(x) for x in v.split()])
loaded = {norm(l.split()[0]) for l in open(top + '/bsp612/out/bringup/load.list') if l.strip() and not l.startswith('#')}
loaded |= {'hhwdt', 'sec_core'}
out, seen = [], set()
def add(n):
    if n in seen or n in loaded: return
    seen.add(n)
    if n not in dep: sys.stderr.write(f'modorder: {n} not in modules.dep (external module?)\n'); return
    for d in dep[n][1]: add(d)
    out.append(dep[n][0])
for a in sys.argv[1:]:
    if a.endswith('.ko') and os.path.exists(a): out.append(os.path.abspath(a))
    else: add(norm(a))
print('\n'.join(out))
