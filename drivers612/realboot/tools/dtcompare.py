#!/usr/bin/env python3
"""Compare device-tree subtrees of two dtbs, property by property (libfdt, read only).

  dtcompare.py <a.dtb> <b.dtb> --path <node> [--path ...] [--allow <node>:<prop> ...]

Each --path is compared recursively: same child nodes, same property names, same bytes.
Phandle values are compared as the PATHS of the nodes they point to wherever a property is a
known phandle list (iommus, memory-region, interconnects, ...), so the two trees may number
their phandles differently. --allow <node>:<prop> lists the differences that are expected
(a node path, '*' = any property of that node; <node> may also end in /* = the whole subtree).
Exit 0 = equal except allowed lines, 1 = differences (printed), 2 = usage / missing node.
"""
import argparse, sys
import libfdt

# properties whose cells are phandles followed by arguments: name -> (count of #cells property
# of the target, or a fixed number of argument cells)
PH_ARGS = {
    'iommus': '#iommu-cells', 'interconnects': '#interconnect-cells', 'clocks': '#clock-cells',
    'mboxes': '#mbox-cells', 'qcom,smem-states': '#qcom,smem-state-cells',
    'interrupts-extended': '#interrupt-cells', 'power-domains': '#power-domain-cells',
}
PH_ONLY = {'memory-region', 'memory-regions', 'qcom,qmp', 'interrupt-parent', 'qcom,rproc',
           'qcom,adsp-rproc', 'qcom,cdsp-rproc', 'qcom,smem-state'}


def load(p):
    return libfdt.Fdt(open(p, 'rb').read())


def phmap(fdt):
    m = {}
    def walk(off, path):
        try:
            ph = fdt.get_phandle(off)
            if ph:
                m[ph] = path
        except libfdt.FdtException:
            pass
        child = fdt.first_subnode(off, [libfdt.FDT_ERR_NOTFOUND])
        while child >= 0:
            walk(child, (path.rstrip('/') + '/' + fdt.get_name(child)))
            child = fdt.next_subnode(child, [libfdt.FDT_ERR_NOTFOUND])
    walk(0, '/')
    return m


def cells(b):
    return [int.from_bytes(b[i:i + 4], 'big') for i in range(0, len(b) - len(b) % 4, 4)]


def norm(fdt, pm, name, val):
    """property value with phandles replaced by target paths (when the property is known)"""
    if name in PH_ONLY and len(val) % 4 == 0:
        return tuple(pm.get(c, 'PH?%x' % c) for c in cells(val))
    if name in PH_ARGS and len(val) % 4 == 0:
        out, cs, i = [], cells(val), 0
        while i < len(cs):
            tgt = pm.get(cs[i])
            if tgt is None:
                return ('UNPARSED', val.hex())
            off = fdt.path_offset(tgt)
            try:
                n = fdt.getprop(off, PH_ARGS[name]).as_uint32()
            except libfdt.FdtException:
                n = 0 if name != 'interrupts-extended' else 3
            out.append((tgt,) + tuple(cs[i + 1:i + 1 + n])); i += 1 + n
        return tuple(out)
    if name == 'phandle' or name == 'linux,phandle':
        return 'PHANDLE'
    return val.hex()


def props(fdt, off):
    d = {}
    po = fdt.first_property_offset(off, [libfdt.FDT_ERR_NOTFOUND])
    while po >= 0:
        p = fdt.get_property_by_offset(po)
        d[p.name] = bytes(p)
        po = fdt.next_property_offset(po, [libfdt.FDT_ERR_NOTFOUND])
    return d


def subnodes(fdt, off):
    out = []
    c = fdt.first_subnode(off, [libfdt.FDT_ERR_NOTFOUND])
    while c >= 0:
        out.append(fdt.get_name(c)); c = fdt.next_subnode(c, [libfdt.FDT_ERR_NOTFOUND])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('--path', action='append', required=True)
    ap.add_argument('--allow', action='append', default=[])
    a = ap.parse_args()
    A, B = load(a.a), load(a.b)
    pa, pb = phmap(A), phmap(B)
    allow = [x.rsplit(':', 1) for x in a.allow]
    def allowed(path, prop):
        for n, p in allow:
            if n.endswith('/*') and (path == n[:-2] or path.startswith(n[:-1])):
                return True
            if n == path and p in ('*', prop):
                return True
        return False
    diffs, ok_diffs, nprop = [], [], [0]
    def cmp(path):
        try:
            oa, ob = A.path_offset(path), B.path_offset(path)
        except libfdt.FdtException:
            missing = 'a' if path not in pa.values() and not node_exists(A, path) else 'b'
            (ok_diffs if allowed(path, '*') else diffs).append(f"{path}: node missing in {missing}")
            return
        da, db = props(A, oa), props(B, ob)
        for k in sorted(set(da) | set(db)):
            nprop[0] += 1
            va = norm(A, pa, k, da[k]) if k in da else None
            vb = norm(B, pb, k, db[k]) if k in db else None
            if va != vb:
                line = f"{path}:{k}: a={'(absent)' if va is None else va} b={'(absent)' if vb is None else vb}"
                (ok_diffs if allowed(path, k) else diffs).append(line)
        sa, sb = subnodes(A, oa), subnodes(B, ob)
        for s in sorted(set(sa) | set(sb)):
            cmp(path.rstrip('/') + '/' + s)
    def node_exists(f, path):
        try:
            f.path_offset(path); return True
        except libfdt.FdtException:
            return False
    for p in a.path:
        if not node_exists(A, p) and not node_exists(B, p):
            print(f"dtcompare: {p} in neither tree"); sys.exit(2)
        cmp(p)
    for l in ok_diffs:
        print("allowed: " + l)
    for l in diffs:
        print("DIFF: " + l)
    print(f"dtcompare: {len(a.path)} subtree(s), {nprop[0]} properties compared, {len(ok_diffs)} allowed difference(s), {len(diffs)} unexpected")
    sys.exit(1 if diffs else 0)


if __name__ == '__main__':
    main()
