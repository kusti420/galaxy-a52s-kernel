package org.a52sxq.bench;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.Choreographer;
import android.view.Display;
import android.view.View;
import android.view.WindowManager;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** display.refresh: each refresh rate at the current resolution via preferredDisplayModeId; Choreographer intervals + jank. */
public class DisplayRefresh extends Test {
    public String id() { return "display.refresh"; }
    public int budget(Ctx c) { return 60; }

    static final class Anim extends View {
        final Paint p = new Paint(); int f;
        Anim(Context c) { super(c); }
        @Override protected void onDraw(Canvas cv) {
            cv.drawColor(0xff101010); p.setColor(0xff30c060);
            int w = getWidth(), h = getHeight(); if (w <= 0) w = 1;
            int x = (f * 12) % w; cv.drawRect(x, 0, x + 80, h, p); f++; invalidate();
        }
    }

    void setMode(final Ctx c, final int id) {
        c.ui(new Runnable() { public void run() { WindowManager.LayoutParams lp = c.act.getWindow().getAttributes(); lp.preferredDisplayModeId = id; c.act.getWindow().setAttributes(lp); } });
    }

    public void run(final Ctx c, Result r) throws Exception {
        final Display d = c.act.getWindowManager().getDefaultDisplay();
        Display.Mode cur = d.getMode();
        ArrayList<Display.Mode> modes = new ArrayList<Display.Mode>();
        StringBuilder all = new StringBuilder();
        for (Display.Mode m : d.getSupportedModes()) {
            all.append(m.getModeId()).append(':').append(m.getPhysicalWidth()).append('x').append(m.getPhysicalHeight()).append('@').append(Math.round(m.getRefreshRate() * 100) / 100.0).append(' ');
            if (m.getPhysicalWidth() != cur.getPhysicalWidth() || m.getPhysicalHeight() != cur.getPhysicalHeight()) continue;
            boolean dup = false; for (Display.Mode o : modes) if (Math.round(o.getRefreshRate()) == Math.round(m.getRefreshRate())) dup = true;
            if (!dup) modes.add(m);
        }
        r.str("modes", all.toString().trim()).num("modes_tested", (long) modes.size());
        if (modes.isEmpty()) { r.fail("no display modes"); return; }
        final int secs = Math.min(c.secs(3), 10);
        c.show(new Anim(c.act));
        int okModes = 0;
        try {
            for (Display.Mode m : modes) {
                int hz = Math.round(m.getRefreshRate()); double period = 1000.0 / m.getRefreshRate();
                c.log("display.refresh: mode " + m.getModeId() + " " + hz + " Hz");
                setMode(c, m.getModeId());
                Ctx.sleep(1200);
                float got = d.getRefreshRate();
                r.num("hz" + hz + "_reported_hz", got);
                final long[] ts = new long[secs * 400]; final int[] n = { 0 };
                final CountDownLatch done = new CountDownLatch(1);
                final long end = System.nanoTime() + secs * 1000000000L;
                c.act.runOnUiThread(new Runnable() { public void run() {
                    Choreographer.getInstance().postFrameCallback(new Choreographer.FrameCallback() { public void doFrame(long t) {
                        if (n[0] < ts.length) ts[n[0]++] = t;
                        if (System.nanoTime() < end && n[0] < ts.length) Choreographer.getInstance().postFrameCallback(this); else done.countDown();
                    } });
                } });
                if (!done.await(secs + 5, TimeUnit.SECONDS)) { r.fail(hz + " Hz: Choreographer stalled"); continue; }
                int k = n[0] - 1;
                if (k < 10) { r.fail(hz + " Hz: only " + n[0] + " frames"); continue; }
                double[] iv = new double[k]; double sum = 0; int jank = 0;
                for (int i = 0; i < k; i++) { iv[i] = (ts[i + 1] - ts[i]) / 1e6; sum += iv[i]; if (iv[i] > 1.5 * period) jank++; }
                Arrays.sort(iv);
                double avg = sum / k, p99 = iv[Math.min(k - 1, (int) (k * 0.99))];
                r.num("hz" + hz + "_avg_ms", avg).num("hz" + hz + "_p99_ms", p99).num("hz" + hz + "_max_ms", iv[k - 1]).num("hz" + hz + "_jank", (long) jank).num("hz" + hz + "_frames", (long) n[0]);
                boolean ok = true;
                if (Math.abs(got - m.getRefreshRate()) > 1.0f) { r.fail(hz + " Hz mode not applied: display reports " + got + " Hz"); ok = false; }
                if (Math.abs(avg - period) > 0.10 * period) { r.fail(hz + " Hz: avg frame interval " + String.format("%.2f", avg) + " ms, expected " + String.format("%.2f", period)); ok = false; }
                if (ok) okModes++;
            }
        } finally { setMode(c, 0); c.clearStage(); }
        if (okModes == modes.size()) r.pass(okModes + " refresh mode(s) verified by Choreographer intervals");
    }
}
