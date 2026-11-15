#!/usr/bin/env python3
"""Generate a52sxq-camera.dtsi from the phone's merged 5.4 tree (downstream-dt/a52sxq-r02.dts),
retargeting phandles to labels and clock / interconnect IDs to the 6.12 header macros.
Run from the project root:  python3 drivers612/camera/dt-work/gen.py
Reads only; writes drivers612/camera/a52sxq-camera.dtsi and dt-work/gen-report.txt."""
import re, os, sys, collections

ROOT = './'
PHONE = ROOT + '/downstream-dt/a52sxq-r02.dts'
BASE = ROOT + '/drivers612/camera/dt-work/yupik-base612.dts'
K54 = os.path.expanduser(os.path.expandvars('$ANDROID_TREE/kernel/samsung/sm7325/include/dt-bindings'))
K612 = [ROOT + '/bsp612/soc-repo/include/dt-bindings', ROOT + '/bsp612/kernel/include/dt-bindings']
OUT = ROOT + '/drivers612/camera/a52sxq-camera.dtsi'
REPORT = ROOT + '/drivers612/camera/dt-work/gen-report.txt'


class Node:
    def __init__(self, name, labels, parent):
        self.name, self.labels, self.parent = name, labels, parent
        self.props = []  # (name, rawvalue or None)
        self.children = []
        self.phandle = None

    def path(self):
        if self.parent is None:
            return ''
        return self.parent.path() + '/' + self.name

    def get(self, k):
        for n, v in self.props:
            if n == k:
                return v
        return None

    def label(self):
        return self.labels[0] if self.labels else None


def parse(fn):
    root = None
    cur = None
    byph = {}
    bypath = {}
    for line in open(fn):
        s = line.strip()
        if not s or s.startswith('/dts-v1/'):
            continue
        if s.endswith('{'):
            head = s[:-1].strip()
            parts = head.split()
            labels = [p[:-1] for p in parts[:-1] if p.endswith(':')]
            name = parts[-1]
            n = Node(name if name != '/' else '', labels, cur)
            if cur is None:
                root = n
            else:
                cur.children.append(n)
            cur = n
            continue
        if s == '};':
            bypath[cur.path() or '/'] = cur
            cur = cur.parent
            continue
        m = re.match(r'^([^\s=]+)\s*=\s*(.*);$', s)
        if m:
            k, v = m.group(1), m.group(2)
            if k == 'phandle':
                cur.phandle = int(v.strip('<>'), 16)
                byph[cur.phandle] = cur
            else:
                cur.props.append((k, v))
        else:
            cur.props.append((s.rstrip(';'), None))
    return root, byph, bypath


proot, pph, ppath = parse(PHONE)
broot, bph, bpath = parse(BASE)

# labels from __symbols__ (phone tree may or may not have inline labels)
for tree_path, tree in ((ppath, 'p'), (bpath, 'b')):
    sym = tree_path.get('/__symbols__')
    if sym:
        for k, v in sym.props:
            if v is None:
                continue
            p = v.strip('"')
            n = tree_path.get(p)
            if n is not None and k not in n.labels:
                n.labels.append(k)
base_labels = {}
for p, n in bpath.items():
    for l in n.labels:
        base_labels[l] = n


def hdr(fn):
    d = {}
    if not os.path.exists(fn):
        return d
    for l in open(fn):
        m = re.match(r'#define\s+(\w+)\s+(\d+|0x[0-9a-fA-F]+)\s*($|/)', l)
        if m:
            d[m.group(1)] = int(m.group(2), 0)
    return d


def find612(rel):
    for b in K612:
        if os.path.exists(b + '/' + rel):
            return b + '/' + rel
    return None


def inv(d):
    r = {}
    for k, v in d.items():
        r.setdefault(v, k)
    return r


cam54 = inv(hdr(K54 + '/clock/qcom,camcc-yupik.h'))
gcc54 = inv(hdr(K54 + '/clock/qcom,gcc-yupik.h'))
cam612 = hdr(find612('clock/qcom,camcc-sc7280.h'))
gcc612 = hdr(find612('clock/qcom,gcc-sc7280.h'))
icc54 = inv(hdr(K54 + '/interconnect/qcom,yupik.h'))
icc612 = hdr(find612('interconnect/qcom,yupik.h'))

missing = collections.OrderedDict()   # label -> description
notes = []
extra_emit = collections.OrderedDict()  # phone nodes that must be emitted because not in base (pinctrl)
used_base_labels = set()


def best_label(n):
    """label to use for phone node n; prefer one that exists in the base."""
    for l in n.labels:
        if l in base_labels:
            return l
    return n.label()


def ref(ph, ctx):
    n = pph.get(ph)
    if n is None:
        notes.append('UNRESOLVED phandle 0x%x in %s' % (ph, ctx))
        return '0x%x /* UNRESOLVED phandle */' % ph
    l = best_label(n)
    if l is None:
        notes.append('phone node %s (phandle 0x%x) has no label; used in %s' % (n.path(), ph, ctx))
        return '&{%s}' % n.path()
    if l in base_labels:
        used_base_labels.add(l)
        bp = base_labels[l].path()
        if bp != n.path():
            notes.append('label %s: phone path %s, 6.12 base path %s (ctx %s)' % (l, n.path(), bp, ctx))
    else:
        if l not in emitted_labels:
            p = n.path()
            if '/pinctrl@f000000/' in p:
                extra_emit[l] = n
            else:
                missing.setdefault(l, p)
    return '&' + l


def cells(v):
    return [int(x, 16) for x in v.strip('<>').split()]


def clock_id(ctrl, i, ctx):
    l = best_label(ctrl) or ''
    if l == 'camcc':
        nm = cam54.get(i)
        if nm and nm in cam612:
            return nm
        notes.append('camcc clock id %d (%s) has no same-named macro in 6.12 qcom,camcc-sc7280.h (ctx %s)' % (i, nm, ctx))
        return '%d /* 5.4 %s: NO 6.12 MACRO */' % (i, nm)
    if l == 'gcc':
        nm = gcc54.get(i)
        if nm and nm in gcc612:
            return nm
        notes.append('gcc clock id %d (%s) has no same-named macro in 6.12 qcom,gcc-sc7280.h (ctx %s)' % (i, nm, ctx))
        return '%d /* 5.4 %s: NO 6.12 MACRO */' % (i, nm)
    notes.append('clock from unexpected provider %s id %d (ctx %s)' % (l, i, ctx))
    return '%d' % i


def spec_list(v, cellprop, ctx, fmt=None):
    c = cells(v)
    out = []
    i = 0
    while i < len(c):
        tgt = pph.get(c[i])
        nc = 0
        if tgt is not None and cellprop:
            x = tgt.get(cellprop)
            nc = cells(x)[0] if x else 0
        args = c[i + 1:i + 1 + nc]
        r = ref(c[i], ctx)
        if fmt:
            out.append('<%s %s>' % (r, fmt(tgt, args)))
        elif args:
            out.append('<%s %s>' % (r, ' '.join(dec(a) for a in args)))
        else:
            out.append('<%s>' % r)
        i += 1 + nc
    return out


def dec(a):
    return str(a) if a < 10 else '0x%x' % a


def icc_fmt(v, ctx):
    c = cells(v)
    out = []
    for i in range(0, len(c), 2):
        nm = icc54.get(c[i + 1])
        if nm and nm in icc612:
            idm = nm
        else:
            notes.append('interconnect id %d (%s) has no same-named macro in 6.12 qcom,yupik.h (ctx %s)' % (c[i + 1], nm, ctx))
            idm = '%d /* 5.4 %s: NO 6.12 MACRO */' % (c[i + 1], nm)
        out.append('%s %s' % (ref(c[i], ctx), idm))
    # pairs of (src, dst)
    res = []
    for i in range(0, len(out), 2):
        res.append('<%s %s>' % (out[i], out[i + 1] if i + 1 < len(out) else ''))
    return res


PH_ALL = {'parent-node', 'eeprom-src', 'actuator-src', 'ois-src', 'led-flash-src', 'memory-region',
          'flash-source', 'torch-source', 'switch-source', 'qcom,wrapper-core'}
IRQ_TYPE = {1: 'IRQ_TYPE_EDGE_RISING', 2: 'IRQ_TYPE_EDGE_FALLING', 4: 'IRQ_TYPE_LEVEL_HIGH', 8: 'IRQ_TYPE_LEVEL_LOW'}
DECIMAL = {'clock-rates', 'clock-rates-option', 'rgltr-min-voltage', 'rgltr-max-voltage', 'rgltr-load-current',
           'regulator-min-microvolt', 'regulator-max-microvolt', 'cci-clk-src', 'spi-max-frequency'}


def join(items, ind, k):
    if len(items) <= 1:
        return ''.join(items)
    pad = '\n' + '\t' * ind + ' ' * (len(k) + 3)
    return (',' + pad).join(items)


def fmt_prop(n, k, v, ind):
    ctx = n.path() + ':' + k
    if v is None:
        return k + ';'
    if not v.startswith('<'):
        if k in CELL_PROPS and v.startswith('"'):
            b = strbytes(v)
            if len(b) % 4 == 0:
                c = [int.from_bytes(b[i:i + 4], 'big') for i in range(0, len(b), 4)]
                notes.append('%s: dtc decompiled cells as string %s; restored to <%s>' % (ctx, v, ' '.join('0x%x' % x for x in c)))
                return '%s = <%s>; /* decompiler printed this as the string %s */' % (k, ' '.join('0x%x' % x for x in c), v.replace('*/', '* /'))
        return '%s = %s;' % (k, v)
    if k == 'shared-gpios':
        return ('/* LEGACY GLOBAL GPIO NUMBER (5.4: tlmm gpiochip base 336 + TLMM %d = CAM_VANA shared by\n' % (cells(v)[0] - 336)
                + '\t' * ind + ' * rear wide sensor and OIS MCU). On 6.12 the base is dynamic: the ported cam_res_mgr\n'
                + '\t' * ind + ' * must match by <&tlmm %d> or this number must be recomputed. See DT-NOTES.md. */\n' % (cells(v)[0] - 336)
                + '\t' * ind + '%s = %s;' % (k, v))
    try:
        if k in ('clocks', 'clocks-option'):
            items = spec_list(v, '#clock-cells', ctx, lambda t, a: clock_id(t, a[0], ctx) if a else '')
            return '%s = %s;' % (k, join(items, ind, k))
        if k.endswith('-supply') or re.match(r'pinctrl-\d+$', k) or k in PH_ALL:
            items = ['<%s>' % ref(c, ctx) for c in cells(v)]
            return '%s = %s;' % (k, join(items, ind, k) if k in PH_ALL else '<%s>' % ' '.join(i[1:-1] for i in items))
        if k == 'gpios' or k.endswith('-gpio') or k.endswith('-gpios'):
            c = cells(v)
            if c and c[0] in pph and pph[c[0]].get('#gpio-cells'):
                return '%s = %s;' % (k, join(spec_list(v, '#gpio-cells', ctx), ind, k))
        if k == 'iommus':
            return '%s = %s;' % (k, join(spec_list(v, '#iommu-cells', ctx, lambda t, a: ' '.join('0x%x' % x for x in a)), ind, k))
        if k == 'interconnects':
            return '%s = %s;' % (k, join(icc_fmt(v, ctx), ind, k))
        if k == 'interrupts':
            c = cells(v)
            if len(c) % 3 == 0 and all(c[i] == 0 for i in range(0, len(c), 3)):
                items = ['<GIC_SPI %d %s>' % (c[i + 1], IRQ_TYPE.get(c[i + 2], str(c[i + 2]))) for i in range(0, len(c), 3)]
                return '%s = %s;' % (k, join(items, ind, k))
        if k in DECIMAL:
            return '%s = <%s>;' % (k, ' '.join(str(x) for x in cells(v)))
    except Exception as e:  # keep raw on any surprise
        notes.append('could not convert %s (%s); left raw' % (ctx, e))
    return '%s = %s;' % (k, v)


emitted_labels = set()
CELL_PROPS = set()
for _n in ppath.values():
    for _k, _v in _n.props:
        if _v and _v.startswith('<'):
            CELL_PROPS.add(_k)
ESC = {'a': 7, 'b': 8, 't': 9, 'n': 10, 'v': 11, 'f': 12, 'r': 13, '\\': 92, '"': 34}


def strbytes(v):
    out = bytearray()
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', v):
        t = m.group(1)
        i = 0
        while i < len(t):
            ch = t[i]
            if ch == '\\':
                nx = t[i + 1]
                if nx == 'x':
                    j = i + 2
                    while j < len(t) and j < i + 4 and t[j] in '0123456789abcdefABCDEF':
                        j += 1
                    out.append(int(t[i + 2:j], 16)); i = j; continue
                if nx in '01234567':
                    j = i + 1
                    while j < len(t) and j < i + 4 and t[j] in '01234567':
                        j += 1
                    out.append(int(t[i + 1:j], 8)); i = j; continue
                out.append(ESC[nx]); i += 2; continue
            out.append(ord(ch)); i += 1
        out.append(0)
    return bytes(out)


def collect_labels(n):
    for l in n.labels:
        emitted_labels.add(l)
    for c in n.children:
        collect_labels(c)


# Phone properties NOT transplanted. qcom,iommu-dma-addr-pool: the 6.12/6.18 arm-smmu WARNs on
# every probe ("deprecated. Switch to using iommu-addresses") and qcom_iommu_get_fast_iova_range()
# fails a fastmap domain with -EINVAL while it is present; cam_smmu never reads it. The pools
# are expressed by cam_iommu_region_partition (6.12 ADAPTATION section) instead.
DROP_PROPS = {'qcom,iommu-dma-addr-pool'}
# Phone properties replaced (path, property) -> lines. Keep in sync with the hand-made fixes.
OVERRIDE_PROPS = {
    ('/soc/i2c@98c000/sm5714-fled', 'status'): [
        '/* MUST stay disabled (boarddt a52sxq-bsp612-fixups.dtsi, drivers612/power): as an I2C',
        ' * client at 0x49 it takes the address before the SM5714 MFD, which then never creates',
        ' * its fuel gauge/charger: Android read 0 V, no USB, and shut down "battery" (runs',
        ' * ab-s41..s46, 2026-11-14). The MFD creates the flash LED child itself. */',
        'status = "disabled";'],
}


def emit(n, ind, out, header=None):
    t = '\t' * ind
    if header is None:
        lab = ''.join(l + ': ' for l in n.labels)
        header = lab + n.name
    out.append('%s%s {' % (t, header))
    # decompiled order is reversed-ish for overlay-applied props; keep as on phone
    for k, v in n.props:
        if k in DROP_PROPS:
            continue
        if (n.path(), k) in OVERRIDE_PROPS:
            out.extend('%s\t%s' % (t, l) for l in OVERRIDE_PROPS[(n.path(), k)])
            continue
        out.append('%s\t%s' % (t, fmt_prop(n, k, v, ind + 1)))
    for c in n.children:
        out.append('')
        emit(c, ind + 1, out)
    out.append('%s};' % t)


def node(path):
    n = ppath.get(path)
    if n is None:
        sys.exit('phone node not found: ' + path)
    return n


soc = node('/soc')
SOC_CAM = []
for c in soc.children:
    comp = c.get('compatible') or ''
    nm = c.name
    if (re.match(r'qcom,(cam|csiphy|cci|csid|vfe|ife|a5|ipe|bps|jpeg|lrme|cpas|ope|camera-flash|torch_|flash_|cam_smmu|cam-)', nm)
            or re.search(r'"qcom,(cam|csiphy|cci|csid|vfe|lrme|msm-cam)', comp)):
        if 'pm8350c-flash' in comp:
            continue
        SOC_CAM.append(c)

I2C_S2MPB03 = node('/soc/i2c@980000')
I2C_FLED = node('/soc/i2c@98c000')
I2C_OIS = node('/soc/i2c@990000')
s2 = [c for c in I2C_S2MPB03.children if 's2mpb03' in (c.get('compatible') or '')]
fled = [c for c in I2C_FLED.children if 'sm5714-fled' in (c.get('compatible') or '')]
ois = [c for c in I2C_OIS.children if (c.get('compatible') or '') == '"qcom,ois"']

# 6.12 adaptation: give the context banks labels so the iommu-addresses reservation can point at them
SMMU = node('/soc/qcom,cam_smmu')
iova_res = []
iova_pools = []
iova_discard = {}  # label -> (start, len) of the io region's iova-region-discard
for cb in SMMU.children:
    pool = cb.get('qcom,iommu-dma-addr-pool')
    if not pool:
        continue
    lab = 'cam_smmu_' + cb.name.replace('msm_cam_smmu_', '')
    if lab not in cb.labels:
        cb.labels.append(lab)
    st, ln = cells(pool)
    lower = st
    for mm in cb.children:
        for rg in mm.children:
            if (rg.get('iova-region-name') or '') == '"io"':
                d = rg.get('iova-region-discard')
                if d:
                    iova_discard[lab] = tuple(cells(d))
                continue
            a, b = rg.get('iova-region-start'), rg.get('iova-region-len')
            def cv(x):
                if x.startswith('<'):
                    return cells(x)[0]
                bb = strbytes(x)
                return int.from_bytes(bb[:4], 'big')
            if a and b:
                lower = max(lower, cv(a) + cv(b))
    end = st + ln
    iova_res.append((lab, lower, end, (1 << 32) - end))
    iova_pools.append((lab, lower, end, (1 << 32) - end, st, ln))

for n in SOC_CAM + s2 + fled + ois:
    collect_labels(n)

body = []


def section(title):
    body.append('')
    body.append('/* ' + '=' * 70)
    for l in title.split('\n'):
        body.append(' * ' + l)
    body.append(' * ' + '=' * 70 + ' */')


section('SoC camera nodes (new in the 6.12 base: it carries no camera nodes at all).\n'
        'Transplanted 1:1 from the phone 5.4 tree, 5.4 downstream bindings kept.')
body.append('&soc {')
first = True
for c in SOC_CAM:
    if not first:
        body.append('')
    first = False
    emit(c, 1, body)
body.append('};')


def bus_section(bus, kids, title):
    section(title)
    l = best_label(bus)
    if l not in base_labels:
        missing.setdefault(l, bus.path())
    else:
        used_base_labels.add(l)
        b = base_labels[l]
        if b.path() != bus.path():
            notes.append('bus label %s: phone %s vs base %s' % (l, bus.path(), b.path()))
    body.append('&%s {' % l)
    body.append('\tstatus = "ok";')
    for k in ('pinctrl-names', 'pinctrl-0', 'pinctrl-1'):
        v = bus.get(k)
        if v and v.startswith('<'):
            body.append('\t/* phone bus (owned by the board fragment): %s = <%s>; */' % (k, ' '.join('&' + (best_label(pph[c]) or '?') for c in cells(v))))
    for c in kids:
        body.append('')
        emit(c, 1, body)
    body.append('};')
    return l


bus_section(I2C_S2MPB03, s2, 'S2MPB03 camera PMIC (I2C %s, phone bus label and address from the phone tree).\n'
            'NOTE: may be owned by the drivers612/power fragment; that directory was EMPTY when this\n'
            'was generated (2026-11-11), so the node is defined here. If power/ later defines the same\n'
            'labels (s2mpb03_0_l1..l7), delete this section and keep the references.' % I2C_S2MPB03.name)
bus_section(I2C_FLED, fled, 'SM5714 flash LED (child of the SM5714 MFD bus %s). The sm5714 MFD/charger node itself\n'
            'belongs to the power fragment; only the fled child is camera.' % I2C_FLED.name)
bus_section(I2C_OIS, ois, 'OIS MCU (rear wide) on %s' % I2C_OIS.name)

# pinctrl: run to fixpoint (emitting may reference more)
pin_out = []
done = set()
diff_pins = []
while True:
    todo = [(l, n) for l, n in extra_emit.items() if l not in done]
    if not todo:
        break
    for l, n in todo:
        done.add(l)
        emitted_labels.add(l)
        # emit relative to tlmm, keeping intermediate parents
        chain = []
        x = n
        while x.parent is not None and not x.path().endswith('/pinctrl@f000000'):
            chain.append(x)
            x = x.parent
        chain.reverse()
        ind = 1
        for a in chain[:-1]:
            pin_out.append('\t' * ind + a.name + ' {')
            ind += 1
        emit(n, ind, pin_out)
        for a in chain[:-1]:
            ind -= 1
            pin_out.append('\t' * ind + '};')
        pin_out.append('')

# pinctrl labels that exist in base: compare content, override when different
def flat(n):
    return (sorted((k, v) for k, v in n.props), sorted((c.name, flat(c)) for c in n.children))


over = []
for l in sorted(used_base_labels):
    b = base_labels[l]
    if '/pinctrl@f000000/' not in b.path():
        continue
    pn = None
    for p, n in ppath.items():
        if l in n.labels:
            pn = n
            break
    if pn is None:
        continue
    if flat(pn) != flat(b):
        diff_pins.append(l)
        emit(pn, 0, over, header='&' + l)
        over.append('')

section('6.12 ADAPTATION (NOT on the phone; the only non-transplanted content in this file).\n'
        '6.12 dropped qcom,iommu-dma-addr-pool. Same technique as donors/redwood-6.12\n'
        '(redwood-camera.dtsi, cam_iommu_region_partition): reserve every IOVA outside each context\n'
        "bank's 5.4 pool with iommu-addresses so the DMA API stays inside the pool and cam_smmu can map\n"
        'firmware/shared/secheap/qdss regions itself. Ranges are COMPUTED from the phone pools and\n'
        'iova-mem-map above (lower bound = max(pool start, end of non-io regions)); they equal\n'
        "redwood's numbers. The phone's qcom,iommu-dma-addr-pool properties are NOT transplanted\n"
        '(gen.py DROP_PROPS): 6.12/6.18 arm-smmu WARNs on each, and they make\n'
        'qcom_iommu_get_fast_iova_range() fail. Phone pools, for reference (base, size):\n'
        + ''.join('  %s <0x%x 0x%x>\n' % (lab, ps, pl) for lab, _l, _e, _t, ps, pl in iova_pools) +
        'The entries are in /soc/qcom,cam_smmu\'s cell format (1 address + 1 size cell, as /soc):\n'
        'of_translate_dma_region() sizes them by the context bank\'s DMA parent, and on 6.18 a\n'
        'parent without #address-cells matches no OF bus, so every entry failed to translate\n'
        '("iommu-addresses: cannot translate entry", plus a "Missing \'#address-cells\'" WARN) and\n'
        'no camera IOVA was reserved at all. 6.12 fell back to /soc\'s cells silently.\n'
        'iova-region-discard of an io region is reserved too: the 5.4 cam_smmu_setup_cb() did\n'
        'iommu_dma_reserve_iova() on it (gone on 6.12, Qualcomm\'s 6.12 cam_smmu_util_iommu_custom()\n'
        'is empty there), and the ICP firmware is told the io region minus that hole\n'
        '(cam_icp_hw_mgr), so a DMA API buffer mapped inside it is unusable for the ICP.')
body.append('&soc {')
body.append('\tqcom,cam_smmu {')
body.append('\t\t#address-cells = <1>;')
body.append('\t\t#size-cells = <1>;')
body.append('\t};')
body.append('')
body.append('\tcam_iova: cam_iommu_region_partition {')
items = []
for lab, lower, end, tail in iova_res:
    items.append('<&%s 0x0 0x%x>' % (lab, lower))
    items.append('<&%s 0x%x 0x%x>' % (lab, end, tail))
    if lab in iova_discard:
        ds, dl = iova_discard[lab]
        assert lower <= ds and ds + dl <= end, (lab, ds, dl)
        items.append('<&%s 0x%x 0x%x>' % (lab, ds, dl))
body.append('\t\tiommu-addresses = ' + (',\n\t\t\t\t  ').join(items) + ';')
body.append('\t};')
body.append('};')
for lab, lower, end, tail in iova_res:
    body.append('')
    body.append('&%s {' % lab)
    body.append('\tmemory-region = <&cam_iova>;')
    # 5.4 cam_smmu set DOMAIN_ATTR_FAULT_MODEL_NO_STALL + _HUPCF at run time on every context
    # bank with "stall-disable"; 6.12 has no domain attributes, arm-smmu reads these strings.
    body.append('\t/* 6.12: replaces the cam_smmu run-time NO_STALL + HUPCF domain attributes */')
    body.append('\tqcom,iommu-faults = "stall-disable", "HUPCF", "non-fatal";')
    body.append('};')

section('Pinctrl states the phone uses that do NOT exist (by label) in the 6.12 base tlmm.')
body.append('&tlmm {')
body.extend(pin_out)
body.append('};')
if over:
    section('Pinctrl states that exist in the 6.12 base under the same label but with DIFFERENT content\n'
            'on the phone: overridden with the phone values (stale base sub-nodes, if any, are noted\n'
            'in DT-NOTES.md).')
    body.extend(over)

head = '''// SPDX-License-Identifier: GPL-2.0-only
/*
 * a52sxq-camera.dtsi - Samsung Galaxy A52s 5G (a52sxq, SM7325 "yupik") camera stack for the
 * Qualcomm 6.12 BSP base dtb (bsp612/out/dist/dtb/yupik.dtb).
 *
 * GENERATED by drivers612/camera/dt-work/gen.py from downstream-dt/a52sxq-r02.dts (the merged
 * tree the phone boots; dtbo r02 covers hw rev 2..0x20, so bench revisions 3 and 4 use it).
 * Every value (voltages, GPIOs, addresses, stream IDs, iova maps, clock rates) is the phone's.
 * Only phandles were retargeted: numeric phandle -> label, clock / interconnect numbers ->
 * the same-named 6.12 header macro (5.4 qcom,camcc-yupik.h numbering != 6.12 numbering).
 * The consumer is the phone's 5.4 Samsung camera techpack forward-ported, so the 5.4
 * downstream bindings (compatibles, property names) are kept exactly.
 * See DT-NOTES.md for missing labels, revision notes and the sensor table.
 */

#include <dt-bindings/clock/qcom,camcc-sc7280.h>
#include <dt-bindings/clock/qcom,gcc-sc7280.h>
#include <dt-bindings/interconnect/qcom,yupik.h>
#include <dt-bindings/interrupt-controller/arm-gic.h>
'''
open(OUT, 'w').write(head + '\n'.join(body) + '\n')

with open(REPORT, 'w') as r:
    r.write('SOC camera nodes emitted:\n')
    for c in SOC_CAM:
        r.write('  %s (%s)\n' % (c.name, c.get('compatible')))
    r.write('\nBase labels referenced (exist in 6.12 base):\n  ' + ' '.join(sorted(used_base_labels)) + '\n')
    r.write('\nMISSING labels (not in 6.12 base, not defined by this fragment):\n')
    for l, p in missing.items():
        if l not in emitted_labels:
            r.write('  %s  (phone: %s)\n' % (l, p))
    r.write('\nPinctrl nodes added under &tlmm (label absent in base):\n  ' + ' '.join(done) + '\n')
    r.write('\nPinctrl labels present in base but content differs (overridden):\n  ' + ' '.join(diff_pins) + '\n')
    r.write('\nNotes:\n')
    for n in sorted(set(notes)):
        r.write('  ' + n + '\n')
print(open(REPORT).read())
