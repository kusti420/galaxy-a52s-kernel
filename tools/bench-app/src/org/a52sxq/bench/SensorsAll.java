package org.a52sxq.bench;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Handler;
import android.os.HandlerThread;
import java.io.File;
import java.io.FileWriter;
import java.util.ArrayList;
import java.util.List;

/** Every sensor: register, collect 3 s (groups of 8 at once), events > 0, rate vs requested, sane values. Evidence: sensors.txt. */
public class SensorsAll extends Test {
    public String id() { return "sensors.all"; }
    public int budget(Ctx c) { return 120; }
    static final class S implements SensorEventListener {
        Sensor s; int n; long first, last; float[] v; boolean nan; double minMag = 1e30, maxMag;
        public void onSensorChanged(SensorEvent e) { if (n == 0) first = e.timestamp; last = e.timestamp; n++; v = e.values.clone();
            double m = 0; int k = Math.min(3, e.values.length); for (int i = 0; i < e.values.length; i++) if (Float.isNaN(e.values[i]) || Float.isInfinite(e.values[i])) nan = true;
            for (int i = 0; i < k; i++) m += e.values[i] * e.values[i]; m = Math.sqrt(m); if (m < minMag) minMag = m; if (m > maxMag) maxMag = m; }
        public void onAccuracyChanged(Sensor s, int a) { }
    }
    /** null = fine, else what is wrong with the values */
    static String sane(S x) {
        if (x.nan) return "NaN/Inf value";
        switch (x.s.getType()) {
            case Sensor.TYPE_ACCELEROMETER: case Sensor.TYPE_ACCELEROMETER_UNCALIBRATED: return x.minMag < 3 || x.maxMag > 30 ? "|a| " + x.minMag + ".." + x.maxMag + " m/s2" : null;
            case Sensor.TYPE_GRAVITY: return x.minMag < 9.0 || x.maxMag > 10.6 ? "|g| " + x.minMag + ".." + x.maxMag : null;
            case Sensor.TYPE_GYROSCOPE: case Sensor.TYPE_GYROSCOPE_UNCALIBRATED: return x.maxMag > 35 ? "|w| " + x.maxMag + " rad/s" : null;
            case Sensor.TYPE_MAGNETIC_FIELD: case Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED: return x.minMag < 1 || x.maxMag > 3000 ? "|B| " + x.minMag + ".." + x.maxMag + " uT" : null;
            case Sensor.TYPE_PRESSURE: return x.v[0] < 300 || x.v[0] > 1100 ? "pressure " + x.v[0] + " hPa" : null;
            case Sensor.TYPE_LIGHT: return x.v[0] < 0 || x.v[0] > 200000 ? "light " + x.v[0] + " lx" : null;
            case Sensor.TYPE_PROXIMITY: return x.v[0] < 0 || x.v[0] > x.s.getMaximumRange() + 0.01 ? "proximity " + x.v[0] : null;
            case Sensor.TYPE_ROTATION_VECTOR: case Sensor.TYPE_GAME_ROTATION_VECTOR: case Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR: return x.maxMag > 1.01 ? "|q| " + x.maxMag : null;
            case Sensor.TYPE_LINEAR_ACCELERATION: return x.maxMag > 30 ? "|a| " + x.maxMag : null;
            default: return null;
        }
    }

    public void run(Ctx c, Result r) throws Exception {
        SensorManager sm = (SensorManager) c.app.getSystemService(Context.SENSOR_SERVICE);
        List<Sensor> all = sm.getSensorList(Sensor.TYPE_ALL);
        HandlerThread ht = new HandlerThread("sensors"); ht.start(); Handler h = new Handler(ht.getLooper());
        File f = c.file("sensors.txt"); FileWriter w = new FileWriter(f); r.ev(f);
        int vendorSilent = 0; StringBuilder vendorL = new StringBuilder(); int cont = 0, contOk = 0, dead = 0, onchg = 0, onchgSilent = 0, trigger = 0, rateOff = 0, insane = 0, regFail = 0;
        StringBuilder deadL = new StringBuilder(), rateL = new StringBuilder(), insaneL = new StringBuilder();
        List<S> batch = new ArrayList<>();
        try {
            for (int i = 0; i <= all.size(); i++) {
                if (i < all.size()) {
                    Sensor s = all.get(i); int mode = s.getReportingMode();
                    if (mode == Sensor.REPORTING_MODE_ONE_SHOT) { trigger++; w.write(String.format("%-44s type=%d one-shot trigger: not sampled\n", s.getName(), s.getType())); continue; }
                    S x = new S(); x.s = s;
                    int us = Math.max(20000, s.getMinDelay());
                    if (!sm.registerListener(x, s, us, h)) { regFail++; deadL.append(s.getName()).append(" (register failed); "); w.write(String.format("%-44s type=%d REGISTER FAILED\n", s.getName(), s.getType())); continue; }
                    batch.add(x);
                }
                if (batch.size() == 8 || (i == all.size() && !batch.isEmpty())) {
                    Ctx.sleep(3000);
                    for (S x : batch) sm.unregisterListener(x);
                    for (S x : batch) {
                        int mode = x.s.getReportingMode(); boolean continuous = mode == Sensor.REPORTING_MODE_CONTINUOUS;
                        double want = 1e6 / Math.max(20000, x.s.getMinDelay()), hz = x.n > 1 ? (x.n - 1) / ((x.last - x.first) / 1e9) : 0;
                        String note = "";
                        if (continuous) { cont++;
                            if (x.n == 0 && x.s.getType() >= Sensor.TYPE_DEVICE_PRIVATE_BASE) { vendorSilent++; vendorL.append(x.s.getName()).append(" (type ").append(x.s.getType()).append("); "); note = "vendor-private type, no events (cannot be judged without the vendor's protocol)"; }
                            else if (x.n == 0) { dead++; deadL.append(x.s.getName()).append("; "); note = "DEAD"; }
                            else { String bad = sane(x);
                                boolean rOk = hz > want * 0.5 && hz < want * 2.5;
                                if (!rOk) { rateOff++; rateL.append(x.s.getName()).append(String.format(" %.1f Hz (asked %.0f); ", hz, want)); note += " RATE"; }
                                if (bad != null) { insane++; insaneL.append(x.s.getName()).append(": ").append(bad).append("; "); note += " VALUES"; }
                                if (rOk && bad == null) contOk++; }
                        } else { onchg++; if (x.n == 0) { onchgSilent++; note = "no event (on-change/special: nothing changed in 3 s)"; } else { String bad = sane(x); if (bad != null) { insane++; insaneL.append(x.s.getName()).append(": ").append(bad).append("; "); note = "VALUES"; } } }
                        w.write(String.format("%-44s type=%-6d mode=%d wake=%d events=%-5d hz=%-7.1f asked=%-5.0f last=%s %s\n", x.s.getName(), x.s.getType(), mode, x.s.isWakeUpSensor() ? 1 : 0, x.n, hz, want,
                                x.v == null ? "-" : java.util.Arrays.toString(x.v.length > 4 ? java.util.Arrays.copyOf(x.v, 4) : x.v), note));
                    }
                    batch.clear();
                }
            }
        } finally { for (S x : batch) sm.unregisterListener(x); w.close(); ht.quitSafely(); }
        r.num("sensors_total", (long) all.size()).num("continuous", (long) cont).num("continuous_ok", (long) contOk).num("dead", (long) (dead + regFail)).num("rate_off", (long) rateOff)
                .num("insane_values", (long) insane).num("on_change", (long) onchg).num("on_change_silent", (long) onchgSilent).num("one_shot_not_sampled", (long) trigger).num("vendor_private_silent", (long) vendorSilent);
        if (vendorSilent > 0) r.note("vendor-private continuous sensors without events (not counted as dead): " + vendorL);
        if (all.isEmpty()) { r.fail("SensorManager lists no sensors"); return; }
        if (dead + regFail > 0) r.fail((dead + regFail) + " dead sensor(s): " + deadL);
        if (rateOff > 0) r.fail(rateOff + " sensor(s) off the requested rate: " + rateL);
        if (insane > 0) r.fail(insane + " sensor(s) with values out of range: " + insaneL);
        r.pass(contOk + "/" + (cont - vendorSilent) + " standard continuous sensors delivered at rate with sane values; " + (onchg - onchgSilent) + "/" + onchg + " on-change sensors reported");
    }
}
