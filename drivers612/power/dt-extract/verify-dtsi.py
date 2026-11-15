#!/usr/bin/env python3
"""Check a52sxq-power.dtsi against downstream-dt/a52sxq-r02.dts: every property line must
appear verbatim (whitespace-normalised) in r02, except lines whose phandles were replaced
by labels and the few documented additions. Prints the exceptions for review."""
import re,os
H=os.path.dirname(os.path.abspath(__file__))
n=lambda l: re.sub(r'\s+',' ',l.strip())
import sys
src=set(n(l) for l in open(sys.argv[1] if len(sys.argv)>1 else H+'/../../../downstream-dt/a52sxq-r02.dts'))
bad=[];ok=0;incomment=False
for i,l in enumerate(open(H+'/../a52sxq-power.dtsi'),1):
    s=n(l)
    if s.startswith('/*'): incomment=True
    if incomment:
        if '*/' in s: incomment=False
        continue
    if not s or s.startswith(('//','*')) or s in ('};','/ {') or s.endswith('{'): continue
    if s in src: ok+=1
    else: bad.append((i,s[:110]))
print('verbatim property lines:',ok); print('not verbatim (%d) — must all be label substitutions or documented additions:'%len(bad))
for b in bad: print('  %4d: %s'%b)
