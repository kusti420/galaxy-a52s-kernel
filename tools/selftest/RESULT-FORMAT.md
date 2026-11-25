# Result format shared by tools/bench-app (A52 Kernel Bench) and tools/selftest

One run = one `results.json`:

    {
      "suite": "a52bench",            // or "selftest"
      "format": 1,
      "device": { "model": "...", "kernel": "6.12.81-...", "sdk": 37, "fingerprint": "..." , "has_vibrator": true },
      "selection": "all", "seconds": 0,
      "started_ms": 0, "finished_ms": 0,          // finished_ms missing = the run did not finish
      "pass": 0, "fail": 0, "skip": 0,
      "tests": [ <one object per test, in run order> ]
    }

One test = one JSON object (the app also logs it to logcat as `A52BENCH: RESULT {...}`):

    {
      "id": "gpu.render",             // <group>.<name>, stable across versions
      "status": "PASS" | "FAIL" | "SKIP",
      "reason": "one line: what was verified / what failed / why skipped",
      "seconds": 21.8,
      "numbers": { "offscreen_fps": 231.8, ... },   // flat, numeric only (null = not measurable); compared by compare.py
      "info": { "gl_renderer": "..." },             // flat strings, not compared
      "evidence": [ "gpu-render-offscreen.png" ],   // file names relative to the directory of results.json
      "notes": [ "..." ]
    }

Rules
- PASS only when the feature was driven for real and the measured output was verified. Otherwise FAIL (with evidence
  files and the measured values in `reason`/`numbers`) or SKIP (reason says what is missing: no network, no SD card...).
- A test that throws, overruns its budget (+15 s) or never sets a verdict is FAIL.
- While a test runs, results.json already holds a placeholder entry for it with status FAIL and reason
  "process died during this test"; it is replaced when the test ends. So a killed app or a reset phone leaves the
  culprit named in the file.
- Number keys are snake_case with the unit as suffix (`_fps`, `_ms`, `_mb_s`, `_hz`, `_db`, `_mb`, `_khz`).
- Host side adds next to results.json: `logcat.txt`, `kmsg-new.txt` (kernel lines during the run), `kbad.txt`
  (WARN/BUG/oops/kgsl OOM/SMMU fault lines among them; any line = the run fails).

Tools: `tools/bench-app/table.py results.json` prints the table (exit 1 on FAIL/incomplete),
`tools/bench-app/compare.py a/results.json b/results.json [min_pct]` diffs two runs.

## tools/selftest runs and the OneUI parity sweep

A selftest run directory (`logs/selftest/<serial>-<time>/`) holds `summary.txt` (header: time, serial, kernel, build,
root, profile), `table.txt` (`<id> PASS|FAIL|SKIP <detail>`), `metrics.tsv` (`name<TAB>value`) and per-test logs;
`mkjson.py` turns it into `results.json` (`tests: {id: {status, detail, evidence}}`, `metrics`), `compare.py <base> <new>`
diffs two of them.

`tools/selftest/oneui/sweep.sh <serial>` (also run by `run.sh --oneui`) adds the OneUI/Samsung rows. Phone-side
checks (`oneui/checks/*.sh`, run as root through `su -c`) print one TAB-separated line per row:

    CHECK <id> <PASS|FAIL|SKIP> <owner> <stable> <detail>
    METRIC <name> <number>

and the host stores them, minus the first column, in `<run>/oneui.tsv`; the same rows appear in `table.txt` with the
id prefixed `o.` so `results.json` and `compare.py` see them.

- `id`: `<area>.<name>`, stable across versions (`svc.vaultkeeper`, `perf.cpufreq_limit.react`, `quirk.bpf_ringbuf`).
- status: PASS = present and working on THIS kernel; FAIL = absent or broken on this kernel (expected for some rows on
  5.4, e.g. the ring buffer); SKIP = could not be checked (no root, not in MTP mode, tool missing).
- `owner`: who fixes a difference: `kernel`, `ROM`, `kernel+ROM`, `info`.
- `stable`: the value that must be equal on 5.4 and 6.12. `set: a b c` is a name set (report.py lists what is missing
  and what is extra on 6.12). Volatile evidence (labels, counts, temperatures, pids) goes into `detail`.
- Collector rows (`col.*`, from `oneui/collect.py` over the saved kernel log and logcat): `stable` is a count;
  report.py compares it numerically (higher on 6.12 = WORSE). The grouped lists are in `<run>/collectors.json` and
  `<run>/collect-*.txt`.
- Privacy: no IMEI/IMSI/ICCID/number/MAC/SSID/serial is printed (lengths and 12-hex-digit hashes only), runs of 14+
  digits are masked, the radio logcat buffer and the full property list are never saved.

`tools/selftest/oneui/report.py <5.4 run> <6.12 run>` writes `drivers612/ONEUI9-PARITY.md`
(feature / 5.4 / 6.12 / verdict / owner).
