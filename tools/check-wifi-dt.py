#!/usr/bin/env python3
"""check-wifi-dt.py <base.dtb> <wifi.dtb>: the M4 Wi-Fi tree against the phone's own downstream tree.

Base tree: WPSS remoteproc and wifi stay disabled. Wi-Fi tree: both okay, WPSS firmware-name the bare
split image wpss.mdt, and every hardware value equal to downstream-dt/a52sxq-r02.dts:
  WPSS  qcom,wpss@8a00000: reg base, wdog IRQ SPI 587, carveout wlan@9ae00000 + 0x1900000
  WLAN  qcom,wcn6750 (icnss2): msi_addr 0x17a10040, SMMU SID 0x1c00/0x1, 32 IRQs SPI 0x300.., MSA
        region wlan_fw@80c00000 + 0xc00000
  rails vdd-cx-mx / vdd-1.8-xo / vdd-1.3-rfa = pm7325 S7 / S1 / S8: pinned in the base tree
"""
import re
import subprocess
import sys

dts = lambda f: subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', f], capture_output=True, text=True).stdout
base, wifi = dts(sys.argv[1]), dts(sys.argv[2])
down = open('downstream-dt/a52sxq-r02.dts').read()
bad = []


def node(text, head):
    i = text.find(head)
    if i < 0:
        return None
    d, j = 0, text.index('{', i)
    for k in range(j, len(text)):
        d += {'{': 1, '}': -1}.get(text[k], 0)
        if d == 0:
            return text[i:k + 1]


def cells(n, prop):
    m = re.search(r'\n\t*' + re.escape(prop) + r' = <([^>]*)>;', n)
    return [int(x, 16) for x in m.group(1).split()] if m else None


def status(n):
    m = re.search(r'status = "(\w+)"', n)
    return m.group(1) if m else 'okay'


def phandle_reg(text, ph):
    m = re.search(r'\{([^{}]*phandle = <' + hex(ph) + r'>;[^{}]*)\}', text)
    return cells('\n' + m.group(1), 'reg') if m else None


def label_reg(text, label):
    n = node(text, label + ': ')
    return cells(n, 'reg') if n else None


for t, name in ((base, 'base'), (wifi, 'wifi')):
    w, r = node(t, 'remoteproc_wpss: remoteproc@8a00000 {'), node(t, 'wifi: wifi@17a10040 {')
    if w is None or r is None:
        bad.append(f'{name} tree lacks remoteproc@8a00000 or wifi@17a10040')
        continue
    want = 'disabled' if name == 'base' else 'okay'
    if status(w) != want or status(r) != want:
        bad.append(f'{name} tree: WPSS {status(w)} / wifi {status(r)}, want {want}')

w, r = node(wifi, 'remoteproc_wpss: remoteproc@8a00000 {'), node(wifi, 'wifi: wifi@17a10040 {')
dw, dr = node(down, 'pil_wpss: qcom,wpss@8a00000 {'), node(down, 'icnss2: qcom,wcn6750 {')
if '\tfirmware-name = "wpss.mdt";' not in w:
    bad.append('WPSS firmware-name is not the bare "wpss.mdt"')
if not re.search(r'qcom,pas-id = <0x06>', dw):
    bad.append('downstream WPSS PAS id is not 6 (qcom_q6v5_pas sc7280 wpss uses 6)')
if cells(w, 'reg')[:2] != [0, 0x8a00000]:
    bad.append('WPSS reg base != 0x8a00000')
if cells(dw, 'interrupts-extended')[2] != 0x24b or cells(w, 'interrupts-extended')[2] != 0x24b:
    bad.append('WPSS wdog IRQ != SPI 587')
mr = cells(w, 'memory-region')
if label_reg(down, 'pil_wpss_mem') != [0, 0x9ae00000, 0, 0x1900000] or not mr:
    bad.append('downstream WPSS carveout changed')
if phandle_reg(wifi, mr[0]) != [0, 0x9ae00000, 0, 0x1900000]:
    bad.append(f'WPSS memory-region != downstream wlan@9ae00000 + 0x1900000 ({phandle_reg(wifi, mr[0])})')
# WLAN
if cells(r, 'reg')[:2] != [0, 0x17a10040] or cells(dr, 'reg')[0] != 0x17a10040:
    bad.append('wifi msi_addr != 0x17a10040')
if cells(r, 'iommus')[1:] != [0x1c00, 1] or cells(dr, 'iommus')[1:] != [0x1c00, 1]:
    bad.append('wifi SMMU SID != 0x1c00/0x1')
ir, idr = cells(r, 'interrupts'), cells(dr, 'interrupts')
if [ir[i + 1] for i in range(0, len(ir), 3)] != [idr[i + 1] for i in range(0, len(idr), 3)] or len(ir) != 96:
    bad.append('wifi IRQs differ from downstream (32 x SPI 0x300..)')
fw = cells(r, 'memory-region')
msa = phandle_reg(wifi, fw[0])
if msa != [0, 0x80c00000, 0, 0xc00000] or label_reg(down, 'wlan_fw_mem') != msa:
    bad.append(f'wifi MSA region != downstream wlan_fw@80c00000 + 0xc00000 ({msa})')
if 'wifi-firmware' in r:
    bad.append('wifi has a wifi-firmware subnode (would map the MSA itself instead of TZ)')
# rails: the three icnss2 supplies are pm7325 s7 / s1 / s8, pinned in the base tree
for sup, rail in (('vdd-cx-mx-supply', 's7b'), ('vdd-1.8-xo-supply', 's1b'), ('vdd-1.3-rfa-supply', 's8b')):
    ph = cells(dr, sup)[0]
    m = re.search(r'\{[^{}]*regulator-name = "(\w+)";[^{}]*phandle = <' + hex(ph) + r'>;', down)
    if not m or m.group(1) != 'pm7325_' + rail[:2]:
        bad.append(f'downstream {sup} is not pm7325_{rail[:2]} ({m and m.group(1)})')
    if f'regulator-name = "vreg_{rail}"' not in base:
        bad.append(f'base tree does not describe vreg_{rail}')
if bad:
    print('\n'.join('FAIL ' + b for b in bad))
    sys.exit(1)
print('ok   wifi dtb: WPSS (PAS 6, wpss.mdt, carveout 0x9ae00000+0x1900000, wdog SPI 587) + wifi '
      '(msi 0x17a10040, SID 0x1c00, 32 IRQs, MSA 0x80c00000+0xc00000, TZ-owned) = downstream; '
      'rails S7B/S1B/S8B pinned in base; base tree keeps both disabled')
