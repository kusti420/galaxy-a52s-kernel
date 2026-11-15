#!/usr/bin/env python3
"""Offline insmod simulation of an Android kexec test ramdisk: the order helper2.sh loads in.

  first stage   <ramdisk lib/modules>/hhwdt.ko, testguard.ko, load.list, zsmalloc.ko, zram.ko
  stages        a52.mods order; "<s>@adsp" stages after all plain ones (they wait for the ADSP)

For every insmod: vermagic == the kernel release; every undefined, non-weak symbol is exported
by vmlinux (the GKI Module.symvers) or by a module already loaded; every modversion CRC the
module records (__versions / __version_ext_*) equals the exporter's CRC (vmlinux: Module.symvers,
modules: their own __kcrctab). A module that fails is not loaded, so what depends on it fails
too, as on the phone. Re-loading a loaded module (the camera stage lists its BSP deps again)
counts as "already" (EEXIST on the phone, harmless). Pure file analysis: nothing is loaded.

Usage: check-load.py --krel <release> --symvers <vmlinux Module.symvers> --first <dir with
       load.list + .ko> --extra <dir with testguard/zram/zsmalloc .ko> --stages <dir with
       <name>/ + <name>/load.list> --mods debug,secure,...,audio@adsp [--builtin modules.builtin]
Exit 1 if anything fails that is not "already"."""
import argparse, os, re, struct, sys


class Elf:
    def __init__(self, path):
        d = self.d = open(path, 'rb').read()
        assert d[:4] == b'\x7fELF' and d[4] == 2, path
        shoff, = struct.unpack_from('<Q', d, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
        self.sh = []
        for i in range(shnum):
            name, typ, flags, addr, off, size, link, info, align, ent = struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize)
            self.sh.append(dict(name=name, type=typ, off=off, size=size, link=link, ent=ent))
        strt = self.sh[shstrndx]
        for s in self.sh:
            s['n'] = self._str(strt['off'], s['name'])
        self.by = {s['n']: (i, s) for i, s in enumerate(self.sh)}

    def _str(self, base, o):
        e = self.d.index(b'\0', base + o)
        return self.d[base + o:e].decode('latin1')

    def sec(self, name):
        x = self.by.get(name)
        return self.d[x[1]['off']:x[1]['off'] + x[1]['size']] if x else None

    def symbols(self):
        st = self.by.get('.symtab')
        if not st:
            return
        st = st[1]
        strs = self.sh[st['link']]['off']
        for i in range(st['size'] // 24):
            name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', self.d, st['off'] + i * 24)
            yield self._str(strs, name), info >> 4, shndx, value


def modinfo(e):
    m = {}
    for kv in (e.sec('.modinfo') or b'').split(b'\0'):
        if b'=' in kv:
            k, v = kv.decode('latin1').split('=', 1)
            m.setdefault(k, v)
    return m


def analyse(path):
    e = Elf(path)
    und, weak, exp = set(), set(), {}
    kcrc_i = e.by.get('__kcrctab', (None,))[0]
    kcrc = e.sec('__kcrctab')
    for name, bind, shndx, val in e.symbols():
        if not name:
            continue
        if shndx == 0:
            (weak if bind == 2 else und).add(name)
        elif name.startswith('__crc_') and kcrc is not None and shndx == kcrc_i:
            exp[name[6:]] = struct.unpack_from('<I', kcrc, val)[0]
        elif name.startswith('__ksymtab_') and not name.startswith('__ksymtab_strings'):
            exp.setdefault(name[10:], None)
    for s in (e.sec('__ksymtab_strings') or b'').split(b'\0'):
        if s:
            exp.setdefault(s.decode('latin1'), None)
    ver = {}
    c, n = e.sec('__version_ext_crcs'), e.sec('__version_ext_names')
    if c is not None and n is not None:
        names = [x.decode('latin1') for x in n.split(b'\0') if x]
        for i, nm in enumerate(names):
            ver[nm] = struct.unpack_from('<I', c, 4 * i)[0]
    v = e.sec('__versions') or b''
    for i in range(len(v) // 64):
        crc, = struct.unpack_from('<Q', v, i * 64)
        nm = v[i * 64 + 8:i * 64 + 64].split(b'\0')[0].decode('latin1')
        if nm:
            ver.setdefault(nm, crc & 0xffffffff)
    mi = modinfo(e)
    return dict(und=und - {'__this_module'}, weak=weak, exp=exp, ver=ver,
                name=mi.get('name', os.path.basename(path)[:-3]), vermagic=mi.get('vermagic', ''))


def read_list(path):
    out = []
    for l in open(path):
        l = l.strip()
        if not l or l.startswith('#'):
            continue
        out.append(l.split()[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--krel', required=True)
    ap.add_argument('--symvers', required=True)
    ap.add_argument('--first', required=True)
    ap.add_argument('--extra', required=True)
    ap.add_argument('--stages', required=True)
    ap.add_argument('--mods', required=True)
    ap.add_argument('--builtin')
    a = ap.parse_args()
    vml = {}
    for l in open(a.symvers):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and f[2] == 'vmlinux':
            vml[f[1]] = int(f[0], 16)
    builtin = set()
    if a.builtin:
        builtin = {os.path.basename(l.strip())[:-3].replace('-', '_') for l in open(a.builtin) if l.strip()}
    plan = [('first', os.path.join(a.first, 'hhwdt.ko')), ('first', os.path.join(a.extra, 'testguard.ko'))]
    plan += [('first', os.path.join(a.first, m)) for m in read_list(os.path.join(a.first, 'load.list'))]
    plan += [('first', os.path.join(a.extra, 'zsmalloc.ko')), ('first', os.path.join(a.extra, 'zram.ko'))]
    mods = a.mods.split(',')
    for s in [m for m in mods if not m.endswith('@adsp')] + [m[:-5] for m in mods if m.endswith('@adsp')]:
        d = os.path.join(a.stages, s)
        lst = os.path.join(d, 'load.list')
        if not os.path.exists(lst):          # packed layout: /a52/mods/<name>.list
            lst = os.path.join(a.stages, s + '.list')
        names = read_list(lst) if os.path.exists(lst) else sorted(f for f in os.listdir(d) if f.endswith('.ko'))
        plan += [(s, os.path.join(d, m)) for m in names]
    loaded = {}           # module name -> exports
    exporter = {}         # symbol -> (module, crc)
    res = {'ok': 0, 'already': 0, 'fail': 0}
    fails = []
    for stage, p in plan:
        if not os.path.exists(p):
            res['fail'] += 1; fails.append((stage, os.path.basename(p), 'file missing')); continue
        m = analyse(p)
        nm = m['name'].replace('-', '_')
        why = []
        if not m['vermagic'].startswith(a.krel + ' '):
            why.append(f"vermagic '{m['vermagic']}'")
        if nm in loaded:
            res['already'] += 1; continue
        if nm in builtin:
            why.append('name clashes with a GKI built-in module')
        for s in sorted(m['und']):
            if s in vml:
                crc = vml[s]
            elif s in exporter:
                crc = exporter[s][1]
            else:
                why.append(f'unknown symbol {s}'); continue
            if s in m['ver'] and crc is not None and m['ver'][s] != crc:
                why.append(f"CRC of {s}: module {m['ver'][s]:#010x}, exporter {crc:#010x}")
        # the loader refuses a module that exports a symbol vmlinux or a loaded module exports
        for s in sorted(m['exp']):
            if s in vml:
                why.append(f'exports duplicate symbol {s} (vmlinux)')
            elif s in exporter:
                why.append(f'exports duplicate symbol {s} (owned by {exporter[s][0]})')
        if why:
            res['fail'] += 1; fails.append((stage, os.path.basename(p), '; '.join(why[:6]) + (f' (+{len(why) - 6})' if len(why) > 6 else '')))
            continue
        res['ok'] += 1
        loaded[nm] = m['exp']
        for s, c in m['exp'].items():
            exporter.setdefault(s, (nm, c))
    print(f"insmod simulation ({a.krel}, mods={a.mods}): {res['ok']} ok, {res['already']} already loaded, {res['fail']} FAIL")
    for f in fails:
        print('  FAIL', *f)
    return 1 if res['fail'] else 0


if __name__ == '__main__':
    sys.exit(main())
