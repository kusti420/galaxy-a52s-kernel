#!/usr/bin/env python3
"""Offline insmod simulation of the KERNEL-ONLY modem test (run-m1.sh / run-m2-618.sh): the order
in which bsp612/ramdisk/init and then the pack's m1.sh load modules. The per-module checks
(vermagic, every undefined symbol exported by vmlinux or an already loaded module, modversion
CRCs, duplicate exports, GKI built-in name clash) are bsp618/android/check-load.py's analyse(),
imported unchanged; only the plan differs from its Android-stage order:

  init     hhwdt.ko (kexec'd boot), escape chain spmi-pmic-arb, qti-regmap-debugfs,
           qcom-spmi-pmic, nvmem_qcom-spmi-sdam, sec_core.ko (one try), then lib/modules/load.list
           without those five (init's SKIP)
  m1.sh    dsp.list without frpc-adsprpc (ld dsp.list "frpc-adsprpc"), modem.list,
           therm.list (only with the argument therm: --therm)
A module already loaded is skipped (m1.sh's ld checks /sys/module). A failed module is not
loaded, so its dependents fail too. sec_core failing is reported as a note (the escape chain is
not part of the modem test; init carries on without it). Pure file analysis: nothing is loaded.
Exit 1 if any init/dsp/modem/therm module fails."""
import argparse, importlib.util, os, sys
sys.dont_write_bytecode = True   # importing check-load.py must not drop a __pycache__ into bsp618/android


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check-load', required=True, help='bsp618/android/check-load.py (or any copy with analyse())')
    ap.add_argument('--krel', required=True)
    ap.add_argument('--symvers', required=True, help='GKI vmlinux Module.symvers')
    ap.add_argument('--builtin')
    ap.add_argument('--first', required=True, help='ramdisk lib/modules (load.list, hhwdt.ko, sec_core.ko)')
    ap.add_argument('--pack', required=True, help='unpacked test pack (dsp.list, modem.list, therm.list, m/)')
    ap.add_argument('--therm', action='store_true')
    a = ap.parse_args()
    spec = importlib.util.spec_from_file_location('check_load', a.check_load)
    cl = importlib.util.module_from_spec(spec); spec.loader.exec_module(cl)

    vml = {}
    for l in open(a.symvers):
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and f[2] == 'vmlinux':
            vml[f[1]] = int(f[0], 16)
    builtin = set()
    if a.builtin:
        builtin = {os.path.basename(l.strip())[:-3].replace('-', '_') for l in open(a.builtin) if l.strip()}

    esc = ['spmi-pmic-arb', 'qti-regmap-debugfs', 'qcom-spmi-pmic', 'nvmem_qcom-spmi-sdam']
    F, M = a.first, os.path.join(a.pack, 'm')
    plan = [('init', os.path.join(F, 'hhwdt.ko'))]
    plan += [('escape', os.path.join(F, m + '.ko')) for m in esc]
    plan += [('escape', os.path.join(F, 'sec_core.ko'))]
    skip = set(esc) | {'sec_core'}
    plan += [('init', os.path.join(F, m)) for m in cl.read_list(os.path.join(F, 'load.list')) if m[:-3] not in skip]
    plan += [('dsp', os.path.join(M, m)) for m in cl.read_list(os.path.join(a.pack, 'dsp.list')) if not m.startswith('frpc-adsprpc')]
    plan += [('modem', os.path.join(M, m)) for m in cl.read_list(os.path.join(a.pack, 'modem.list'))]
    if a.therm:
        plan += [('therm', os.path.join(M, m)) for m in cl.read_list(os.path.join(a.pack, 'therm.list'))]

    loaded, exporter, fails, notes = {}, {}, [], []
    cnt = {}
    for stage, p in plan:
        c = cnt.setdefault(stage, [0, 0, 0])
        if not os.path.exists(p):
            c[2] += 1; fails.append((stage, os.path.basename(p), 'file missing')); continue
        m = cl.analyse(p)
        nm = m['name'].replace('-', '_')
        if nm in loaded:
            c[1] += 1; continue
        why = []
        if not m['vermagic'].startswith(a.krel + ' '):
            why.append(f"vermagic '{m['vermagic']}'")
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
        for s in sorted(m['exp']):
            if s in vml:
                why.append(f'exports duplicate symbol {s} (vmlinux)')
            elif s in exporter:
                why.append(f'exports duplicate symbol {s} (owned by {exporter[s][0]})')
        if why:
            msg = '; '.join(why[:6]) + (f' (+{len(why) - 6})' if len(why) > 6 else '')
            if stage == 'escape' and os.path.basename(p) == 'sec_core.ko':
                notes.append((stage, os.path.basename(p), msg))
            else:
                c[2] += 1; fails.append((stage, os.path.basename(p), msg))
            continue
        c[0] += 1
        loaded[nm] = m['exp']
        for s, crc in m['exp'].items():
            exporter.setdefault(s, (nm, crc))
    tot = [sum(v[i] for v in cnt.values()) for i in range(3)]
    print(f"kernel-only insmod simulation ({a.krel}{', therm' if a.therm else ''}): "
          f"{tot[0]} ok, {tot[1]} already loaded, {tot[2]} FAIL")
    for st, v in cnt.items():
        print(f"  {st:7s} {v[0]:3d} ok {v[1]:3d} already {v[2]:3d} FAIL")
    for n in notes:
        print('  note', *n)
    for f in fails:
        print('  FAIL', *f)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
