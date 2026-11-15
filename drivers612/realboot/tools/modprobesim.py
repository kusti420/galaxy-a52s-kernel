#!/usr/bin/env python3
"""Dry run of Android's libmodprobe on a module directory: does it resolve, in the way the ROM's
loaders will, every module it is asked for? No kernel involved (loadsim.py checks symbols,
vermagic and CRCs); this checks the CONFIG FILES as libmodprobe parses them.

  modprobesim.py --dir <local dir> --as <path on the phone> --load-file modules.load
  modprobesim.py --dir <local dir> --as <path on the phone> --modules m1 m2 ...

A port of system/core/libmodprobe (module_config.cpp ParseCfg/ParseDepCallback/..., libmodprobe.cpp
LoadWithAliases/InsmodWithDeps/LoadListedModules, libmodprobe_ext.cpp ModuleExists, utils.cpp
CanonicalizeModulePath), with finit_module() replaced by "the file exists". Same quirks:
lines are split on single spaces, so "a.ko: " (trailing space) gives an empty dependency, which
libmodprobe turns into "<dir>/" -> "malformed module name" -> the module and everything that
depends on it fail (2026-11-14 rehearsal: the vendor add-on's audio set loaded nothing).
--load-file = first-stage init / `modprobe -a FILE` (LoadListedModules), --modules = the
`modprobe -a -d DIR m1 m2 ...` form of the vendor rc (LoadWithAliases(m, strict) per name).
Exit 1 if any requested module would not load; prints libmodprobe's ERROR lines.
"""
import argparse, fnmatch, os, sys

class Sim:
    def __init__(self, local, base, load_file):
        self.local, self.base = local.rstrip('/'), base.rstrip('/')
        self.deps, self.aliases, self.pre, self.post = {}, [], [], []
        self.load, self.options, self.block, self.loaded, self.errors = [], {}, set(), set(), []
        for name, cb in (('modules.alias', self.p_alias), ('modules.dep', self.p_dep),
                         ('modules.softdep', self.p_softdep), (load_file, self.p_load),
                         ('modules.options', self.p_options), ('modules.blocklist', self.p_block)):
            p = os.path.join(self.local, name)
            if not os.path.isfile(p): continue
            for line in open(p, encoding='utf-8', errors='replace').read().split('\n'):
                if not line or line[0] == '#': continue
                cb(line.split(' '))

    def err(self, m): self.errors.append(m)
    def canon(self, p):
        s = p.rfind('/') + 1; e = len(p) - 3 if p.endswith('.ko') else len(p)
        if e - s <= 1: self.err(f"malformed module name: {p}"); return ''
        return p[s:e].replace('-', '_')
    def p_dep(self, a):
        pos = a[0].find(':')
        pre = '' if a[0][:1] == '/' else self.base + '/'
        if pos < 0: self.err("dependency lines must start with name followed by ':'"); return
        d = [pre + a[0][:pos]] + [('' if x[:1] == '/' else self.base + '/') + x for x in a[1:]]
        c = self.canon(a[0][:pos])
        if c: self.deps[c] = d
    def p_alias(self, a):
        if a[0] != 'alias' or len(a) != 3: self.err(f"bad modules.alias line {a}"); return
        self.aliases.append((a[1], a[2]))
    def p_softdep(self, a):
        if a[0] != 'softdep' or len(a) < 4: self.err(f"bad modules.softdep line {a}"); return
        st = ''
        for t in a[2:]:
            if t in ('pre:', 'post:'): st = t; continue
            if not st: self.err(f"malformed modules.softdep at token {t}"); return
            (self.pre if st == 'pre:' else self.post).append((a[1], t))
    def p_load(self, a):
        c = self.canon(a[0])
        if c: self.load.append(c)
    def p_options(self, a):
        if a[0] not in ('options', 'dyn_options') or len(a) < 2: self.err(f"bad modules.options line {a}"); return
        c = self.canon(a[1])
        if c in self.options: self.err(f"multiple options lines present for module {a[1]}"); return
        self.options[c] = ' '.join(a[2:])
    def p_block(self, a):
        if a[0] != 'blocklist' or len(a) != 2: self.err(f"bad modules.blocklist line {a}"); return
        c = self.canon(a[1])
        if c: self.block.add(c)

    def local_path(self, p):
        return self.local + p[len(self.base):] if p.startswith(self.base + '/') else None
    def exists(self, m, use_block):
        if use_block and m in self.block: return False
        d = self.deps.get(m)
        if not d: return False
        lp = self.local_path(d[0])
        if lp is None or not os.path.exists(lp): self.err(f"module {m} can't be loaded; can't access {d[0]}"); return False
        if not os.path.isfile(lp): self.err(f"module {m} is not a regular file"); return False
        return True
    def with_deps(self, m, use_block):
        d = self.deps.get(m)
        if not m or not d: self.err(f"Module {m} not in dependency file"); return False
        for dep in reversed(d[1:]):
            if not self.with_aliases(dep, True, use_block): return False
        for mod, sd in self.pre:
            if mod == m: self.with_aliases(sd, False, use_block)
        self.loaded.add(self.canon(d[0]))
        for mod, sd in self.post:
            if mod == m: self.with_aliases(sd, False, use_block)
        return True
    def with_aliases(self, name, strict, use_block=False):
        c = self.canon(name)
        if c in self.loaded: return True
        todo = {c}
        for al, mod in self.aliases:
            if fnmatch.fnmatchcase(name, al) and self.canon(mod) not in self.loaded: todo.add(mod)
        ok = False
        for m in sorted(todo):
            if not self.exists(m, use_block): continue
            if self.with_deps(m, use_block): ok = True
        if strict and not ok:
            self.err(f"LoadWithAliases was unable to load {name}, tried: {', '.join(sorted(todo))}")
            return False
        return True

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dir', required=True); ap.add_argument('--as', dest='base', required=True)
    ap.add_argument('--load-file'); ap.add_argument('--modules', nargs='*', default=[])
    ap.add_argument('--label', default='')
    a = ap.parse_args()
    s = Sim(a.dir, a.base, a.load_file or 'modules.load')
    bad = []
    if a.load_file:
        for m in s.load:
            if not s.with_aliases(m, True): bad.append(m)
    for m in a.modules:
        if not s.with_aliases(m, True): bad.append(m)
    n = len(s.load) if a.load_file else len(a.modules)
    print(f"modprobe dry run {a.label} ({a.base}): {n - len(bad)}/{n} requested modules resolve, "
          f"{len(s.loaded)} insmods; {len(s.errors)} libmodprobe errors")
    for e in s.errors[:12]: print("  ERROR " + e)
    if bad: print("  NOT LOADED: " + ' '.join(bad)); sys.exit(1)

if __name__ == '__main__':
    main()
