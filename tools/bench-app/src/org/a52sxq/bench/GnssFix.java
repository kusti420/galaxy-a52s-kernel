package org.a52sxq.bench;

import android.content.Context;
import android.location.GnssStatus;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** gnss.fix: GNSS status for the time budget: satellites seen/used, C/N0, TTFF. SKIP with 0 satellites (indoors). */
public class GnssFix extends Test {
    public String id() { return "gnss.fix"; }
    public int budget(Ctx c) { return Math.min(c.secs(30), 60) + 15; }

    public void run(Ctx c, Result r) throws Exception {
        LocationManager lm = (LocationManager) c.app.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null || !lm.getAllProviders().contains(LocationManager.GPS_PROVIDER)) { r.fail("no GPS provider on this device"); return; }
        if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) { r.skip("GPS provider disabled (location is off)"); return; }
        int secs = Math.min(c.secs(30), 60);
        HandlerThread ht = new HandlerThread("gnss"); ht.start(); Handler h = new Handler(ht.getLooper());
        final AtomicInteger maxSeen = new AtomicInteger(), maxUsed = new AtomicInteger(), statusEvents = new AtomicInteger(), fixes = new AtomicInteger(), started = new AtomicInteger();
        final AtomicLong ttff = new AtomicLong(-1), firstFixMs = new AtomicLong(-1);
        final double[] cn = { 0, 0, 0 };   // max, sum, count (sats with cn0 > 0)
        final float[] acc = { -1 };
        final long t0 = System.currentTimeMillis();
        GnssStatus.Callback cb = new GnssStatus.Callback() {
            @Override public void onStarted() { started.incrementAndGet(); }
            @Override public void onFirstFix(int ms) { ttff.set(ms); }
            @Override public void onSatelliteStatusChanged(GnssStatus s) {
                statusEvents.incrementAndGet();
                int n = s.getSatelliteCount(), used = 0, seen = 0;
                synchronized (cn) {
                    for (int i = 0; i < n; i++) { float v = s.getCn0DbHz(i); if (v > 0) { seen++; if (v > cn[0]) cn[0] = v; cn[1] += v; cn[2]++; } if (s.usedInFix(i)) used++; }
                }
                if (seen > maxSeen.get()) maxSeen.set(seen); if (used > maxUsed.get()) maxUsed.set(used);
            }
        };
        LocationListener ll = new LocationListener() {
            @Override public void onLocationChanged(Location l) { fixes.incrementAndGet(); firstFixMs.compareAndSet(-1, System.currentTimeMillis() - t0); acc[0] = l.getAccuracy(); }
            @Override public void onStatusChanged(String p, int s, Bundle b) { }
            @Override public void onProviderEnabled(String p) { }
            @Override public void onProviderDisabled(String p) { }
        };
        try {
            try {
                lm.registerGnssStatusCallback(cb, h);
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, ll, ht.getLooper());
            } catch (SecurityException e) { r.fail("location permission missing (grant ACCESS_FINE_LOCATION): " + e.getMessage()); return; }
            int tick = 0;
            while (System.currentTimeMillis() - t0 < secs * 1000L) {
                Ctx.sleep(500);
                if (++tick % 10 == 0) c.log("gnss.fix: " + (System.currentTimeMillis() - t0) / 1000 + "/" + secs + " s, sats " + maxSeen.get() + " used " + maxUsed.get() + " fixes " + fixes.get());
                if (fixes.get() >= 3 && System.currentTimeMillis() - t0 > 8000) break;
            }
        } finally {
            try { lm.removeUpdates(ll); } catch (Throwable t) { }
            try { lm.unregisterGnssStatusCallback(cb); } catch (Throwable t) { }
            ht.quitSafely();
        }
        double mx, mean; synchronized (cn) { mx = cn[0]; mean = cn[2] > 0 ? cn[1] / cn[2] : 0; }
        r.num("seconds", (System.currentTimeMillis() - t0) / 1000.0).num("engine_started", (long) started.get()).num("status_events", (long) statusEvents.get())
         .num("sats_seen_max", (long) maxSeen.get()).num("sats_used_max", (long) maxUsed.get()).num("cn0_max_dbhz", mx).num("cn0_mean_dbhz", mean)
         .num("fixes", (long) fixes.get()).num("ttff_ms", ttff.get()).num("first_location_ms", firstFixMs.get());
        if (acc[0] >= 0) r.num("accuracy_m", acc[0]);
        if (statusEvents.get() == 0) { r.fail("no GNSS status callbacks in " + secs + " s (engine started=" + started.get() + "): GNSS HAL not reporting"); return; }
        if (maxSeen.get() == 0) { r.skip("0 satellites with signal in " + secs + " s (" + statusEvents.get() + " status reports): indoors / no sky view"); return; }
        if (maxSeen.get() < 4) { r.fail("only " + maxSeen.get() + " satellites with C/N0 > 0 (max " + mx + " dB-Hz)"); return; }
        r.pass(maxSeen.get() + " sats seen, " + maxUsed.get() + " used, C/N0 max " + String.format("%.1f", mx) + " dB-Hz, " + (fixes.get() > 0 ? "fix after " + firstFixMs.get() + " ms" : "no fix in " + secs + " s"));
    }
}
