#!/usr/bin/env python3
"""Build the alternative base FDT for a kexec from the 6.18 harness into a DIFFERENT kernel.

  mkkexecdtb.py --base <dtb> [--overlay <dtbo> ...] --live <live.dtb> -o <out.dtb>

--base     the new kernel's dtb (bsp612/out/dist/dtb/yupik.dtb), or an already merged one
--overlay  overlays applied on it with fdtoverlay (bsp612/out/bringup/a52sxq-bringup.dtbo)
--live     the phone's dumped live tree (testdev-<serial>/live.dtb, from /sys/firmware/fdt of
           the stock 5.4 kernel): the source of what the Samsung bootloader and the
           hypervisor patch into the tree at boot.

A kexec'd kernel gets no bootloader pass, so these runtime patches are copied here:
  1. memory node: `reg` (the real RAM banks; the static dtb has size 0) and `ddr_device_type`.
     Target node: the root child with device_type = "memory" (/memory or /memory@80000000).
  2. /hypervisor: the whole node (haven-vm id, hh-watchdog, resource-manager-rpc with its
     capability ids and interrupts). It has no phandles; its interrupts resolve through the
     root interrupt-parent, which is checked (added from the GIC node if the root has none).
  3. /reserved-memory/uh_guest_region and uh_heap_region (hypervisor memory, reg only).
     If the target has no `no-map` on them the live tree did not either: copied as they are.
  4. watchdog at 17c10000 (/soc/qcom,wdt@17c10000 downstream, /soc@0/watchdog@17c10000
     mainline): `status` from the live tree ("disabled": the hardware watchdog belongs to
     the hypervisor). A target that already says "disabled" or "reserved" is left alone.
  5. ARM timer node (compatible arm,armv8-timer; /soc/timer downstream, /timer mainline):
     `always-on` if the live tree has it.
NOT copied, on purpose: /chosen bootargs, linux,initrd-start/end, kaslr-seed, rng-seed. The
harness kernel writes them itself at kexec_file_load (drivers/of/kexec.c) from the kx
arguments. Old linux,initrd-* in the base are removed there as well.
Checks: the result must reserve the ramoops block at 0xf0b00000 (the harness's crash guard
reads the next boot's verdict from it); a warning is printed if it does not.
"""
import argparse, os, subprocess, sys, tempfile
import libfdt
from libfdt import Fdt, QUIET_NOTFOUND, FdtException

def off(fdt, path):
    return fdt.path_offset(path, QUIET_NOTFOUND)

def subnodes(fdt, node):
    out = []; o = fdt.first_subnode(node, QUIET_NOTFOUND)
    while o >= 0:
        out.append(fdt.get_name(o)); o = fdt.next_subnode(o, QUIET_NOTFOUND)
    return out

def props(fdt, node):
    out = []; o = fdt.first_property_offset(node, QUIET_NOTFOUND)
    while o >= 0:
        p = fdt.get_property_by_offset(o); out.append((p.name, bytes(p)))
        o = fdt.next_property_offset(o, QUIET_NOTFOUND)
    return out

def getprop(fdt, path, name):
    o = off(fdt, path)
    if o < 0: return None
    p = fdt.getprop(o, name, QUIET_NOTFOUND)
    return None if isinstance(p, int) else bytes(p)

def setprop(fdt, path, name, val):
    fdt.setprop(off(fdt, path), name, val)

def join(parent, name):
    return ('' if parent == '/' else parent) + '/' + name

def copy_node(src, spath, dst, dparent, name, log):
    """copy node spath of src to dst as dparent/name, replacing an existing one"""
    dpath = join(dparent, name)
    if off(dst, dpath) >= 0:
        dst.del_node(off(dst, dpath)); log.append(f"  replaced existing {dpath}")
    dst.add_subnode(off(dst, dparent), name)
    for pn, pv in props(src, off(src, spath)):
        if pn in ('phandle', 'linux,phandle'):
            log.append(f"  NOTE {spath} has a phandle (dropped: nothing in the new tree may point to it)")
            continue
        setprop(dst, dpath, pn, pv)
    for sub in subnodes(src, off(src, spath)):
        copy_node(src, join(spath, sub), dst, dpath, sub, log)

def find_child(fdt, parent, pred):
    o = off(fdt, parent)
    if o < 0: return None
    for n in subnodes(fdt, o):
        if pred(n, join(parent, n)): return join(parent, n)
    return None

def find_compat(fdt, compat, parents):
    for par in parents:
        r = find_child(fdt, par, lambda n, p: compat in (getprop(fdt, p, 'compatible') or b'').split(b'\0'))
        if r: return r
    return None

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', required=True); ap.add_argument('--overlay', action='append', default=[])
    ap.add_argument('--live', required=True); ap.add_argument('-o', '--out', required=True)
    a = ap.parse_args()
    base = a.base
    tmp = None
    if a.overlay:
        tmp = tempfile.NamedTemporaryFile(suffix='.dtb', delete=False); tmp.close()
        subprocess.run(['fdtoverlay', '-i', a.base, '-o', tmp.name] + a.overlay, check=True)
        base = tmp.name
    dst = Fdt(open(base, 'rb').read()); live = Fdt(open(a.live, 'rb').read())
    if tmp: os.unlink(tmp.name)
    dst.resize(dst.totalsize() + 0x10000)
    log = []; warn = []
    soc_parents = ['/soc', '/soc@0', '/']

    # 1. memory
    isram = lambda f: (lambda n, p: getprop(f, p, 'device_type') == b'memory\0')
    lmem = find_child(live, '/', isram(live)); dmem = find_child(dst, '/', isram(dst))
    if not lmem: sys.exit("live tree has no memory node")
    if not dmem:
        dst.add_subnode(0, 'memory'); dmem = '/memory'; setprop(dst, dmem, 'device_type', b'memory\0')
    for cells in ('#address-cells', '#size-cells'):
        if getprop(live, '/', cells) != getprop(dst, '/', cells):
            sys.exit(f"root {cells} differ between live and new tree: memory reg cannot be copied as is")
    reg = getprop(live, lmem, 'reg'); setprop(dst, dmem, 'reg', reg)
    banks = [int.from_bytes(reg[i:i + 8], 'big') for i in range(0, len(reg), 8)]
    log.append(f"1. {dmem}: reg <- live {lmem}: " + ', '.join(f"{banks[i]:#x}+{banks[i+1]:#x}" for i in range(0, len(banks), 2)))
    ddr = getprop(live, lmem, 'ddr_device_type')
    if ddr is not None:
        setprop(dst, dmem, 'ddr_device_type', ddr); log.append(f"1. {dmem}: ddr_device_type = {int.from_bytes(ddr, 'big')}")
    else: warn.append("live memory node has no ddr_device_type")

    # 2. /hypervisor
    if off(live, '/hypervisor') >= 0:
        copy_node(live, '/hypervisor', dst, '/', 'hypervisor', log)
        log.append("2. /hypervisor: copied (" + ', '.join(subnodes(live, off(live, '/hypervisor'))) + ")")
        if getprop(dst, '/', 'interrupt-parent') is None:
            gic = find_compat(dst, b'arm,gic-v3', soc_parents)
            ph = getprop(dst, gic, 'phandle') if gic else None
            if ph: setprop(dst, '/hypervisor', 'interrupt-parent', ph); log.append(f"2. /hypervisor: interrupt-parent = {gic}")
            else: warn.append("root has no interrupt-parent and no GIC phandle found: /hypervisor interrupts will not resolve")
    else: warn.append("live tree has no /hypervisor node")

    # 3. uh regions
    if off(dst, '/reserved-memory') < 0: sys.exit("new tree has no /reserved-memory")
    for n in ('uh_guest_region', 'uh_heap_region'):
        if off(live, '/reserved-memory/' + n) >= 0:
            copy_node(live, '/reserved-memory/' + n, dst, '/reserved-memory', n, log)
            r = getprop(live, '/reserved-memory/' + n, 'reg')
            log.append(f"3. /reserved-memory/{n}: reg = {int.from_bytes(r[:8], 'big'):#x}+{int.from_bytes(r[8:16], 'big'):#x}")
        else: warn.append(f"live tree has no /reserved-memory/{n}")

    # 3b. no-map regions of the harness's live tree that the new tree does not reserve (rmtfs).
    # The harness's own drivers may have handed such memory to another VM/subsystem with a
    # stage-2 permission change, which survives kexec. 2026-11-14: rmtfs@9c900000 (0x280000)
    # is assigned to the modem RW/no-exec by the harness's qcom_rmtfs_mem; the 6.12 tree has no
    # such node, used it as RAM, and file pages there died on instruction fetch (SIGBUS
    # BUS_OBJERR, bad pages 0x9c9b9000 / 0x9c959000 caught by drivers612/debug/seaprobe).
    def ranges(t, o):
        out = []
        for n in subnodes(t, o):
            r = getprop(t, '/reserved-memory/' + n, 'reg')
            if r and len(r) >= 16: out.append((int.from_bytes(r[:8], 'big'), int.from_bytes(r[8:16], 'big')))
        return out
    have = ranges(dst, off(dst, '/reserved-memory'))
    lo = off(live, '/reserved-memory')
    for n in (subnodes(live, lo) if lo >= 0 else []):
        p = '/reserved-memory/' + n
        r = getprop(live, p, 'reg')
        if not r or len(r) < 16 or getprop(live, p, 'no-map') is None: continue
        # only regions proven to carry a stage-2 assignment across kexec; carrying all no-map
        # regions (splash, trustedvm, xbl, sec-debug, ...) made runs ab-s52/s53 reset ~30 s in
        if not n.startswith('rmtfs'): continue
        s = int.from_bytes(r[:8], 'big'); z = int.from_bytes(r[8:16], 'big')
        if z == 0 or any(a <= s and s + z <= a + b for a, b in have): continue
        name = 'kexec-live-' + n.replace('@', '-')
        dst.add_subnode(off(dst, '/reserved-memory'), name)
        setprop(dst, '/reserved-memory/' + name, 'reg', bytes(r[:16]))
        setprop(dst, '/reserved-memory/' + name, 'no-map', b'')
        log.append(f"3b. /reserved-memory/{name}: {s:#x}+{z:#x} no-map (live {n}, not reserved in the new tree)")

    # 4. hardware watchdog status
    iswdt = lambda n, p: n.endswith('@17c10000')
    lw = next((r for r in (find_child(live, p, iswdt) for p in soc_parents) if r), None)
    dw = next((r for r in (find_child(dst, p, iswdt) for p in soc_parents) if r), None)
    ls = getprop(live, lw, 'status') if lw else None
    if dw and ls:
        cur = getprop(dst, dw, 'status')
        if cur in (b'disabled\0', b'reserved\0'): log.append(f"4. {dw}: status already {cur[:-1].decode()}, left alone")
        else: setprop(dst, dw, 'status', ls); log.append(f"4. {dw}: status = {ls[:-1].decode()} (was {cur})")
    elif dw: warn.append(f"live {lw} has no status property; {dw} left alone")
    else: log.append("4. no node @17c10000 in the new tree: nothing to disable")

    # 5. timer always-on
    lt = find_compat(live, b'arm,armv8-timer', soc_parents); dt = find_compat(dst, b'arm,armv8-timer', soc_parents)
    if lt and dt and getprop(live, lt, 'always-on') is not None:
        setprop(dst, dt, 'always-on', b''); log.append(f"5. {dt}: always-on")
    elif not dt: warn.append("no arm,armv8-timer node found in the new tree")
    else: log.append("5. live timer has no always-on: nothing to do")

    # checks
    ok = False; o = off(dst, '/reserved-memory')
    for n in subnodes(dst, o):
        r = getprop(dst, '/reserved-memory/' + n, 'reg')
        if r and len(r) >= 16:
            s = int.from_bytes(r[:8], 'big'); z = int.from_bytes(r[8:16], 'big')
            if s <= 0xf0b00000 < s + z: ok = True; log.append(f"check: 0xf0b00000 (harness ramoops) is reserved by /reserved-memory/{n}")
    if not ok: warn.append("NOTHING reserves 0xf0b00000: the new kernel may overwrite the harness's ramoops log")
    dst.pack()
    open(a.out, 'wb').write(dst.as_bytearray())
    print('\n'.join(log)); [print("WARNING:", w) for w in warn]
    print(f"wrote {a.out} ({dst.totalsize()} bytes)")
    if dst.totalsize() > 4 * 1024 * 1024: sys.exit("over the 4 MiB limit of /sys/firmware/kexec_fdt")

if __name__ == '__main__':
    main()
