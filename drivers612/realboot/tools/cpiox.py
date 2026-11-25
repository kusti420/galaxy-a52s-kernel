#!/usr/bin/env python3
"""Extract a (possibly concatenated) newc cpio stream into a directory, like the kernel does
with an initramfs: archives are unpacked in order and later files replace earlier ones.
Only regular files, directories and symlinks are created (device nodes are listed in
<out>/.cpiox-nodes.txt instead, so no root is needed). Input: gzip, lz4 (legacy) or raw.

  cpiox.py <archive> <outdir>
"""
import gzip, io, os, stat, subprocess, sys

def raw(path):
    # segments of different compression may follow each other, as the kernel accepts (OneUI 9 port: the ROM's
    # vendor ramdisk is gzip, our fragment after it lz4): gzip members are inflated one by one, an lz4 (legacy or
    # frame) segment runs to the end (lz4 -dc handles concatenated lz4 streams), anything else is raw
    d = open(path, 'rb').read(); out = b''
    while d:
        if d[:2] == b'\x1f\x8b':
            z = __import__('zlib').decompressobj(16 + 15); out += z.decompress(d); out += z.flush(); d = z.unused_data
            while d[:1] == b'\0': d = d[1:]
        elif d[:4] in (b'\x02\x21\x4c\x18', b'\x04\x22\x4d\x18'):
            out += subprocess.run(['lz4', '-dc'], input=d, check=True, stdout=subprocess.PIPE).stdout; d = b''
        else:
            out += d; d = b''
    return out

def main():
    src, out = sys.argv[1], sys.argv[2]
    data = raw(src); i = 0; nodes = []; n = 0
    os.makedirs(out, exist_ok=True)
    while i + 110 <= len(data):
        if data[i:i + 6] != b'070701':
            if data[i] == 0: i += 1; continue          # padding between archives
            sys.exit(f"bad cpio magic at {i:#x}")
        f = [int(data[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        mode, fsize, nsize = f[1], f[6], f[11]
        name = data[i + 110:i + 110 + nsize - 1].decode()
        i = (i + 110 + nsize + 3) & ~3
        body = data[i:i + fsize]; i = (i + fsize + 3) & ~3
        if name == 'TRAILER!!!': continue
        p = os.path.normpath(os.path.join(out, name))
        if not p.startswith(os.path.abspath(out)) and not p.startswith(out): sys.exit(f"unsafe path {name}")
        if stat.S_ISDIR(mode): os.makedirs(p, exist_ok=True); continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if os.path.lexists(p) and not os.path.isdir(p): os.unlink(p)
        if stat.S_ISREG(mode):
            with open(p, 'wb') as fh: fh.write(body)
            os.chmod(p, mode & 0o7777 | 0o200); n += 1
        elif stat.S_ISLNK(mode): os.symlink(body.decode(), p)
        else: nodes.append(f"{oct(mode)} {f[9]}:{f[10]} {name}")
    open(os.path.join(out, '.cpiox-nodes.txt'), 'w').write('\n'.join(nodes) + '\n')
    print(f"{src}: {n} files, {len(nodes)} device nodes -> {out}")

if __name__ == '__main__':
    main()
