#!/usr/bin/env python3
"""Undefined-symbol check of the survey's built .ko files against 6.18 (modpost only prints 10).
Provider = 6.18 GKI Module.symvers + every Module.symvers the survey wrote. A missing symbol is
  cascade   exported by one of OUR 6.12 modules that failed to build on 6.18,
  gki-gap   exported by 6.12 GKI but not by 6.18 GKI (removed, renamed or unexported),
  other     neither (was unresolved on 6.12 too, or comes from an unsurveyed module).
Also lists GKI symbols the modules import whose namespace changed 6.12 -> 6.18.
Output: out-survey/symbols.json + summary. Usage: survey-symbols.py"""
import os, glob, json, subprocess, collections
B = os.path.dirname(os.path.abspath(__file__)); R = os.path.dirname(B)
S = os.environ.get('SURVEY_SRC', os.path.join(B, 'survey-src')); O = os.path.join(B, 'out-survey')
RS = os.environ.get('SURVEY_RESULTS', O)  # bsp618/port: results of the port tree go elsewhere
NM = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r596125/bin/llvm-nm')
SKIP = ('/donors/', '/androidboot/out/', '/out/')

def symvers(paths):
    d = {}
    for p in paths:
        for l in open(p):
            a = l.rstrip('\n').split('\t')
            if len(a) >= 4:
                d[a[1]] = a[4] if len(a) > 4 else ''
    return d

def kos(root):
    return [k for k in glob.glob(os.path.join(root, '**', '*.ko'), recursive=True) if not any(s in k for s in SKIP)]

g18 = symvers([os.path.join(O, 'gki/Module.symvers')])
g12 = symvers([os.path.join(R, 'bsp612/out/gki/Module.symvers')])
ours18 = symvers([p for p in glob.glob(os.path.join(S, '**/Module.symvers'), recursive=True) if not any(s in p for s in SKIP)])
ours12 = symvers([p for d in ('bsp612/soc-repo-staging', 'drivers612', 'samsung612/modules')
                  for p in glob.glob(os.path.join(R, d, '**/Module.symvers'), recursive=True) if not any(s in p for s in SKIP)])
miss = collections.defaultdict(lambda: collections.defaultdict(set))
ns = collections.defaultdict(set)
built = kos(S)
for k in built:
    m = os.path.relpath(k, S)
    for line in subprocess.run([NM, '-u', k], capture_output=True, text=True).stdout.split('\n'):
        sym = line.split()[-1] if line.split() else ''
        if not sym or sym.startswith('__this_module'):
            continue
        if sym in g18:
            if g12.get(sym, g18[sym]) != g18[sym]:
                ns[(sym, g12.get(sym), g18[sym])].add(m)
            continue
        if sym in ours18:
            continue
        kind = 'cascade' if sym in ours12 else ('gki-gap' if sym in g12 else 'other')
        miss[kind][sym].add(m)
out = {k: {s: sorted(v) for s, v in d.items()} for k, d in miss.items()}
out['namespace'] = [{'sym': a, 'ns612': b, 'ns618': c, 'modules': sorted(v)} for (a, b, c), v in ns.items()]
json.dump(out, open(os.path.join(RS, 'symbols.json'), 'w'), indent=1)
print(f"{len(built)} built .ko checked")
for k in ('cascade', 'gki-gap', 'other'):
    d = miss.get(k, {})
    mods = set(x for v in d.values() for x in v)
    print(f"{k:8s}: {len(d)} symbols, {len(mods)} modules")
    if k != 'cascade':
        for s, v in sorted(d.items(), key=lambda kv: -len(kv[1])):
            print(f"   {s}: {', '.join(sorted(os.path.basename(x) for x in v))}")
for e in out['namespace']:
    print(f"namespace {e['sym']}: {e['ns612']!r} -> {e['ns618']!r}: {', '.join(os.path.basename(x) for x in e['modules'])}")
