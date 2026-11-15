#!/usr/bin/env python3
"""Generate ../a52sxq-power.dtsi from the nodes extracted verbatim out of
downstream-dt/a52sxq-r02.dts (nodes-r02.txt, vadc-r02.txt, pins-r02.txt).
Only mechanical edits are made: 'phandle' lines dropped, numeric phandles replaced by
labels, re-indentation. No value is typed by hand. Re-run: ./gen-dtsi.py"""
import re,os
H=os.path.dirname(os.path.abspath(__file__))
def blocks(fn):
    out={};cur=None
    for l in open(os.path.join(H,fn)).read().split('\n'):
        m=re.match(r'/\* ==== (\S+)\s+\(r02 lines (\d+)-(\d+)\) ==== \*/',l)
        if m: cur=m.group(1); out[cur]={'lines':[], 'src':(m.group(2),m.group(3))}; continue
        if cur: out[cur]['lines'].append(l)
    return out
PH={ # numeric phandle in r02 -> label (all labels exist in the 6.12 base or in this file)
 '0x571':'&pmk8350_vadc','0x3c':'&tlmm',
 '0x572':'&bat_thm_default','0x573':'&chg_thm_default','0x577':'&gpio1_adc_default',
 '0x578':'&gpio4_adc_default','0x5b5':'&if_pmic_irq','0x5b6':'&usbpd_irq'}
def fix(l):
    if re.match(r'\s*phandle = ',l): return None
    m=re.match(r'(\s*)(io-channels) = <(.*)>;',l)
    if m:
        v=m.group(3).split(); assert len(v)%2==0
        return '%s%s = %s;'%(m.group(1),m.group(2),', '.join('<%s %s>'%(PH[v[i]],v[i+1]) for i in range(0,len(v),2)))
    m=re.match(r'(\s*)(pinctrl-0) = <(.*)>;',l)
    if m: return '%s%s = <%s>;'%(m.group(1),m.group(2),' '.join(PH[x] for x in m.group(3).split()))
    m=re.match(r'(\s*)([a-z0-9,_-]+(?:gpio|usbpd_int)) = <(0x3c) (\S+) (\S+)>;',l)
    if m: return '%s%s = <&tlmm %s %s>;'%(m.group(1),m.group(2),m.group(4),m.group(5))
    return l
def emit(b,indent):
    ls=[fix(l) for l in b['lines']]
    ls=[l for l in ls if l is not None]
    while ls and not ls[-1].strip(): ls.pop()
    base=len(ls[0])-len(ls[0].lstrip('\t'))
    out=['\t'*indent+'/* r02.dts lines %s-%s */'%b['src']]
    for l in ls:
        out.append(('\t'*indent+l[base:]) if l.strip() else '')
    return '\n'.join(out)+'\n'
N=blocks('nodes-r02.txt'); V=blocks('vadc-r02.txt'); Pn=blocks('pins-r02.txt')
smd=[k for k in N if k.startswith('/samsung_mobile_device/')]
# vadc channels the Samsung drivers consume
vl=V[list(V)[0]]['lines']; chans=[]
for name in ('chg_thm','bat_thm','wf_therm','pa_therm','ap_therm'):
    i=next(i for i,l in enumerate(vl) if l.strip()==name+' {')
    j=next(j for j in range(i,len(vl)) if vl[j].strip()=='};')
    chans.append('\n'.join(l[4:] for l in vl[i:j+1]))
o=[]
o.append(open(os.path.join(H,'header.txt')).read())
o.append('/ {\n\tsmd: samsung_mobile_device {\n\t\tcompatible = "simple-bus";\n')
for k in smd:
    extra=''
    o.append(emit(N[k],2))
o.append('\t};\n};\n')
o.append('''
/*
 * Not in r02.dts: properties the 6.12 donor (physwizz) reads under a NEW name. Derived
 * mechanically from the phone's battery,health_condition = <cycle asoc> pairs
 * (r02 line 628: <900 0  1200 0  1500 0>). Only feeds the "battery health" label
 * (GOOD/NORMAL/AGED), not a charging limit.
 */
&sec_battery {
	battery,health_condition_cycle = <0x384 0x4b0 0x5dc>;
	battery,health_condition_asoc = <0x00 0x00 0x00>;
};

/*
 * I2C bus numbers. The ROM's sepolicy labels the supplies by device path
 * (device/samsung/sm7325-common/sepolicy genfs_contexts:
 *  /devices/platform/soc/98c000.i2c/i2c-21/21-0049/, .../21-0057/power_supply/pca9468-charger/,
 *  /devices/platform/soc/a80000.i2c/i2c-23/23-0033/wakeup/), so SE3 must stay i2c-21 and SE8
 * i2c-23 as on 5.4. NEW (5.4 got these numbers from probe order): pin them with aliases.
 * This moves dynamically numbered buses above 23: coordinate with the other drivers612
 * fragments (touch, NFC, camera) before merging.
 */
&aliases {
	i2c21 = "/soc/i2c@98c000";
	i2c23 = "/soc/i2c@a80000";
};

&soc {
''')
o.append(emit(N['/soc/usb-notifier'],1))
o.append('''
	/* NEW (not on 5.4): extcon bridge, see src/glue/a52sxq_usb_glue.c */
	a52sxq_usb_extcon: a52sxq-usb-extcon {
		compatible = "samsung,a52sxq-usb-extcon";
	};
};

/*
 * dwc3-msm: on 5.4 Samsung's usb_notifier called dwc_msm_vbus_event()/dwc_msm_id_event()
 * inside dwc3-msm.c. The BSP driver takes the same information from an extcon device.
 * r02 (line 19302 on) has extcon = <&eud> only, maximum-speed = "high-speed", dr_mode = "otg".
 * The phone's USB-C port is USB 2.0 only: keep "high-speed" (the 6.12 base says super-speed).
 */
&usb0 {
	extcon = <&eud>, <&a52sxq_usb_extcon>;
};

&pmk8350_vadc {
	/*
	 * r02.dts lines 5005-5152. Same binding in the 6.12 BSP driver (soc-repo
	 * drivers/iio/adc/qcom-spmi-adc5.c, "qcom,spmi-adc7"): label, qcom,pre-scaling,
	 * qcom,hw-settle-time, qcom,ratiometric, qcom,scale-fn-type are all still parsed.
	 * qcom,scale-fn-type = 5 is SCALE_HW_CALIB_DEFAULT in both kernels (enum entries 0..7
	 * are identical; later entries were reordered, none is used here), i.e. the channel
	 * returns microvolts and Samsung's own tables convert to temperature.
	 * reg = (SID 1 = PM7325) << 8 | channel: 0x146 AMUX_THM3_100K_PU, 0x148
	 * AMUX_THM5_100K_PU, 0x14a/0x14b/0x14c GPIO1/2/3_100K_PU.
	 * NOTE: Qualcomm's yupik-pmic-overlay.dtsi puts "pm7325_sdm_skin_therm" on 0x146;
	 * the phone has no such channel. Do not carry it (and its adc_tm/thermal-zone users)
	 * into the a52sxq tree.
	 */
''')
for c in chans: o.append('\n'.join('\t'+l[1:] if l.startswith('\t\t') else l for l in c.split('\n')).replace('\t\t\t\t','\t')+'\n\n')
o.append('};\n\n&pm7325_gpios {\n')
o.append('\tchg_thm {\n'+emit(Pn[[k for k in Pn if k.endswith('chg_thm_default')][0]],2)+'\t};\n\n')
o.append('\tbat_thm {\n'+emit(Pn[[k for k in Pn if k.endswith('bat_thm_default')][0]],2)+'\t};\n\n')
for k in Pn:
    if k.endswith('gpio1_adc_default') or k.endswith('gpio4_adc_default'): o.append(emit(Pn[k],1)+'\n')
o.append('};\n\n&tlmm {\n')
for k in Pn:
    if '/pinctrl@f000000/' in k: o.append(emit(Pn[k],1)+'\n')
o.append('};\n')
o.append('''
/* SE0, TLMM 0/1 (bus pins as in the 6.12 base: qupv3_se0_i2c_active/sleep, checked equal) */
&qupv3_se0_i2c {
	status = "okay";

''')
o.append(emit(N['/soc/i2c@980000/s2mpb03_pmic@56'],1))
o.append('''};

/* SE3, TLMM 12/13, 400 kHz (r02 line 20205: qcom,clk-freq-out = <0x61a80>) */
&qupv3_se3_i2c {
	status = "okay";
	qcom,clk-freq-out = <0x61a80>;

''')
F=blocks('fled-r02.txt')
# Order as in the LIVE tree of the phone (testdev-PHONE1/live.dts: sm5714@49, pca9468@57,
# sm5714-fled). sm5714@49 and sm5714-fled both carry reg = <0x49>: the first one becomes the
# i2c client, the second fails with -EBUSY (as on 5.4; the fled driver is an MFD cell and
# only looks its node up by name). The merged r02.dts lists the fled first; that order
# would leave the MFD without its i2c client.
# 6.12 (hardware, 2026-11-13/14): the I2C-level sm5714-fled is created BEFORE sm5714@49 anyway
# and takes 0x49 -> no fuel gauge/charger, Android saw 0 V and shut down "battery". So:
#  - the I2C-level node is emitted with status = "disabled" (never an I2C client),
#  - its settings are emitted a second time as a CHILD node "sm5714-fled" of sm5714@49 with
#    reg/compatible/status left out (a pure data node: nothing can bind to it, the I2C core
#    only instantiates direct children of the adapter). The MFD cell "sm5714-fled"
#    (mfd_sm5714) is the device; leds-sm5714-fled reads this child of its parent first.
fled = F[list(F)[0]]
fled_i2c = {'src': fled['src'], 'lines': []}
for l in fled['lines']:
    if re.match(r'\s*status = ', l):
        ind = l[:len(l) - len(l.lstrip('\t'))]
        fled_i2c['lines'] += [ind + '/*',
            ind + ' * disabled (2026-11-13, hardware): on 6.12 this node is created before sm5714@49,',
            ind + ' * takes address 0x49, and the MFD client is never registered (no fuel gauge, no',
            ind + ' * charger). The flash LED settings in use are the child node of sm5714@49.',
            ind + ' */',
            ind + 'status = "disabled";']
    else:
        fled_i2c['lines'].append(l)
fled_child = {'src': fled['src'],
              'lines': [l for l in fled['lines'] if not re.match(r'\s*(status|reg|compatible) = ', l)]}
mfd = emit(N['/soc/i2c@98c000/sm5714@49'],1).rstrip('\n').split('\n')
assert mfd[-1] == '\t};'
child = emit(fled_child,2).rstrip('\n').split('\n')
child[0] = child[0][:-3] + ', without reg/compatible/status: settings for the MFD cell sm5714-fled */'
o.append('\n'.join(mfd[:-1] + [''] + child + ['\t};']) + '\n\n')
o.append(emit(N['/soc/i2c@98c000/pca9468@57'],1)+'\n')
o.append('\t/* same address as sm5714@49 on purpose (see the generator); must stay AFTER it */\n')
o.append(emit(fled_i2c,1))
o.append('''};

/* SE8, TLMM 32/33, 400 kHz (r02 lines 20441-20442) */
&qupv3_se8_i2c {
	status = "okay";
	qcom,clk-freq-out = <0x61a80>;
	i2c-gpio,delay-us = <0x05>;

''')
o.append(emit(N['/soc/i2c@a80000/usbpd-sm5714@33'],1))
o.append('};\n')
open(os.path.join(H,'..','a52sxq-power.dtsi'),'w').write(''.join(o))
