#!/usr/bin/env python3
"""Turn the module set of a TESTED kexec ramdisk into the module layout of a real boot.

  modplan.py --ref <unpacked test ramdisk> --first "<stage ...>" --late "<stage ...>"
             --wlan <stage> [--extra-after <stage>:<file.ko> ...] [--drop "<name ...>"]
             --out <dir>

The test ramdisk (drivers612/androidboot/pack-kexec-rd.sh) carries
  /lib/modules/load.list          bsp612's first-stage set, loaded first by helper2.sh
  /lib/modules/{zsmalloc,zram,sec_core,hhwdt,testguard}.ko
  /a52/mods/<stage>.list + <stage>/*.ko   the extra stages (a52.mods=...), "NN-" name prefixes,
                                  optional parameters, a trailing "&" = background insmod.
The module files are taken byte for byte (they are the ones that ran on the phone).

Output (<out>/):
  first/<name>.ko  first.load  first.params     vendor_boot ramdisk /lib/modules, in load order
  late/<name>.ko   late.load   late.params      /vendor/lib/modules/6.12 (after the ADSP runs)
  wlan/<name>.ko   wlan.load                    /vendor/lib/modules/5.4-gki (macloader's path)
  plan.txt                                      what came from where, what was dropped and why
Rules:
  - a module name already planned is skipped (in the test it got EEXIST); a second copy with
    different bytes is an error;
  - "NN-" prefixes are removed (libmodprobe takes the module name from the file name);
  - parameters the Samsung ABL passes on the command line itself (msm_drm.dsi_display0,
    msm_drm.lcd_id, sec_common_fn.lcd_id: panel-specific, read by libmodprobe from
    /proc/cmdline) are NOT written; sec_core clear_on_load=0 (test-only) is dropped;
  - "&" (background insmod: sec-battery's probe waits for the chargers listed after it)
    becomes the kernel's generic async_probe module option.
"""
import argparse, hashlib, os, re, shutil, subprocess, sys

ABL_PARAMS = {('msm_drm', 'dsi_display0'), ('msm_drm', 'lcd_id'), ('sec_common_fn', 'lcd_id')}
TEST_ONLY_PARAMS = {('sec_core', 'clear_on_load')}

def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest()

def modname(path):
    r = subprocess.run(['modinfo', '-F', 'name', path], stdout=subprocess.PIPE, text=True)
    n = r.stdout.strip()
    return n if n else re.sub(r'^\d+-', '', os.path.basename(path))[:-3].replace('-', '_')

def read_list(path):
    out = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        words = line.split()
        bg = words[-1] == '&' if len(words) > 1 else False
        if bg:
            words = words[:-1]
        elif words[-1].endswith('&'):
            words[-1] = words[-1][:-1]; bg = True
            if not words[-1]: words = words[:-1]
        out.append((words[0], words[1:], bg))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref', required=True)
    ap.add_argument('--first', required=True)
    ap.add_argument('--late', required=True)
    ap.add_argument('--wlan', required=True)
    ap.add_argument('--extra-after', action='append', default=[])
    ap.add_argument('--drop', default='')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    ref = a.ref; drop = set(a.drop.split())
    planned = {}           # file name -> (group, src, md5)
    groups = {'first': [], 'late': [], 'wlan': []}
    params = {'first': [], 'late': [], 'wlan': []}
    log = []
    extras = {}
    for e in a.extra_after:
        st, ko = e.split(':', 1); extras.setdefault(st, []).append(ko)

    def add(group, src, args, bg, origin, rename=None):
        f = rename or re.sub(r'^\d+-', '', os.path.basename(src))
        name = modname(src)
        if name in drop or f[:-3] in drop:
            log.append(f"DROP  {f:32s} {origin} (test-only)"); return
        h = md5(src)
        if f in planned:
            if planned[f][2] != h:
                sys.exit(f"{f}: two different builds ({planned[f][1]} and {src})")
            log.append(f"dup   {f:32s} {origin} (already in {planned[f][0]}: EEXIST in the test)")
            return
        planned[f] = (group, src, h)
        groups[group].append((f, src))
        kept = []
        for p in args:
            k = p.split('=', 1)[0]
            if (name, k) in ABL_PARAMS:
                log.append(f"param {f:32s} {p} -> not written: the ABL passes {name}.{k} on the command line")
            elif (name, k) in TEST_ONLY_PARAMS:
                log.append(f"param {f:32s} {p} -> dropped (test-only; module default)")
            else:
                kept.append(p)
        if bg:
            kept.append('async_probe=1')
            log.append(f"param {f:32s} '&' (background insmod) -> async_probe=1")
        if kept:
            params[group].append((name, kept))
        log.append(f"{group:5s} {f:32s} {origin}")

    M = os.path.join(ref, 'lib/modules')
    for f, args, bg in read_list(os.path.join(M, 'load.list')):
        add('first', os.path.join(M, f), args, bg, 'base (bsp612 first stage)')
    for f in ('zsmalloc.ko', 'zram.ko'):
        add('first', os.path.join(M, f), [], False, 'base (GKI zram for the ROM swap)')
    for f in sorted(os.listdir(M)):
        if f.endswith('.ko') and f not in planned and f not in ('zsmalloc.ko', 'zram.ko'):
            log.append(f"skip  {f:32s} ref /lib/modules, not in load.list (helper-only or loaded by a stage)")
    for group, stages in (('first', a.first.split()), ('late', a.late.split()), ('wlan', [a.wlan])):
        for st in stages:
            lst = os.path.join(ref, 'a52/mods', st + '.list')
            if not os.path.exists(lst):
                sys.exit(f"stage {st}: no {lst}")
            for f, args, bg in read_list(lst):
                add(group, os.path.join(ref, 'a52/mods', st, f), args, bg, f"stage {st}")
            for ko in extras.get(st, []):
                add(group, ko, [], False, f"realboot module after stage {st}")
    # wlan.ko goes where macloader finit_module()s it: <dir>/qca_cld3_wlan.ko
    groups['wlan'] = [('qca_cld3_wlan.ko' if f == 'wlan.ko' else f, s) for f, s in groups['wlan']]
    for g, items in groups.items():
        d = os.path.join(a.out, g); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        with open(os.path.join(a.out, g + '.load'), 'w') as fh:
            for f, s in items:
                shutil.copyfile(s, os.path.join(d, f)); fh.write(f + '\n')
        with open(os.path.join(a.out, g + '.params'), 'w') as fh:
            for n, p in params[g]:
                fh.write(f"options {n} {' '.join(p)}\n")
    with open(os.path.join(a.out, 'plan.txt'), 'w') as fh:
        fh.write('\n'.join(log) + '\n')
    print(' '.join(f"{g}={len(v)}" for g, v in groups.items()))

if __name__ == '__main__':
    main()
