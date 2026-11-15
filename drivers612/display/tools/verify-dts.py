#!/usr/bin/env python3
"""Compare the display nodes of a 6.12 test dtb (yupik.dts + a52sxq-display.dtsi) with the
phone's merged 5.4 dtb, property by property. Usage: verify-dts.py <phone.dtb> <new.dtb>"""
import sys, libfdt
a = libfdt.Fdt(open(sys.argv[1], 'rb').read()); b = libfdt.Fdt(open(sys.argv[2], 'rb').read())
ROOTS = ['/soc/qcom,mdss_mdp@ae00000', '/soc/qcom,mdss_dsi_ctrl0@ae94000', '/soc/qcom,mdss_dsi_phy0@ae94900',
         '/soc/qcom,sde_rscc@af20000', '/soc/qcom,smmu_sde_unsec_cb', '/soc/qcom,smmu_sde_sec_cb',
         '/soc/qcom,dsi-display-primary', '/soc/qcom,wb-display@0', '/soc/qcom,dsi-display@0', '/soc/qcom,dsi-display@1',
         '/soc/self_display_FC3_dtsi'] + ['/soc/pinctrl@f000000/panel_yd01_%s_%s' % (x, y)
         for x in ('te', 'reset', 'ubcon', 'esd_1') for y in ('active', 'suspend')]
PH = ('clocks', 'interconnects', 'iommus', 'connectors', 'interrupt-parent', 'memory-region', 'phandle',
      'qcom,dsi-default-panel', 'qcom,mdp', 'qcom,dsi-phy', 'qcom,dsi-ctrl', 'ss,self_display')
isph = lambda n: n in PH or n.endswith('-supply') or n.startswith('pinctrl-') and n != 'pinctrl-names' \
    or n.endswith('-gpio') or n in ('samsung,ub-con-det', 'samsung,esd-irq-gpio1')
def props(f, off):
    d = {}; o = f.first_property_offset(off, libfdt.QUIET_NOTFOUND)
    while o >= 0:
        p = f.get_property_by_offset(o); d[p.name] = bytes(p)
        o = f.next_property_offset(o, libfdt.QUIET_NOTFOUND)
    return d
def subs(f, off):
    d = {}; s = f.first_subnode(off, libfdt.QUIET_NOTFOUND)
    while s >= 0:
        d[f.get_name(s)] = s; s = f.next_subnode(s, libfdt.QUIET_NOTFOUND)
    return d
st = dict(nodes=0, same=0, ph=0, diff=0)
def cmp(path, oa, ob):
    st['nodes'] += 1
    pa, pb = props(a, oa), props(b, ob)
    for n in sorted(set(pa) | set(pb)):
        if isph(n):
            st['ph'] += 1
            if n not in pb: print('MISSING(phandle prop)', path, n)
            elif n not in pa: print('ADDED', path, n)
            elif len(pa[n]) != len(pb[n]): print('CHANGED LENGTH', path, n, len(pa[n]), '->', len(pb[n]))
            continue
        if n not in pb: print('MISSING', path, n); st['diff'] += 1
        elif n not in pa: print('ADDED', path, n, pb[n][:24].hex()); st['diff'] += 1
        elif pa[n] != pb[n]: print('CHANGED', path, n, pa[n][:40], '->', pb[n][:40]); st['diff'] += 1
        else: st['same'] += 1
    sa, sb = subs(a, oa), subs(b, ob)
    for n in sorted(set(sa) | set(sb)):
        if n not in sb:
            if not (n.startswith('qcom,mdss_dsi_')): print('NODE MISSING', path + '/' + n)
        elif n not in sa: print('NODE ADDED', path + '/' + n)
        else: cmp(path + '/' + n, sa[n], sb[n])
for r in ROOTS:
    try: oa = a.path_offset(r)
    except Exception: print('not in phone tree:', r); continue
    try: ob = b.path_offset(r)
    except Exception: print('NODE MISSING', r); continue
    cmp(r, oa, ob)
print(st)
