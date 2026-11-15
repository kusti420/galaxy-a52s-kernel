#!/usr/bin/env python3
"""Hop-2 survey report: per-module status of the 6.12 module set rebuilt against ACK 6.18.

Expected modules = the *.mod files the 6.12 builds left behind (bsp612/soc-repo-staging,
drivers612/, samsung612/modules/): each lists the objects of one module. A module is
  built     its .ko exists in the survey tree (modpost ran),
  compiled  every object compiled against 6.18 but no .ko (modpost did not run: the same
            make had failures elsewhere, or modpost failed),
  failed    at least one object did not compile.
  dropped   (port tree only: <results>/dropped.json, written by bsp618/port/port618.py) taken
            out of the build on purpose: GKI/upstream provides it, or this phone never uses it.
Compile errors come from the survey logs (bsp618/out-survey/logs) and are attributed to the
failing objects through the .c file of the object (or the include chain for header errors).
Output: out-survey/report.json (+ text summary on stdout). Usage: survey-report.py
"""
import json, os, re, sys, glob, collections

B = os.path.dirname(os.path.abspath(__file__))
R = os.path.dirname(B)
# SURVEY_SRC / SURVEY_RESULTS: report on another source mirror (bsp618/port: bsp618/src and
# bsp618/out-port, whose logs/ hold the build logs); defaults = the survey itself
S = os.environ.get('SURVEY_SRC', os.path.join(B, 'survey-src'))
O = os.environ.get('SURVEY_RESULTS', os.path.join(B, 'out-survey'))

SETS = [  # name, 6.12 dir (repo-relative) holding the .mod files, survey logs
    ('soc-repo', 'bsp612/soc-repo-staging', ['soc.log']),
    ('sec_core', 'samsung612/modules/sec_core', ['drivers/sec_core.log']),
    ('qfprom-sys', 'drivers612/qfprom-sys', ['drivers/qfprom-sys.log']),
    ('testguard', 'drivers612/androidboot/testguard', ['drivers/testguard.log']),
    ('debug/fnprobe', 'drivers612/debug/fnprobe', ['drivers/fnprobe.log']),
    ('debug/seaprobe', 'drivers612/debug/seaprobe', ['drivers/seaprobe.log']),
    ('hwbringup/pdmapper', 'drivers612/hwbringup/pdmapper', ['drivers/pdmapper.log']),
    ('secure/ioncompat', 'drivers612/secure/ioncompat', ['drivers/drivers612_secure_ioncompat.log']),
    ('secure/securemsm', 'drivers612/secure/securemsm', ['drivers/drivers612_secure_securemsm.log', '{S}/drivers612/secure/securemsm/build.log']),
    ('secure/adsprpc', 'drivers612/secure/adsprpc', ['drivers/drivers612_secure_adsprpc.log']),
    ('display', 'drivers612/display', ['drivers/drivers612_display.log', '{S}/drivers612/display/logs/*.log']),
    ('touch', 'drivers612/touch', ['drivers/drivers612_touch.log']),
    ('power', 'drivers612/power', ['drivers/drivers612_power.log']),
    ('audio', 'drivers612/audio/audio-kernel', ['drivers/drivers612_audio.log', '{S}/drivers612/audio/build.log']),
    ('audio/samsung', 'drivers612/audio/samsung', ['drivers/drivers612_audio_samsung.log', '{S}/drivers612/audio/samsung/*/build.log']),
    ('gpu (kgsl)', 'drivers612/gpu-video/gpu', ['drivers/drivers612_gpu-video_gpu.log', '{S}/drivers612/gpu-video/gpu/build.log']),
    ('video (msm_vidc)', 'drivers612/gpu-video/video', ['drivers/drivers612_gpu-video_video.log', '{S}/drivers612/gpu-video/video/build.log']),
    ('conn/subsys_compat', 'drivers612/conn/subsys_compat', ['drivers/drivers612_conn_subsys_compat.log']),
    ('conn/rild/drb', 'drivers612/conn/rild', ['drivers/drivers612_conn_rild_drb.log']),
    ('conn/data', 'drivers612/conn/data', ['drivers/drivers612_conn_data.log', '{S}/drivers612/conn/data/build.log']),
    ('conn/bt', 'drivers612/conn/bt', ['drivers/drivers612_conn_bt.log']),
    ('conn/wlan', 'drivers612/conn/wlan', ['drivers/drivers612_conn_wlan.log', '{S}/drivers612/conn/wlan/out-platform.log', '{S}/drivers612/conn/wlan/out-qcacld.log']),
    ('camera', 'drivers612/camera', ['drivers/camera-dep-ioncompat.log', 'drivers/camera-dep-fled-stub.log', 'drivers/drivers612_camera.log', '{S}/drivers612/camera/build.log']),
]
# sets only the port tree builds (build-survey.sh "extra"); not part of the survey's 395
if os.environ.get('SURVEY_SRC'):
    SETS += [
        ('fingerprint', 'drivers612/fingerprint/src', ['drivers/fingerprint.log']),
        ('nfc', 'drivers612/nfc/src', ['drivers/nfc.log']),
        ('vibrator', 'drivers612/vibrator/src', ['drivers/vibrator.log']),
        ('realboot/dspboot', 'drivers612/realboot/modules/dspboot', ['drivers/dspboot.log']),
        ('hhwdt', 'modules/hhwdt', ['drivers/hhwdt.log']),
    ]
SKIP = ('/donors/', '/androidboot/out/', '/hwbringup/pack', '/wifibt/pack', '/out/')


def norm(p, base=None):
    if base and not p.startswith('/'):
        p = os.path.join(base, p)
    return os.path.normpath(p)


def rel(p):
    p = norm(p)
    for root in (S, R):
        if p.startswith(root + '/'):
            return p[len(root) + 1:]
    return p


def expected(d612):
    mods = {}
    for f in glob.glob(os.path.join(R, d612, '**', '*.mod'), recursive=True):
        if any(s in f for s in SKIP):
            continue
        objs = [rel(l.strip()) for l in open(f) if l.strip()]
        mods[rel(f)[:-4]] = objs  # repo-relative module path without extension
    return mods


ERR = re.compile(r'^(?P<f>[^:\s]+\.[chS]):(?P<l>\d+):(?P<c>\d+): (?:fatal )?error: (?P<m>.*)$')
INC = re.compile(r'^In file included from (?P<f>[^:\s]+):\d+')
MAKEFAIL = re.compile(r"\*\*\* \[[^\]]*?: (?P<o>\S+\.o)\] Error")
MODPOST = re.compile(r'^(?:ERROR|WARNING): modpost: "(?P<s>[^"]+)" \[(?P<m>[^\]]+)\] undefined!')


BASES = {'soc-repo': ['bsp612/soc-repo-staging/build'],
         'display': ['drivers612/display/techpack/display-drivers', 'drivers612/display/techpack/mm-drivers'],
         'camera': ['drivers612/camera/work/drivers'],
         'conn/wlan': ['drivers612/conn/wlan/work/qcacld-3.0', 'drivers612/conn/wlan/work/platform'],
         'conn/data': ['drivers612/conn/data/src'],
         'secure/securemsm': ['drivers612/secure/securemsm/src'],
         'gpu (kgsl)': ['drivers612/gpu-video/gpu/src'],
         'touch': ['drivers612/touch/src'],
         'audio': ['drivers612/audio/audio-kernel'],
         'audio/samsung': ['drivers612/audio/samsung/sec_audio', 'drivers612/audio/samsung/tas256x']}


def resolver(name, d612):
    bases = [os.path.join(S, b) for b in BASES.get(name, [])]
    bases += sorted({os.path.dirname(os.path.join(S, m)) for m in expected(d612)})
    bases += [os.path.join(S, d612), os.path.join(R, 'ack')]

    def res(p):
        if p.startswith('/'):
            return norm(p)
        for b in bases:
            q = norm(p, b)
            if os.path.exists(q):
                return q
        return norm(p, bases[0])
    return res


def parse_logs(logs, res=norm):
    errs = []   # (root .c file, error file, line, msg)
    failed_objs = set()
    modpost = []
    for lg in logs:
        pat = lg.replace('{S}', S) if lg.startswith('{S}') else os.path.join(O, 'logs', lg)
        for path in glob.glob(pat):
            root = None
            for line in open(path, errors='replace'):
                line = line.rstrip('\n')
                m = INC.match(line)
                if m:
                    if root is None:
                        root = res(m['f'])
                    continue
                m = ERR.match(line)
                if m:
                    f = res(m['f'])
                    r = root if (root and not f.endswith('.c')) else f
                    errs.append((r, f, int(m['l']), m['m']))
                    root = None
                    continue
                if not line.startswith(' ') and not line.startswith('In file'):
                    root = None
                m = MAKEFAIL.search(line)
                if m:
                    failed_objs.add(rel(res(m['o'][:-2] + '.c')))
                m = MODPOST.match(line)
                if m:
                    modpost.append((m['s'], m['m']))
    return errs, failed_objs, modpost


def main():
    report = {'sets': []}
    dp = os.path.join(O, 'dropped.json')
    dropped = json.load(open(dp)) if os.path.exists(dp) else {}
    for name, d612, logs in SETS:
        mods = expected(d612)
        errs, failed_objs, modpost = parse_logs(logs, resolver(name, d612))
        uniq = sorted(set(errs))
        by_c = collections.defaultdict(list)
        for r, f, l, m in uniq:
            by_c[rel(r)].append((rel(f), l, m))
        out = []
        for mod, objs in sorted(mods.items()):
            ko = os.path.join(S, mod + '.ko')
            missing = [o for o in objs if not os.path.exists(os.path.join(S, o))]
            st = 'built' if os.path.exists(ko) else ('compiled' if not missing else 'failed')
            if st != 'built' and mod in dropped:
                st = 'dropped'
            merrs = []
            for o in missing:
                merrs += by_c.get(o[:-2] + '.c', [])
            out.append({'module': mod, 'status': st, 'objects': len(objs), 'missing': missing,
                        'errors': sorted(set(map(tuple, merrs)))})
            if st == 'dropped':
                out[-1]['reason'] = dropped[mod]
        report['sets'].append({'name': name, 'dir': d612, 'modules': out,
                               'errors': [(rel(r), rel(f), l, m) for r, f, l, m in uniq],
                               'failed_objs': sorted(failed_objs), 'modpost': modpost})
        c = collections.Counter(m['status'] for m in out)
        print(f"{name:22s} {len(out):4d} modules: {c['built']:3d} built, {c['compiled']:3d} compiled, "
              f"{c['failed']:3d} failed" + (f", {c['dropped']:3d} dropped" if dropped else '')
              + f"; {len(uniq)} unique errors")
    json.dump(report, open(os.path.join(O, 'report.json'), 'w'), indent=1)


# ---- root-cause clusters: (id, regex over the error message) in match order ----
RULES = [
    ('werror-proto', r"-Wmissing-prototypes|-Wmissing-declarations"),
    ('ns-string', r"expected ';' after top level declarator"),
    ('remove-new', r"'remove_new'"),
    ('timer-api', r"'(del_timer(_sync)?|from_timer|hrtimer_init|timer|\w*_timer)'|alarmtimer|ALARMTIMER"),
    ('gpio-pinctrl', r"PIN_CONFIG_OUTPUT|struct gpio_chip|'valid_mask'|struct gpio'|struct gpio \*|gpio_is_shared|gpio_free_arry|gpiochip_"),
    ('mm-page', r"nth_page|memdesc_flags_t|'struct page \*' (from|with an expression of type) 'int'|parameter of type 'struct page \*'|NR_BOUNCE|NR_WRITEBACK_TEMP|sections_per_block|zpool\.h|PageMovable"),
    ('dma-fence-heap', r"dma_fence|timeline_value_str|fence_value_str|use_64bit_seqno|dma_heap_ops|get_dmabuf_debugfs_data"),
    ('iommu', r"iommu|io_pgtable|pgsize_bitmap|enable_nesting|kvm/iommu\.h|pkvm_module_ops|IO_PGTABLE|arm_lpae|'irqreturn_t'"),
    ('drm', r"drm_|mipi_dsi|FB_EVENT_BLANK|pfn_t\.h|'struct_mutex'|'date' does not refer|hdmi_codec_ops|snd_soc_component \*, struct device_node \*"),
    ('const-callbacks', r"const struct bin_attribute|device_match_t"),
    ('sched-walt', r"cfs_rq|set_next_entity|binder_transaction"),
    ('crypto-blk', r"crypto_comp|crypto_alloc_comp|crypto_free_comp|crypto_has_comp|blk_crypto_key|BLK_CRYPTO_KEY_TYPE|scatterwalk"),
    ('ida-simple', r"ida_simple_"),
    ('usb-ufs-internals', r"dwc3_ep|DWC3_DEPCMD|'UFS_[A-Z_]+'|ufshcd_|ucsi"),
    ('cfg80211-net', r"wiphy|wireless_dev|rtnl_newlink_params|softnet_data|napi"),
    ('asoc', r"SND_SOC_DAIFMT|snd_compr|snd_soc_pcm_runtime|trace/hooks/sound\.h|expected single argument 'rtd'"),
    ('v4l2', r"vidioc_|v4l2_"),
    ('coresight', r"TRFCR_ELx"),
    ('misc-api', r"driver_override|power_supply_config|sdhci_pltfm_free|of_pci_parse_bus_range|aer_stats|console_stop|_boost_|SPI_CS_CNT_MAX|gic_chip_data|nr_irqs|typecheck_irq_probe|aqr107|blk-mq-virtio|wakeup_source_add|file not found"),
    ('werror-other', r"\[-Werror"),
]
WERROR = {'werror-proto', 'werror-other'}


def classify(msg, fname=''):
    for cid, rx in RULES:
        if re.search(rx, msg):
            return cid
    if 'too few arguments' in msg or 'too many arguments' in msg or 'incompatible function pointer' in msg:
        for key, cid in (('drm', 'drm'), ('msm_fb', 'drm'), ('sde_', 'drm'), ('lt9611', 'drm'),
                         ('walt', 'sched-walt'), ('hdmi-codec', 'asoc'), ('vidc', 'v4l2'), ('rmnet', 'cfg80211-net')):
            if key in fname:
                return cid
        return 'signature-other'
    if 'errors generated' in msg or 'too many errors' in msg:
        return None
    return 'other'


def clusters():
    r = json.load(open(os.path.join(O, 'report.json')))
    cl = collections.defaultdict(lambda: {'modules': set(), 'errors': 0, 'sole': set(), 'example': None,
                                          'by_set': collections.Counter(), 'sites': set()})
    mods_failed = 0
    werror_only = []
    no_errors = []
    for s in r['sets']:
        for m in s['modules']:
            if m['status'] != 'failed':
                continue
            mods_failed += 1
            cs = set()
            for f, l, msg in m['errors']:
                cid = classify(msg, f)
                if not cid:
                    continue
                cs.add(cid)
                c = cl[cid]
                c['modules'].add(m['module'])
                c['by_set'][s['name']] += 0
                if (f, l, msg) not in c['sites']:
                    c['sites'].add((f, l, msg))
                    c['errors'] += 1
                if c['example'] is None or (len(msg) < len(c['example'][2]) and len(msg) > 40):
                    c['example'] = (f, l, msg)
            for cid in cs:
                cl[cid]['by_set'][s['name']] += 1
            if not cs:
                no_errors.append(m['module'])
            elif cs <= WERROR:
                werror_only.append(m['module'])
            real = cs - WERROR
            if len(real) == 1:
                cl[next(iter(real))]['sole'].add(m['module'])
            elif not real and len(cs) == 1:
                cl[next(iter(cs))]['sole'].add(m['module'])
    out = {k: {'modules': sorted(v['modules']), 'n_modules': len(v['modules']), 'n_errors': v['errors'],
               'sole': sorted(v['sole']), 'example': v['example'], 'by_set': dict(v['by_set'])}
           for k, v in cl.items()}
    json.dump({'clusters': out, 'failed': mods_failed, 'werror_only': werror_only, 'no_errors': no_errors},
              open(os.path.join(O, 'clusters.json'), 'w'), indent=1)
    print(f"\n{mods_failed} failed modules; {len(werror_only)} blocked only by -Werror diagnostics; "
          f"{len(no_errors)} with no attributed error")
    for k, v in sorted(out.items(), key=lambda kv: -kv[1]['n_modules']):
        print(f"{k:20s} {v['n_modules']:4d} modules ({len(v['sole']):3d} sole non-Werror cause), {v['n_errors']:4d} error sites")


def modules_md():
    """Per-module appendix for SURVEY.md (out-survey/modules.md)."""
    r = json.load(open(os.path.join(O, 'report.json')))
    L = []
    for s in r['sets']:
        ms = s['modules']
        c = collections.Counter(m['status'] for m in ms)
        L.append(f"### {s['name']} (`{s['dir']}`): {len(ms)} modules, {c['built']} built, "
                 f"{c['compiled']} compiled without .ko, {c['failed']} failed"
                 + (f", {c['dropped']} dropped" if c['dropped'] else '') + "\n")
        ok = [os.path.basename(m['module']) for m in ms if m['status'] not in ('failed', 'dropped')]
        if ok:
            L.append('Built: ' + ', '.join(f'`{x}`' for x in sorted(ok)) + '\n')
        for m in ms:
            if m['status'] == 'dropped':
                L.append(f"Dropped: `{os.path.basename(m['module'])}` ({m['reason']})\n")
        bad = [m for m in ms if m['status'] == 'failed']
        if bad:
            L.append('| failed module | causes (cluster: error sites) | failing objects |')
            L.append('|---|---|---|')
            for m in sorted(bad, key=lambda m: os.path.basename(m['module'])):
                cc = collections.Counter(filter(None, (classify(msg, f) for f, l, msg in m['errors'])))
                L.append(f"| `{os.path.basename(m['module'])}` | "
                         + ', '.join(f'{k}: {v}' for k, v in cc.most_common())
                         + f" | {len(m['missing'])} of {m['objects']} |")
            L.append('')
    open(os.path.join(O, 'modules.md'), 'w').write('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
    clusters()
    modules_md()
