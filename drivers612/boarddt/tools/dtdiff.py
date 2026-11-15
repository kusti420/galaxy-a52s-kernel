#!/usr/bin/env python3
"""
dtdiff.py <phone-merged.dtb> <our-merged.dtb> <units.tsv> <detail-out.txt>

"Phone 5.4 merged tree vs our 6.12 merged tree", by subsystem. Nodes are matched by label
(nearest labelled ancestor + relative path), so nodes that moved between 5.4 and 6.12
(regulators, QUP engines, placeholders) still pair up. Cells that differ are accepted when both
are phandles of nodes with the same key.
"""
import struct, sys, collections, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fdt

def index(root):
    labels = collections.defaultdict(set)
    for l, p in fdt.symbols(root).items():
        labels[p].add(l)
    ph = {}
    nodes = {}
    for n in root.walk():
        p = n.path()
        if p.startswith("/__"):
            continue
        nodes[p] = n
        v = n.props.get("phandle")
        if v and len(v) == 4:
            ph[struct.unpack(">I", v)[0]] = p
    return nodes, labels, ph

def keys(nodes, labels, other_labels):
    out = {}
    for p in nodes:
        parts = [x for x in p.split("/") if x]
        key = ("/", p)
        for i in range(len(parts), 0, -1):
            anc = "/" + "/".join(parts[:i])
            ls = labels.get(anc)
            if ls:
                both = ls & other_labels
                if both or i == len(parts) or True:
                    key = (min(both) if both else min(ls), "/".join(parts[i:]))
                    if both:
                        break
                    # keep looking upwards for an ancestor both trees label
                    continue
        out[p] = key
    return out

pn, pl, pph = index(fdt.load(sys.argv[1]))
on, ol, oph = index(fdt.load(sys.argv[2]))
pall = set().union(*pl.values()); oall = set().union(*ol.values())
pk = keys(pn, pl, oall); ok = keys(on, ol, pall)
obykey = {}
for p, k in ok.items():
    obykey.setdefault(k, p)
psym = fdt.symbols(fdt.load(sys.argv[1]))

unit_prefix, target_props = {}, {}
for line in open(sys.argv[3]):
    sub, tkey, child, props = line.rstrip("\n").split("\t")
    tp = tkey if tkey.startswith("/") else psym.get(tkey)
    if tp is None:
        continue
    if child:
        unit_prefix[(tp.rstrip("/") + "/" + child)] = sub
    else:
        target_props[tp] = (sub, set(props.split()))

def sub_of(path):
    parts = [x for x in path.split("/") if x]
    for i in range(len(parts), 0, -1):
        s = unit_prefix.get("/" + "/".join(parts[:i]))
        if s:
            return s
    return "soc-base"

def same(pv, ov):
    if pv == ov:
        return True
    if len(pv) != len(ov) or len(pv) % 4:
        return False
    for i in range(0, len(pv), 4):
        a, b = struct.unpack_from(">I", pv, i)[0], struct.unpack_from(">I", ov, i)[0]
        if a == b:
            continue
        if a in pph and b in oph and pk[pph[a]] == ok[oph[b]]:
            continue
        return False
    return True

def show(v):
    if fdt.is_strings(v):
        return ", ".join('"%s"' % s for s in fdt.strings(v))
    if len(v) % 4 == 0:
        c = struct.unpack(">%dI" % (len(v) // 4), v)
        return "<" + " ".join("0x%x" % x for x in c[:12]) + (" ...>" if len(c) > 12 else ">")
    return v.hex()

st = collections.defaultdict(collections.Counter)
detail = collections.defaultdict(list)
missing_paths = set()
for p in sorted(pn):
    sub = sub_of(p)
    st[sub]["nodes"] += 1
    op = obykey.get(pk[p])
    if op is None:
        st[sub]["nodes_missing"] += 1
        parent = p.rsplit("/", 1)[0] or "/"
        if parent not in missing_paths:
            detail[sub].append("MISSING NODE  %s" % p)
        missing_paths.add(p)
        continue
    o = on[op]
    for name, v in pn[p].props.items():
        if name in ("phandle", "linux,phandle"):
            continue
        s = sub
        tp = target_props.get(p)
        if tp and name in tp[1]:
            s = tp[0]
        st[s]["props"] += 1
        if name not in o.props:
            st[s]["props_missing"] += 1
            detail[s].append("MISSING PROP  %s : %s = %s" % (p, name, show(v)))
        elif not same(v, o.props[name]):
            st[s]["props_differ"] += 1
            detail[s].append("DIFFERS       %s : %s\n                phone: %s\n                ours:  %s" % (p, name, show(v), show(o.props[name])))
pkeys = set(pk.values())
extra = [p for p, k in ok.items() if k not in pkeys]
with open(sys.argv[4], "w") as f:
    for sub in sorted(detail):
        f.write("==== %s ====\n%s\n\n" % (sub, "\n".join(detail[sub])))
    f.write("==== nodes only in our 6.12 tree (%d) ====\n%s\n" % (len(extra), "\n".join(sorted(extra))))
print("%-14s %7s %9s %8s %9s %8s" % ("subsystem", "nodes", "missing", "props", "missing", "differ"))
tot = collections.Counter()
for sub in sorted(st, key=lambda s: (s == "soc-base", s)):
    c = st[sub]; tot.update(c)
    print("%-14s %7d %9d %8d %9d %8d" % (sub, c["nodes"], c["nodes_missing"], c["props"], c["props_missing"], c["props_differ"]))
print("%-14s %7d %9d %8d %9d %8d" % ("TOTAL", tot["nodes"], tot["nodes_missing"], tot["props"], tot["props_missing"], tot["props_differ"]))
print("nodes only in our tree: %d   (soc-base = Qualcomm's own 5.4 base vs 6.12 base, not board data)" % len(extra))
