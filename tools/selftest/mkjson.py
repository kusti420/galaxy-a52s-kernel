#!/usr/bin/env python3
"""tools/selftest/mkjson.py <rundir>: turn one self-test run directory into <rundir>/results.json.

Reads summary.txt (header lines written by run.sh), table.txt (id, result, detail), metrics.tsv
(name<TAB>value; the last value wins; numeric when possible) and hands-on.txt. Missing files are fine.
results.json: {serial, time, kernel, build, quick, root, klog, sim, tests: {id: {status, detail,
evidence: [files <rundir>/<id>.*]}}, metrics: {...}, hands_on: [...]}. compare.py reads these."""
import glob, json, os, re, sys


def read(path):
    try:
        with open(path, errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def numeric(v):
    v = v.strip()
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def build(run):
    run = os.path.abspath(run)
    out = {"serial": None, "time": None, "kernel": None, "build": None, "quick": None, "root": None,
           "klog": None, "sim": None, "rundir": run, "tests": {}, "metrics": {}, "hands_on": []}
    for line in read(os.path.join(run, "summary.txt"))[:8]:
        m = re.match(r"selftest (\S+ \S+)\s+serial (\S+)\s+quick=(\d)", line)
        if m:
            out["time"], out["serial"], out["quick"] = m.group(1), m.group(2), int(m.group(3))
        m = re.match(r"kernel (\S+)\s+build (.*)", line)
        if m:
            out["kernel"], out["build"] = m.group(1), m.group(2).strip()
        m = re.match(r"root=(\S+) klog=(\S+) sim=(\d)", line)
        if m:
            out["root"], out["klog"], out["sim"] = m.group(1), m.group(2), int(m.group(3))
    if out["serial"] is None:  # fall back to the directory name <serial>-<date>-<time>
        m = re.match(r"(.+)-(\d{8})-(\d{6})$", os.path.basename(run))
        if m:
            out["serial"] = m.group(1)
            d, t = m.group(2), m.group(3)
            out["time"] = "%s-%s-%s %s:%s:%s" % (d[:4], d[4:6], d[6:], t[:2], t[2:4], t[4:])
    for line in read(os.path.join(run, "table.txt")):
        m = re.match(r"(\S+)\s+(PASS|FAIL|SKIP)\s*(.*)", line)
        if not m:
            continue
        tid = m.group(1)
        ev = sorted(os.path.basename(p) for p in glob.glob(os.path.join(run, glob.escape(tid) + ".*"))
                    if os.path.getsize(p) > 0)
        out["tests"][tid] = {"status": m.group(2), "detail": m.group(3).strip(), "evidence": ev}
    for line in read(os.path.join(run, "metrics.tsv")):
        if "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        if k.strip():
            out["metrics"][k.strip()] = numeric(v)
    out["hands_on"] = sorted({l.strip() for l in read(os.path.join(run, "hands-on.txt")) if l.strip()})
    c = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for t in out["tests"].values():
        c[t["status"]] += 1
    out["totals"] = c
    return out


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    res = build(sys.argv[1])
    path = os.path.join(sys.argv[1], "results.json")
    with open(path, "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    print("%s: %d tests (%d PASS, %d FAIL, %d SKIP), %d metrics" % (
        path, len(res["tests"]), res["totals"]["PASS"], res["totals"]["FAIL"], res["totals"]["SKIP"],
        len(res["metrics"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
