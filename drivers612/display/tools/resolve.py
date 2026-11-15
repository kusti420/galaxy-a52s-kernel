#!/usr/bin/env python3
"""Second pass after transplant.py: resolve diff3 conflicts where the Samsung side is the base
plus pure insertions (always true for #if blocks) by anchoring every inserted run on the
nearest base line that still exists exactly once in r7's side of the conflict.
Every automatic placement is logged (file:line of the result) for human review.
Usage: resolve.py <display-drivers dir> <review log>"""
import sys, os, re, difflib
root, logp = sys.argv[1:3]
log = open(logp, 'w'); left = 0; done = 0
def resolve(O, B, T):
    if not any(l.strip() for l in O + B): return list(T), 'both r7 and base only blank lines: samsung side taken'
    sm = difflib.SequenceMatcher(None, B, T, autojunk=False)
    ins = []  # (base index, lines)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal': continue
        if tag != 'insert': return None, 'samsung side is not base+insertions'
        ins.append((i1, T[j1:j2]))
    Os = [l.strip() for l in O]
    def uniq(s): return s and Os.count(s) == 1
    places = []  # (index in O to insert before, lines, how)
    for n, (i, lines) in enumerate(ins):
        # the lines just outside the conflict are common to all three sides: exact anchors
        if i == 0: places.append((0, n, lines, 'hunk start')); continue
        if i == len(B): places.append((len(O), n, lines, 'hunk end')); continue
        pre = next(((i - 1 - k, k) for k in range(i) if uniq(B[i - 1 - k].strip())), None)
        post = next(((i + k, k) for k in range(len(B) - i) if uniq(B[i + k].strip())), None)
        if pre and (not post or pre[1] <= post[1]):
            places.append((Os.index(B[pre[0]].strip()) + 1, n, lines, f'after "{B[pre[0]].strip()[:60]}" (dist {pre[1]})'))
        elif post:
            places.append((Os.index(B[post[0]].strip()), n, lines, f'before "{B[post[0]].strip()[:60]}" (dist {post[1]})'))
        else: return None, 'no anchor for an insertion in the middle'
    res = list(O); hows = []
    for pos, n, lines, how in sorted(places, key=lambda p: (-p[0], -p[1])):
        res[pos:pos] = lines; hows.append(how)
    return res, '; '.join(reversed(hows))
for d, _, files in os.walk(root):
    for f in files:
        if not f.endswith(('.c', '.h')): continue
        p = os.path.join(d, f); L = open(p, errors='replace').read().splitlines(True)
        if not any(l.startswith('<<<<<<< r7') for l in L): continue
        out = []; i = 0
        while i < len(L):
            if not L[i].startswith('<<<<<<< r7'): out.append(L[i]); i += 1; continue
            a = i; b = next(k for k in range(a, len(L)) if L[k].startswith('||||||| s23-base'))
            c = next(k for k in range(b, len(L)) if L[k].startswith('======='))
            e = next(k for k in range(c, len(L)) if L[k].startswith('>>>>>>> s23-samsung'))
            res, how = resolve(L[a+1:b], L[b+1:c], L[c+1:e])
            rel = os.path.relpath(p, root)
            if res is None:
                left += 1; log.write(f'UNRESOLVED {rel}:{len(out)+1}: {how}\n'); out.extend(L[a:e+1])
            else:
                done += 1
                risky = 'no anchor' in how or re.search(r'dist [1-9]', how)
                log.write(f'{"CHECK" if risky else "auto "} {rel}:{len(out)+1}: {how}\n'); out.extend(res)
            i = e + 1
        open(p, 'w').write(''.join(out))
print('resolved', done, 'left', left)
