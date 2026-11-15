#!/usr/bin/env python3
"""Transplant Samsung's CONFIG_DISPLAY_SAMSUNG hooks from the S23 (sm8550) display tree onto
Qualcomm's r7 techpack by a 3-way merge per file:
  base   = S23 file with every CONFIG_DISPLAY_SAMSUNG block evaluated as "not set" (pure QC 5.15-era code)
  theirs = S23 file as shipped (with hooks)
  ours   = r7 file
Usage: transplant.py <s23 display-drivers> <pristine r7 display-drivers> <output display-drivers>
Writes merged files to output, conflict report to stdout."""
import re, sys, os, subprocess, tempfile
s23, r7, out = sys.argv[1:4]
IF = re.compile(r'^\s*#\s*(if|ifdef|ifndef)\b(.*)')
ELSE = re.compile(r'^\s*#\s*else\b'); ELIF = re.compile(r'^\s*#\s*elif\b'); ENDIF = re.compile(r'^\s*#\s*endif\b')
def cond_value(kind, rest):
    """None = not a Samsung condition; True/False = value with DISPLAY_SAMSUNG unset."""
    r = rest.split('/*')[0].split('//')[0].strip()
    if 'CONFIG_DISPLAY_SAMSUNG' not in r: return None
    if kind == 'ifdef': return False
    if kind == 'ifndef': return True
    if re.match(r'^0\b', r): return None
    neg = bool(re.match(r'^!\s*(IS_ENABLED|defined)\s*\(\s*CONFIG_DISPLAY_SAMSUNG\s*\)\s*$', r))
    if neg: return True
    if re.match(r'^(IS_ENABLED|defined)\s*\(\s*CONFIG_DISPLAY_SAMSUNG\s*\)(\s*&&.*)?$', r): return False
    raise SystemExit('unhandled condition: ' + rest)
def strip(lines):
    res = []; stack = []  # entries: None (foreign if) or [value, in_else]
    def emitting(): return all(e is None or (e[0] != e[1]) for e in stack)
    for l in lines:
        m = IF.match(l)
        if m:
            v = cond_value(m.group(1), m.group(2))
            if v is None:
                if emitting(): res.append(l)
                stack.append(None)
            else: stack.append([v, False])
            continue
        if ELIF.match(l) and stack and stack[-1] is not None: raise SystemExit('elif in samsung block')
        if ELSE.match(l) and stack and stack[-1] is not None:
            stack[-1][1] = True; continue
        if ENDIF.match(l):
            e = stack.pop()
            if e is None and emitting(): res.append(l)
            continue
        if emitting(): res.append(l)
    assert not stack
    return res
tot = 0
for root, dirs, files in os.walk(s23):
    rel = os.path.relpath(root, s23)
    if rel.startswith(('msm/samsung', 'msm/dp', '.git')): continue
    for f in files:
        if not f.endswith(('.c', '.h')): continue
        p = os.path.join(root, f); rp = os.path.join(rel, f)
        txt = open(p, errors='replace').read()
        if 'CONFIG_DISPLAY_SAMSUNG' not in txt: continue
        ours = os.path.join(r7, rp)
        if not os.path.exists(ours): print('NO r7 FILE', rp); continue
        base = ''.join(strip(txt.splitlines(True)))
        with tempfile.NamedTemporaryFile('w', suffix='.base', delete=False) as b: b.write(base)
        r = subprocess.run(['git', 'merge-file', '-p', '--diff3', '-L', 'r7', '-L', 's23-base', '-L', 's23-samsung', ours, b.name, p], capture_output=True)
        os.unlink(b.name)
        o = os.path.join(out, rp); open(o, 'wb').write(r.stdout)
        n = r.stdout.count(b'\n<<<<<<< ')
        tot += n
        print(f'{n:3d} conflicts  {txt.count("CONFIG_DISPLAY_SAMSUNG"):3d} hooks  {rp}')
print('total conflicts', tot)
