#!/usr/bin/env python3
"""dt-compare.py <phone.dtb> <merged.dtb>: fingerprint nodes of the 6.12 tree vs the phone's.

Uses only fdtget/fdtput-free reads via `fdtget` (dtc package). Phandle-valued properties are
compared by the path of the node they point to, since phandle numbers differ between trees.
Exit status 1 on any mismatch.
"""
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


def path_of_phandle(dtb, ph):
    """Path of the node whose phandle is ph (walks __symbols__ first, then a full search)."""
    out = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", dtb],
                         capture_output=True, text=True).stdout
    # cheap parser: track the node path and look for "phandle = <ph>;"
    path = []
    want = "phandle = <%s>;" % ph
    for line in out.splitlines():
        s = line.strip()
        if s.endswith("{"):
            name = s[:-1].strip()
            if ":" in name:
                name = name.split(":")[-1].strip()
            path.append(name)
        elif s.startswith("};"):
            path.pop()
        elif s == want:
            return "/" + "/".join(p for p in path[1:])
    return None


_cache = {}


def resolve(dtb, ph):
    key = (dtb, ph)
    if key not in _cache:
        _cache[key] = path_of_phandle(dtb, "0x%x" % int(ph, 16))
    return _cache[key]


def tail(path):
    """Compare targets by their last two components (paths of parents differ: QUP wrapper
    nodes, rsc/drv names) - enough to tell pin states and regulators apart."""
    return "/".join(path.split("/")[-2:]) if path else None


PHANDLE_PROPS = {"pinctrl-0": [0], "etspi-sleepPin": [0], "etspi-btp-supply": [0]}


def compare_node(pnode, mnode, new_props=(), ignore=("phandle",)):
    pp, mp = props(PHONE, pnode), props(MERGED, mnode)
    if not pp:
        FAIL.append("phone node %s not found" % pnode)
        return
    if not mp:
        FAIL.append("merged node %s not found" % mnode)
        return
    for p in sorted(set(pp) | set(mp)):
        if p in ignore:
            continue
        if p not in mp:
            FAIL.append("%s: %s missing in the 6.12 tree" % (mnode, p))
            continue
        if p not in pp:
            if p in new_props:
                print("  new  %-24s %s" % (p, fdtget(MERGED, mnode, p)))
            else:
                FAIL.append("%s: %s not in the phone's node" % (mnode, p))
            continue
        a, b = fdtget(PHONE, pnode, p), fdtget(MERGED, mnode, p)
        if p in PHANDLE_PROPS and a and b:
            av, bv = a.split(), b.split()
            for i in PHANDLE_PROPS[p]:
                av[i] = tail(resolve(PHONE, av[i]))
                bv[i] = tail(resolve(MERGED, bv[i]))
            a, b = " ".join(map(str, av)), " ".join(map(str, bv))
        ok = a == b
        print("  %-4s %-24s %s" % ("ok" if ok else "DIFF", p, b if ok else "%s (phone: %s)" % (b, a)))
        if not ok:
            FAIL.append("%s: %s differs" % (mnode, p))


def sym(dtb, label):
    return fdtget(dtb, "/__symbols__", label, "s")


print("etspi node:")
compare_node("/soc/etspi,et7xx", "/soc/etspi,et7xx", new_props=("etspi-btp-supply",))
b = fdtget(MERGED, "/soc/etspi,et7xx", "etspi-btp-supply")
if b and tail(resolve(MERGED, b.split()[0])) != "rpmh-regulator-ldoc3/regulator-pm8350c-l3":
    FAIL.append("etspi-btp-supply does not point at L3C: %s" % resolve(MERGED, b.split()[0]))

for label in ("et7xx_rst",):
    print("%s:" % label)
    pn, mn = sym(PHONE, label), sym(MERGED, label)
    for sub in ("config", "mux"):
        compare_node(pn + "/" + sub, mn + "/" + sub)

print("L3C:")
compare_node(sym(PHONE, "pm8350c_l3"), sym(MERGED, "pm8350c_l3"))

print("TrustZone SPI engine (QUP SE14) untouched:")
for label in ("qupv3_se14_spi", "qupv3_se14_i2c"):
    path = sym(MERGED, label)
    st = fdtget(MERGED, path, "status", "s") if path else None
    print("  %-16s %s status=%s" % (label, path, st))
    if st != "disabled":
        FAIL.append("%s is not disabled" % label)
res = fdtget(MERGED, sym(MERGED, "tlmm"), "qcom,gpios-reserved", "u") or ""
print("  tlmm qcom,gpios-reserved = %s" % res)
if not {"56", "57", "58", "59"} <= set(res.split()):
    FAIL.append("TLMM 56..59 not reserved")
# no other node may claim the SE14 pins or the sensor's sleep pin
dts = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", MERGED],
                     capture_output=True, text=True).stdout
if dts.count('compatible = "etspi,et7xx"') != 1:
    FAIL.append("etspi,et7xx compatible appears %d times" % dts.count('compatible = "etspi,et7xx"'))


def se14_pin_users(text):
    """(node, status) of every node whose pinctrl-N names a pin state on TLMM 56..59."""
    stack, nodes = [], {}
    for line in text.splitlines():
        s = line.strip()
        if s.endswith("{"):
            stack.append(s[:-1].strip().split(":")[-1].strip())
            nodes.setdefault("/".join(stack), {"ph": None, "pins": False, "status": None, "refs": []})
        elif s.startswith("};"):
            stack.pop()
        elif stack:
            n = nodes["/".join(stack)]
            if s.startswith("phandle = <"):
                n["ph"] = s.split("<")[1].split(">")[0]
            if s.startswith("pins") and any('"gpio%d"' % g in s for g in (56, 57, 58, 59)):
                n["pins"] = True
            if s.startswith("status = "):
                n["status"] = s.split('"')[1]
            if s.startswith("pinctrl-") and "<" in s:
                n["refs"] += s.split("<")[1].split(">")[0].split()
    states = set()
    for p, n in nodes.items():
        if n["pins"]:
            for q in (p, "/".join(p.split("/")[:-1])):
                if nodes.get(q, {}).get("ph"):
                    states.add(nodes[q]["ph"])
    return [(p, n["status"]) for p, n in nodes.items() if set(n["refs"]) & states]


for node, status in se14_pin_users(dts):
    print("  TLMM 56..59 pin state used by %s (status %s)" % (node, status))
    if status not in ("disabled", "fail"):
        FAIL.append("enabled node %s uses a pin state on TLMM 56..59" % node)

if FAIL:
    print("FAILED:")
    for f in FAIL:
        print("  " + f)
    sys.exit(1)
print("all checks passed")
