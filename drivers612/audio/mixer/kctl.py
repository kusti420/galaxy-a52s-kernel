#!/usr/bin/env python3
"""Static kcontrol-name extractor for the msm audio techpack (regex based).
usage: kctl.py <tree root> [subdir ...]  -> prints "name<TAB>file" lines
Limits: ignores #ifdef (superset of all configs); names built at run time
(snprintf/kasprintf, macro string pasting with arguments) are not seen;
codec name_prefix is not applied (lahaina.c sets none for bolero/wcd93xx);
DAPM mixer controls are "<widget> <ctl>", mux/demux controls are "<widget>"."""
import re, sys, os
root = sys.argv[1]; subs = sys.argv[2:] or ['.']
CM = re.compile(r'/\*.*?\*/|//[^\n]*', re.S)
ARR = re.compile(r'struct\s+snd_kcontrol_new\s+(\w+)\s*(\[[^\]]*\])?\s*=\s*')
MAC = re.compile(r'\b([A-Z][A-Z0-9_]+)\s*\(\s*"((?:[^"\\]|\\.)*)"')
NAME = re.compile(r'\.name\s*=\s*"((?:[^"\\]|\\.)*)"')
WID = re.compile(r'\bSND_SOC_DAPM_(\w+)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,')
def body(s, i):
    d = 0; j = i
    while j < len(s):
        c = s[j]
        if c == '"':
            j += 1
            while j < len(s) and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
        elif c in '({': d += 1
        elif c in ')}': d -= 1
        elif c == ';' and d == 0: return s[i:j], j
        j += 1
    return s[i:], j
def args(s, i):  # from after '(' matched... find closing paren
    d = 1; j = i
    while j < len(s) and d:
        c = s[j]
        if c == '"':
            j += 1
            while j < len(s) and s[j] != '"':
                j += 2 if s[j] == '\\' else 1
        elif c == '(': d += 1
        elif c == ')': d -= 1
        j += 1
    return s[i:j]
out = set()
for sub in subs:
    for dp, dn, fn in os.walk(os.path.join(root, sub)):
        for f in fn:
            if not f.endswith(('.c', '.h')): continue
            p = os.path.join(dp, f); rel = os.path.relpath(p, root)
            s = CM.sub(' ', open(p, errors='replace').read())
            arrays = {}; spans = []
            for m in ARR.finditer(s):
                b, e = body(s, m.end())
                names = [x.group(2) for x in MAC.finditer(b) if not x.group(1).startswith('SND_SOC_DAPM_')]
                names += [x.group(1) for x in NAME.finditer(b)]
                arrays[m.group(1)] = names; spans.append((m.end(), e))
            used = set()
            for m in WID.finditer(s):
                kind, w = m.group(1), m.group(2)
                a = args(s, m.end())
                ids = [i for i in re.findall(r'\b[A-Za-z_]\w*\b', a) if i in arrays]
                base = kind.replace('_E', '') if kind.endswith('_E') else kind
                if base in ('MUX', 'DEMUX', 'VIRT_MUX', 'VALUE_MUX'):
                    out.add((w, rel)); used.update(ids)
                elif ids:
                    for i in ids:
                        used.add(i)
                        for n in arrays[i]:
                            if base == 'MIXER_NAMED_CTL': out.add((n, rel))
                            else: out.add((w + ' ' + n, rel))
            # codec-local wrappers such as RX_MACRO_DAPM_MUX("name", ...) / *_DAPM_ENUM widgets
            for m in re.finditer(r'\b(?!SND_SOC_)(\w*DAPM_MUX\w*)\s*\(\s*"((?:[^"\\]|\\.)*)"', s):
                out.add((m.group(2), rel + ' (wrapper mux macro)'))
            for a, names in arrays.items():
                if a in used: continue
                for n in names: out.add((n, rel))
            # kcontrol macros outside any snd_kcontrol_new initializer (e.g. inside #define lists)
            for m in MAC.finditer(s):
                if any(b <= m.start() < e for b, e in spans): continue
                if re.match(r'SOC_(SINGLE|DOUBLE|ENUM|VALUE_ENUM|BYTES|SND_SOC_BYTES)|SND_SOC_BYTES', m.group(1)) and not m.group(1).startswith('SOC_DAPM'):
                    out.add((m.group(2), rel + ' (macro outside array)'))
for n, f in sorted(out): print(n + '\t' + f)
