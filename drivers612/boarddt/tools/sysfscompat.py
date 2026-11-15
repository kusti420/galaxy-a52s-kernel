#!/usr/bin/env python3
"""5.4-compatible sysfs device paths for the 6.12 / 6.18 board tree (research/sepolicy/PATHS.md).

The ROM's SELinux genfscon labels (research/sepolicy/genfscon-sysfs-lineage-a52sxq.txt) are keyed
to the 5.4 sysfs layout. Two things in the 6.12 tree move devices away from those paths:
  1. the QUP serial engines (I2C/SPI/UART) are children of their qupv3 wrapper node, so their
     platform devices live under /devices/platform/soc/9c0000.qcom,qupv3_0_geni_se/ instead of
     directly under /devices/platform/soc/ (5.4: SE nodes are /soc children that point at the
     wrapper with "qcom,wrapper-core");
  2. the i2c adapter numbers: only i2c18 has an alias, the rest are numbered dynamically in probe
     order (5.4: i2c-gpio first at 0.5 s, then the geni buses in DT order; 6.12: modules, and
     a80000 fails, so every later bus moves).
`apply` fixes both in a finished tree (after every overlay):
  * every ENABLED SE node of a "qcom,geni-se-qup" wrapper whose driver is a soc-repo module
    (qcom,i2c-geni, qcom,spi-geni, qcom,msm-geni-serial-hs, qcom,msm-geni-uart) is moved to /soc,
    right after its wrapper, and gets qcom,wrapper-core = <&wrapper>. Needs soc-repo patch
    bsp612/patches/soc-repo/0009 in i2c-msm-geni / spi-msm-geni / msm_geni_serial (they found
    the wrapper as dev->parent only). The GKI built-in debug console (qcom,geni-debug-uart,
    994000) and disabled nodes stay where they are.
  * /aliases i2cN = the 5.4 bus number of every 5.4 bus (I2C_54 below).
  * /__symbols__, /aliases and /chosen paths of moved nodes are rewritten.
Everything else is copied unchanged (props, order, phandles, memory reservations).

  sysfscompat.py apply IN.dtb OUT.dtb      transform (idempotent; refuses odd layouts)
  sysfscompat.py check DTB                 exit 0 if DTB is in the 5.4 layout ("flat"), 1 if not
  sysfscompat.py ko-patched KO...          exit 0 if every .ko has the 0009 wrapper lookup
  sysfscompat.py verify OLD.dtb NEW.dtb    NEW == apply(OLD) exactly; lists every property change
  sysfscompat.py sim DTB [--kernel 54|612] simulated sysfs paths (platform devices, SPMI, i2c)
The genfscon mapping table is research/sepolicy/mktable.py (uses sim).
"""
import struct, sys, re, os, argparse

# ----------------------------------------------------------------------------- FDT read/write
class Node:
    __slots__ = ('name', 'props', 'children', 'parent')
    def __init__(self, name, parent=None):
        self.name, self.props, self.children, self.parent = name, [], [], parent
    def path(self):
        if self.parent is None: return '/'
        p = self.parent.path()
        return (p if p.endswith('/') else p + '/') + self.name
    def prop(self, n, d=None):
        for k, v in self.props:
            if k == n: return v
        return d
    def setprop(self, n, v):
        for i, (k, _) in enumerate(self.props):
            if k == n: self.props[i] = (n, v); return
        self.props.append((n, v))
    def delprop(self, n):
        self.props = [(k, v) for k, v in self.props if k != n]
    def child(self, n):
        for c in self.children:
            if c.name == n: return c
        return None
    def get(self, path):
        n = self
        for part in [x for x in path.split('/') if x]:
            n = n.child(part)
            if n is None: return None
        return n
    def walk(self):
        yield self
        for c in self.children: yield from c.walk()
    def strs(self, n):
        v = self.prop(n)
        return [] if v is None else [s.decode('latin1') for s in v.split(b'\0')[:-1]]
    def str(self, n, d=None):
        s = self.strs(n); return s[0] if s else d
    def u32s(self, n):
        v = self.prop(n)
        return None if v is None else list(struct.unpack('>%dI' % (len(v) // 4), v[:len(v) // 4 * 4]))

class Tree:
    def __init__(self, blob):
        magic, total, ost, ostr, orsv, ver, lcv, cpuid = struct.unpack_from('>8I', blob, 0)
        assert magic == 0xd00dfeed, 'not a dtb'
        self.cpuid = cpuid
        self.rsv = []; p = orsv
        while True:
            a, s = struct.unpack_from('>QQ', blob, p); p += 16
            if a == 0 and s == 0: break
            self.rsv.append((a, s))
        def cstr(o):
            return blob[o:blob.index(b'\0', o)]
        p = ost; cur = None; self.root = None
        while True:
            tok = struct.unpack_from('>I', blob, p)[0]; p += 4
            if tok == 1:
                nm = cstr(p); p = (p + len(nm) + 1 + 3) & ~3
                n = Node(nm.decode('latin1'), cur)
                if cur is None: self.root = n
                else: cur.children.append(n)
                cur = n
            elif tok == 2: cur = cur.parent
            elif tok == 3:
                ln, no = struct.unpack_from('>II', blob, p); p += 8
                cur.props.append((cstr(ostr + no).decode('latin1'), blob[p:p + ln])); p = (p + ln + 3) & ~3
            elif tok == 4: continue
            elif tok == 9: break
            else: raise ValueError('bad token %#x at %#x' % (tok, p - 4))
    def blob(self):
        st = bytearray(); strs = bytearray(); soff = {}
        def so(n):
            if n not in soff:
                soff[n] = len(strs); strs.extend(n.encode('latin1') + b'\0')
            return soff[n]
        def emit(n):
            st.extend(struct.pack('>I', 1)); nm = n.name.encode('latin1') + b'\0'
            st.extend(nm + b'\0' * ((4 - len(nm) % 4) % 4))
            for k, v in n.props:
                st.extend(struct.pack('>III', 3, len(v), so(k))); st.extend(v + b'\0' * ((4 - len(v) % 4) % 4))
            for c in n.children: emit(c)
            st.extend(struct.pack('>I', 2))
        emit(self.root); st.extend(struct.pack('>I', 9))
        rsv = b''.join(struct.pack('>QQ', a, s) for a, s in self.rsv) + b'\0' * 16
        orsv = 40; ost = orsv + len(rsv); ostr = ost + len(st); total = ostr + len(strs)
        return struct.pack('>10I', 0xd00dfeed, total, ost, ostr, orsv, 17, 16, self.cpuid, len(strs), len(st)) + rsv + bytes(st) + bytes(strs)
    def by_phandle(self):
        m = {}
        for n in self.root.walk():
            v = n.prop('phandle') or n.prop('linux,phandle')
            if v and len(v) == 4: m[struct.unpack('>I', v)[0]] = n
        return m

def load(p):
    with open(p, 'rb') as f: return Tree(f.read())

def okay(n):
    s = n.str('status', 'okay')
    return s in ('okay', 'ok')

def strprop(s):
    return s.encode('latin1') + b'\0'

# ----------------------------------------------------------------------------- the 5.4 layout
WRAPPER_COMPAT = 'qcom,geni-se-qup'
# soc-repo module drivers that bsp612/patches/soc-repo/0009 teaches the qcom,wrapper-core lookup
FLAT_COMPAT = ('qcom,i2c-geni', 'qcom,spi-geni', 'qcom,msm-geni-serial-hs', 'qcom,msm-geni-uart')
# i2c adapter numbers on the phone's 5.4 kernel. Rule (both kernels, drivers/i2c/i2c-core-base.c):
# an /aliases i2cN fixes N; every other adapter gets the lowest free number >= highest alias + 1
# in registration order. 5.4 (phone 1 last_kmsg-recoveryloop, phone 2 genfscon list): alias
# i2c18 = 984000; i2c-gpio soc:i2c@17 registers first (built-in, 0.50 s) -> 19; the geni buses
# probe in DT order at ~1.77 s: 980000 -> 20, 98c000 -> 21 (sm5714 21-0049, pca9468 21-0057),
# 990000 -> 22 (22-0051), a80000 -> 23 (usbpd-sm5714 23-0033), a84000 -> 24, a94000 -> 25 (stm_ts
# 25-0049). Keyed by the bus node's unit address (the node name of i2c@17 is the same on 6.12).
I2C_54 = {'i2c@17': 19, 'i2c@980000': 20, 'i2c@984000': 18, 'i2c@98c000': 21, 'i2c@990000': 22,
          'i2c@a80000': 23, 'i2c@a84000': 24, 'i2c@a94000': 25}

def wrappers(t):
    soc = t.root.child('soc')
    return soc, [c for c in soc.children if WRAPPER_COMPAT in c.strs('compatible')]

def movable(wrap):
    return [c for c in wrap.children if okay(c) and any(x in FLAT_COMPAT for x in c.strs('compatible'))]

def is_flat(t):
    soc, ws = wrappers(t)
    return not any(movable(w) for w in ws)

def eff_prop(n, name):
    while n is not None:
        v = n.prop(name)
        if v is not None: return v
        n = n.parent
    return None

def apply(t, log):
    soc, ws = wrappers(t)
    if not ws: raise SystemExit('no %s wrapper under /soc' % WRAPPER_COMPAT)
    moved = {}   # old path -> new path
    for w in ws:
        if w.prop('ranges') != b'' or w.prop('#address-cells') != soc.prop('#address-cells') \
           or w.prop('#size-cells') != soc.prop('#size-cells'):
            raise SystemExit('%s: ranges/cells differ from /soc: moving its children would change reg' % w.path())
        wph = w.prop('phandle')
        if not wph: raise SystemExit('%s has no phandle' % w.path())
        pos = soc.children.index(w) + 1
        for c in movable(w):
            if soc.child(c.name) is not None:
                raise SystemExit('/soc already has a node %s (cannot move %s)' % (c.name, c.path()))
            if c.prop('qcom,wrapper-core') not in (None, wph):
                raise SystemExit('%s: qcom,wrapper-core points elsewhere' % c.path())
            ip_old = eff_prop(c, 'interrupt-parent')
            old = c.path()
            w.children.remove(c); c.parent = soc; soc.children.insert(pos, c); pos += 1
            if eff_prop(c, 'interrupt-parent') != ip_old:
                raise SystemExit('%s: interrupt-parent would change' % old)
            c.setprop('qcom,wrapper-core', wph)
            moved[old] = c.path(); log('moved %s -> %s (qcom,wrapper-core = <%#x>)' % (old, c.path(), struct.unpack('>I', wph)[0]))
    def rewrite(s):
        for o, n in moved.items():
            if s == o or s.startswith(o + '/'): return n + s[len(o):]
        return s
    nsym = 0
    for node in (t.root.child('__symbols__'), t.root.child('aliases'), t.root.child('chosen')):
        if node is None: continue
        for i, (k, v) in enumerate(node.props):
            if k in ('phandle', 'linux,phandle', 'bootargs') or not v.endswith(b'\0'): continue
            if node.name == 'chosen' and k not in ('stdout-path', 'linux,stdout-path'): continue
            s = v[:-1].decode('latin1'); base, sep, opt = s.partition(':') if node.name == 'chosen' else (s, '', '')
            r = rewrite(base)
            if r != base:
                node.props[i] = (k, strprop(r + sep + opt))
                if node.name == '__symbols__': nsym += 1
                else: log('%s/%s: %s -> %s' % (node.path(), k, s, r + sep + opt))
    log('/__symbols__: %d labels rewritten to the new paths' % nsym)
    # no other string property may still name a moved path
    for n in t.root.walk():
        for k, v in n.props:
            for o in moved:
                if o.encode() + b'\0' in v or (o + '/').encode() in v:
                    raise SystemExit('%s/%s still names %s' % (n.path(), k, o))
    # i2c aliases with the 5.4 numbers
    al = t.root.child('aliases')
    if al is None: raise SystemExit('no /aliases')
    byname = {}
    for n in soc.walk():
        if n.name in I2C_54 and n.parent is soc or (n.parent is not None and n.parent.parent is soc and WRAPPER_COMPAT in n.parent.strs('compatible') and n.name in I2C_54):
            byname[n.name] = n.path()
    for nm, num in sorted(I2C_54.items(), key=lambda x: x[1]):
        if nm not in byname: raise SystemExit('i2c bus node %s not found' % nm)
        key = 'i2c%d' % num; want = strprop(byname[nm])
        # an alias pointing at a different node with the same number would clash
        for k, v in al.props:
            if k != key and re.fullmatch(r'i2c\d+', k) and v == want:
                raise SystemExit('/aliases/%s already names %s' % (k, byname[nm]))
        if al.prop(key) != want:
            log('/aliases/%s: %s -> %s' % (key, (al.str(key) or '(none)'), byname[nm]))
        al.setprop(key, want)
    return moved

# ----------------------------------------------------------------------------- sysfs simulation
BUS_COMPAT = ('simple-bus', 'simple-mfd', 'isa', 'arm,amba-bus')

def translate(n):
    """of_translate_address of the first reg entry of n (None = OF_BAD_ADDR)."""
    reg = n.prop('reg')
    p = n.parent
    if reg is None or p is None: return None
    ac = struct.unpack('>I', p.prop('#address-cells', b'\0\0\0\x02'))[0]
    sc = struct.unpack('>I', p.prop('#size-cells', b'\0\0\0\x01'))[0]
    if len(reg) < 4 * ac or ac == 0: return None
    addr = 0
    for i in range(ac): addr = addr << 32 | struct.unpack_from('>I', reg, 4 * i)[0]
    cur = p
    while cur.parent is not None:
        rng = cur.prop('ranges')
        if rng is None: return None
        cac = struct.unpack('>I', cur.prop('#address-cells', b'\0\0\0\x02'))[0]
        csc = struct.unpack('>I', cur.prop('#size-cells', b'\0\0\0\x01'))[0]
        pp = cur.parent
        pac = struct.unpack('>I', pp.prop('#address-cells', b'\0\0\0\x02'))[0]
        if csc == 0: return None
        if rng == b'':
            cur = pp; continue
        w = cac + pac + csc; cells = struct.unpack('>%dI' % (len(rng) // 4), rng); hit = None
        for i in range(0, len(cells) - w + 1, w):
            ca = 0
            for x in cells[i:i + cac]: ca = ca << 32 | x
            pa = 0
            for x in cells[i + cac:i + cac + pac]: pa = pa << 32 | x
            sz = 0
            for x in cells[i + cac + pac:i + w]: sz = sz << 32 | x
            if ca <= addr < ca + sz: hit = pa + (addr - ca); break
        if hit is None: return None
        addr = hit; cur = pp
    return addr

def bus_id(n):
    """of_device_make_bus_id (identical format on 5.4 and 6.12)."""
    name = None; node = n
    while node.parent is not None:
        a = translate(node)
        short = node.name.split('@')[0]
        if a is not None:
            return '%x.%s' % (a, short) + (':' + name if name else '')
        name = node.name + (':' + name if name else '')
        node = node.parent
    return name

FAIL_612 = ('i2c@a80000',)   # 6.12: "pin-32 (a80000.i2c) EINVAL": tlmm qcom,gpios-reserved has 32 33

def simulate(t, kernel, failing=None):
    """{node: sysfs dir} for platform devices + i2c adapters/clients + SPMI PMIC function devices;
    i2c numbering included. failing: bus node names whose adapter never registers (default: the
    6.12 a80000 pinctrl failure on 6.12, nothing on 5.4)."""
    if failing is None: failing = FAIL_612 if kernel != 54 else ()
    dev = {}; i2c = {}
    soc, ws = wrappers(t)
    def populate(parent_node, parent_dir, recurse_all=False):
        for c in parent_node.children:
            if c.prop('compatible') is None or not okay(c): continue
            d = parent_dir + '/' + bus_id(c); dev[c] = d
            comp = c.strs('compatible')
            if any(x in BUS_COMPAT for x in comp) or (kernel != 54 and WRAPPER_COMPAT in comp):
                populate(c, d)
    populate(t.root, '/devices/platform')
    # SPMI: the arbiter's PMIC children are spmi devices "spmi-0/<sid>" (5.4 Qualcomm core
    # "spmi0-%02x", 6.12 "%d-%02x"), their function nodes platform devices (pmic of_platform_populate)
    for n in list(dev):
        if not any('spmi-pmic-arb' in x for x in n.strs('compatible')): continue
        for pm in n.children:
            if not okay(pm) or pm.prop('reg') is None: continue
            sid = struct.unpack('>I', pm.prop('reg')[:4])[0]
            sd = dev[n] + '/spmi-0/' + (('spmi0-%02x' if kernel == 54 else '0-%02x') % sid)
            dev[('spmi', pm)] = sd
            for fn in pm.children:
                if fn.prop('compatible') is None or not okay(fn): continue
                dev[fn] = sd + '/' + bus_id(fn)
    # i2c numbering
    al = t.root.child('aliases'); amap = {}
    if al is not None:
        for k, v in al.props:
            m = re.fullmatch(r'i2c(\d+)', k)
            if m:
                tn = t.root.get(v[:-1].decode('latin1'))
                if tn is not None: amap[tn] = int(m.group(1))
    first = max(amap.values()) + 1 if amap else 0
    buses = [n for n in dev if not isinstance(n, tuple) and any(x in ('qcom,i2c-geni', 'i2c-gpio') for x in n.strs('compatible'))]
    # registration order: 5.4 = i2c-gpio (built-in) then geni in DT order; 6.12 = modules: geni
    # (stage i2c / first stage) in DT order, a80000 fails its pinctrl (pin 32) on 6.12, i2c-gpio
    # (=m) is not in any load list
    order = sorted(buses, key=lambda n: (0 if 'i2c-gpio' in n.strs('compatible') else 1, list(t.root.walk()).index(n)))
    if kernel != 54:
        order = [n for n in order if 'i2c-gpio' not in n.strs('compatible')]
    order = [n for n in order if n.name not in failing]
    used = set(amap.values()); nxt = first
    for n in order:
        if n in amap: num = amap[n]
        else:
            while nxt in used: nxt += 1
            num = nxt; used.add(num)
        i2c[n] = num
        d = dev[n] + '/i2c-%d' % num; dev[('adap', n)] = d
        taken = set()
        for cl in n.children:
            if not okay(cl) or cl.prop('reg') is None: continue
            a = struct.unpack('>I', cl.prop('reg')[:4])[0]
            if a in taken: continue          # i2c core: second client at an address -> -EBUSY
            taken.add(a)
            dev[('client', cl)] = d + '/%d-%04x' % (num, a)
    return dev, i2c

def sim_paths(t, kernel):
    dev, i2c = simulate(t, kernel)
    out = []
    for k, v in dev.items():
        n = k[1] if isinstance(k, tuple) else k
        out.append((v, n.path()))
    return sorted(out), i2c

# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('apply'); a.add_argument('inp'); a.add_argument('out'); a.add_argument('-q', action='store_true')
    c = sub.add_parser('check'); c.add_argument('dtb')
    k = sub.add_parser('ko-patched'); k.add_argument('ko', nargs='+')
    s = sub.add_parser('sim'); s.add_argument('dtb'); s.add_argument('--kernel', type=int, default=612)
    v = sub.add_parser('verify'); v.add_argument('old'); v.add_argument('new')
    o = ap.parse_args()
    if o.cmd == 'verify':
        # proof that NEW = apply(OLD) and nothing else: re-apply on OLD and compare blobs, then
        # list every node/property difference by (moved) path
        t_old = load(o.old); t_ref = load(o.old); moved = apply(t_ref, lambda l: None)
        t_new = load(o.new)
        if t_ref.blob() != t_new.blob():
            sys.exit('%s is not exactly sysfscompat.apply(%s)' % (o.new, o.old))
        def m(p):
            for a, b in moved.items():
                if p == a or p.startswith(a + '/'): return b + p[len(a):]
            return p
        old = {m(n.path()): dict(n.props) for n in t_old.root.walk()}
        new = {n.path(): dict(n.props) for n in t_new.root.walk()}
        assert set(old) == set(new), 'node sets differ'
        diffs = 0
        for p in sorted(new):
            for k in sorted(set(old[p]) | set(new[p])):
                if old[p].get(k) != new[p].get(k):
                    diffs += 1
                    if p not in ('/__symbols__',):
                        print('%s/%s: %s -> %s' % (p, k, 'absent' if k not in old[p] else 'changed', 'absent' if k not in new[p] else 'set'))
        print('%d property differences (incl. /__symbols__); %d nodes moved; all other nodes and properties identical' % (diffs, len(moved)))
        return
    if o.cmd == 'apply':
        t = load(o.inp)
        lines = []
        moved = apply(t, lines.append)
        if not o.q:
            for l in lines: print(l)
        with open(o.out, 'wb') as f: f.write(t.blob())
        print('%s: %d SE nodes moved to /soc, i2c aliases = 5.4 numbers' % (o.out, len(moved)))
    elif o.cmd == 'check':
        t = load(o.dtb); al = t.root.child('aliases')
        ok = is_flat(t) and all(al.prop('i2c%d' % v) is not None for v in I2C_54.values())
        print('%s: %s' % (o.dtb, '5.4 sysfs layout' if ok else 'NOT in the 5.4 sysfs layout'))
        sys.exit(0 if ok else 1)
    elif o.cmd == 'ko-patched':
        bad = [f for f in o.ko if b'a52sxq-wrapper-core' not in open(f, 'rb').read()]
        for f in bad: print('NOT patched (bsp612/patches/soc-repo/0009): %s' % f)
        sys.exit(1 if bad else 0)
    elif o.cmd == 'sim':
        paths, i2c = sim_paths(load(o.dtb), o.kernel)
        for p, n in paths: print('%s\t%s' % (p, n))

if __name__ == '__main__':
    main()
