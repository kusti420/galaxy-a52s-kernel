#!/usr/bin/env python3
"""Review aid: for every CONFIG_DISPLAY_SAMSUNG block, compare the code line just before and just
after it in the S23 tree and in our merged tree. Blocks whose neighbours differ on BOTH sides
(r7 rewrote the surrounding code) are listed for manual review; one-sided differences are counted.
Usage: hook-context-check.py <s23 display-drivers> <our display-drivers>"""
import re, sys, os
s23, ours = sys.argv[1:3]
IF = re.compile(r'^\s*#\s*(if|ifdef|ifndef)\b'); ENDIF = re.compile(r'^\s*#\s*endif\b')
def blocks(path):
    L = open(path, errors='replace').read().splitlines()
    res = []; i = 0
    def nb(idx, step):
        while 0 <= idx < len(L):
            t = L[idx].strip()
            if t and not t.startswith(('/*', '*', '//')): return t
            idx += step
        return ''
    while i < len(L):
        if IF.match(L[i]) and 'CONFIG_DISPLAY_SAMSUNG' in L[i] and not re.match(r'^\s*#\s*if\s+0', L[i]):
            d = 1; j = i + 1
            while j < len(L) and d:
                if IF.match(L[j]): d += 1
                elif ENDIF.match(L[j]): d -= 1
                j += 1
            key = '\n'.join(l.strip() for l in L[i:j] if l.strip())
            res.append((key, nb(i - 1, -1), nb(j, 1), i + 1)); i = j
        else: i += 1
    return res
both = one = ok = missing = 0
for root, _, files in os.walk(s23):
    rel = os.path.relpath(root, s23)
    if rel.startswith(('msm/samsung', 'msm/dp')): continue
    for f in files:
        if not f.endswith(('.c', '.h')): continue
        a = os.path.join(root, f); b = os.path.join(ours, rel, f)
        if 'CONFIG_DISPLAY_SAMSUNG' not in open(a, errors='replace').read() or not os.path.exists(b): continue
        ob = blocks(b); used = set()
        for key, pre, post, ln in blocks(a):
            m = next((k for k, x in enumerate(ob) if x[0] == key and k not in used), None)
            if m is None: missing += 1; print(f'ABSENT-OR-EDITED {rel}/{f} (s23 line {ln}): {key.splitlines()[1][:70] if len(key.splitlines())>1 else ""}'); continue
            used.add(m); _, p2, n2, l2 = ob[m]
            dp = pre != p2; dn = post != n2
            if dp and dn:
                both += 1; print(f'REVIEW {rel}/{f}:{l2}\n    s23 before: {pre[:90]}\n    our before: {p2[:90]}\n    s23 after : {post[:90]}\n    our after : {n2[:90]}')
            elif dp or dn:
                one += 1; print(f'ONE-SIDE {rel}/{f}:{l2} ({"before" if dp else "after"})\n    s23: {(pre if dp else post)[:100]}\n    our: {(p2 if dp else n2)[:100]}')
            else: ok += 1
print(f'blocks: same neighbours both sides {ok}, one side differs {one}, both differ {both}, absent/edited {missing}')
