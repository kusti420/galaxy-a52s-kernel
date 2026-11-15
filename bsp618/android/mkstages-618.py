#!/usr/bin/env python3
"""bsp618/android/stage-618/<name>/: the 6.12 Android-test module stages
(drivers612/androidboot/out/stage-<name>/) with every .ko replaced by its 6.18 port build.

For each 6.12 stage file the 6.12 build it came from is found by GNU build-id (the stage copies
are exact or --strip-debug copies; the build-id survives stripping), mapped to the same path in
the 6.18 port tree (bsp612/X, drivers612/X, samsung612/modules/X -> bsp618/src/...; bsp612/out/gki
-> bsp618/out-survey/gki; modules/hhwdt -> bsp618/src/modules/hhwdt) and copied under the SAME
file name, so the 6.12 load.list (order, NN- prefixes, insmod parameters, trailing "&") is reused
as is. Exceptions are applied to the list and written to stage-618/MAP.txt:
  dropped  built into the 6.18 GKI (hwmon: CONFIG_HWMON=y): the line is commented out
  moved    the 6.18 file is somewhere else in the port tree (found by unique basename)
  MISSING  no 6.18 build: the stage is incomplete (exit status 1)
pre.sh files are copied unchanged. Only .ko/load.list/pre.sh are written; nothing is loaded.
Usage: mkstages-618.py [stage ...]   (default: every 6.12 stage)"""
import glob, os, re, shutil, subprocess, sys

A = os.path.dirname(os.path.abspath(__file__))
B = os.path.dirname(A)
R = os.path.dirname(B)
S612 = os.path.join(R, 'drivers612/androidboot/out')
OUT = os.path.join(A, 'stage-618')
RE = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-readelf')
# 6.12 build trees a stage file can come from, in order of preference
ROOTS612 = ['bsp612/soc-repo-staging', 'drivers612', 'samsung612/modules', 'bsp612/techpacks',
            'bsp612/out/gki', 'modules/hhwdt']
# copies, not builds: packs, stages, install trees under */out/ (bsp612/out/gki is the GKI build)
NOT_A_BUILD = ('/out/', '/pack', '/stage/', '/dist/')
DROP618 = {'hwmon.ko': 'built into the 6.18 GKI (CONFIG_HWMON=y; soc-repo copy DROPPED in port618.py)'}


def build_id(p):
    o = subprocess.run([RE, '-n', p], capture_output=True, text=True).stdout
    m = re.search(r'Build ID:\s*([0-9a-f]+)', o)
    return m.group(1) if m else None


def index612():
    idx = {}
    for root in ROOTS612:
        for k in glob.glob(os.path.join(R, root, '**', '*.ko'), recursive=True):
            rel = os.path.relpath(k, R)
            if root != 'bsp612/out/gki' and any(s in '/' + rel for s in NOT_A_BUILD):
                continue
            b = build_id(k)
            if b:
                idx.setdefault(b, []).append(rel)
    return idx


def to618(rel):
    if rel.startswith('bsp612/out/gki/'):
        return os.path.join(B, 'out-survey/gki', rel[len('bsp612/out/gki/'):])
    return os.path.join(B, 'src', rel)


_by_name = None


def by_basename(name):
    global _by_name
    if _by_name is None:
        _by_name = {}
        for root in (os.path.join(B, 'src'), os.path.join(B, 'out-survey/gki')):
            for k in glob.glob(os.path.join(root, '**', '*.ko'), recursive=True):
                if any(s in k for s in ('/androidboot/out/', '/realboot/out/', '/donors/')):
                    continue
                _by_name.setdefault(os.path.basename(k), []).append(k)
    return _by_name.get(name, [])


def main():
    stages = sys.argv[1:] or sorted(os.path.basename(d)[6:] for d in glob.glob(os.path.join(S612, 'stage-*')))
    idx = index612()
    os.makedirs(OUT, exist_ok=True)
    rows, missing = [], 0
    for st in stages:
        src, dst = os.path.join(S612, 'stage-' + st), os.path.join(OUT, st)
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        os.makedirs(dst)
        lst = open(os.path.join(src, 'load.list')).read() if os.path.exists(os.path.join(src, 'load.list')) else None
        for f in ('pre.sh',):
            if os.path.exists(os.path.join(src, f)):
                shutil.copy2(os.path.join(src, f), os.path.join(dst, f))
        for k in sorted(glob.glob(os.path.join(src, '*.ko'))):
            fn = os.path.basename(k)
            plain = re.sub(r'^\d\d-', '', fn)
            o612 = sorted(idx.get(build_id(k), []),
                          key=lambda p: (next((i for i, r in enumerate(ROOTS612) if p.startswith(r + '/')), 99), len(p), p))
            o612 = o612[0] if o612 else None
            if plain in DROP618:
                rows.append((st, fn, o612, '-', 'dropped: ' + DROP618[plain]))
                if lst is not None:
                    lst = re.sub(r'^(' + re.escape(fn) + r'\b.*)$', r'# \1   # bsp618: ' + DROP618[plain], lst, flags=re.M)
                continue
            cand = to618(o612) if o612 else None
            status = 'ok'
            if not cand or not os.path.exists(cand):
                hits = by_basename(os.path.basename(o612) if o612 else plain)
                if len(hits) == 1:
                    cand, status = hits[0], 'moved'
                else:
                    rows.append((st, fn, o612, '-', f'MISSING ({len(hits)} basename matches)'))
                    missing += 1
                    continue
            shutil.copy2(cand, os.path.join(dst, fn))
            rows.append((st, fn, o612, os.path.relpath(cand, R), status))
        if lst is not None:
            open(os.path.join(dst, 'load.list'), 'w').write(lst)
    with open(os.path.join(OUT, 'MAP.txt'), 'w') as f:
        f.write('# stage  file  6.12-origin  6.18-source  status   (bsp618/android/mkstages-618.py)\n')
        for r in rows:
            f.write('  '.join(str(x) for x in r) + '\n')
    bad = [r for r in rows if r[4] != 'ok']
    print(f'stage-618: {len(stages)} stages, {len(rows)} files, {len(rows) - len(bad)} ok')
    for r in bad:
        print('  ', *r)
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
