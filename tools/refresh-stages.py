#!/usr/bin/env python3
"""Replaces every .ko in drivers612/androidboot/out/stage-*/ with the current build of the same
module (by file name, numeric 'NN-' prefix ignored): bsp612/out/dist (GKI + soc-repo), then the
project's own build trees. Strips debug info. Reports anything it could not find."""
import os, glob, shutil, subprocess, re, sys
top = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
strip = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-strip')
idx = {}
def add(root, prio):
    for p in glob.glob(root + '/**/*.ko', recursive=True):
        if '/donors/' in p or '/out/stage-' in p or '/pack' in p.split(top)[-1] or '/hwbringup/' in p or '/wifibt/' in p: continue
        n = os.path.basename(p)
        if n not in idx or idx[n][0] > prio or (idx[n][0] == prio and os.path.getmtime(p) > os.path.getmtime(idx[n][1])):
            idx[n] = (prio, p)
add(top + '/bsp612/out/dist/lib/modules', 0)
add(top + '/bsp612/out/bringup', 1)
for r in ('drivers612', 'samsung612/modules', 'modules/ioncompat'):
    add(top + '/' + r, 2)
# the patched pd-mapper is now part of bsp612 (patches 0005/0006)
alias = {'qcom_pd_mapper_a52.ko': 'qcom_pd_mapper.ko'}
miss = 0
for st in sorted(glob.glob(top + '/drivers612/androidboot/out/stage-*')):
    for k in sorted(glob.glob(st + '/*.ko')):
        n = re.sub(r'^\d+-', '', os.path.basename(k)); n = alias.get(n, n)
        if n not in idx:
            print('MISSING', os.path.relpath(k, top)); miss += 1; continue
        shutil.copy(idx[n][1], k); subprocess.run([strip, '--strip-debug', k])
    print(os.path.basename(st), 'refreshed')
sys.exit(1 if miss else 0)
