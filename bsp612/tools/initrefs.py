#!/usr/bin/env python3
"""Finds the bug class of the qcom_tsens crash in kernel modules: relocations in data that
stays alive after module init (.data, .rodata, .data.rel.ro...) pointing to code in
.init.text, which is freed once the module is loaded. A later call (deferred probe, ops
table) then lands in reused memory. Usage: initrefs.py <module.ko> ...
Needs pyelftools-free operation: uses llvm-readelf output."""
import os
import subprocess, sys, re
RE = os.path.expandvars('$ANDROID_TREE/prebuilts/clang/host/linux-x86/clang-r547379/bin/llvm-readelf')
LIVE = re.compile(r'^\.(data|rodata)(\.|$)|^\.data\.rel\.ro')
for ko in sys.argv[1:]:
    out = subprocess.run([RE, '-S', '-s', '-r', '--wide', ko], capture_output=True, text=True).stdout
    secs = {}
    for m in re.finditer(r'^\s*\[\s*(\d+)\]\s+(\S+)', out, re.M):
        secs[m.group(1)] = m.group(2)
    syms = {}
    for m in re.finditer(r'^\s*\d+:\s+[0-9a-f]+\s+\d+\s+(\w+)\s+\w+\s+\w+\s+(\w+)\s+(\S+)', out, re.M):
        syms[m.group(3)] = secs.get(m.group(2), m.group(2))
    hits = set()
    cur = None
    for line in out.split('\n'):
        m = re.match(r"Relocation section '\.rela(\S+)'", line)
        if m:
            cur = m.group(1); continue
        if cur and LIVE.search(cur):
            f = line.split()
            if len(f) >= 5 and f[2].startswith('R_AARCH64'):
                sym = f[4]
                if syms.get(sym, '').startswith('.init.text'):
                    hits.add((cur, sym))
    for c, s in sorted(hits):
        print(f'{ko.split("/")[-1]}: {c} -> {s} (in .init.text)')
