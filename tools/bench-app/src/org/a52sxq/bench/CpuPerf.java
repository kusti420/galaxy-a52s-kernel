package org.a52sxq.bench;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/** cpu.perf: fixed integer + float workload, single- and all-core, with per-core cpufreq observed under load. */
public class CpuPerf extends Test {
    public String id() { return "cpu.perf"; }
    public int budget(Ctx c) { return 40; }

    static long intUnit() { long x = 0x9E3779B97F4A7C15L, s = 0; for (int i = 0; i < 4000000; i++) { x ^= x << 13; x ^= x >>> 7; x ^= x << 17; s += x & 0xffff; } return s; }
    static long floatUnit() {
        long sum = 0;
        for (int py = 0; py < 96; py++) for (int px = 0; px < 96; px++) {
            double cr = -2.0 + px * (3.0 / 96), ci = -1.5 + py * (3.0 / 96), zr = 0, zi = 0; int it = 0;
            while (it < 256 && zr * zr + zi * zi < 4.0) { double t = zr * zr - zi * zi + cr; zi = 2 * zr * zi + ci; zr = t; it++; }
            sum += it;
        }
        return sum;
    }
    static long readLong(String p) { try (BufferedReader r = new BufferedReader(new FileReader(p))) { return Long.parseLong(r.readLine().trim()); } catch (Throwable t) { return -1; } }

    /** returns {intUnits, floatUnits, badChecksums} done by n threads in ms */
    static long[] load(int n, final long ms, final long refI, final long refF) throws InterruptedException {
        final AtomicLong iu = new AtomicLong(), fu = new AtomicLong(), bad = new AtomicLong();
        Thread[] th = new Thread[n];
        final long half = ms / 2;
        for (int i = 0; i < n; i++) {
            th[i] = new Thread(new Runnable() { public void run() {
                long t0 = System.nanoTime();
                while (System.nanoTime() - t0 < half * 1000000L) { if (intUnit() != refI) bad.incrementAndGet(); iu.incrementAndGet(); }
                t0 = System.nanoTime();
                while (System.nanoTime() - t0 < half * 1000000L) { if (floatUnit() != refF) bad.incrementAndGet(); fu.incrementAndGet(); }
            } }, "cpuperf-" + i);
            th[i].start();
        }
        for (Thread t : th) t.join(ms + 10000);
        return new long[] { iu.get(), fu.get(), bad.get() };
    }

    public void run(Ctx c, Result r) throws Exception {
        final int ncpu = Runtime.getRuntime().availableProcessors();
        final long[] maxKhz = new long[ncpu];
        final AtomicBoolean stop = new AtomicBoolean();
        Thread sampler = new Thread(new Runnable() { public void run() {
            while (!stop.get()) {
                for (int i = 0; i < ncpu; i++) { long v = readLong("/sys/devices/system/cpu/cpu" + i + "/cpufreq/scaling_cur_freq"); if (v > maxKhz[i]) maxKhz[i] = v; }
                Ctx.sleep(100);
            }
        } }, "cpuperf-freq");
        sampler.start();
        try {
            long refI = intUnit(), refF = floatUnit();
            long ms = 6000;
            c.log("cpu.perf: single thread " + ms + " ms");
            long[] st = load(1, ms, refI, refF);
            c.log("cpu.perf: " + ncpu + " threads " + ms + " ms");
            long[] mt = load(ncpu, ms, refI, refF);
            double sec = ms / 2000.0;
            double stI = st[0] / sec, stF = st[1] / sec, mtI = mt[0] / sec, mtF = mt[1] / sec;
            r.num("cpus", (long) ncpu).num("st_int_units_s", stI).num("st_float_units_s", stF).num("mt_int_units_s", mtI).num("mt_float_units_s", mtF)
             .num("mt_int_speedup", stI > 0 ? mtI / stI : 0).num("mt_float_speedup", stF > 0 ? mtF / stF : 0).num("bad_checksums", st[2] + mt[2]);
            r.str("int_checksum", Long.toHexString(refI)).str("float_checksum", Long.toString(refF));
            int readable = 0;
            for (int i = 0; i < ncpu; i++) { if (maxKhz[i] > 0) { readable++; r.num("cpu" + i + "_max_khz", maxKhz[i]); long hw = readLong("/sys/devices/system/cpu/cpu" + i + "/cpufreq/cpuinfo_max_freq"); if (hw > 0) r.num("cpu" + i + "_hw_max_khz", hw); } }
            if (readable == 0) r.note("cpufreq scaling_cur_freq not readable from the app");
            if (st[2] + mt[2] > 0) r.fail((st[2] + mt[2]) + " workload units produced a wrong checksum");
            if (refF != floatUnit() || refI != intUnit()) r.fail("reference checksum not reproducible");
            if (st[0] == 0 || st[1] == 0) r.fail("single-thread workload did not complete a unit");
            if (!(mtI > 2 * stI && mtF > 2 * stF)) r.fail("multi-thread score not > 2x single (int " + mtI + " vs " + stI + ", float " + mtF + " vs " + stF + ")");
            r.pass("st int " + Math.round(stI) + "/s float " + Math.round(stF) + "/s; mt x" + String.format("%.1f", mtI / Math.max(stI, 1e-9)) + " int, x" + String.format("%.1f", mtF / Math.max(stF, 1e-9)) + " float on " + ncpu + " cpus");
        } finally { stop.set(true); sampler.join(1000); }
    }
}
