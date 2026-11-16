#!/usr/bin/env python3
"""check-gpu-dt.py <base.dtb> <panel.dtb> <gpu.dtb>: offline check of the mainline GPU tree
against the phone's own 5.4 tree (downstream-dt/a52sxq-r02.dts: qcom,kgsl-3d0, qcom,gmu,
qcom,kgsl-hyp, pil_gpu_micro_code_mem). Run by ./build-mainline.sh.

- base and panel trees keep the GPU disabled (only the gpu tree enables it);
- chip id, registers, IRQ, SMMU stream ids of GPU and GMU = downstream;
- zap shader: bare firmware-name (resolved in the phone's own apnhlos), carveout = downstream;
- OPPs this phone's speed bin uses (fuse 0x75 = 117 -> supported-hw bit 0): frequency, RPMh level
  and DDR vote = downstream qcom,gpu-pwrlevels for speed-bin 0x75 (vote = bus-table-ddr7 index
  qcom,bus-freq-ddr7, LPDDR4X).
"""
import re
import sys

import libfdt
from libfdt import Fdt, QUIET_NOTFOUND

BIN = 0x75          # this phone's fuse (6.18 KGSL: 550/450/315 MHz = downstream speed-bin 0x75)
BIN_BIT = 0         # drm/msm a6xx_catalog 0x06030500 speedbins: { 117, 0 }

bad = []
trees = [Fdt(open(p, 'rb').read()) for p in sys.argv[1:4]]


def node(f, p):
    o = 0
    for c in [x for x in p.split('/') if x]:
        s = f.first_subnode(o, QUIET_NOTFOUND)
        while s >= 0 and f.get_name(s) != c:
            s = f.next_subnode(s, QUIET_NOTFOUND)
        if s < 0:
            return -1
        o = s
    return o


def prop(f, o, n):
    v = f.getprop(o, n, QUIET_NOTFOUND) if o >= 0 else -1
    return None if isinstance(v, int) else bytes(v)


def cells(b):
    return [int.from_bytes(b[i:i + 4], 'big') for i in range(0, len(b), 4)] if b else []


GPU, GMU = '/soc@0/gpu@3d00000', '/soc@0/gmu@3d6a000'
for f, name in zip(trees[:2], ('base', 'panel')):
    if prop(f, node(f, GPU), 'status') != b'disabled\0':
        bad.append(f'{name} tree: gpu is not disabled')
g = trees[2]
go, mo = node(g, GPU), node(g, GMU)
if go < 0 or mo < 0:
    print('FAIL gpu tree lacks the gpu/gmu nodes')
    sys.exit(1)
if prop(g, go, 'status') not in (b'okay\0', None):
    bad.append('gpu tree: gpu not okay')
if prop(g, mo, 'status') not in (b'okay\0', None):
    bad.append('gpu tree: gmu not okay')

src = open('downstream-dt/a52sxq-r02.dts').read()
kg = src[src.index('msm_gpu: qcom,kgsl-3d0@3d00000 {'):]
kg = kg[:kg.index('kgsl_msm_iommu: qcom,kgsl-iommu@3da0000')]
gm = src[src.index('gmu: qcom,gmu@3d69000 {'):]
gm = gm[:gm.index('};')]
hx = lambda s: [int(x, 16) for x in s.split()]

# chip id: compatible qcom,adreno-635.0 = 0x06030500 = downstream qcom,chipid
chip = int(re.search(r'qcom,chipid = <(0x[0-9a-f]+)>', kg).group(1), 16)
if b'qcom,adreno-635.0\0' not in (prop(g, go, 'compatible') or b'') or chip != 0x06030500:
    bad.append(f'chip id: downstream {chip:#x}, dtb compatible {prop(g, go, "compatible")}')
# registers: kgsl_3d0_reg_memory and cx_dbgc as downstream, rscc downstream (in the gpu node) =
# mainline's in the gmu node
dreg = hx(re.search(r'\breg = <([^>]*)>', kg).group(1))
dnames = re.search(r'reg-names = ([^;]*);', kg).group(1).replace('"', '').replace(' ', '').split(',')
dmap = {n: (dreg[2 * i], dreg[2 * i + 1]) for i, n in enumerate(dnames)}
mreg = cells(prop(g, go, 'reg'))
mmap = {n: (mreg[4 * i + 1], mreg[4 * i + 3]) for i, n in
        enumerate(prop(g, go, 'reg-names').decode().strip('\0').split('\0'))}
for n in ('kgsl_3d0_reg_memory', 'cx_dbgc'):
    if mmap.get(n) != dmap.get(n):
        bad.append(f'gpu reg {n}: {mmap.get(n)} != downstream {dmap.get(n)}')
greg = cells(prop(g, mo, 'reg'))
gnames = prop(g, mo, 'reg-names').decode().strip('\0').split('\0')
gmap = {n: (greg[4 * i + 1], greg[4 * i + 3]) for i, n in enumerate(gnames)}
if gmap.get('rscc') != dmap.get('rscc'):
    bad.append(f'gmu rscc {gmap.get("rscc")} != downstream {dmap.get("rscc")}')
dg = hx(re.search(r'\breg = <([^>]*)>', gm).group(1))
if gmap.get('gmu') != (dg[0], dg[1]) or gmap.get('gmu_pdc') != (dg[2], dg[3]):
    bad.append(f'gmu reg {gmap} != downstream {dg}')
# IRQs (GIC SPI numbers)
dirq = hx(re.search(r'interrupts = <([^>]*)>', kg).group(1))[1]
if cells(prop(g, go, 'interrupts'))[1] != dirq:
    bad.append(f'gpu irq {cells(prop(g, go, "interrupts"))} != downstream SPI {dirq}')
dgi = hx(re.search(r'interrupts = <([^>]*)>', gm).group(1))
if [cells(prop(g, mo, 'interrupts'))[i] for i in (1, 4)] != [dgi[1], dgi[4]]:
    bad.append('gmu irqs differ from downstream')
# SMMU stream ids: GPU = gfx3d_user/gfx3d_lpac (0, 1 / 0x400), GMU = 5 / 0x400
it = cells(prop(g, go, 'iommus'))
if [(it[i + 1], it[i + 2]) for i in range(0, len(it), 3)] != [(0, 0x400), (1, 0x400)]:
    bad.append(f'gpu iommus {it}')
iu = src[src.index('gfx3d_user: gfx3d_user {'):src.index('gfx3d_secure: gfx3d_secure {')]
if [tuple(hx(x)[1:]) for x in re.findall(r'iommus = <([^>]*)>', iu)] != [(0, 0x400), (1, 0x400)]:
    bad.append('downstream gfx3d_user/lpac stream ids changed')
if cells(prop(g, mo, 'iommus'))[1:] != hx(re.search(r'iommus = <([^>]*)>', gm).group(1))[1:]:
    bad.append('gmu stream id differs from downstream')
# zap shader
zo = node(g, GPU + '/zap-shader')
fw = prop(g, zo, 'firmware-name')
if fw != b'a660_zap.mdt\0':
    bad.append(f'zap firmware-name {fw} (want the bare own a660_zap.mdt)')
if not re.search(r'qcom,pas-id = <0x0d>;\s*qcom,firmware-name = "a660_zap"', src):
    bad.append('downstream zap PAS id / name changed (drm/msm uses PAS 13)')
ph = cells(prop(g, zo, 'memory-region'))[0]
ro = g.node_offset_by_phandle(ph)
zr = cells(prop(g, ro, 'reg'))
dz = re.search(r'pil_gpu_micro_code_mem: gpu_micro_code@\w+ \{[^}]*reg = <([^>]*)>', src)
dzr = hx(dz.group(1))
if (zr[1], zr[3]) != (dzr[1], dzr[3]) or prop(g, ro, 'no-map') is None:
    bad.append(f'zap carveout {zr} != downstream {dzr} or not no-map')
# OPPs of this speed bin vs downstream speed-bin 0x75
tbl = hx(re.search(r'qcom,bus-table-ddr7 = <([^>]*)>', kg).group(1))
blk = re.search(r'qcom,speed-bin = <0x%x>;(.*?)\n\t\t\t\t\};' % BIN, kg, re.S).group(1)
want = {}
for m in re.finditer(r'qcom,gpu-freq = <(0x[0-9a-f]+)>;\s*qcom,level = <(0x[0-9a-f]+)>;\s*'
                     r'qcom,bus-freq-ddr7 = <(0x[0-9a-f]+)>', blk):
    hz, lvl, bi = (int(x, 16) for x in m.groups())
    want[hz] = (lvl, tbl[bi])
po = g.node_offset_by_phandle(cells(prop(g, go, 'operating-points-v2'))[0])
have = {}
o = g.first_subnode(po, QUIET_NOTFOUND)
while o >= 0:
    hw = cells(prop(g, o, 'opp-supported-hw'))
    if hw and hw[0] & (1 << BIN_BIT):
        hz = cells(prop(g, o, 'opp-hz'))
        hz = (hz[0] << 32) | hz[1]
        have[hz] = (cells(prop(g, o, 'opp-level'))[0], cells(prop(g, o, 'opp-peak-kBps'))[0])
    o = g.next_subnode(o, QUIET_NOTFOUND)
if not want or have != want:
    bad.append(f'OPPs of bin {BIN:#x}: dtb {have} != downstream {want}')
if bad:
    print('\n'.join('FAIL ' + b for b in bad))
    sys.exit(1)
print(f'ok   gpu dtb: Adreno 0x06030500, regs/IRQs/SMMU SIDs (GPU 0,1 GMU 5) = downstream, zap PAS 13 '
      f'"a660_zap.mdt" in {zr[1]:#x}+{zr[3]:#x} = downstream, bin {BIN:#x} OPPs '
      + ' '.join(f'{h // 1000000}MHz/lvl{l}/{k}kBps' for h, (l, k) in sorted(have.items()))
      + ' = downstream; GPU disabled in base + panel trees')
