#!/usr/bin/env python3
"""Offline model of how the 6.12 kernel reads iommu-addresses for one device node (read only).

  iommu-resv-sim.py <dtb> <device node path> [--expect-fast <base>-<end>] [--expect-no-warn]

Model (bsp612/kernel drivers/iommu/of_iommu.c of_iommu_get_resv_regions, drivers/of/address.c
of_translate_dma_region/__of_translate_address, soc-repo qcom-iommu-util.c
get_iova_range_from_iommu_addresses): for each memory-region of the device that has
iommu-addresses, walk the words: a phandle that is not the device is skipped (ONE word); for the
device, address + size are read with the #address-cells/#size-cells of the device's parent
(searched upwards), the address is translated up the tree through dma-ranges (none here: 1:1, but
every level keeps only its own #address-cells: of_bus_default_translate), a 0 size gives the
kernel's "Cannot reserve IOVA region of 0 size". Fastmap range: base = end of the first merged
region if it starts at 0, end = 4 GiB - 1 or the start of the last region if that one covers 4 GiB - 1.
"""
import argparse, sys
import libfdt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dtb'); ap.add_argument('dev')
    ap.add_argument('--expect-fast'); ap.add_argument('--expect-no-warn', action='store_true')
    a = ap.parse_args()
    f = libfdt.Fdt(open(a.dtb, 'rb').read())
    def off(p): return f.path_offset(p)
    def parent(p): return p.rsplit('/', 1)[0] or '/'
    def getu(p, n):
        v = f.getprop(off(p), n, [libfdt.FDT_ERR_NOTFOUND])
        return None if isinstance(v, int) else v.as_uint32()
    def ncells(p, n, dflt):   # of_bus_n_*_cells(p): p and its parents
        while True:
            v = getu(p, n)
            if v is not None: return v
            if p == '/': return dflt
            p = parent(p)
    def words(p, n):
        v = f.getprop(off(p), n, [libfdt.FDT_ERR_NOTFOUND])
        if isinstance(v, int): return None
        b = bytes(v); return [int.from_bytes(b[i:i + 4], 'big') for i in range(0, len(b), 4)]
    def num(ws):
        r = 0
        for w in ws: r = (r << 32) | w
        return r
    phmap = {}
    def walk(o, p):
        ph = f.get_phandle(o)
        if ph: phmap[ph] = p
        c = f.first_subnode(o, [libfdt.FDT_ERR_NOTFOUND])
        while c >= 0:
            walk(c, (p.rstrip('/') + '/' + f.get_name(c))); c = f.next_subnode(c, [libfdt.FDT_ERR_NOTFOUND])
    walk(0, '/')
    dev = a.dev; mr = words(dev, 'memory-region') or []
    regions, warns = [], 0
    for ph in mr:
        rp = phmap.get(ph)
        ia = words(rp, 'iommu-addresses') if rp else None
        if not ia: continue
        par = parent(dev)
        na, ns = ncells(par, '#address-cells', 2), ncells(par, '#size-cells', 1)
        i = 0
        while i < len(ia):
            p = ia[i]; i += 1
            if phmap.get(p) != dev: continue
            addr = num(ia[i:i + na]); size = num(ia[i + na:i + na + ns]); i += na + ns
            # translate upwards: each level keeps only its parent's #address-cells words
            q = par; a_ = addr
            while q != '/':
                pna = ncells(parent(q), '#address-cells', 2)
                if words(q, 'dma-ranges'):
                    print(f"{dev}: dma-ranges on {q}: not modelled"); sys.exit(2)
                a_ &= (1 << (32 * pna)) - 1
                q = parent(q)
            if size == 0:
                warns += 1; print(f"{dev}: Cannot reserve IOVA region of 0 size (cells {na}+{ns})"); continue
            regions.append((a_, a_ + size - 1))
            print(f"{dev}: reserved [{a_:#x}, {a_ + size - 1:#x}] (cells {na}+{ns}{'' if a_ == addr else f', address {addr:#x} truncated by the translation'})")
    regions.sort(); merged = []
    for s, e in regions:
        if merged and s <= merged[-1][1] + 1: merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else: merged.append((s, e))
    FM = (1 << 32) - 1
    base = merged[0][1] + 1 if merged and merged[0][0] == 0 else 0
    end = FM
    if merged and merged[-1][0] <= FM <= merged[-1][1]: end = merged[-1][0] - 1
    print(f"{dev}: merged {', '.join(f'[{s:#x},{e:#x}]' for s, e in merged)}; fastmap IOVA range [{base:#x}, {end:#x}]")
    ok = True
    if a.expect_fast:
        b, e = (int(x, 16) for x in a.expect_fast.split('-'))
        if (b, e) != (base, end): print(f"{dev}: EXPECTED fastmap range [{b:#x}, {e:#x}]"); ok = False
    if a.expect_no_warn and warns: print(f"{dev}: EXPECTED no zero-size warning"); ok = False
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
