#!/usr/bin/env python3
"""tools/selftest/oneui/collect.py <run dir>: host-side collectors of the OneUI parity sweep.

Reads what sweep.sh saved (kmsg.txt, logcat.txt, props.txt, tombstones.txt, dropbox-tags.txt; for a plain
selftest run dir: kmsg-after.txt, logcat-after.txt) and groups it:
  avc denials (one signature per perms/scontext/tcontext/tclass/name), init services dying or looping, processes
  that 'have died', tombstones + dropbox crash tags, fatal crashes, sysfs/proc/dev paths that userspace failed to
  open (ENOENT / EACCES, by path and log tag), FreecessHandler / MARs errors, kernel WARN/BUG lines, QSEECOM TA
  loads and errors.
stdout: one TSV row per collector in the oneui.tsv format (id, status, owner, stable, detail); ids start with
"col." and their stable value is a number that report.py compares numerically (6.12 above 5.4 = worse).
Files: <run>/collectors.json (everything, grouped) and <run>/collect-*.txt (readable lists, used by report.py to
show what is NEW on 6.12). Runs of 14+ digits are masked in everything written."""
import collections, json, os, re, sys

KBAD = re.compile(r"WARNING: CPU|WARNING: at |\bBUG:|Internal error|Unable to handle kernel|Oops|Kernel panic|soft lockup|"
                  r"rcu_(preempt|sched).*(stall|detected)|hung_task|blocked for more than|page allocation failure|"
                  r"Out of memory: Kill|kgsl.*(out of memory|GPU PAGE FAULT|gpu fault|snapshot created|hang detected)|"
                  r"arm-smmu.*(context fault|Unhandled)|ufshcd.*(abort|error handler)|watchdog: BUG|UBSAN|KASAN|"
                  r"refcount_t:|sysfs: cannot create duplicate|deadlock")
KBAD_NOT = re.compile(r"\] (calling|initcall) +[A-Za-z_0-9.]+\+0x|\] probe of [^ ]+ returned ")
AVC_KERNEL_SIDE = re.compile(r"scontext=u:r:kernel|tcontext=u:object_r:(sysfs|proc|debugfs|unlabeled|device|configfs|tracefs|"
                             r"sysfs_devices_system_cpu)( |$)|tclass=(system|bpf|perf_event)")
SVC_EXIT = re.compile(r"init: Service '([^']+)' \(pid \d+\) (exited with status (\d+)|received signal (\d+))")
SVC_START = re.compile(r"init: starting service '([^']+)'")
SVC_IGNORE = re.compile(r"^(bootanim|gsid|flash_recovery|vendor\.macloader|logcatd|dumpstate\w*|bugreport\w*|adbd|usbd|"
                        r"exec \d+ .*|vendor\.qcrild_dummy)$")
DIED = re.compile(r"Process ([\w.:\-]+) \(pid \d+\) has died(?:: (\w+))?")
PATHFAIL = re.compile(r"(No such file or directory|ENOENT|Permission denied|EACCES|[Ff]ailed to open|[Cc]annot open|"
                      r"[Cc]ould not open|[Cc]an't open|open failed|[Ff]ailed to (?:read|write)|[Uu]nable to (?:open|read|write)|"
                      r"fail(?:ed)? to open|open error|errno ?[=:(]? ?(?:2|13)\b)")
PATH = re.compile(r"(/(?:sys|proc|dev|config|d)/[\w./:@,+\-]+)")
LOGCAT = re.compile(r"^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+\d+\s+\d+ ([VDIWEF]) ([^:]*?)\s*: (.*)$")
FREECESS = re.compile(r"[Ff]reecess|MARs|kfreecess")
FREECESS_BAD = re.compile(r"fail|error|exception|unable|not support|cannot|can't|denied|invalid|timeout|null", re.I)
TA_LOADED = re.compile(r"App with id \d+ \(([\w.\-]+)\) now loaded")
TA_KFAIL = re.compile(r"(?:qseecom_load_app|__qseecom_load_fw|qseecom_load_external_elf)[^\n]*?(?:\(([\w.\-]+)\))?[^\n]*(?:fail|error|ret = -|rc=-)", re.I)
TA_REQ = re.compile(r"QSEECom_start_app called, path \S+ fname ([\w.\-]+)|startApp called path \S+ app name ([\w.\-]+)|qsc_start_app[^\n]*name[ =:]+([\w.\-]+)")
TA_NOFILE = re.compile(r"QSEECOMAPI: Error::Cannot open the file \S*/([\w.\-]+)\.mdt")
QSEE_BAD = re.compile(r"(qseecom|QSEECOM|smcinvoke|QSEECOMAPI|QSEECOMD)[^\n]*(fail|[Ee]rror|ERROR|timed out)")


def scrub(s):
    return re.sub(r"\d{14,}", "<digits>", s)


def read(run, *names):
    for n in names:
        p = os.path.join(run, n)
        if os.path.exists(p):
            with open(p, errors="replace") as f:
                return f.read().splitlines()
    return []


def avc_sig(line):
    def g(rx):
        m = re.search(rx, line)
        return m.group(0) if m else ""
    perms = g(r"denied +\{[^}]*\}").replace("denied", "").strip()
    name = re.sub(r"\d+", "N", g(r'(?:name|path)="[^"]*"'))
    s = re.sub(r":s0.*", "", g(r"scontext=\S+"))
    t = re.sub(r":s0.*", "", g(r"tcontext=\S+"))
    return " ".join(x for x in (perms, s, t, g(r"tclass=\S+"), name) if x)


def norm(msg):
    return re.sub(r"\d+", "N", re.sub(r"0x[0-9a-fA-F]+", "0xN", msg)).strip()[:200]


def collect(run):
    kmsg = read(run, "kmsg.txt", "kmsg-after.txt")
    logcat = read(run, "logcat.txt", "logcat-after.txt")
    logcat = [l for l in logcat if not re.match(r"\d\d-\d\d \S+\s+\d+\s+\d+ [VDIWEF] adbd\s*:", l)]   # adbd echoes the testers' own shell commands
    props = read(run, "props.txt")
    out = {"run": os.path.abspath(run), "kmsg_lines": len(kmsg), "logcat_lines": len(logcat)}

    # --- avc: the same denial is in dmesg (audit) and in logcat; count per source and keep the larger count
    per = [collections.Counter(), collections.Counter()]
    for i, src in enumerate((kmsg, logcat)):
        for l in src:
            if re.search(r"avc: +denied", l):
                per[i][avc_sig(l)] += 1
    sigs = {s: max(per[0][s], per[1][s]) for s in set(per[0]) | set(per[1])}
    out["avc"] = dict(sorted(sigs.items(), key=lambda kv: -kv[1]))
    out["avc_kernel_side"] = sorted(s for s in sigs if AVC_KERNEL_SIDE.search(s) and "scontext=u:r:shell " not in s + " ")
    bydom = collections.Counter()
    for s, n in sigs.items():
        m = re.search(r"scontext=u:r:(\S+)", s)
        bydom[m.group(1) if m else "?"] += n
    out["avc_by_domain"] = dict(bydom.most_common())

    # --- init services
    exits, starts = collections.Counter(), collections.Counter()
    for l in kmsg + logcat:
        m = SVC_EXIT.search(l)
        if m and not SVC_IGNORE.match(m.group(1)) and m.group(3) != "0":
            exits["%s %s" % (m.group(1), "status " + m.group(3) if m.group(3) else "signal " + m.group(4))] += 1
        m = SVC_START.search(l)
        if m and not SVC_IGNORE.match(m.group(1)):
            starts[m.group(1)] += 1
    out["svc_abnormal_exits"] = dict(exits.most_common())
    loops = {s: n for s, n in starts.items() if n >= 4}
    out["svc_start_counts_4plus"] = dict(sorted(loops.items(), key=lambda kv: -kv[1]))
    out["svc_restarting_props"] = sorted(m.group(1) for l in props for m in [re.match(r"\[init\.svc\.([^\]]+)\]: \[restarting\]", l)] if m)

    # --- processes that died (ActivityManager), fatal crashes
    died = collections.Counter()
    fatal = collections.Counter()
    for l in logcat:
        m = DIED.search(l)
        if m:
            died[m.group(1)] += 1
        if (re.search(r"Fatal signal \d+", l) or "FATAL EXCEPTION" in l) and " adbd " not in l[:60]:
            fatal[norm(re.sub(r"^.*?(Fatal signal|FATAL EXCEPTION)", r"\1", l))[:120]] += 1
        m = re.search(r"AndroidRuntime: Process: ([\w.:]+)", l)
        if m:
            fatal["java crash in " + m.group(1)] += 1
    out["process_died"] = dict(died.most_common())
    out["fatal"] = dict(fatal.most_common())

    # --- tombstones + dropbox
    tomb = read(run, "tombstones.txt")
    tfiles = [l for l in tomb if re.search(r"tombstone_\d+(\.pb)?$", l) and not l.startswith("==")]
    cmds = collections.Counter(scrub(l.split(":", 1)[1].strip()) for l in tomb if l.startswith("Cmdline:"))
    out["tombstone_files"] = len([l for l in tfiles if not l.endswith(".pb")]) or len(tfiles)
    out["tombstone_cmdlines"] = dict(cmds.most_common())
    drop = {}
    for l in read(run, "dropbox-tags.txt"):
        p = l.split()
        if len(p) == 2 and p[0].isdigit():
            drop[p[1]] = int(p[0])
    out["dropbox_tags"] = drop
    crash_tags = {k: v for k, v in drop.items() if re.search(r"TOMBSTONE|_crash|_anr|watchdog|SYSTEM_RESTART|_wtf", k)}
    out["dropbox_crash_tags"] = crash_tags

    # --- sysfs/proc/dev paths userspace failed on, by path + tag
    pf = collections.Counter()
    for l in logcat:
        if not PATHFAIL.search(l):
            continue
        m = LOGCAT.match(l)
        tag, msg = (m.group(2), m.group(3)) if m else ("?", l)
        kind = "EACCES" if re.search(r"Permission denied|EACCES|errno ?[=:(]? ?13\b", msg) else "ENOENT"
        for p in PATH.findall(msg):
            p = re.sub(r"\d+", "N", p.rstrip(".,:"))
            if re.match(r"/(sys/fs/cgroup|dev/(cpuctl|cpuset|blkio|memcg|stune)|proc/N)(/|$)", p):
                continue  # per-pid cgroup paths: process already gone, not a kernel interface
            pf["%s %s [%s]" % (kind, p, tag.strip())] += 1
    out["path_failures"] = dict(pf.most_common())

    # --- Freecess / MARs
    fr = collections.Counter()
    frall = 0
    for l in logcat + kmsg:
        if FREECESS.search(l):
            frall += 1
            m = LOGCAT.match(l)
            lvl, msg = (m.group(1), m.group(2) + ": " + m.group(3)) if m else ("K", re.sub(r"^\[[ \d.]+\] ?", "", l))
            if lvl in "EF" or (lvl in "WK" and FREECESS_BAD.search(msg)) or re.search(r"exception|fail", msg, re.I):
                fr[norm(msg)] += 1
    out["freecess_lines"] = frall
    out["freecess_errors"] = dict(fr.most_common())

    # --- vaultkeeper / CASS (warning+error lines, grouped)
    vk = collections.Counter()
    for l in logcat:
        if re.search(r"vaultkeeper|VK |CASS", l, re.I):
            m = LOGCAT.match(l)
            if m and m.group(1) in "WEF":
                vk[norm(m.group(2) + ": " + m.group(3))] += 1
    out["vaultkeeper_errors"] = dict(vk.most_common())

    # --- kernel
    kb = collections.Counter(norm(re.sub(r"^\[[ \d.]+\] ?", "", l)) for l in kmsg if KBAD.search(l) and not KBAD_NOT.search(l))
    out["kernel_bad"] = dict(kb.most_common())
    tas = set()
    for l in kmsg + logcat:
        for m in TA_LOADED.finditer(l):
            if "qsee" in l.lower() or "smcinvoke" in l.lower():
                tas.add(m.group(1))
    out["ta_loaded"] = sorted(tas)
    # --- spec 04 (tee.* / drm.*): TA set of the whole boot + the Widevine level the plugin itself logs.
    # kmsg-early.txt / logcat-early.txt come from boot-capture.sh (taken ~40 s after boot, same boot id). They are used
    # for these rows only, so the counters above stay comparable with older runs.
    ek = read(run, "kmsg-early.txt"); el = read(run, "logcat-early.txt")
    def first_ts(lines):
        for l in lines[:50]:
            m = re.match(r"^\[ *(\d+)\.\d+\]", l)
            if m:
                return int(m.group(1))
        return None
    best = ek if (ek and (first_ts(ek) or 0) <= (first_ts(kmsg) if first_ts(kmsg) is not None else 1 << 30)) else kmsg
    out["kmsg_first_s"] = first_ts(best)
    boot_tas, failed, requested = set(), collections.Counter(), set()
    for l in best:
        if "QSEECOM" not in l and "qseecom" not in l and "smcinvoke" not in l:
            continue
        for m in TA_LOADED.finditer(l):
            boot_tas.add(m.group(1))
        m = TA_KFAIL.search(l)
        if m:
            failed[m.group(1) or "?"] += 1
    for l in (el + logcat):
        if re.match(r"\d\d-\d\d \S+\s+\d+\s+\d+ [VDIWEF] adbd\s*:", l):
            continue
        for m in TA_REQ.finditer(l):
            requested.add(next(g for g in m.groups() if g))
        m = TA_NOFILE.search(l)
        if m:
            failed[m.group(1) + ".mdt(not-at-first-path)"] += 1
    out["ta_boot_set"] = sorted(boot_tas); out["ta_requested"] = sorted(requested); out["ta_failed"] = dict(failed.most_common())
    wv = {"level": None, "l1_ok": 0, "l3_fallback": 0, "inits": 0, "api": None, "ta": None, "iface": None, "errors": collections.Counter()}
    for l in (el + logcat):
        if "WVCdm" not in l and "OEMCrypto" not in l:
            continue
        if "L3 Initialized. Trying L1" in l:
            wv["inits"] += 1
        if re.search(r"Level 1 success|I will use level 1", l):
            wv["l1_ok"] += 1
        if re.search(r"[Ff]alling [Bb]ack to L(evel )?3|[Uu]sing L(evel )?3|Could not (load|initialize) (L1|level 1)|L1 (failed|not)|will use level 3", l):
            wv["l3_fallback"] += 1
        for k, rx in (("api", r"Api +version +([\d.]+)"), ("ta", r"TA +version +([\d.]+)"), ("iface", r"TA-HLOS interface\s*:\s*(\w+)")):
            m = re.search(rx, l)
            if m:
                wv[k] = m.group(1)
        m = LOGCAT.match(l)
        if m and m.group(1) in "EF" and "unknown string property" not in l:
            wv["errors"][norm(m.group(2) + ": " + m.group(3))] += 1
    wv["level"] = "L3" if wv["l3_fallback"] and not wv["l1_ok"] else "L1" if wv["l1_ok"] else None
    wv["errors"] = dict(wv["errors"].most_common(6))
    out["widevine_log"] = wv
    qb = collections.Counter(norm(re.sub(r"^\[[ \d.]+\] ?|^\d\d-\d\d \S+\s+\d+\s+\d+ ", "", l)) for l in kmsg + logcat if QSEE_BAD.search(l) and not re.match(r"\d\d-\d\d \S+\s+\d+\s+\d+ [VDI] ", l))
    out["qseecom_errors"] = dict(qb.most_common())
    return json.loads(scrub(json.dumps(out)))


def top(d, n=4, w=150):
    return "; ".join("%sx %s" % (v, k) for k, v in list(d.items())[:n])[:w * n] if isinstance(d, dict) else " ".join(d[:n])


def rows(c):
    r = []
    def add(i, bad, owner, n, detail, fail_on_any=False):
        r.append((i, "FAIL" if (fail_on_any and bad) else "PASS", owner, str(n), detail))
    nolog = "" if c["logcat_lines"] else " (NO LOGCAT in this run dir)"
    nok = "" if c["kmsg_lines"] else " (no kernel log: needs root)"
    add("col.avc_denials", 0, "ROM", sum(c["avc"].values()), "%d signatures; by domain: %s%s" % (len(c["avc"]), top(c["avc_by_domain"], 6, 40), nolog))
    add("col.avc_signatures", 0, "ROM", len(c["avc"]), top(c["avc"], 3))
    add("col.avc_kernel_side", c["avc_kernel_side"], "kernel+ROM", len(c["avc_kernel_side"]), "unlabelled sysfs/proc/debugfs or kernel domain: " + "; ".join(c["avc_kernel_side"][:3]), True)
    add("col.svc_restarting", c["svc_restarting_props"], "kernel+ROM", len(c["svc_restarting_props"]), " ".join(c["svc_restarting_props"]), True)
    add("col.svc_abnormal_exits", c["svc_abnormal_exits"], "kernel+ROM", sum(c["svc_abnormal_exits"].values()), top(c["svc_abnormal_exits"], 6, 60) + nok, True)
    add("col.svc_restart_loops", c["svc_start_counts_4plus"], "kernel+ROM", len(c["svc_start_counts_4plus"]), "started 4+ times: " + top(c["svc_start_counts_4plus"], 6, 50), True)
    add("col.process_died", 0, "info", sum(c["process_died"].values()), top(c["process_died"], 6, 50))
    add("col.fatal_crashes", c["fatal"], "kernel+ROM", sum(c["fatal"].values()), top(c["fatal"], 3), True)
    add("col.tombstones", c["tombstone_files"], "kernel+ROM", c["tombstone_files"], top(c["tombstone_cmdlines"], 5, 50), True)
    add("col.dropbox_crashes", 0, "kernel+ROM", sum(c["dropbox_crash_tags"].values()), top(c["dropbox_crash_tags"], 8, 40))
    add("col.path_failures", 0, "kernel+ROM", len(c["path_failures"]), "distinct path+tag pairs userspace failed to open: " + top(c["path_failures"], 4, 110))
    add("col.freecess_errors", c["freecess_errors"], "kernel", sum(c["freecess_errors"].values()), "%d Freecess/MARs lines in all; %s" % (c["freecess_lines"], top(c["freecess_errors"], 3)), True)
    add("col.vaultkeeper_errors", 0, "kernel+ROM", sum(c["vaultkeeper_errors"].values()), top(c["vaultkeeper_errors"], 4))
    add("col.kernel_bad", c["kernel_bad"], "kernel", sum(c["kernel_bad"].values()), top(c["kernel_bad"], 3) + nok, True)
    add("col.qseecom_errors", c["qseecom_errors"], "kernel", sum(c["qseecom_errors"].values()), top(c["qseecom_errors"], 3), True)
    r.append(("sec.ta_loaded", "PASS" if c["ta_loaded"] else "SKIP", "kernel", "set: " + " ".join(c["ta_loaded"]) if c["ta_loaded"] else "no TA load line in the kernel log",
              "QSEECOM 'now loaded' lines still in the log (the log rolls over: compare soon after boot)"))
    # spec 04 rows
    ks = c.get("kmsg_first_s")
    if c["ta_boot_set"] and ks is not None and ks <= 3:
        r.append(("tee.ta_boot_set", "PASS", "kernel", "set: " + " ".join(c["ta_boot_set"]), "kernel log reaches back to %d s: every qseecom TA load of this boot" % ks))
    else:
        r.append(("tee.ta_boot_set", "SKIP", "kernel", "kernel log starts at %s s" % ("?" if ks is None else ks),
                  "the TA load lines of early boot are gone; partial: %s. Run tools/selftest/oneui/boot-capture.sh <serial> while the phone boots, then the sweep" % (" ".join(c["ta_boot_set"]) or "none")))
    r.append(("tee.ta_requested", "PASS" if c["ta_requested"] else "SKIP", "kernel+ROM", "set: " + " ".join(c["ta_requested"]) if c["ta_requested"] else "no start_app line in logcat",
              "TA names userspace asked qseecom for (logcat QSEECom_start_app / QSEECOM_HAL startApp lines; logcat usually reaches back to boot)"))
    r.append(("tee.ta_load_failures", "PASS", "kernel+ROM", str(len(c["ta_failed"])), (top(c["ta_failed"], 8, 40) or "none") + " (not-at-first-path = libQSEEComAPI did not find the .mdt in the first directory it tries; it may load from the next one: only a kernel-side failure line is a real load failure)"))
    w = c["widevine_log"]
    if w["level"]:
        r.append(("drm.widevine_log_level", "PASS" if w["level"] == "L1" else "FAIL", "kernel+ROM", "securityLevel=%s" % w["level"],
                  "from the plugin's own log: %d CDM inits, %d x 'Level 1 success', %d x L3 fallback; OEMCrypto API %s, TA %s, TA interface %s; errors: %s"
                  % (w["inits"], w["l1_ok"], w["l3_fallback"], w["api"], w["ta"], w["iface"], top(w["errors"], 3, 90) or "none")))
    else:
        r.append(("drm.widevine_log_level", "SKIP", "kernel+ROM", "no OEMCrypto init line in logcat", "nothing opened Widevine since the log began (%d CDM inits seen)" % w["inits"]))
    return r


def main():
    if len(sys.argv) not in (2, 3) or not os.path.isdir(sys.argv[1]) or (len(sys.argv) == 3 and sys.argv[2] != "--update"):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    run = sys.argv[1]
    c = collect(run)
    update = len(sys.argv) == 3
    with open(os.path.join(run, "collectors.json"), "w") as f:
        json.dump(c, f, indent=1)
    for key in ("avc", "path_failures", "svc_abnormal_exits", "process_died", "freecess_errors", "kernel_bad", "fatal", "qseecom_errors", "vaultkeeper_errors"):
        with open(os.path.join(run, "collect-%s.txt" % key), "w") as f:
            for k, v in c[key].items():
                f.write("%6d  %s\n" % (v, k))
    lines = ["\t".join(x.replace("\t", " ").replace("\n", " ") for x in r) for r in rows(c)]
    if update:  # collect.py <run> --update: recompute the collector rows of an existing oneui.tsv from the saved logs
        p = os.path.join(run, "oneui.tsv")
        with open(p) as f:
            keep = [l.rstrip("\n") for l in f if not l.startswith(("col.", "sec.ta_loaded\t", "tee.ta_", "drm.widevine_log_level\t"))]
        with open(p, "w") as f:
            f.write("\n".join(keep + lines) + "\n")
        print("updated %d collector rows in %s" % (len(lines), p))
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
