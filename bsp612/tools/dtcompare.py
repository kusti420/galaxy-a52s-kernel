#!/usr/bin/env python3
"""Compare the 6.12 yupik base dtb with the 5.4 base the phone boots, from the point of view
of an overlay: which labels (/__symbols__) and node paths the stock Samsung dtbo needs.
Usage: dtcompare.py base54.dts base612.dts overlay.dts [overlay.dts ...]   (decompiled dts)"""
import re, sys

def parse(path):
    nodes, props, stack = set(), {}, []
    for line in open(path, errors='replace'):
        s = line.strip()
        m = re.match(r'^(?:[\w,.+-]+:\s*)*([^\s{};=]+)\s*\{$', s)
        if m:
            name = m.group(1)
            stack.append('' if name == '/' else name)
            nodes.add('/'.join(stack) or '/')
            continue
        if s == '};':
            if stack: stack.pop()
            continue
        m = re.match(r'^([^\s=;]+)\s*(?:=\s*(.*))?;$', s)
        if m:
            props[('/'.join(stack) or '/', m.group(1))] = m.group(2) or ''
    return nodes, props

def table(props, node):
    return {k[1]: re.findall(r'"([^"]*)"', v) for k, v in props.items() if k[0] == node}

n54, p54 = parse(sys.argv[1]); n612, p612 = parse(sys.argv[2])
s54 = {k: v[0] for k, v in table(p54, '/__symbols__').items()}
s612 = {k: v[0] for k, v in table(p612, '/__symbols__').items()}
print(f"5.4 base: {len(n54)} nodes, {len(s54)} labels;  6.12 base: {len(n612)} nodes, {len(s612)} labels")
print(f"labels in 5.4 base missing from 6.12 base: {len(set(s54)-set(s612))};  same label, different path: "
      f"{sum(1 for k in s54 if k in s612 and s54[k] != s612[k])};  5.4 node paths missing in 6.12: {len(n54-n612)}")
for p in ('/soc/qcom,wdt@17c10000', '/soc/timer', '/soc', '/reserved-memory', '/aliases', '/firmware', '/chosen', '/hypervisor'):
    print(f"  path {p}: 5.4 {'yes' if p in n54 else 'NO'}, 6.12 {'yes' if p in n612 else 'NO'}")
for ov in sys.argv[3:]:
    no, po = parse(ov)
    fix = table(po, '/__fixups__')
    frag_targets = {}   # label -> number of fragments that target it
    for lab, uses in fix.items():
        for u in uses:
            if re.match(r'^/fragment@[^/:]+:target:0$', u):
                frag_targets[lab] = frag_targets.get(lab, 0) + 1
    tpaths = [v.strip('"') for k, v in po.items() if k[1] == 'target-path']
    miss = sorted(l for l in fix if l not in s612)
    moved = sorted(l for l in fix if l in s612 and l in s54 and s612[l] != s54[l])
    miss_t = sorted(l for l in frag_targets if l not in s612)
    print(f"\n== {ov}: model {po.get(('/', 'model'), '?')}")
    print(f"labels the overlay needs: {len(fix)} ({len(frag_targets)} are fragment targets, {sum(frag_targets.values())} fragments); "
          f"target-path fragments: {len(tpaths)} {sorted(set(tpaths))}")
    print(f"needed but not in the 5.4 base either (sanity): {sorted(l for l in fix if l not in s54)}")
    print(f"MISSING in 6.12 base: {len(miss)} labels, of which {len(miss_t)} are fragment targets")
    print(f"present but at a different path in 6.12: {len(moved)}")
    print("missing fragment targets (label -> 5.4 path):")
    for l in miss_t: print(f"  {l} -> {s54.get(l, '?')}")
    print("missing referenced labels (label -> 5.4 path):")
    for l in miss:
        if l not in frag_targets: print(f"  {l} -> {s54.get(l, '?')}")
    print("moved (label: 5.4 path -> 6.12 path):")
    for l in moved: print(f"  {l}: {s54[l]} -> {s612[l]}")
    for t in sorted(set(tpaths)):
        print(f"target-path {t}: {'present' if t in n612 else 'MISSING'} in 6.12 base")
