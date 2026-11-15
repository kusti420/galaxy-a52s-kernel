#!/usr/bin/env python3
"""a52ram-decode.py <dump> [-o out.txt]: put the a52bc area (kernel-diag/a52bc.c) in reading order.

<dump> is either the 6.18 harness's `cat /proc/a52ram` output (NUL bytes already dropped) or a
raw 128 KiB image of 0xf0be0000 (QEMU pmemsave). Layout: console head 0x00000..0x0ffff
(written once), console tail 0x10000..0x1efff (circular; "T<offset | wraps << 20>" in the
breadcrumb page says where the next byte goes), breadcrumb page 0x1f000.. starting with
"\\nA52BC1 attempt=N".
Output: breadcrumbs first (the verdict), then the head, then the tail oldest-first.
Limit: in the NUL-dropped form the tail is re-ordered only if the head is exactly 64 KiB and
the tail exactly 60 KiB long; bit decay that turned a byte into NUL (seen after key resets)
shifts that, in which case the tail is printed as stored (a note says so).
"""
import argparse, re, sys

HEAD, LOGEND, BC = 0x10000, 0x1f000, 0x1f000

ap = argparse.ArgumentParser()
ap.add_argument('dump'); ap.add_argument('-o')
a = ap.parse_args()
raw = open(a.dump, 'rb').read()
notes = []
if len(raw) == 0x20000 and b'\nA52BC1 attempt=' in raw[BC:]:
    log, bc = raw[:LOGEND], raw[BC:]
    head, tail = log[:HEAD].replace(b'\0', b''), log[HEAD:]
    tail_written = tail.rstrip(b'\0')
    raw_form = True
else:
    i = raw.rfind(b'\nA52BC1 attempt=')
    if i < 0:
        sys.exit("no a52bc breadcrumb page (\\nA52BC1 attempt=) in the dump: the a52bc kernel never "
                 "reached setup_arch, or this is not an a52bc area")
    log, bc = raw[:i], raw[i:]
    head, tail_written = log[:HEAD], log[HEAD:]
    raw_form = False
bc = bc.replace(b'\0', b'')
m = re.findall(rb'^T([0-9a-f]{8})$', bc, re.M)
if m and len(head) == HEAD:
    v = int(m[-1], 16); pos, wraps = v & 0xfffff, v >> 20
    n = LOGEND - HEAD
    if wraps == 0:
        tail = tail_written[:pos - HEAD]
    elif raw_form or len(tail_written) == n:
        t = (log[HEAD:LOGEND] if raw_form else tail_written)
        k = pos - HEAD
        tail = t[k:] + t[:k]
        notes.append(f"tail wrapped {wraps}x: oldest byte at {pos:#x}")
    else:
        tail = tail_written
        notes.append(f"tail is {len(tail_written)} bytes, not {n} (NUL holes, bit decay?): printed as stored")
else:
    tail = tail_written
    if len(head) < HEAD:
        notes.append(f"console head not full ({len(head)} bytes): no tail yet")
out = []
out.append(b'==== a52bc breadcrumbs ====' + bc.rstrip(b' \n') + b'\n')
for n_ in notes:
    out.append(b'note: ' + n_.encode() + b'\n')
out.append(b'==== console head (first %d bytes) ====\n' % len(head) + head)
if tail:
    out.append(b'\n==== console tail (oldest first, %d bytes) ====\n' % len(tail) + tail)
data = b''.join(out)
if a.o:
    open(a.o, 'wb').write(data)
else:
    sys.stdout.buffer.write(data)
