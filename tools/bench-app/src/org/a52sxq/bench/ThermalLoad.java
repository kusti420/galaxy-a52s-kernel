package org.a52sxq.bench;

import android.content.Context;
import android.os.PowerManager;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/** thermal.load: all-core CPU load for N s while sampling PowerManager thermal status + headroom (and thermal zones if readable). */
public class ThermalLoad extends Test {
    public String id() { return "thermal.load"; }
    public int budget(Ctx c) { return c.secs(60) + 20; }

    static double zoneMax() {
        double max = Double.NaN;
        File[] z = new File("/sys/class/thermal").listFiles();
        if (z == null) return max;
        for (File f : z) {
            if (!f.getName().startsWith("thermal_zone")) continue;
            try (BufferedReader r = new BufferedReader(new FileReader(new File(f, "temp")))) {
                double v = Double.parseDouble(r.readLine().trim()); if (Math.abs(v) > 1000) v /= 1000.0;
                if (v > 0 && v < 150 && (Double.isNaN(max) || v > max)) max = v;
            } catch (Throwable t) { }
        }
        return max;
    }

    public void run(Ctx c, Result r) throws Exception {
        PowerManager pm = (PowerManager) c.app.getSystemService(Context.POWER_SERVICE);
        final int secs = c.secs(60), ncpu = Runtime.getRuntime().availableProcessors();
        final AtomicBoolean stop = new AtomicBoolean(); final AtomicLong work = new AtomicLong();
        Thread[] th = new Thread[ncpu];
        for (int i = 0; i < ncpu; i++) { th[i] = new Thread(new Runnable() { public void run() {
            double a = 1.0001; long x = 88172645463325252L;
            while (!stop.get()) { for (int k = 0; k < 200000; k++) { x ^= x << 13; x ^= x >>> 7; x ^= x << 17; a = Math.sqrt(a * 1.7 + (x & 7)); } work.incrementAndGet(); }
        } }, "thermal-" + i); th[i].setDaemon(true); th[i].start(); }
        File csv = c.file("thermal_load.csv"); StringBuilder sb = new StringBuilder("t_s,status,headroom,zone_max_c\n");
        double h0 = Double.NaN, hEnd = Double.NaN, hMax = Double.NaN, z0 = Double.NaN, zEnd = Double.NaN, zMax = Double.NaN; int stMax = 0, st0 = -1, nan = 0, samples = 0;
        try {
            long t0 = System.currentTimeMillis();
            while (true) {
                long el = System.currentTimeMillis() - t0;
                int st = pm.getCurrentThermalStatus(); float h = pm.getThermalHeadroom(10); double z = zoneMax();
                samples++;
                if (st0 < 0) st0 = st; if (st > stMax) stMax = st;
                if (Float.isNaN(h)) nan++; else { if (Double.isNaN(h0)) h0 = h; hEnd = h; if (Double.isNaN(hMax) || h > hMax) hMax = h; }
                if (!Double.isNaN(z)) { if (Double.isNaN(z0)) z0 = z; zEnd = z; if (Double.isNaN(zMax) || z > zMax) zMax = z; }
                sb.append(el / 1000.0).append(',').append(st).append(',').append(h).append(',').append(z).append('\n');
                if (samples % 5 == 1) c.log("thermal.load: " + el / 1000 + "/" + secs + " s status " + st + " headroom " + h);
                if (el >= secs * 1000L) break;
                if (st >= PowerManager.THERMAL_STATUS_SEVERE) { r.note("stopped the load early: thermal status " + st); break; }
                Ctx.sleep(Math.min(2000, Math.max(1, secs * 1000L - el)));   // getThermalHeadroom is rate limited: one call per >= 1 s
            }
        } finally { stop.set(true); for (Thread t : th) t.join(2000); }
        try (FileWriter w = new FileWriter(csv)) { w.write(sb.toString()); } r.ev(csv);
        r.num("seconds", (long) secs).num("threads", (long) ncpu).num("work_units", work.get()).num("samples", (long) samples).num("headroom_nan_samples", (long) nan)
         .num("headroom_start", h0).num("headroom_end", hEnd).num("headroom_max", hMax).num("status_start", (long) st0).num("status_max", (long) stMax);
        if (!Double.isNaN(zMax)) r.num("zone_max_start_c", z0).num("zone_max_end_c", zEnd).num("zone_max_peak_c", zMax); else r.note("/sys/class/thermal zones not readable from the app");
        if (Double.isNaN(h0)) r.fail("getThermalHeadroom returned NaN for all " + samples + " samples (thermal HAL gives no skin temperature/thresholds)");
        if (stMax >= PowerManager.THERMAL_STATUS_SEVERE) r.fail("thermal status reached " + stMax + " (>= SEVERE) under " + secs + " s load");
        if (work.get() == 0) r.fail("load threads did no work");
        r.pass(secs + " s all-core load: headroom " + String.format("%.2f", h0) + " -> " + String.format("%.2f", hEnd) + " (max " + String.format("%.2f", hMax) + "), status max " + stMax);
    }
}
