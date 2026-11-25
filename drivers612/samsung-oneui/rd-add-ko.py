#!/usr/bin/env python3
"""Make a test ramdisk that differs from a tested one ONLY by new modules appended to one stage.

  rd-add-ko.py IN.cpio.gz OUT.cpio.gz STAGE NEW.ko...

IN is a (possibly concatenated) newc cpio stream, gzip or raw (as rd-swap-ko.py). The stage list
a52/mods/STAGE.list gets one line per NEW.ko appended (file name, in the order given), and each
NEW.ko is inserted as a regular file a52/mods/STAGE/<name>.ko (mode 0644, uid/gid/mtime of the
list entry, a fresh inode number) right after the list entry. Every other byte of the stream is
copied unchanged. Fails if a module of that name is already anywhere in the ramdisk, if the stage
list or directory is missing, or if a NEW.ko's vermagic differs from the stage's modules.
Used for s99q = s99m + the Samsung OneUI compat modules (drivers612/samsung-oneui).
"""
import gzip, os, re, sys

def vermagic(b):
    m = re.search(rb'vermagic=([^\0]*)', b)
    return m.group(1) if m else None

def hdr(fields, name):
    nb = name.encode() + b'\0'
    fields = list(fields); fields[11] = len(nb)
    h = b'070701' + b''.join(b'%08X' % v for v in fields)
    pad = (4 - (len(h) + len(nb)) % 4) % 4
    return h + nb + b'\0' * pad

def entries(data):
    i = 0
    while i < len(data):
        if data[i:i + 6] != b'070701':
            if data[i] == 0: yield ('pad', i, i + 1, None, None, None); i += 1; continue
            sys.exit('bad cpio magic at %#x' % i)
        f = [int(data[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        nsize, fsize = f[11], f[6]
        name = data[i + 110:i + 110 + nsize - 1].decode()
        npad = (110 + nsize + 3) & ~3
        body = data[i + npad:i + npad + fsize]
        nxt = i + npad + ((fsize + 3) & ~3)
        yield ('ent', i, nxt, f, name, body)
        i = nxt

def main():
    if len(sys.argv) < 5: sys.exit(__doc__)
    src, dst, stage, kos = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    data = open(src, 'rb').read()
    gz = data[:2] == b'\x1f\x8b'
    if gz: data = gzip.decompress(data)
    new = [(os.path.basename(k), open(k, 'rb').read()) for k in kos]
    lst, sdir = 'a52/mods/%s.list' % stage, 'a52/mods/%s' % stage
    names, inos, vm, have_dir, have_list = set(), set(), set(), False, False
    for t, a, b, f, name, body in entries(data):
        if t != 'ent': continue
        inos.add(f[0])
        names.add(re.sub(r'^\d+-', '', os.path.basename(name)))
        if name == sdir and (f[1] & 0o170000) == 0o040000: have_dir = True
        if name == lst: have_list = True
        if name.startswith(sdir + '/') and name.endswith('.ko'): vm.add(vermagic(body))
    if not have_dir or not have_list: sys.exit('stage %s: list or directory missing in %s' % (stage, src))
    for n, b in new:
        if n in names: sys.exit('%s already in %s' % (n, src))
        if {vermagic(b)} != vm: sys.exit('%s: vermagic %r != stage %r' % (n, vermagic(b), vm))
    ino = max(inos) + 1000
    out = bytearray(); done = False
    for t, a, b, f, name, body in entries(data):
        if t == 'pad': out += data[a:b]; continue
        if name != lst:
            out += data[a:b]; continue
        txt = body if body.endswith(b'\n') or not body else body + b'\n'
        txt += b''.join(n.encode() + b'\n' for n, _ in new)
        g = list(f); g[6] = len(txt)
        out += hdr(g, name) + txt + b'\0' * ((4 - len(txt) % 4) % 4)
        for n, kb in new:
            g = list(f); g[0] = ino; ino += 1; g[1] = 0o100644; g[4] = 1; g[6] = len(kb)
            out += hdr(g, '%s/%s' % (sdir, n)) + kb + b'\0' * ((4 - len(kb) % 4) % 4)
            print('added %s/%s (%d bytes)' % (sdir, n, len(kb)))
        done = True
    assert done
    with open(dst, 'wb') as fh:
        fh.write(gzip.compress(bytes(out), 6, mtime=0) if gz else bytes(out))
    print('%s: %s.list + %d modules' % (dst, stage, len(new)))

if __name__ == '__main__':
    main()
