#!/usr/bin/env python3
"""Owners and modes that the ROM's ueventd gives the modem/data device nodes on the 6.x kernel,
checked against what the same nodes had on the phone's 5.4 kernel (read only, offline).

  ueventd-check.py --ueventd <rc> [--ueventd <rc> ...] --dev54 <ls -lZ /dev of a 5.4 boot>
                   --dtb <tree> --modules <dir with the planned .ko files> -o <devnodes.txt>

ueventd model (system/core/init/devices.cpp): every "/dev/<pattern> <mode> <user> <group>" line
of the rc files in parse order (system first, then vendor); the LAST matching line wins
(DeviceHandler::GetDevicePermissions walks the list backwards); a pattern with '*' is an
fnmatch(FNM_PATHNAME) pattern; no matching line = 0600 root root; a line whose user or group
is not an AID (android_ids, oem_N, the device's config.fs) is rejected by the parser and does not
apply (e.g. smd4's system_ext_bridge_rw: root root 0600 on 5.4 too).

Node list: the fixed nodes of the modem/data modules (table NODES below, provider module must be
in --modules) + one per qcom,glinkpkt child of the tree (qcom,glinkpkt-dev-name). The rmtfs UIO
can be uio0..uio2 (msm_drm may register a UIO first): all three are checked.
Output: one line per node "<name> <mode octal> <uid> <gid> <provider>" for the rehearsal's
on-phone check (nodes that do not exist there are skipped by it: e.g. uio1/uio2, rmnet_ctrl). Exit 1 if a node that existed on 5.4 gets a different owner, group
or mode, or a provider module is missing.
"""
import argparse, fnmatch, os, re, sys
import libfdt

# node -> (provider module, note); "subsys_modem" comes from the first-stage subsys_compat
NODES = [
    ('ipa', 'ipam', 'IPA driver; ipa_fws.rc writes 1 at early-boot'),
    ('ipaNatTable', 'ipam', 'IPA NAT (ipacm)'),
    ('ipa_odl_ctl', 'ipam', 'IPA ODL'),
    ('ipa_adpl', 'ipam', 'IPA ADPL (dataadpl, disabled service)'),
    ('wwan_ioctl', 'ipam', 'rmnet_ipa fd ioctl (ipacm)'),
    ('uio0', 'msm_sharedmem', 'rmt_storage shared buffer (UIO name rmtfs)'),
    ('uio1', 'msm_sharedmem', 'rmtfs UIO if another UIO registered first'),
    ('uio2', 'msm_sharedmem', 'rmtfs UIO if two other UIOs registered first'),
    ('drb', 'dev_ril_bridge', 'Samsung dev RIL bridge (rild)'),
    ('subsys_modem', 'subsys_compat', 'pm-service vote = modem boot'),
    ('rmnet_ctrl', 'usb_f_gsi', 'USB rmnet tethering control (only when init.qcom.usb.rc mkdirs gsi.rmnet)'),
    ('dpl_ctrl', 'usb_f_gsi', 'USB DPL control (only with gsi.dpl)'),
]
AID = {'root': 0, 'system': 1000, 'radio': 1001, 'bluetooth': 1002, 'graphics': 1003,
       'input': 1004, 'audio': 1005, 'camera': 1006, 'log': 1007, 'compass': 1008,
       'mount': 1009, 'wifi': 1010, 'adb': 1011, 'install': 1012, 'media': 1013, 'dhcp': 1014,
       'sdcard_rw': 1015, 'vpn': 1016, 'keystore': 1017, 'usb': 1018, 'drm': 1019,
       'mdnsr': 1020, 'gps': 1021, 'nfc': 1027, 'shell': 2000, 'diag': 2002,
       'inet': 3003, 'net_admin': 3005}


def aid(name, extra):
    """uid of a user/group name as ueventd decodes it (android_ids + oem_N + the vendor's
    config.fs AIDs); None = unknown: ueventd rejects the whole line (ParsePermissionsLine)"""
    if name in AID:
        return AID[name]
    if name in extra:
        return extra[name]
    m = re.fullmatch(r'oem_(\d+)', name)
    return int(m.group(1)) if m else None


def aidheader(path):
    """AOSP android_filesystem_config.h: #define AID_<NAME> <n> -> name (lower case)"""
    out = {}
    for ln in open(path):
        m = re.match(r'^#define AID_([A-Z0-9_]+)\s+(\d+)\b', ln)
        if m and not m.group(1).endswith(('_START', '_END')):
            out[m.group(1).lower()] = int(m.group(2))
    return out


def configfs(path):
    out = {}; cur = None
    for ln in open(path):
        m = re.match(r'^\[AID_([A-Z0-9_]+)\]', ln)
        if m:
            cur = m.group(1).lower(); continue
        m = re.match(r'^value:\s*(\d+)', ln)
        if m and cur:
            out[cur] = int(m.group(1)); cur = None
    return out


def rules(paths, extra):
    out = []
    for p in paths:
        for ln in open(p, errors='replace'):
            w = ln.split('#', 1)[0].split()
            if len(w) == 4 and w[0].startswith('/dev/'):
                src = f"{os.path.basename(p)}: {' '.join(w)}"
                u, g = aid(w[2], extra), aid(w[3], extra)
                if u is None or g is None:
                    print(f"note: ueventd rejects '{src}' (unknown user/group): the line does not apply")
                    continue
                out.append((w[0], int(w[1], 8), u, g, src))
    return out


def perm(rs, dev):
    for pat, mode, u, g, src in reversed(rs):
        if ('*' in pat and fnmatch.fnmatch(dev, pat)) or pat == dev:
            return mode, u, g, src
    return 0o600, 0, 0, '(no valid rule: ueventd default 0600 root root)'


def dev54(path):
    d = {}
    for ln in open(path, errors='replace'):
        m = re.match(r'^([cb])([-rwxsStT]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\S+)\s+\d+,\s*\d+\s+\S+\s+\S+\s+(\S+)$', ln.strip())
        if m:
            bits = m.group(2); mode = 0
            for i, ch in enumerate(bits):
                if ch not in '-SsTt' or ch in 'st':
                    mode |= 1 << (8 - i)
            d[m.group(6)] = (mode, m.group(3), m.group(4), m.group(5))
    return d


def glinkpkt(dtb):
    f = libfdt.Fdt(open(dtb, 'rb').read())
    try:
        off = f.path_offset('/soc/qcom,glinkpkt')
    except libfdt.FdtException:
        return []
    out = []
    c = f.first_subnode(off, [libfdt.FDT_ERR_NOTFOUND])
    while c >= 0:
        def prop(n):
            v = f.getprop(c, n, [libfdt.FDT_ERR_NOTFOUND])
            return None if isinstance(v, int) else v.as_str()
        st, name = prop('status'), prop('qcom,glinkpkt-dev-name')
        if name is not None and st in (None, 'okay', 'ok'):
            out.append((name, 'glink_pkt', f"glink channel {prop('qcom,glinkpkt-ch-name')} on {prop('qcom,glinkpkt-edge')}"))
        c = f.next_subnode(c, [libfdt.FDT_ERR_NOTFOUND])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ueventd', action='append', required=True)
    ap.add_argument('--dev54', required=True)
    ap.add_argument('--dtb', required=True)
    ap.add_argument('--modules', action='append', required=True)
    ap.add_argument('--config-fs', help="the device's config.fs (vendor AIDs)")
    ap.add_argument('--aid-header', help='AOSP android_filesystem_config.h (all android_ids)')
    ap.add_argument('-o', required=True)
    a = ap.parse_args()
    extra = aidheader(a.aid_header) if a.aid_header else {}
    if a.config_fs:
        extra.update(configfs(a.config_fs))
    rs = rules(a.ueventd, extra); ref = dev54(a.dev54)
    mods = set()
    for d in a.modules:
        mods |= {f[:-3].replace('-', '_') for f in os.listdir(d) if f.endswith('.ko')}
    bad = 0; lines = []
    for node, prov, note in NODES + glinkpkt(a.dtb):
        if prov not in mods:
            print(f"FAIL {node}: provider {prov}.ko not in the module plan"); bad += 1; continue
        mode, u, g, src = perm(rs, '/dev/' + node)
        r = ref.get(node)
        if r is None:
            st = 'not on 5.4'
        else:
            ru, rg = aid(r[1], extra), aid(r[2], extra)
            if (r[0], ru, rg) == (mode, u, g):
                st = f"= 5.4 ({r[1]}:{r[2]} {r[3]})"
            else:
                st = f"5.4 had {oct(r[0])} {r[1]}:{r[2]}"
                print(f"FAIL {node}: ueventd gives {oct(mode)} {u}:{g} ({src}), {st}"); bad += 1
        print(f"ok   /dev/{node:13s} {oct(mode)[2:]:>4s} {u:>4d}:{g:<4d} {st:58s} [{prov}: {note}; {src}]")
        lines.append(f"{node} {oct(mode)[2:]} {u} {g} {prov}")
    with open(a.o, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    print(f"ueventd-check: {len(lines)} nodes, {bad} problem(s)")
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
