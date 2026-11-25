#!/usr/bin/env python3
"""Load-order gate for the a52sxq userspace switch (a52sxq.ko, drivers612/samsung-oneui/a52sxq_core).

  us-order-check.py <plan dir>                        (<dir>/first.load + <dir>/first/*.ko)
  us-order-check.py --load <modules.load> --dir <ko dir> [--parallel]

Consumers bind to the switch late and soft (<linux/a52sxq_userspace.h>: symbol_get() of
a52sxq_userspace_get on use). Until a52sxq.ko is loaded they get the AOSP answer, so a consumer
that reads the switch at probe/init time and loads BEFORE a52sxq.ko silently runs the AOSP
variant (2026-11-25: usb_notify_layer's set_otg_notify(), called from usb_notifier's probe, left
secure_lock/lock_state unset -> no One UI lock-screen USB restriction).

A consumer = a module that references a52sxq_userspace_get without defining it: an undefined
symbol of that name (hard import) or the NUL-terminated string in an allocated section (the
symbol_get()/__symbol_get() name literal). Debug sections do not count. The provider is the
module that defines it.

FAIL (exit 1) when the provider is in this list and a consumer comes before it (line numbers =
sequential load order). Modules that use the notifier chain (also those that read the getter as
well: a52sxq_sec_class re-syncs from its notifier bind work, 2 s x 45) or only the hint call are
listed as INFO (they re-bind / tolerate a missing provider). --parallel: modules.load order is not the load
order under libmodprobe's parallel mode; the check still runs but a WARNING says so.
"""
import argparse, os, struct, sys

GET = b'a52sxq_userspace_get'
SOFT = (b'a52sxq_userspace_register_notifier', b'a52sxq_userspace_hint')
SHF_ALLOC = 0x2
SHT_NOBITS, SHT_SYMTAB = 8, 2


def scan(path):
    """-> (defines GET, refs GET, soft names referenced) from the ELF64 LE module."""
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        sys.exit(f"{path}: not an ELF64 LE object")
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    # (name, type, flags, addr, offset, size, link, info, align, entsize)
    defines = refs = False
    soft = set()

    def has(blob, name):
        z = b'\0' + name + b'\0'
        return z in blob or blob.startswith(name + b'\0')

    for s in secs:
        typ, flags, off, size, link, entsize = s[1], s[2], s[4], s[5], s[6], s[9]
        if typ == SHT_SYMTAB:
            st = secs[link]; strtab = d[st[4]:st[4] + st[5]]
            for i in range(size // entsize):
                st_name, st_info, st_other, st_shndx = struct.unpack_from('<IBBH', d, off + i * entsize)
                e = strtab.find(b'\0', st_name)
                nm = strtab[st_name:e]
                if nm == GET:
                    if st_shndx == 0:
                        refs = True
                    else:
                        defines = True
                elif nm in SOFT and st_shndx == 0:
                    soft.add(nm.decode())
        elif flags & SHF_ALLOC and typ != SHT_NOBITS:
            blob = d[off:off + size]
            if has(blob, GET):
                refs = True
            for n in SOFT:
                if has(blob, n):
                    soft.add(n.decode())
    return defines, refs and not defines, soft


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('plan', nargs='?')
    ap.add_argument('--load')
    ap.add_argument('--dir')
    ap.add_argument('--parallel', action='store_true')
    a = ap.parse_args()
    if a.plan:
        load, kdir = os.path.join(a.plan, 'first.load'), os.path.join(a.plan, 'first')
    elif a.load and a.dir:
        load, kdir = a.load, a.dir
    else:
        ap.error('give a plan dir or --load + --dir')
    mods = [l.strip() for l in open(load) if l.strip() and not l.startswith('#')]
    provider = None; consumers = []; soft_only = []
    for n, m in enumerate(mods, 1):
        p = os.path.join(kdir, os.path.basename(m))
        if not os.path.exists(p):
            sys.exit(f"{m} (line {n}): no {p}")
        defines, refs, soft = scan(p)
        if defines:
            if provider:
                sys.exit(f"a52sxq_userspace_get defined twice: {provider[1]} and {m}")
            provider = (n, m)
        elif refs and 'a52sxq_userspace_register_notifier' in soft:
            soft_only.append((n, m, ['a52sxq_userspace_get +'] + sorted(soft)))
        elif refs:
            consumers.append((n, m))
        elif soft:
            soft_only.append((n, m, sorted(soft)))
    print(f"userspace switch: {len(mods)} modules in {load}")
    if a.parallel:
        print("WARNING: parallel module loading: modules.load order is not the load order (a52sxq.ko needs "
              "load_sequential=1 or a dependency edge for a guarantee)")
    for n, m, s in soft_only:
        print(f"INFO  {n:4d} {m}: {' '.join(s)} (re-binds on the notifier / tolerates a missing provider)")
    if not provider:
        for n, m in consumers:
            print(f"INFO  {n:4d} {m}: reads the switch; no provider in this list (AOSP answer until a52sxq.ko loads)")
        print("userspace switch: provider not in this stage, nothing to order")
        return 0
    pn, pm = provider
    early = [(n, m) for n, m in consumers if n < pn]
    for n, m in consumers:
        print(f"{'EARLY' if n < pn else 'ok   '} {n:4d} {m}: reads the switch ({'before' if n < pn else 'after'} {pm} at {pn})")
    if early:
        print(f"userspace switch: FAIL: {len(early)} consumer(s) load before {pm} (line {pn}): "
              + ' '.join(f"{m}@{n}" for n, m in early))
        return 1
    print(f"userspace switch: PASS: provider {pm} at line {pn}, {len(consumers)} consumer(s) after it")
    return 0


if __name__ == '__main__':
    sys.exit(main())
