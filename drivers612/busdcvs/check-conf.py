#!/usr/bin/env python3
"""Offline check of busdcvs.conf against a device tree: every sysfs path it writes must belong
to a device the tree creates, and the interconnect list must be complete.

  check-conf.py <dtb> <busdcvs.conf>

Maps (6.12 naming, of_device_make_bus_id + the dcvs kobjects):
  devices/system/cpu/bus_dcvs/<HW>/<addr>.<name>/x    -> /soc/<name>@<addr>, enabled, its
                                                          qcom,target-dev has qcom,dcvs-hw-type of <HW>
  devices/system/cpu/bus_dcvs/<HW>/soc:qcom,memlat:<g>:<m>/x -> /soc/qcom,memlat/<g>/<m>, and
                                                          <g>'s qcom,target-dev is <HW>
  devices/system/cpu/bus_dcvs/<HW>/boost_freq         -> a qcom,dcvs-hw of that type with a
                                                          slow path (qcom,dcvs-path-type 0)
  devices/system/cpu/bus_dcvs/memlat_settings/x       -> /soc/qcom,memlat enabled
  devices/platform/soc/<addr>.interconnect/state_synced, soc:interconnect -> the provider node;
                                                          and every enabled /soc node with
                                                          #interconnect-cells and a qcom,yupik-*
                                                          compatible must be listed
Also: no SCMI vendor protocol child (reg 0x80) under an arm,scmi node (dt-fix.sh ran).
"""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../boarddt/tools'))
import fdt  # noqa: E402

HW = {'DDR': 0, 'LLCC': 1, 'L3': 2, 'DDRQOS': 3}

def u32s(b):
    return [struct.unpack_from('>I', b, i)[0] for i in range(0, len(b), 4)]

def s(n, p):
    v = n.props.get(p)
    return v.rstrip(b'\0').decode() if v is not None else None

def enabled(n):
    while n is not None and n.parent is not None:
        if s(n, 'status') not in (None, 'okay', 'ok'):
            return False
        n = n.parent
    return True

def main():
    dtb, conf = sys.argv[1], sys.argv[2]
    root = fdt.load(dtb); soc = root.get('/soc')
    byph = {}
    for n in root.walk():
        if 'phandle' in n.props:
            byph[u32s(n.props['phandle'])[0]] = n
    def hwtype(n):
        t = byph.get(u32s(n.props['qcom,target-dev'])[0]) if 'qcom,target-dev' in n.props else None
        return u32s(t.props['qcom,dcvs-hw-type'])[0] if t is not None and 'qcom,dcvs-hw-type' in t.props else None
    errs = []; seen_icc = set(); n_ok = 0
    for ln, line in enumerate(open(conf), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        path = line.split()[0]; parts = path.split('/')
        where = f'{conf}:{ln}: {path}'
        if path.startswith('devices/system/cpu/bus_dcvs/'):
            rest = parts[4:]
            if rest[0] == 'memlat_settings':
                ml = soc.children.get('qcom,memlat')
                if ml is None or not enabled(ml): errs.append(f'{where}: no enabled /soc/qcom,memlat')
                else: n_ok += 1
                continue
            hw = rest[0]
            if hw not in HW: errs.append(f'{where}: unknown hw {hw}'); continue
            if rest[1] == 'boost_freq':
                ok = False
                for n in root.get('/soc/qcom,dcvs').children.values() if root.get('/soc/qcom,dcvs') else []:
                    if 'qcom,dcvs-hw-type' in n.props and u32s(n.props['qcom,dcvs-hw-type'])[0] == HW[hw] and enabled(n):
                        ok = any('qcom,dcvs-path-type' in c.props and u32s(c.props['qcom,dcvs-path-type'])[0] == 0
                                 and enabled(c) for c in n.children.values())
                if not ok: errs.append(f'{where}: no enabled qcom,dcvs-hw type {HW[hw]} with a slow path')
                else: n_ok += 1
                continue
            dev = rest[1]
            if dev.startswith('soc:qcom,memlat:'):
                g, m = dev[len('soc:qcom,memlat:'):].split(':')
                n = root.get(f'/soc/qcom,memlat/{g}/{m}')
                if n is None or not enabled(n): errs.append(f'{where}: no enabled /soc/qcom,memlat/{g}/{m}'); continue
                if hwtype(n.parent) != HW[hw]: errs.append(f'{where}: group {g} targets hw {hwtype(n.parent)}, not {hw}'); continue
                n_ok += 1; continue
            addr, _, name = dev.partition('.')
            n = soc.children.get(f'{name}@{addr}')
            if n is None or not enabled(n): errs.append(f'{where}: no enabled /soc/{name}@{addr}'); continue
            if hwtype(n) != HW[hw]: errs.append(f'{where}: {name}@{addr} targets hw {hwtype(n)}, not {hw}'); continue
            n_ok += 1
        elif path.startswith('devices/platform/soc/') and parts[-1] == 'state_synced':
            dev = parts[3]
            node = 'interconnect' if dev == 'soc:interconnect' else 'interconnect@' + dev.split('.')[0]
            n = soc.children.get(node)
            if n is None or not enabled(n) or '#interconnect-cells' not in n.props:
                errs.append(f'{where}: no enabled interconnect provider /soc/{node}'); continue
            seen_icc.add(node); n_ok += 1
        else:
            errs.append(f'{where}: path class not checked by this tool')
    want = {k for k, n in soc.children.items() if '#interconnect-cells' in n.props and enabled(n)
            and (s(n, 'compatible') or '').startswith('qcom,yupik-')}
    if want - seen_icc: errs.append(f'interconnect providers not in {conf}: {sorted(want - seen_icc)}')
    for n in root.walk():
        if (s(n, 'compatible') or '') == 'arm,scmi':
            for c in n.children.values():
                if 'reg' in c.props and u32s(c.props['reg'])[0] == 0x80:
                    errs.append(f'{c.path()}: SCMI vendor protocol node present (memlat/pmu-lib would defer: run dt-fix.sh)')
    for e in errs: print('FAIL', e)
    print(f'check-conf: {n_ok} paths match the tree, {len(want)} interconnect providers all listed' if not errs
          else f'check-conf: {len(errs)} problem(s)')
    sys.exit(1 if errs else 0)

if __name__ == '__main__':
    main()
