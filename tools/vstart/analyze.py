#!/usr/bin/env python3
"""Video-start stutter analyzer for atrace captures (offline, stdlib only).

Usage:
  analyze.py RUN.trace            one compact block for one run
  analyze.py DIR [DIR ...]        per-config summary (median over runs) for
                                  every <codec>-<n>.trace in each DIR
  analyze.py -v DIR               also print the per-run blocks

Inputs per run (same stem): <stem>.trace (atrace text, optional "TRACE:"
header, zlib/gzip compressed is fine), <stem>-logcat.txt (threadtime),
<stem>-amstart.txt.

t0 definition
  t0 = task_newtask of the player process (zygote fork of the pid that owns
  the com.samsung.android.video threads; cold start).  If no fork is in the
  trace (warm start), t0 = first trace event of that process.  All "+ms"
  values are relative to t0.  "intent" is the logcat ActivityStarter /
  "START u0" line mapped to trace time (usually 20-30 ms before t0).

Logcat -> trace mapping
  atrace writes trace_event_clock_sync realtime_ts=<epoch ms> at
  parent_ts=<trace s>.  The logcat local-time offset (timezone) is the
  difference rounded to 15 min.  Checked by matching the logcat
  "SurfaceView ... first frame is available" line against the trace's
  first SurfaceView onFrameAvailable ("map err").  Fallback without
  clock_sync: align on that first-frame pair.

Video frames
  Q = producer side: "onFrameAvailable - <..SurfaceView..>" slices in the
      app (codec renderOutputBuffer -> BLAST queue).
  L = consumer side: surfaceflinger "latchBuffer <..SurfaceView..(BLAST)..>"
      (what reaches the screen; gaps here are visible stutter).
  first video frame = first Q event.  Windows: [ff, ff+2s] and
  [ff+2s, ff+4s] clipped to the trace end (coverage printed).
"""
import collections
import datetime
import gzip
import os
import re
import statistics
import sys
import zlib

APP_PKG = "com.samsung.android.video"
APP_COMM_HINT = "g.android.video"        # 15-char truncated comm
CLUSTERS = (("silver", (0, 1, 2, 3)), ("gold", (4, 5, 6)), ("prime", (7,)))
VIDEO_CODEC_RE = re.compile(
    r"c2\.[\w.]*?(avc|hevc|h264|h265|vp8|vp9|av1|h263|mpeg2|mpeg4|dolby)[\w.]*", re.I)
ALLOC_RE = re.compile(r"(?i:alloc|dma_?buf|dma_?heap|gralloc)|\bion\b|libion|\bION\b")
CLK_RE = re.compile(r"(?i)video_cc|mvs|iris|venus|vidc|ddr|bimc|llcc|gpu_cc|gfx3d|gmu|"
                    r"\bbw\b|_bw|memlat|cpubw|cdsp|mnoc|snoc")

LINE_RE = re.compile(
    r"^\s*(?P<comm>.+?)-(?P<tid>\d+)\s+(?:\(\s*(?P<tgid>[\d-]+)\)\s+)?"
    r"\[(?P<cpu>\d+)\]\s+(?:\S+\s+)?(?P<ts>\d+\.\d+):\s+(?P<ev>\w+):\s?(?P<args>.*)$")
KV_RE = re.compile(r"(\w+)=(\S+)")


# ----------------------------------------------------------------- loading
def read_trace_text(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    i = raw.find(b"TRACE:\n", 0, 4096)
    if i >= 0:
        body = raw[i + 7:]
        if body[:1] == b"\x78":                 # atrace -z (zlib)
            try:
                body = zlib.decompress(body)
            except zlib.error:
                pass
        raw = body
    return raw.decode("utf-8", "replace")


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = (len(s) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


class Trace:
    def __init__(self, path):
        self.sched_tids = collections.defaultdict(list)   # tid -> [ts] switch-in
        self.tid2tgid = {}
        self.comm = {}                 # tid -> last comm
        self.freq = collections.defaultdict(list)          # cpu -> [(ts, khz)]
        self.idle = collections.defaultdict(list)          # cpu -> [(ts, state)]
        self.freq_limits = []          # (ts, cpu, min, max)
        self.clk = []                  # (ts, name, rate)
        self.slices = []               # (tid, tgid, start, dur, name, depth)
        self.instants = []             # (ts, tid, tgid, name)
        self.binder = []               # (start, dur, ctid, ctgid, dproc, code, flags)
        self.newtask = {}              # pid -> (ts, parent tgid, comm)
        self.clock_sync = None         # (trace_s, realtime_ms)
        self.first_ts = self.last_ts = None
        self.first_by_tgid = {}
        self._parse(read_trace_text(path))

    def _parse(self, text):
        stacks = collections.defaultdict(list)
        pend_binder = {}               # client tid -> [(start, tid, tgid, dproc, code, flags)]
        parent_ts = None
        for line in text.splitlines():
            if not line or line[0] == "#":
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            ts = float(m.group("ts"))
            tid = int(m.group("tid"))
            tg = m.group("tgid")
            tgid = int(tg) if tg and tg.isdigit() else None
            if tgid is not None and tid:
                self.tid2tgid[tid] = tgid
                self.first_by_tgid.setdefault(tgid, ts)
            if tid:
                self.comm[tid] = m.group("comm").strip()
            if self.first_ts is None:
                self.first_ts = ts
            self.last_ts = ts
            ev = m.group("ev")
            a = m.group("args")
            if ev == "tracing_mark_write":
                if a.startswith("trace_event_clock_sync:"):
                    if "parent_ts=" in a:
                        parent_ts = float(a.split("parent_ts=")[1])
                    elif "realtime_ts=" in a and parent_ts is not None:
                        self.clock_sync = (parent_ts, int(a.split("realtime_ts=")[1]))
                    continue
                p = a.split("|", 3)
                k = p[0]
                if k == "B" and len(p) >= 3:
                    name = "|".join(p[2:])
                    stacks[tid].append((ts, name))
                elif k == "E":
                    st = stacks.get(tid)
                    if st:
                        s, name = st.pop()
                        self.slices.append((tid, tgid, s, ts - s, name, len(st)))
                elif k == "I" and len(p) >= 3:
                    self.instants.append((ts, tid, tgid, p[2]))
            elif ev == "sched_switch":
                kv = dict(KV_RE.findall(a.replace(" ==> ", " ")))
                np = int(kv.get("next_pid", 0))
                if np:
                    self.sched_tids[np].append(ts)
                    self.comm.setdefault(np, kv.get("next_comm", "?"))
            elif ev == "cpu_frequency":
                kv = dict(KV_RE.findall(a))
                self.freq[int(kv["cpu_id"])].append((ts, int(kv["state"])))
            elif ev == "cpu_idle":
                kv = dict(KV_RE.findall(a))
                st = int(kv["state"])
                self.idle[int(kv["cpu_id"])].append((ts, -1 if st >= 2**31 else st))
            elif ev == "cpu_frequency_limits":
                kv = dict(KV_RE.findall(a))
                self.freq_limits.append((ts, int(kv["cpu_id"]), int(kv["min"]), int(kv["max"])))
            elif ev == "clk_set_rate":
                f = a.split()
                if len(f) >= 2 and CLK_RE.search(f[0]):
                    self.clk.append((ts, f[0], int(f[1])))
            elif ev in ("devfreq_frequency", "devfreq_monitor", "bw_hwmon_update",
                        "memlat_dev_update", "bw_hwmon_meas", "gpu_frequency",
                        "kgsl_pwrlevel", "kgsl_buslevel", "kgsl_gpubusy", "icc_set_bw"):
                self.clk.append((ts, ev + ":" + a[:60], None))
            elif ev == "task_newtask":
                kv = dict(KV_RE.findall(a))
                self.newtask[int(kv["pid"])] = (ts, tgid, kv.get("comm"))
            elif ev == "binder_transaction":
                kv = dict(KV_RE.findall(a))
                flags = int(kv.get("flags", "0"), 16)
                if kv.get("reply") == "1":
                    dt = int(kv.get("dest_thread", 0))
                    st = pend_binder.get(dt)
                    if st:
                        s = st.pop()
                        self.binder.append((s[0], ts - s[0], s[1], s[2], s[3], s[4], s[5],
                                            tid))
                elif not flags & 1:                         # not oneway
                    pend_binder.setdefault(tid, []).append(
                        (ts, tid, tgid, int(kv.get("dest_proc", 0)), kv.get("code"), flags))
        for tid, st in stacks.items():                      # unclosed slices
            for depth, (s, name) in enumerate(st):
                self.slices.append((tid, self.tid2tgid.get(tid), s, self.last_ts - s,
                                    name + " [open]", depth))

    def pname(self, tgid):
        if tgid is None:
            return "?"
        c = self.comm.get(tgid)
        if c:
            return c
        names = [self.comm[t] for t, g in self.tid2tgid.items() if g == tgid and t in self.comm]
        return collections.Counter(names).most_common(1)[0][0] if names else str(tgid)


# ----------------------------------------------------------------- logcat
LOGCAT_RE = re.compile(r"^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3})\s+(\d+)\s+(\d+)\s+\w\s+(.*)$")


def read_logcat(path, year):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        m = LOGCAT_RE.match(line.strip())
        if not m:
            continue
        mo, d, H, M, S, ms, pid, tid, msg = m.groups()
        naive = datetime.datetime(year, int(mo), int(d), int(H), int(M), int(S),
                                  int(ms) * 1000, tzinfo=datetime.timezone.utc).timestamp()
        out.append((naive, int(pid), int(tid), msg))
    return out


def read_amstart(path):
    r = {}
    if os.path.exists(path):
        for line in open(path, errors="replace"):
            m = re.match(r"\s*(TotalTime|WaitTime|ThisTime|LaunchState):\s*(\S+)", line)
            if m:
                r[m.group(1)] = m.group(2)
    return r


# ----------------------------------------------------------------- analysis
def tw_stats(series, a, b):
    """time-weighted mean/max of a step series [(ts,val)] over [a,b]; None-safe."""
    if b <= a or not series:
        return None
    cur = None
    for ts, v in series:
        if ts <= a:
            cur = v
        else:
            break
    tot = w = 0.0
    mx = cur
    t = a
    for ts, v in series:
        if ts <= a:
            continue
        if ts >= b:
            break
        if cur is not None:
            tot += cur * (ts - t)
            w += ts - t
        cur, t = v, ts
        mx = v if mx is None else max(mx, v)
    if cur is not None:
        tot += cur * (b - t)
        w += b - t
    return (tot / w if w else None, mx, w / (b - a))


def time_at(series, a, b, pred):
    cur = None
    for ts, v in series:
        if ts <= a:
            cur = v
    t, acc, known = a, 0.0, 0.0
    for ts, v in series:
        if ts <= a:
            continue
        if ts >= b:
            break
        if cur is not None:
            known += ts - t
            if pred(cur):
                acc += ts - t
        cur, t = v, ts
    if cur is not None:
        known += b - t
        if pred(cur):
            acc += b - t
    return acc / known if known else None


def frame_stats(times, a, b):
    ts = [t for t in times if a <= t < b]
    iv = [(y - x) * 1000 for x, y in zip(ts, ts[1:])]
    return {"n": len(ts), "p50": pct(iv, 50), "p90": pct(iv, 90),
            "max": max(iv) if iv else None,
            "g50": sum(1 for i in iv if i > 50), "g100": sum(1 for i in iv if i > 100),
            "cov": max(0.0, b - a)}


def analyze(trace_path):
    stem = trace_path[:-len(".trace")] if trace_path.endswith(".trace") else trace_path
    tr = Trace(trace_path)
    year = datetime.datetime.now().year
    if tr.clock_sync:
        year = datetime.datetime.fromtimestamp(tr.clock_sync[1] / 1000,
                                               datetime.timezone.utc).year
    lc = read_logcat(stem + "-logcat.txt", year)
    am = read_amstart(stem + "-amstart.txt")
    R = {"name": os.path.basename(stem), "am": am, "notes": []}

    # --- app pid
    app = None
    for _, pid, _, msg in lc:
        if "MoviePlayer" in msg and ("BLASTBufferQueue" in msg or "MediaCodec" in msg
                                     or "CCodec" in msg):
            app = pid
            break
    if app is None:
        for _, pid, _, msg in lc:
            if msg.startswith(("CCodec", "MediaCodec")):
                app = pid
                break
    if app is None:
        c = collections.Counter(g for t, g in tr.tid2tgid.items()
                                if tr.comm.get(t, "").endswith(APP_COMM_HINT))
        app = c.most_common(1)[0][0] if c else None
    R["app"] = app
    if app is None:
        R["notes"].append("player process not found")
        return R, tr
    if app in tr.newtask:
        t0, src = tr.newtask[app][0], "fork"
    else:
        t0, src = tr.first_by_tgid.get(app, tr.first_ts), "first-event"
    R["t0"], R["t0src"] = t0, src
    R["span"] = (tr.last_ts - t0)

    # --- video frames
    sv = lambda n: "SurfaceView" in n and APP_PKG in n
    q = sorted(s for tid, g, s, d, n, dep in tr.slices
               if g == app and n.startswith("onFrameAvailable - ") and sv(n))
    lat = sorted(ts for ts, tid, g, n in tr.instants
                 if n.startswith("latchBuffer ") and sv(n))
    ff = q[0] if q else None
    R["ff"] = ff

    # --- logcat mapping
    off = None
    lc_ff = next((t for t, p, _, m in lc if "SurfaceView" in m and
                  "first frame is available" in m and p == app), None)
    if tr.clock_sync and lc:
        ps, rt = tr.clock_sync
        diffs = sorted(t - rt / 1000.0 for t, _, _, _ in lc)
        tz = round(diffs[len(diffs) // 2] / 900.0) * 900
        off = tz + rt / 1000.0 - ps        # logcat_naive - off = trace ts
        R["mapsrc"] = "clock_sync tz=%+.2fh" % (tz / 3600)
    elif lc_ff is not None and ff is not None:
        off = lc_ff - ff
        R["mapsrc"] = "first-frame align"
    if off is not None:
        tmap = lambda t: t - off
        R["maperr"] = (tmap(lc_ff) - ff) * 1000 if (lc_ff is not None and ff) else None
        ev = {}
        for t, pid, tid, msg in lc:
            mt = tmap(t)
            if "intent" not in ev and ("MoviePlayer" in msg and
                                       ("START u0" in msg or "Collecting in transition" in msg)):
                ev["intent"] = mt
            m = re.search(r"Displayed .*MoviePlayer.*\+(\S+)", msg)
            if m and "displayed" not in ev:
                ev["displayed"] = mt
                R["displayed_str"] = m.group(1)
            m = re.search(r"allocate\((c2[^)]*)\)", msg)
            if m and VIDEO_CODEC_RE.search(m.group(1)) and "alloc" not in ev:
                ev["alloc"] = mt
                R["vcodec"] = m.group(1)
            vc = R.get("vcodec")
            if vc and ("[%s] state->set(STARTING)" % vc) in msg and "starting" not in ev:
                ev["starting"] = mt
            if vc and ("[%s] state->set(RUNNING)" % vc) in msg and "running" not in ev:
                ev["running"] = mt
            if "SurfaceView" in msg and "first frame is available" in msg and "lc_ff" not in ev:
                ev["lc_ff"] = mt
        R["lcev"] = ev
    if "vcodec" not in R:
        m = next((VIDEO_CODEC_RE.search(n) for _, _, _, _, n, _ in tr.slices
                  if "renderOutputBuffer(" in n), None)
        if m:
            R["vcodec"] = m.group(0)

    # --- frame windows
    end = tr.last_ts
    if ff is not None:
        R["fq"] = [frame_stats(q, ff, min(ff + 2, end)), frame_stats(q, ff + 2, min(ff + 4, end))]
        R["fl"] = [frame_stats(lat, ff, min(ff + 2, end)),
                   frame_stats(lat, ff + 2, min(ff + 4, end))]
        # gap locations (Q side) relative to ff, ms
        R["gaps"] = [((x - ff) * 1000, (y - x) * 1000) for x, y in zip(q, q[1:])
                     if y - x > 0.05 and x < ff + 4]
        # desired present times the player passed to renderOutputBuffer(@ts=): a gap
        # here was scheduled by the player (preroll / AV sync), not a decode stall
        dts = sorted(int(m.group(1)) / 1e9 for _, g, _, _, n, _ in tr.slices if g == app
                     for m in [re.search(r"renderOutputBuffer\(c2[^@]*@ts=(\d+)", n)] if m)
        R["pgaps"] = [((x - ff) * 1000, (y - x) * 1000) for x, y in zip(dts, dts[1:])
                      if y - x > 0.05 and x < ff + 4]

    # --- cpu freq / idle
    wins = [(t0, t0 + 1), (t0 + 1, t0 + 2), (t0 + 2, t0 + 4)]
    R["wins"] = [(min(a, end), min(b, end)) for a, b in wins]
    cl = {}
    for cname, cpus in CLUSTERS:
        cpu = next((c for c in cpus if tr.freq.get(c)), cpus[0])
        ser = list(tr.freq.get(cpu, []))
        # a min==max cpu_frequency_limits event pins the clock without any
        # cpu_frequency event (prime during the launch boost): use it as a point
        ser += [(ts, mn) for ts, c, mn, mx in tr.freq_limits if c in cpus and mn == mx]
        ser.sort()
        lo = min((v for _, v in ser), default=None)
        rows = []
        for a, b in R["wins"]:
            st = tw_stats(ser, a, b)
            fl = time_at(ser, a, b, lambda v: v == lo) if lo is not None else None
            idl = [time_at(tr.idle.get(c, []), a, b, lambda v: v >= 0) for c in cpus]
            idl = [x for x in idl if x is not None]
            rows.append((st, fl, statistics.mean(idl) if idl else None))
        cl[cname] = {"lo": lo, "hi": max((v for _, v in ser), default=None), "rows": rows}
    R["cpu"] = cl
    R["limits"] = [((ts - t0) * 1000, c, mn, mx) for ts, c, mn, mx in tr.freq_limits]

    # --- clocks / bus
    R["clk"] = [((ts - t0) * 1000, n, r) for ts, n, r in tr.clk]

    # --- alloc slices
    al = [(s, d, n, g) for tid, g, s, d, n, dep in tr.slices if ALLOC_RE.search(n)]
    groups = collections.defaultdict(list)
    for s, d, n, g in al:
        key = re.sub(r"\d+", "#", n)[:48] + " @" + tr.pname(g)[:16]
        groups[key].append((d * 1000, (s - t0) * 1000))
    R["alloc"] = sorted(((k, len(v), sum(x for x, _ in v), max(v)) for k, v in groups.items()),
                        key=lambda r: -r[2])
    R["alloc_tot"] = sum(d for _, d, _, _ in al) * 1000
    R["alloc_wait"] = sum(d for _, d, n, _ in al if "wait" in n.lower()) * 1000

    # --- binder > 10 ms involving app / media
    media = set()
    for _, pid, _, msg in lc:
        if re.match(r"(QC2|C2Soft|C2Comp|Codec2|QCodec|Venus|vidc)", msg):
            media.add(pid)
    for t, g in tr.tid2tgid.items():
        c = tr.comm.get(t, "")
        if re.match(r"(EvtQ_|C2Comp|media|vendor\.qti\.med|android\.hardwar.*media)", c) \
                and g != app:
            media.add(g)
    media.discard(None)
    R["media"] = {g: tr.pname(g) for g in sorted(media)}
    inv = media | {app}
    bl = []
    for s, d, ctid, ctg, dproc, code, flags, stid in tr.binder:
        if d > 0.010 and s >= t0 and (ctg in inv or dproc in inv):
            bl.append((d * 1000, (s - t0) * 1000, tr.comm.get(ctid, str(ctid)),
                       tr.pname(ctg), tr.pname(dproc), code))
    R["binder"] = sorted(bl, reverse=True)

    # --- main thread long slices in [t0, t0+2]
    ml = [(d * 1000, (s - t0) * 1000, n, dep) for tid, g, s, d, n, dep in tr.slices
          if tid == app and t0 <= s < t0 + 2 and d > 0.016]
    R["main"] = sorted(ml, reverse=True)
    return R, tr


# ----------------------------------------------------------------- output
def f(v, fmt="%.0f", na="-"):
    return na if v is None else fmt % v


def rel(R, t):
    return None if t is None else (t - R["t0"]) * 1000


def mhz(k):
    return None if k is None else k / 1000.0


def print_run(R):
    p = print
    am = R["am"]
    p("== %s  app=%s  t0=%s(%s)  trace covers t0..+%s ms  am Total/Wait=%s/%s %s" % (
        R["name"], R.get("app"), f(R.get("t0"), "%.6f"), R.get("t0src"),
        f(R.get("span", 0) * 1000), am.get("TotalTime", "-"), am.get("WaitTime", "-"),
        am.get("LaunchState", "")))
    if "t0" not in R:
        p("  " + "; ".join(R["notes"]))
        return
    ev = R.get("lcev", {})
    p("  logcat (%s, map err %s ms): intent %s  alloc(%s) %s  STARTING %s  RUNNING %s"
      "  Displayed %s (+%s)  first frame %s; trace first frame %s" % (
          R.get("mapsrc", "none"), f(R.get("maperr"), "%.1f"), f(rel(R, ev.get("intent"))),
          R.get("vcodec", "?"), f(rel(R, ev.get("alloc"))), f(rel(R, ev.get("starting"))),
          f(rel(R, ev.get("running"))), f(rel(R, ev.get("displayed"))),
          R.get("displayed_str", "-"), f(rel(R, ev.get("lc_ff"))), f(rel(R, R.get("ff")))))
    if R.get("ff") is not None:
        for tag, key in (("Q", "fq"), ("L", "fl")):
            s = []
            for lab, w in zip(("ff..+2s", "+2..+4s"), R[key]):
                s.append("%s[%.1fs] n=%d p50/p90/max=%s/%s/%s >50=%d >100=%d" % (
                    lab, w["cov"], w["n"], f(w["p50"], "%.1f"), f(w["p90"], "%.1f"),
                    f(w["max"]), w["g50"], w["g100"]))
            p("  frames %s: %s" % (tag, " | ".join(s)))
        if R["gaps"]:
            p("  Q gaps>50ms (at+ms:len): " + " ".join(
                "%.0f:%.0f" % g for g in R["gaps"][:10]) + "   planned by player (render ts): "
              + (" ".join("%.0f:%.0f" % g for g in R["pgaps"][:10]) or "none"))
    p("  cpu MHz mean/max lo% idle%  [t0,+1] [+1,+2] [+2,+4]   (lo = min seen)")
    for cname, c in R["cpu"].items():
        cells = []
        for st, fl, idl in c["rows"]:
            mean, mx = (st[0], st[1]) if st else (None, None)
            cells.append("%5s/%-5s %3s%% %3s%%" % (f(mhz(mean)), f(mhz(mx)),
                                                  f(fl and fl * 100), f(idl and idl * 100)))
        p("   %-6s lo=%-5s %s" % (cname, f(mhz(c["lo"])), " | ".join(cells)))
    if R["limits"]:
        p("  freq limits: " + " ".join("%+.0f cpu%d %s-%s" % (t, c, f(mhz(a)), f(mhz(b)))
                                       for t, c, a, b in R["limits"][:8]))
    vc = [(t, n, r) for t, n, r in R["clk"] if r is not None and "core_clk" in n
          and ("mvs0" in n or "vidc" in n or "venus" in n)]
    oth = [(t, n, r) for t, n, r in R["clk"] if not (r is not None and
                                                     re.search(r"video_cc|video_pll", n))]
    p("  video core clk: " + (" ".join("+%.0f %s MHz" % (t, f(r / 1e6))
                                       for t, n, r in vc) or "no events"))
    if oth:
        c = collections.Counter(re.sub(r"\d+", "#", n)[:40] for _, n, _ in oth)
        p("  other clk/bus/gpu: " + ", ".join("%s x%d" % kv for kv in c.most_common(5)))
    else:
        p("  other clk/bus/gpu: none (no devfreq/bw/gpu_frequency events in trace)")
    p("  alloc slices: total %.1f ms (wait %.1f ms); top:" % (R["alloc_tot"], R["alloc_wait"]))
    for k, n, tot, (mx, at) in R["alloc"][:5]:
        p("    %-66s n=%-3d tot=%6.1f max=%5.1f@+%.0f" % (k, n, tot, mx, at))
    p("  binder >10ms (app/media; media=%s): %d" % (
        ",".join("%d:%s" % kv for kv in R["media"].items()), len(R["binder"])))
    for d, at, cth, cp, dp, code in R["binder"][:5]:
        p("    %5.1f ms @+%.0f %s(%s) -> %s code=%s" % (d, at, cth[:16], cp[:16], dp[:16], code))
    p("  main thread >16ms in [t0,+2s]: %d, sum(top-level) %.0f ms" % (
        len(R["main"]), sum(d for d, _, _, dep in R["main"] if dep == 0)))
    for d, at, n, dep in R["main"][:6]:
        p("    %5.1f ms @+%-5.0f d%d %s" % (d, at, dep, n[:70]))


def med(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def print_summary(cfg, runs):
    by = collections.OrderedDict()
    for R in sorted(runs, key=lambda r: r["name"]):
        by.setdefault(R["name"].rsplit("-", 1)[0], []).append(R)
    cols = list(by)
    rows = []

    def row(label, fn, fmt="%.0f"):
        cells = []
        for c in cols:
            vals = []
            for R in by[c]:
                try:
                    vals.append(fn(R))
                except (KeyError, TypeError, IndexError, AttributeError):
                    vals.append(None)
            cells.append(f(med(vals), fmt))
        rows.append((label, cells))

    ev = lambda R, k: rel(R, R["lcev"][k])
    row("runs", lambda R: len(by[R["name"].rsplit("-", 1)[0]]))
    row("am TotalTime ms", lambda R: float(R["am"]["TotalTime"]))
    row("intent -> t0 ms", lambda R: -ev(R, "intent"))
    row("t0 -> codec alloc", lambda R: ev(R, "alloc"))
    row("t0 -> codec RUNNING", lambda R: ev(R, "running"))
    row("t0 -> Displayed", lambda R: ev(R, "displayed"))
    row("t0 -> 1st video frame", lambda R: rel(R, R["ff"]))
    row("alloc -> RUNNING ms", lambda R: ev(R, "running") - ev(R, "alloc"))
    row("RUNNING -> 1st frame", lambda R: rel(R, R["ff"]) - ev(R, "running"))
    for tag, key in (("Q", "fq"), ("L", "fl")):
        for wi, wl in ((0, "ff..+2"), (1, "+2..+4")):
            row("%s %s cover s" % (tag, wl), lambda R: R[key][wi]["cov"], "%.1f")
            row("%s %s frames" % (tag, wl), lambda R: R[key][wi]["n"])
            row("%s %s p50/p90" % (tag, wl), lambda R: R[key][wi]["p50"], "%.1f")
            rows[-1] = (rows[-1][0], [a + "/" + b for a, b in zip(rows[-1][1], [
                f(med([R[key][wi]["p90"] for R in by[c]]), "%.1f") for c in cols])])
            row("%s %s max ms" % (tag, wl), lambda R: R[key][wi]["max"])
            row("%s %s gaps>50/>100" % (tag, wl), lambda R: R[key][wi]["g50"])
            rows[-1] = (rows[-1][0], [a + "/" + b for a, b in zip(rows[-1][1], [
                f(med([R[key][wi]["g100"] for R in by[c]])) for c in cols])])
    for cname, _ in CLUSTERS:
        for wi, wl in enumerate(("t0+0..1", "t0+1..2", "t0+2..4")):
            def cm(R, cname=cname, wi=wi):
                return R["cpu"][cname]["rows"][wi][0][0] / 1000.0
            row("%s %s MHz mean" % (cname, wl), cm)
            lo = [f(med([R["cpu"][cname]["rows"][wi][1] * 100 if R["cpu"][cname]["rows"][wi][1]
                         is not None else None for R in by[c]])) for c in cols]
            il = [f(med([R["cpu"][cname]["rows"][wi][2] * 100 if R["cpu"][cname]["rows"][wi][2]
                         is not None else None for R in by[c]])) for c in cols]
            rows[-1] = (rows[-1][0] + " /lo%/idle%",
                        ["%s/%s/%s" % (a, b, d) for a, b, d in zip(rows[-1][1], lo, il)])

    def vclk_final(R):
        vc = [r for t, n, r in R["clk"] if r and "mvs0_core" in n]
        return vc[-1] / 1e6 if vc else None

    def vclk_peak_dur(R):
        vc = [(t, r) for t, n, r in R["clk"] if r and "mvs0_core" in n]
        if not vc:
            return None
        pk = max(r for _, r in vc)
        i = next(i for i, (_, r) in enumerate(vc) if r == pk)
        return (vc[i + 1][0] if i + 1 < len(vc) else R["span"] * 1000) - vc[i][0]
    row("video core clk peak MHz", lambda R: max(r for t, n, r in R["clk"]
                                                  if r and "mvs0_core" in n) / 1e6)
    row("video clk peak held ms", vclk_peak_dur)
    row("video core clk final MHz", vclk_final)
    row("alloc slices total ms", lambda R: R["alloc_tot"], "%.1f")
    row("alloc wait ms", lambda R: R["alloc_wait"], "%.1f")
    row("Q gaps>50 in ff..+4 n", lambda R: len(R["gaps"]))
    row("  of which planned (render ts)", lambda R: len(R["pgaps"]))
    row("binder>10ms app/media n", lambda R: len(R["binder"]))
    row("binder>10ms max ms", lambda R: R["binder"][0][0] if R["binder"] else 0)
    row("main >16ms in t0..+2 n", lambda R: len(R["main"]))
    row("main >16ms top-level sum", lambda R: sum(d for d, _, _, dep in R["main"] if dep == 0))
    print("#### %s  (median over runs)" % cfg)
    w = max(len(r[0]) for r in rows)
    print("%-*s  %s" % (w, "", "  ".join("%-16s" % c for c in cols)))
    for label, cells in rows:
        print("%-*s  %s" % (w, label, "  ".join("%-16s" % c for c in cells)))
    # recurring long main-thread slices & binder partners
    names = collections.Counter()
    for R in runs:
        for d, at, n, dep in R["main"]:
            if dep == 0:
                names[re.sub(r"\d+", "#", n)[:50]] += 1
    if names:
        print("main-thread >16ms (runs x): " + "; ".join("%s x%d" % kv
                                                       for kv in names.most_common(4)))
    bp = collections.Counter()
    for R in runs:
        for d, at, cth, cp, dp, code in R["binder"]:
            bp["%s->%s" % (cp[:15], dp[:15])] += 1
    if bp:
        print("binder>10ms pairs: " + "; ".join("%s x%d" % kv for kv in bp.most_common(4)))


def main(argv):
    verbose = "-v" in argv
    args = [a for a in argv if a != "-v"]
    if not args:
        print(__doc__)
        return 2
    for a in args:
        if os.path.isdir(a):
            runs = []
            for fn in sorted(os.listdir(a)):
                if re.match(r".+-\d+\.trace$", fn):
                    R, _ = analyze(os.path.join(a, fn))
                    if "t0" in R:
                        runs.append(R)
                    if verbose:
                        print_run(R)
            if runs:
                print_summary(os.path.basename(os.path.normpath(a)), runs)
            else:
                print("#### %s: no usable runs" % a)
        else:
            R, _ = analyze(a)
            print_run(R)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
