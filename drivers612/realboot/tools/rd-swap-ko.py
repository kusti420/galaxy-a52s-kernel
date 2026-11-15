#!/usr/bin/env python3
"""Make a test ramdisk that differs from a tested one ONLY in the given kernel modules.

  rd-swap-ko.py IN.cpio.gz OUT.cpio.gz NEW.ko...

IN is a (possibly concatenated) newc cpio stream, gzip or raw (pack-kexec-rd.sh /
pack-kexec-rd-618.sh output). Every regular file whose name is NEW.ko's file name, optionally
with a numeric "NN-" stage prefix (a52/mods/i2c/02-i2c-msm-geni.ko), gets NEW.ko's content; the
cpio headers keep name, mode, uid/gid, mtime and inode, only the size field changes. Every other
byte of the stream (all other entries, archive boundaries, padding) is copied unchanged. Fails
unless every NEW.ko replaced at least one entry and every replaced entry has the same vermagic.
Prints what was replaced. Used for s75 = s74 + bsp612/patches/soc-repo/0009 (i2c-msm-geni,
msm_geni_serial) and a9 = a8 + the same on 6.18 (research/sepolicy/PATHS.md).
"""
import gzip, os, re, sys

def vermagic(b):
    m = re.search(rb'vermagic=([^\0]*)', b)
    return m.group(1) if m else None

def main():
    if len(sys.argv) < 4: sys.exit(__doc__)
    src, dst, kos = sys.argv[1], sys.argv[2], sys.argv[3:]
    data = open(src, 'rb').read()
    gz = data[:2] == b'\x1f\x8b'
    if gz: data = gzip.decompress(data)
    new = {os.path.basename(k): open(k, 'rb').read() for k in kos}
    hits = {k: 0 for k in new}
    out = bytearray(); i = 0
    while i < len(data):
        if data[i:i + 6] != b'070701':
            if data[i] == 0: out.append(0); i += 1; continue
            sys.exit('bad cpio magic at %#x' % i)
        hdr = bytearray(data[i:i + 110])
        f = [int(hdr[6 + 8 * k:14 + 8 * k], 16) for k in range(13)]
        mode, fsize, nsize = f[1], f[6], f[11]
        nend = i + 110 + nsize
        name = data[i + 110:nend - 1].decode()
        npad = (110 + nsize + 3) & ~3
        body = data[i + npad:i + npad + fsize]
        nxt = i + npad + ((fsize + 3) & ~3)
        base = re.sub(r'^\d+-', '', os.path.basename(name))
        if (mode & 0o170000) == 0o100000 and base in new:
            nb = new[base]
            if vermagic(nb) != vermagic(body):
                sys.exit('%s: vermagic %r != %r of %s' % (name, vermagic(nb), vermagic(body), base))
            hdr[54:62] = b'%08X' % len(nb)
            out += hdr + data[i + 110:i + npad] + nb + b'\0' * ((4 - len(nb) % 4) % 4)
            hits[base] += 1
            print('replaced %s (%d -> %d bytes)' % (name, fsize, len(nb)))
        else:
            out += data[i:nxt]
        i = nxt
    miss = [k for k, n in hits.items() if n == 0]
    if miss: sys.exit('not in %s: %s' % (src, ' '.join(miss)))
    with open(dst, 'wb') as fh:
        fh.write(gzip.compress(bytes(out), 6, mtime=0) if gz else bytes(out))
    print('%s: %d entries replaced' % (dst, sum(hits.values())))

if __name__ == '__main__':
    main()
