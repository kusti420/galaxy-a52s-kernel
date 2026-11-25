#!/usr/bin/env python3
"""Move ONE module of a test ramdisk to the END of another stage; every other byte stays as it was.
  rd-move-ko.py IN.cpio.gz OUT.cpio.gz NAME.ko FROM_STAGE TO_STAGE
Removes a52/mods/FROM/NAME.ko and its line in a52/mods/FROM.list, appends NAME.ko to a52/mods/TO.list and inserts
a52/mods/TO/NAME.ko (same bytes, mode, uid/gid/mtime) right after that list entry. Fails if the module is not in FROM,
or already in TO. Concatenated newc streams (gzip or raw) as rd-swap-ko.py / rd-add-ko.py.
Written 2026-11-25 to load a52sxq.ko (the userspace switch) before usb_notifier probes (lock-screen USB restriction).
"""
import gzip, sys

def hdr(f, name, fsize):
    nb = name.encode() + b'\0'
    f = list(f); f[11] = len(nb); f[6] = fsize
    h = b'070701' + b''.join(b'%08X' % v for v in f)
    return h + nb + b'\0' * ((4 - (len(h) + len(nb)) % 4) % 4)

def entries(d):
    i = 0
    while i < len(d):
        if d[i:i + 6] != b'070701':
            if d[i] == 0: yield ('pad', i, i + 1, None, None, None); i += 1; continue
            sys.exit('bad cpio magic at %#x' % i)
        f = [int(d[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        name = d[i + 110:i + 110 + f[11] - 1].decode()
        npad = (110 + f[11] + 3) & ~3
        body = d[i + npad:i + npad + f[6]]
        nxt = i + npad + ((f[6] + 3) & ~3)
        yield ('ent', i, nxt, f, name, body)
        i = nxt

def ent(f, name, body):
    return hdr(f, name, len(body)) + body + b'\0' * ((4 - len(body) % 4) % 4)

def main():
    if len(sys.argv) != 6: sys.exit(__doc__)
    src, dst, ko, frm, to = sys.argv[1:]
    raw = open(src, 'rb').read()
    gz = raw[:2] == b'\x1f\x8b'
    d = gzip.decompress(raw) if gz else raw
    E = list(entries(d))
    names = [e[4] for e in E if e[0] == 'ent']
    pf, pt = 'a52/mods/%s/%s' % (frm, ko), 'a52/mods/%s/%s' % (to, ko)
    if pf not in names: sys.exit('%s not in the ramdisk' % pf)
    if pt in names: sys.exit('%s already in the ramdisk' % pt)
    if 'a52/mods/%s.list' % to not in names: sys.exit('no stage list for %s' % to)
    mod = next(e for e in E if e[0] == 'ent' and e[4] == pf)
    out = bytearray(); last = 0
    for e in E:
        kind, a, b, f, name, body = e
        if kind != 'ent':
            out += d[a:b]; continue
        if name == pf:
            continue
        if name == 'a52/mods/%s.list' % frm:
            lines = [l for l in body.decode().splitlines() if l.strip() != ko]
            if len(lines) == len(body.decode().splitlines()): sys.exit('%s not in %s.list' % (ko, frm))
            out += ent(f, name, ('\n'.join(lines) + '\n').encode()); continue
        if name == 'a52/mods/%s.list' % to:
            nb = body.decode().rstrip('\n') + '\n' + ko + '\n'
            out += ent(f, name, nb.encode())
            mf = list(mod[3]); mf[0] = max(x[3][0] for x in E if x[0] == 'ent') + 1
            out += ent(mf, pt, mod[5]); continue
        out += d[a:b]
    data = gzip.compress(bytes(out), 9) if gz else bytes(out)
    open(dst, 'wb').write(data)
    print('moved %s: %s -> %s (appended to %s.list)' % (ko, frm, to, to))

main()
