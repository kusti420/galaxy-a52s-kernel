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
