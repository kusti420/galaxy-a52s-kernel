#!/usr/bin/env python3
"""resv-overlap.py <dtb> <node name under /reserved-memory>: exit 1 if any OTHER fixed
/reserved-memory region overlaps the named node's reg (used by build-realboot.sh DIAG=1 for
the a52bc area at 0xf0be0000)."""
import sys
import libfdt

f = libfdt.Fdt(open(sys.argv[1], 'rb').read())
rm = f.path_offset('/reserved-memory')
regs = {}
o = f.first_subnode(rm, libfdt.QUIET_NOTFOUND)
while o >= 0:
    r = f.getprop(o, 'reg', libfdt.QUIET_NOTFOUND)
    if not isinstance(r, int):
        b = bytes(r)
        regs[f.get_name(o)] = [(int.from_bytes(b[i:i + 8], 'big'), int.from_bytes(b[i + 8:i + 16], 'big'))
                               for i in range(0, len(b), 16)]
    o = f.next_subnode(o, libfdt.QUIET_NOTFOUND)
me = sys.argv[2]
if me not in regs:
    sys.exit(f"no /reserved-memory/{me} with reg")
bad = [(n, s, z) for n, rr in regs.items() if n != me for s, z in rr
       for ms, mz in regs[me] if s < ms + mz and ms < s + z]
for n, s, z in bad:
    print(f"overlap: {n} {s:#x}+{z:#x}", file=sys.stderr)
sys.exit(1 if bad else 0)
