#!/usr/bin/env python3
"""Extract the A52s display board nodes from the phone's merged 5.4 device tree
(downstream-dt/a52sxq-r02.dts, the tree the phone boots) and write them as label-based
dtsi files. Property values are copied as text; only phandle cells are rewritten to &labels.
Usage: gen-dts.py <a52sxq-r02.dts> <a52sxq-r02.dtb> <outdir>
"""
import os
import sys, re, libfdt
src, dtb, out = sys.argv[1:4]
fdt = libfdt.Fdt(open(dtb, 'rb').read())
# path -> label
sym = fdt.path_offset('/__symbols__')
path2label = {}
o = fdt.first_property_offset(sym)
while o >= 0:
    p = fdt.get_property_by_offset(o)
    path2label.setdefault(p.as_str(), p.name)
    o = fdt.next_property_offset(o, libfdt.QUIET_NOTFOUND)
# prefer some well-known labels when a node has several
PREFER = {'L8C', 'L13C', 'tlmm', 'dispcc', 'gcc'}
o = fdt.first_property_offset(sym)
while o >= 0:
    p = fdt.get_property_by_offset(o)
    if p.name in PREFER: path2label[p.as_str()] = p.name
    o = fdt.next_property_offset(o, libfdt.QUIET_NOTFOUND)
ph = {}  # phandle -> (label, path, node offset)
def walk(off, path):
    try:
        h = fdt.get_phandle(off)
    except Exception:
        h = 0
    if h: ph[h] = (path2label.get(path or '/'), path or '/', off)
    s = fdt.first_subnode(off, libfdt.QUIET_NOTFOUND)
    while s >= 0:
        walk(s, path + '/' + fdt.get_name(s))
        s = fdt.next_subnode(s, libfdt.QUIET_NOTFOUND)
walk(0, '')
def ncells(h, prop):
    try: return fdt.getprop(ph[h][2], prop).as_uint32()
    except Exception: return None
def lab(h):
    l = ph.get(h, (None,))[0]
    if not l: raise SystemExit('no label for phandle 0x%x (%s)' % (h, ph.get(h)))
    used.add(l); return '&' + l
used = set()
SPEC = {'clocks': '#clock-cells', 'interconnects': '#interconnect-cells', 'iommus': '#iommu-cells',
        'power-domains': '#power-domain-cells'}
GPIO = re.compile(r'(-gpios?|^samsung,ub-con-det|^samsung,esd-irq-gpio\d)$')
SINGLE = re.compile(r'(-supply|^interrupt-parent|^memory-region|^qcom,dsi-default-panel|^qcom,mdp|^qcom,dsi-phy|^qcom,dsi-ctrl|^ss,self_display)$')
ALL = re.compile(r'^(pinctrl-\d+|connectors)$')
def conv(name, cells):
    if name == 'connectors':  # DisplayPort is not ported: sde_dp is left out of the component list
        cells = [c for c in cells if ph[c][0] != 'sde_dp']
    if ALL.match(name): return '<' + ' '.join(lab(c) for c in cells) + '>'
    if SINGLE.search(name): return '<' + lab(cells[0]) + '>'
    cp = SPEC.get(name) or ('#gpio-cells' if GPIO.search(name) else None)
    if not cp: return None
    outp, i = [], 0
    while i < len(cells):
        n = ncells(cells[i], cp)
        if n is None: raise SystemExit('%s: 0x%x has no %s' % (name, cells[i], cp))
        args = ['0x%x' % c for c in cells[i+1:i+1+n]]
        l = lab(cells[i])
        if name == 'clocks' and l[1:] in CLKNAME: args = [CLKNAME[l[1:]][cells[i+1]]]
        outp.append('<' + ' '.join([l] + args) + '>')
        i += 1 + n
    return ', '.join(outp)
# clock ids of gcc/dispcc are written as macro names: 5.4 used qcom,{gcc,dispcc}-yupik.h, the
# 6.12 base uses the -sc7280.h headers, and a few gcc numbers differ between them.
CLKNAME = {}
K54 = os.path.expandvars('$ANDROID_TREE/kernel/samsung/sm7325/include/dt-bindings/clock/qcom,%s-yupik.h')
for cc in ('gcc', 'dispcc'):
    CLKNAME[cc] = {int(m.group(2)): m.group(1) for m in re.finditer(r'#define\s+(\w+_CLK(?:_SRC)?)\s+(\d+)', open(K54 % cc).read())}
lines = open(src).read().split('\n')
def node_text(label, drop_children=None, as_ref=False, keep_label=True):
    """text of the node defined as 'label: name {' ; returns list of lines, re-indented"""
    for i, l in enumerate(lines):
        if re.match(r'\s*(\w+: )*%s: [^ ]+ \{$' % re.escape(label), l): break
    else: raise SystemExit('label %s not found' % label)
    ind = len(l) - len(l.lstrip('\t'))
    depth, res, skip = 0, [], 0
    for l in lines[i:]:
        t = l[ind:] if l.strip() else ''
        s = t.strip()
        if skip:
            skip += s.endswith('{') - (s == '};')
            continue
        if s.endswith('{') and depth >= 1 and drop_children and drop_children(s):
            skip = 1; continue
        if s.endswith('{'):
            if depth == 0:
                name = s[:-1].strip().split(': ')[-1]
                t = ('&%s {' % label) if as_ref else ('%s: %s {' % (label, name))
            else:
                t = re.sub(r'^(\t*)(\w+: )+', r'\1', t) if not keep_label else t
            depth += 1
        elif s == '};':
            depth -= 1
        elif s.startswith('phandle = '):
            continue
        else:
            m = re.match(r'^(\t*)([^ =;]+) = <([^>]*)>;$', t)
            if m:
                c = conv(m.group(2), [int(x, 0) for x in m.group(3).split()])
                if c: t = '%s%s = %s;' % (m.group(1), m.group(2), c)
        res.append(t)
        if depth == 0: break
    while res and res[-2:-1] == ['']: del res[-2]
    return res
def emit(fn, header, blocks):
    with open(out + '/' + fn, 'w') as f:
        f.write('// SPDX-License-Identifier: GPL-2.0-only\n/*\n' + header + ' */\n')
        for target, nodes in blocks:
            f.write('\n&%s {\n' % target)
            for k, n in enumerate(nodes):
                if k: f.write('\n')
                f.write('\n'.join(('\t' + x if x else x) for x in n) + '\n')
            f.write('};\n')
GEN = (' * GENERATED by tools/gen-dts.py from downstream-dt/a52sxq-r02.dts (the merged tree the\n'
       ' * phone boots: yupik.dtb + overlay a52sxq_kor_single_w00_r02, used by hardware revisions\n'
       ' * 2 and later, so 3 and 4 too). Values are byte-for-byte the phone\'s; only phandles were\n'
       ' * turned into labels. Do not edit by hand; edit the generator.\n')
emit('a52sxq-panel-S6E3FC3_AMS646YD01_LO_FHD.dtsi', ' * Samsung S6E3FC3 / AMS646YD01 panel node + its self-display (self mask) table.\n' + GEN,
     [('soc', [node_text('self_display_FC3_dtsi')]),
      ('mdss_mdp', [node_text('ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD')])])
emit('a52sxq-panel-PBA_BOOTING_FHD.dtsi', ' * Samsung "PBA booting" dummy panel (main board without a panel attached).\n' + GEN,
     [('mdss_mdp', [node_text('ss_dsi_panel_PBA_BOOTING_FHD')])])
pins = ['panel_yd01_te_active', 'panel_yd01_te_suspend', 'panel_yd01_reset_active', 'panel_yd01_reset_suspend',
        'panel_yd01_ubcon_active', 'panel_yd01_ubcon_suspend', 'panel_yd01_esd_1_active', 'panel_yd01_esd_1_suspend']
emit('a52sxq-display-board.dtsi', ' * A52s display board wiring: pin states, DSI display node, Samsung display-name nodes.\n' + GEN,
     [('tlmm', [node_text(p) for p in pins]),
      ('soc', [node_text('sde_wb'), node_text('sde_dsi'), node_text('ss_dsi_panel_PBA_BOOTING_FHD_display'),
               node_text('ss_dsi_panel_S6E3FC3_AMS646YD01_LO_FHD_display')])])
panel_child = lambda s: s.startswith(('qcom,mdss_dsi_', 'dsi_', 'ss_dsi_panel')) or 'ss_dsi_panel' in s
emit('yupik-sde.dtsi', ' * SoC display nodes (SDE 7.2 MDP, DSI0 controller + PHY, RSC, SMMU contexts). The 6.12 yupik\n'
     ' * base has none of them. DisplayPort (sde_dp, ext_disp) is not carried over.\n' + GEN,
     [('soc', [node_text('mdss_mdp', drop_children=panel_child), node_text('mdss_dsi0'), node_text('mdss_dsi_phy0'),
               node_text('sde_rscc'), node_text('smmu_sde_unsec'), node_text('smmu_sde_sec')])])
print('labels referenced:', ' '.join(sorted(used)))
