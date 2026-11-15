#!/usr/bin/env python3
"""dt-compare.py <phone.dtb> <merged.dtb>: NFC nodes of the 6.12 tree vs the phone's.

Reads with fdtget/dtc only. Phandle-valued properties are compared by the path tail of the
node they point to, since phandle numbers differ between trees. Exit status 1 on any mismatch.
Checks:
  1. sec-nfc@27, fixed_regulator@1 (PVDD) and the seven NFC/LDO pin states equal the phone's;
  2. the SE9 I2C controller is enabled, its sleep state is the phone's, its SPI personality
     is disabled, sec-nfc@27 is the only enabled child;
  3. TLMM 36..42 are not reserved for TZ, and no other enabled node claims them (pin state
     or GPIO specifier).
"""
import re
import subprocess
import sys

PHONE, MERGED = sys.argv[1], sys.argv[2]
FAIL = []


def fdtget(dtb, node, prop=None, typ="x"):
    args = ["fdtget"]
    if prop is None:
        args += ["-p", dtb, node]
    else:
        args += ["-t", typ, dtb, node, prop]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        return None
    return r.stdout.strip()


def props(dtb, node):
    out = fdtget(dtb, node)
    return [] if out is None else out.split()


def subnodes(dtb, node):
    r = subprocess.run(["fdtget", "-l", dtb, node], capture_output=True, text=True)
    return [] if r.returncode else r.stdout.split()


_dts = {}


def dts(dtb):
    if dtb not in _dts:
        _dts[dtb] = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", dtb],
                                   capture_output=True, text=True).stdout
    return _dts[dtb]


_ph = {}


def phandle_map(dtb):
    """phandle (int) -> node path."""
    if dtb in _ph:
        return _ph[dtb]
    m, path = {}, []
    for line in dts(dtb).splitlines():
        s = line.strip()
        if s.endswith("{"):
            name = s[:-1].strip().split(":")[-1].strip()
            path.append(name)
        elif s.startswith("};"):
            path.pop()
        else:
            g = re.match(r"phandle = <(0x[0-9a-f]+)>;", s)
            if g:
                m[int(g.group(1), 16)] = "/" + "/".join(path[1:])
    _ph[dtb] = m
    return m


def tail(path):
    """Compare targets by their last two components (parents differ between the trees:
    QUP wrapper nodes, pin group containers) - enough to tell pin states/regulators apart."""
    return "/".join(path.split("/")[-2:]) if path else None


def resolve(dtb, cell):
    return tail(phandle_map(dtb).get(int(cell, 16)))


# property -> phandle cell positions ("all" = every cell)
PHANDLE_PROPS = {
    "pinctrl-0": "all", "pinctrl-1": "all", "nfc_pvdd-supply": [0], "interrupt-parent": [0],
    "sec-nfc,irq-gpio": [0], "sec-nfc,ven-gpio": [0], "sec-nfc,firm-gpio": [0],
    "sec-nfc,clk_req-gpio": [0], "gpio": [0],
}


def norm(dtb, p, val):
    if val is None or p not in PHANDLE_PROPS:
        return val
    v = val.split()
    idx = range(len(v)) if PHANDLE_PROPS[p] == "all" else PHANDLE_PROPS[p]
    for i in idx:
        v[i] = str(resolve(dtb, v[i]))
    return " ".join(v)


def compare_node(pnode, mnode, ignore=("phandle",), only=None):
    pp, mp = props(PHONE, pnode), props(MERGED, mnode)
    if not pp:
        FAIL.append("phone node %s not found" % pnode)
        return
    if not mp:
        FAIL.append("merged node %s not found" % mnode)
        return
    for p in sorted(set(pp) | set(mp)):
        if p in ignore or (only and p not in only):
            continue
        if p not in mp:
            FAIL.append("%s: %s missing in the 6.12 tree" % (mnode, p))
            continue
        if p not in pp:
            FAIL.append("%s: %s not in the phone's node" % (mnode, p))
            continue
        a = norm(PHONE, p, fdtget(PHONE, pnode, p))
        b = norm(MERGED, p, fdtget(MERGED, mnode, p))
        ok = a == b
        print("  %-4s %-22s %s" % ("ok" if ok else "DIFF", p, b if ok else "%s (phone: %s)" % (b, a)))
        if not ok:
            FAIL.append("%s: %s differs" % (mnode, p))


def sym(dtb, label):
    return fdtget(dtb, "/__symbols__", label, "s")


pi2c, mi2c = sym(PHONE, "qupv3_se9_i2c"), sym(MERGED, "qupv3_se9_i2c")
print("sec-nfc@27 (%s):" % mi2c)
compare_node(pi2c + "/sec-nfc@27", mi2c + "/sec-nfc@27")

print("PVDD fixed_regulator@1:")
preg = "/samsung_mobile_device/fixed_regulator@1"
mreg = sym(MERGED, "a52sxq_nfc_pvdd")
print("  6.12 node: %s" % mreg)
compare_node(preg, mreg)
sup = fdtget(MERGED, mi2c + "/sec-nfc@27", "nfc_pvdd-supply")
if not sup or phandle_map(MERGED).get(int(sup.split()[0], 16)) != mreg:
    FAIL.append("nfc_pvdd-supply does not point at %s" % mreg)
if fdtget(MERGED, "/samsung_mobile_device", "compatible", "s") != "simple-bus":
    FAIL.append("/samsung_mobile_device is not a simple-bus: the regulator would not probe")

for label in ("nfc_firm_gpio", "nfc_ven_gpio", "nfc_irq_gpio", "nfc_clk_req_gpio",
              "nfc_i2c_sda_sleep", "nfc_i2c_scl_sleep", "ldo_gpio1"):
    print("%s:" % label)
    pn, mn = sym(PHONE, label), sym(MERGED, label)
    if not mn:
        FAIL.append("label %s missing in the 6.12 tree" % label)
        continue
    for sub in ("config", "mux"):
        compare_node(pn + "/" + sub, mn + "/" + sub)

print("SE9 controller:")
st = fdtget(MERGED, mi2c, "status", "s")
print("  i2c@a84000 status=%s" % st)
if st != "okay":
    FAIL.append("qupv3_se9_i2c not okay")
compare_node(pi2c, mi2c, only=("pinctrl-1", "qcom,clk-freq-out", "reg", "interrupts"))
spi = sym(MERGED, "qupv3_se9_spi")
st = fdtget(MERGED, spi, "status", "s") if spi else None
print("  spi@a84000 (%s) status=%s" % (spi, st))
if spi and st != "disabled":
    FAIL.append("qupv3_se9_spi is not disabled")
for child in subnodes(MERGED, mi2c):
    st = fdtget(MERGED, mi2c + "/" + child, "status", "s") or "okay"
    print("  child %-12s status=%s" % (child, st))
    if child != "sec-nfc@27" and st in ("okay", "ok"):
        FAIL.append("another enabled device on the NFC bus: %s" % child)

print("TLMM 36..42:")
PINS = set(range(36, 43))
tlmm = sym(MERGED, "tlmm")
res = set(int(x) for x in (fdtget(MERGED, tlmm, "qcom,gpios-reserved", "u") or "").split())
print("  qcom,gpios-reserved = %s" % sorted(res))
if res & PINS:
    FAIL.append("NFC pins reserved for TZ: %s" % sorted(res & PINS))

ALLOWED = ("sec-nfc@27", "i2c@a84000", "fixed_regulator@1")
tlmm_ph = fdtget(MERGED, tlmm, "phandle", "x")
text = dts(MERGED)
stack, nodes = [], {}
for line in text.splitlines():
    s = line.strip()
    if s.endswith("{"):
        stack.append(s[:-1].strip().split(":")[-1].strip())
        nodes.setdefault("/".join(stack), {"ph": None, "pins": False, "status": None,
                                           "refs": [], "gpios": False})
    elif s.startswith("};"):
        stack.pop()
    elif stack:
        n = nodes["/".join(stack)]
        g = re.match(r"phandle = <(0x[0-9a-f]+)>;", s)
        if g:
            n["ph"] = g.group(1)
        if s.startswith("pins") and any('"gpio%d"' % g in s for g in PINS):
            n["pins"] = True
        if s.startswith("status = "):
            n["status"] = s.split('"')[1]
        if s.startswith("pinctrl-") and "<" in s:
            n["refs"] += s.split("<")[1].split(">")[0].split()
        # GPIO specifiers <&tlmm N flags> anywhere in a property value
        if "<" in s and tlmm_ph:
            cells = " ".join(re.findall(r"<([^>]*)>", s)).split()
            for i in range(len(cells) - 1):
                try:
                    if int(cells[i], 16) == int(tlmm_ph, 16) and int(cells[i + 1], 16) in PINS \
                            and not s.startswith(("interrupt", "phandle", "pinctrl")):
                        n["gpios"] = True
                except ValueError:
                    pass
states = set()
for p, n in nodes.items():
    if n["pins"]:
        for q in (p, "/".join(p.split("/")[:-1])):
            if nodes.get(q, {}).get("ph"):
                states.add(nodes[q]["ph"])


def enabled(path):
    """A node is live if neither it nor any parent is disabled."""
    parts = path.split("/")
    for i in range(1, len(parts) + 1):
        st = nodes.get("/".join(parts[:i]), {}).get("status")
        if st in ("disabled", "fail"):
            return False
    return True


for p, n in sorted(nodes.items()):
    name = p.split("/")[-1]
    uses = bool(set(n["refs"]) & states) or n["gpios"]
    if not uses:
        continue
    live = enabled(p)
    print("  TLMM 36..42 used by %-58s %s" % (p.lstrip("/")[-58:], "live" if live else "disabled"))
    if live and name not in ALLOWED:
        FAIL.append("enabled node %s claims a TLMM 36..42 pin" % p)

if FAIL:
    print("FAILED:")
    for f in FAIL:
        print("  " + f)
    sys.exit(1)
print("all checks passed")
