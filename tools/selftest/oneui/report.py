#!/usr/bin/env python3
"""tools/selftest/oneui/report.py <5.4 run dir> [<6.12 run dir>] [-o drivers612/ONEUI9-PARITY.md] [--note "text"]

5.4-vs-6.12 OneUI 9 parity report from two sweep runs (tools/selftest/oneui/sweep.sh, or run.sh --oneui) on the
same phone. Reads <run>/oneui.tsv (id, status, owner, stable, detail), <run>/collectors.json and summary.txt and
writes a Markdown table: feature / 5.4 / 6.12 / verdict / owner, worst first, then what is NEW on 6.12 in the
collectors (avc signatures, failing sysfs paths, dying services, Freecess errors, kernel WARN lines).
With one run dir the 6.12 column is "pending" (baseline-only report).

Verdicts: REGRESSION (5.4 PASS, 6.12 FAIL) | MISSING (a name set lost entries on 6.12) | DIFFERENT (both PASS,
the stable value differs) | WORSE (a collector count went up) | broken on both | fixed on 6.12 | extra on 6.12 |
better | not compared (a SKIP, or the row exists on one side only) | parity.
Exit status 1 when there is any REGRESSION, MISSING or WORSE row, else 0."""
import json, os, re, sys

ORDER = ["REGRESSION", "MISSING", "WORSE", "DIFFERENT", "broken on both", "not compared", "pending",
         "fixed on 6.12", "extra on 6.12", "better", "parity"]
BAD = ("REGRESSION", "MISSING", "WORSE")


def load(run):
    rows, order = {}, []
    p = os.path.join(run, "oneui.tsv")
    if not os.path.exists(p):
        sys.exit("no oneui.tsv in %s (run tools/selftest/oneui/sweep.sh first)" % run)
    with open(p, errors="replace") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 4:
                continue
            c += [""] * (5 - len(c))
            if c[0] not in rows:
                order.append(c[0])
            rows[c[0]] = {"status": c[1], "owner": c[2], "stable": c[3], "detail": c[4]}
    head = {}
    try:
        with open(os.path.join(run, "summary.txt"), errors="replace") as f:
            txt = f.read()
        m = re.search(r"selftest (\S+ \S+)\s+serial (\S+)", txt)
        if m:
            head["time"], head["serial"] = m.group(1), m.group(2)
        m = re.search(r"^kernel (\S+)\s+build (.*)$", txt, re.M)
        if m:
            head["kernel"], head["build"] = m.group(1), m.group(2).strip()
        m = re.search(r"^root=(\S+)", txt, re.M)
        if m:
            head["root"] = m.group(1)
    except OSError:
        pass
    coll = {}
    try:
        with open(os.path.join(run, "collectors.json")) as f:
            coll = json.load(f)
    except (OSError, ValueError):
        pass
    return {"dir": run, "rows": rows, "order": order, "head": head, "coll": coll}


NOISE = re.compile(r"^(waiting_for_supplier|hwmon\d+|wakeup\d+)$")   # driver-core attrs / instance numbers, not interfaces


def setof(stable):
    return set(x for x in stable[4:].split() if not NOISE.match(x)) if stable.startswith("set:") else None


def notes():
    """tools/selftest/oneui/notes.tsv: <id><TAB><note>: hand-written remarks per row (tool limits, re-check rules)"""
    n = {}
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "notes.tsv")) as f:
            for l in f:
                p = l.rstrip("\n").split("\t", 1)
                if len(p) == 2 and not l.startswith("#"):
                    n[p[0]] = p[1]
    except OSError:
        pass
    return n


def verdict(i, a, b):
    """a = 5.4 row, b = 6.12 row (either may be None) -> (verdict, note)"""
    if b is None:
        return "not compared", "row only in the 5.4 run"
    if a is None:
        return "not compared", "row only in the 6.12 run"
    sa, sb = a["status"], b["status"]
    if i.startswith("col."):
        try:
            na, nb = int(a["stable"]), int(b["stable"])
        except ValueError:
            return "not compared", "collector value not numeric"
        if nb > na:
            return "WORSE", "%d -> %d" % (na, nb)
        return ("better", "%d -> %d" % (na, nb)) if nb < na else ("parity", "")
    if "SKIP" in (sa, sb):
        return "not compared", "SKIP on %s" % ("both" if sa == sb else "5.4" if sa == "SKIP" else "6.12")
    if sa == "PASS" and sb == "FAIL":
        return "REGRESSION", ""
    if sa == "FAIL" and sb == "PASS":
        return "fixed on 6.12", ""
    xa, xb = setof(a["stable"]), setof(b["stable"])
    if xa is not None and xb is not None:
        miss, extra = sorted(xa - xb), sorted(xb - xa)
        if miss:
            return "MISSING", "missing on 6.12: %s%s" % (" ".join(miss), ("; extra: " + " ".join(extra)) if extra else "")
        if extra:
            return "extra on 6.12", "extra: " + " ".join(extra)
        return ("parity", "") if sa == "PASS" else ("broken on both", "")
    if sa == "FAIL":
        return "broken on both", "" if a["stable"] == b["stable"] else "values differ"
    if a["stable"] != b["stable"]:
        return "DIFFERENT", ""
    return "parity", ""


def cell(r, n=110):
    if r is None:
        return "-"
    s = r["stable"]
    x = setof(s)
    if x is not None:
        s = "%d names" % len(x)
    elif not s:
        s = r["detail"]
    s = s.replace("|", "\\|").replace("\n", " ")
    return "%s: %s" % (r["status"], s if len(s) <= n else s[:n - 1] + "…")


def newkeys(a, b, key, n=40):
    da, db = a["coll"].get(key) or {}, b["coll"].get(key) or {}
    if isinstance(db, list):
        return [(k, 1) for k in db if k not in set(da)][:n]
    return sorted(((k, v) for k, v in db.items() if k not in da), key=lambda kv: -kv[1])[:n]


def main():
    args = sys.argv[1:]
    out = None
    remark = None
    if "--note" in args:
        k = args.index("--note")
        remark = args[k + 1]
        del args[k:k + 2]
    if "-o" in args:
        k = args.index("-o")
        out = args[k + 1]
        del args[k:k + 2]
    if len(args) not in (1, 2) or not all(os.path.isdir(a) for a in args):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
    out = out or os.path.join(repo, "drivers612", "ONEUI9-PARITY.md")
    a = load(args[0])
    b = load(args[1]) if len(args) == 2 else None
    ka = a["head"].get("kernel", "?")
    kb = b["head"].get("kernel", "?") if b else None
    warn = []
    if not ka.startswith("5.4"):
        warn.append("the first run is kernel %s, not 5.4" % ka)
    if b and not kb.startswith("6."):
        warn.append("the second run is kernel %s, not 6.x" % kb)
    if b and a["head"].get("serial") != b["head"].get("serial"):
        warn.append("the runs are from different phones (%s vs %s)" % (a["head"].get("serial"), b["head"].get("serial")))
    if b and a["head"].get("build") != b["head"].get("build"):
        warn.append("ROM builds differ: differences may be ROM-side (%s vs %s)" % (a["head"].get("build"), b["head"].get("build")))
    for r in (a, b):
        if r and r["head"].get("root") == "none":
            warn.append("run %s had no root: most rows are SKIP" % os.path.basename(r["dir"]))
    global NOTES
    NOTES = notes()
    ids = list(a["order"]) + ([i for i in b["order"] if i not in a["rows"]] if b else [])
    table = []
    for i in ids:
        ra, rb = a["rows"].get(i), (b["rows"].get(i) if b else None)
        v, note = ("pending", "") if b is None else verdict(i, ra, rb)
        owner = (rb or ra)["owner"]
        if i in NOTES:
            note = (note + "; " if note else "") + "NOTE: " + NOTES[i]
        table.append((ORDER.index(v), i, ra, rb, v, note, owner))
    counts = {}
    for t in table:
        counts[t[4]] = counts.get(t[4], 0) + 1
    L = []
    L.append("# OneUI 9 on 6.12: parity with the 5.4 kernel (same phone, same ROM)\n")
    L.append("Generated by `tools/selftest/oneui/report.py` from two runs of `tools/selftest/oneui/sweep.sh`. Do not edit by")
    L.append("hand: rerun the sweep and the report. Every cell is what the sweep measured in that run; nothing here is")
    L.append("inferred. PASS/FAIL in a cell is that kernel's own result; the verdict column is the comparison.\n")
    L.append("| | 5.4 baseline | 6.12 |")
    L.append("|---|---|---|")
    L.append("| run | `%s` | %s |" % (os.path.relpath(a["dir"], repo), ("`%s`" % os.path.relpath(b["dir"], repo)) if b else "pending (no 6.12 run yet)"))
    L.append("| kernel | %s | %s |" % (ka, kb or "-"))
    L.append("| ROM build | %s | %s |" % (a["head"].get("build", "?"), b["head"].get("build", "?") if b else "-"))
    L.append("| time | %s | %s |" % (a["head"].get("time", "?"), b["head"].get("time", "?") if b else "-"))
    L.append("| root | %s | %s |" % (a["head"].get("root", "?"), b["head"].get("root", "?") if b else "-"))
    L.append("")
    for r, tag in ((a, "5.4"), (b, "6.12")):   # ROM version of each run (props.txt), so a ROM delta is visible
        try:
            with open(os.path.join(r["dir"], "props.txt")) as f:
                m = re.search(r"\[ro\.build\.display\.id\]: \[([^\]]*)\]", f.read())
            if m:
                L.append("%s run ROM: %s  " % (tag, m.group(1)))
        except (OSError, TypeError):
            pass
    L.append("")
    if remark:
        L.append("**Note: %s**\n" % remark)
    for w in warn:
        L.append("**WARNING: %s.**\n" % w)
    L.append("## Summary\n")
    L.append(", ".join("%s: %d" % (v, counts[v]) for v in ORDER if v in counts) + " (of %d rows).\n" % len(table))
    L.append("Owner = who fixes a difference: kernel (this repo), ROM (the OneUI 9 port, ~/git/MonsterROM), kernel+ROM (decide")
    L.append("after reading the evidence), info (not a defect by itself).\n")

    def emit(title, rows, with_note=True):
        if not rows:
            return
        L.append("## %s\n" % title)
        L.append("| feature | 5.4 | 6.12 | verdict | someone at the phone |")
        L.append("|---|---|---|---|---|")
        for _, i, ra, rb, v, note, owner in rows:
            vv = v + ((": " + note.replace("|", "\\|")[:400]) if (note and with_note) else "")
            L.append("| `%s` | %s | %s | %s | %s |" % (i, cell(ra), cell(rb) if b else "pending", vv, owner))
        L.append("")

    table.sort(key=lambda t: (t[0], ids.index(t[1])))
    if b:
        emit("Needs work (regressions, missing interfaces, worse counts)", [t for t in table if t[4] in BAD])
        emit("Different values (both kernels pass their own check: read the evidence)", [t for t in table if t[4] == "DIFFERENT"])
        emit("Broken on both kernels (not a 6.12 regression)", [t for t in table if t[4] == "broken on both"])
        emit("Not compared (SKIP on one side, or a row that exists on one side only)", [t for t in table if t[4] == "not compared"])
        emit("Better on 6.12", [t for t in table if t[4] in ("fixed on 6.12", "extra on 6.12", "better")])
        emit("Parity", [t for t in table if t[4] == "parity"], False)
        L.append("## New on 6.12 in the collectors (not present in the 5.4 run)\n")
        any_new = False
        for key, title in (("avc", "SELinux denial signatures"), ("path_failures", "sysfs/proc/dev paths userspace failed to open"),
                           ("svc_abnormal_exits", "init services exiting abnormally"), ("svc_start_counts_4plus", "services started 4+ times"),
                           ("fatal", "fatal crashes"), ("tombstone_cmdlines", "tombstones by command line"),
                           ("freecess_errors", "FreecessHandler / MARs errors"), ("vaultkeeper_errors", "vaultkeeper / CASS warning+error lines"), ("kernel_bad", "kernel WARN/BUG/error lines"),
                           ("qseecom_errors", "QSEECOM / smcinvoke errors"), ("avc_kernel_side", "kernel-side (unlabelled) denial signatures")):
            nk = newkeys(a, b, key)
            if not nk:
                continue
            any_new = True
            L.append("### %s (%d new%s)\n" % (title, len(nk), ", top 40" if len(nk) == 40 else ""))
            L.append("```")
            for k, v in nk:
                L.append("%5d  %s" % (v, k[:230]))
            L.append("```\n")
        if not any_new:
            L.append("Nothing new: every grouped signature of the 6.12 run is also in the 5.4 run.\n")
        gone = sorted(set(a["coll"].get("ta_loaded") or []) - set(b["coll"].get("ta_loaded") or []))
        if gone:
            L.append("TAs with a QSEECOM load line on 5.4 but not on 6.12 (the kernel log rolls over: confirm soon after boot): %s\n" % " ".join(gone))
    else:
        emit("5.4 baseline (6.12 pending)", table)
    L.append("## How to rerun\n")
    L.append("    tools/selftest/oneui/sweep.sh PHONE1            # on 5.4, then again on 6.12 (read-mostly, silent)")
    L.append("    tools/selftest/oneui/report.py <5.4 run dir> <6.12 run dir>")
    L.append("")
    with open(out, "w") as f:
        f.write("\n".join(L))
    if b:  # the rows that differ, for a quick message
        for _, i, ra, rb, v, note, owner in table:
            if v not in ("parity", "pending"):
                print("%-14s %-34s 5.4 %s | 6.12 %s%s [%s]" % (v, i, cell(ra, 60), cell(rb, 60), (" | " + note[:330]) if note else "", owner))
    print("%s: %s" % (os.path.relpath(out, repo), ", ".join("%s %d" % (v, counts[v]) for v in ORDER if v in counts)))
    return 1 if any(v in counts for v in BAD) else 0


if __name__ == "__main__":
    sys.exit(main())
