#!/usr/bin/env python3
"""Review aid: for every CONFIG_DISPLAY_SAMSUNG block, compare the name of the enclosing
function (nearest preceding column-0 definition line) in the S23 tree and in our merged tree.
A difference means the merge put the block into another function (twin functions with the same
lines), or r7 renamed/split the function. Usage: hook-function-check.py <s23> <ours>"""
import re, sys, os
s23, ours = sys.argv[1:3]
IF = re.compile(r'^\s*#\s*(if|ifdef|ifndef)\b'); ENDIF = re.compile(r'^\s*#\s*endif\b')
FN = re.compile(r'^(?!#|typedef|struct\b.*[;{]\s*$|enum\b|union\b|/\*|\s|\}|EXPORT|module_|MODULE|DEFINE|static DEFINE|static DEVICE_ATTR|late_initcall)[A-Za-z_].*?\b([A-Za-z_]\w*)\s*\([^;]*$')
def blocks(path):
    L = open(path, errors='replace').read().splitlines(); res = []; i = 0; fn = '<file scope>'; depth_fn = ''
    while i < len(L):
        m = FN.match(L[i])
        if m: fn = m.group(1)
        elif L[i].startswith('}'): fn = '<file scope after ' + fn.replace('<file scope after ', '').rstrip('>') + '>'
        if IF.match(L[i]) and 'CONFIG_DISPLAY_SAMSUNG' in L[i] and not re.match(r'^\s*#\s*if\s+0', L[i]):
            d = 1; j = i + 1; inner = None
            while j < len(L) and d:
                if IF.match(L[j]): d += 1
                elif ENDIF.match(L[j]): d -= 1
                mm = FN.match(L[j])
                if mm and inner is None: inner = mm.group(1)
                j += 1
            key = '\n'.join(l.strip() for l in L[i:j] if l.strip())
            res.append((key, fn if not fn.startswith('<file') else '<file scope>', i + 1))
            if inner: fn = inner
            i = j
        else: i += 1
    return res
bad = n = 0
for root, _, files in os.walk(s23):
    rel = os.path.relpath(root, s23)
    if rel.startswith(('msm/samsung', 'msm/dp')): continue
    for f in files:
        if not f.endswith('.c'): continue
        a = os.path.join(root, f); b = os.path.join(ours, rel, f)
        if 'CONFIG_DISPLAY_SAMSUNG' not in open(a, errors='replace').read() or not os.path.exists(b): continue
        ob = blocks(b); used = set()
        for key, fn, ln in blocks(a):
            m = next((k for k, x in enumerate(ob) if x[0] == key and k not in used), None)
            if m is None: continue
            used.add(m); n += 1
            if ob[m][1] != fn:
                bad += 1; print(f'FUNCTION DIFFERS {rel}/{f}:{ob[m][2]}  s23: {fn}  ours: {ob[m][1]}   [{key.splitlines()[1][:60] if len(key.splitlines()) > 1 else ""}]')
print(f'{n} blocks compared, {bad} in a different function')
