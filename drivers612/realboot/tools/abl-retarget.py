#!/usr/bin/env python3
"""Re-target the measured bootloader (ABL) part of a real-boot command line to the other test phone.

  abl-retarget.py --abl <file> --src-harness <dtb> --dst-harness <dtb> [--expect k=v ...]
                  [--normal-live <dtb> --normal-prefix <file>] -o <file>

--abl          the ABL's own arguments measured on the phone the realboot build was made for
               (build-realboot.sh: cmdline-predicted-4096.txt minus CONFIG_CMDLINE, DT bootargs and
               the vendor_boot cmdline), a NORMAL boot of that phone's LineageOS
--src-harness  /sys/firmware/fdt of the 6.18 harness boot on that same phone (logs/kx-*-pN-*/harness-live.dtb)
--dst-harness  the same for the target phone. Both harness boots are recovery boots of the same harness
               build, so every value that differs between the two trees is a per-phone ABL value
               (serial, revision, subpcb, ap_serial, bootloader, rp, kg.ap, em.did, wb.snapQB, ...).
Rule per word of --abl: boot-mode words (MODE_KEYS: recovery boots carry other values) are kept;
a key with the same value in both harness trees is kept; a key whose value differs between them
must have the source phone's harness value in --abl and gets the target's. Keys in only one of
the two harness trees, or with several different values, are an error (the model would not fit).
--expect k=v   the result must contain this word (e.g. androidboot.bootloader=A528BXXU5FWK4)
--normal-live / --normal-prefix  optional cross-check against a NORMAL boot of the target phone
               under any ROM: live /chosen/bootargs minus the prefix (that ROM's dtb bootargs + " " +
               its vendor cmdline) = the target's normal-boot ABL part. Allowed differences:
               ROM_KEYS (which dtb/dtbo entry of that ROM was picked) and STATE_KEYS (charger state
               at power-on); anything else fails.
"""
import argparse, subprocess, sys

MODE_KEYS = {'androidboot.boot_recovery', 'androidboot.force_normal_boot', 'androidboot.dtb_idx',
             'androidboot.dtbo_idx', 'androidboot.edtbo_ver'}
ROM_KEYS = {'androidboot.dtb_idx', 'androidboot.dtbo_idx'}
STATE_KEYS = {'sec_mparam.charging_mode'}


def bootargs(dtb):
    return subprocess.run(['fdtget', dtb, '/chosen', 'bootargs'], stdout=subprocess.PIPE, text=True,
                          check=True).stdout.rstrip('\n')


def kv(words):
    """key -> set of values (a word without '=' is its own key with value None)"""
    m = {}
    for w in words:
        k, eq, v = w.partition('=')
        m.setdefault(k, set()).add(v if eq else None)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--abl', required=True)
    ap.add_argument('--src-harness', required=True)
    ap.add_argument('--dst-harness', required=True)
    ap.add_argument('--expect', action='append', default=[])
    ap.add_argument('--normal-live')
    ap.add_argument('--normal-prefix')
    ap.add_argument('-o', required=True)
    a = ap.parse_args()
    abl = open(a.abl).read().split()
    src, dst = kv(bootargs(a.src_harness).split()), kv(bootargs(a.dst_harness).split())
    err = []
    only = sorted(set(src) ^ set(dst))
    if only:
        err.append(f"keys in only one harness tree: {only}")
    out, changed = [], []
    for w in abl:
        k, eq, v = w.partition('=')
        v = v if eq else None
        if k in MODE_KEYS or k not in src or k not in dst:
            if k not in MODE_KEYS and (k in src or k in dst):
                err.append(f"{k}: in one harness tree only")
            elif k not in MODE_KEYS:
                print(f"note: {w} not in the harness trees, kept")
            out.append(w)
            continue
        if src[k] == dst[k]:
            out.append(w)
            continue
        if len(src[k]) != 1 or len(dst[k]) != 1:
            err.append(f"{k}: several values ({sorted(map(str, src[k]))} / {sorted(map(str, dst[k]))})")
            out.append(w)
            continue
        (sv,), (dv,) = src[k], dst[k]
        if v != sv:
            err.append(f"{k}: --abl has {v}, the source phone's harness {sv}: --abl is not that phone's")
        nw = k if dv is None else f"{k}={dv}"
        changed.append(f"{w} -> {nw}")
        out.append(nw)
    for e in a.expect:
        if e not in out:
            err.append(f"result lacks {e}")
    res = ' '.join(out)
    if a.normal_live:
        live = bootargs(a.normal_live)
        prefix = open(a.normal_prefix).read().strip()
        if not live.startswith(prefix):
            err.append("normal-boot live tree: bootargs do not start with the given prefix (wrong ROM dump?)")
        else:
            nb, rk = kv(live[len(prefix):].split()), kv(out)
            diff = sorted(k for k in set(nb) | set(rk) if nb.get(k) != rk.get(k))
            bad = [k for k in diff if k not in ROM_KEYS | STATE_KEYS]
            info = ', '.join(f"{k} {sorted(map(str, rk.get(k, {'-'})))} vs normal {sorted(map(str, nb.get(k, {'-'})))}" for k in diff)
            if bad:
                err.append(f"vs the target's measured normal boot: unexpected differences {bad}")
            print(f"cross-check vs the target's normal boot ({a.normal_live}): "
                  f"{'only ROM/state keys differ: ' + info if diff else 'identical'}")
    for c in changed:
        print(f"retarget: {c}")
    if err:
        for e in err:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    open(a.o, 'w').write(res + '\n')
    print(f"retargeted ABL part: {len(changed)} words changed, {len(res)} chars (source {len(' '.join(abl))})")


if __name__ == '__main__':
    main()
