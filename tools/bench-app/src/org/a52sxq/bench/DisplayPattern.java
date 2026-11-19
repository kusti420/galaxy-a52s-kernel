package org.a52sxq.bench;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Display;
import android.view.PixelCopy;
import android.view.View;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Known pattern (8 colour bars + 8 grey steps) in the content area, verified by PixelCopy of the window. */
public class DisplayPattern extends Test {
    public String id() { return "display.pattern"; }
    public int budget(Ctx c) { return 20; }
    static final int[] BARS = { 0xFFFFFFFF, 0xFFFFFF00, 0xFF00FFFF, 0xFF00FF00, 0xFFFF00FF, 0xFFFF0000, 0xFF0000FF, 0xFF000000 };
    static int grey(int i) { int g = i * 255 / 7; return 0xFF000000 | g << 16 | g << 8 | g; }

    static final class PatternView extends View {
        final Paint p = new Paint();
        volatile int draws;
        PatternView(Context c) { super(c); }
        @Override protected void onDraw(Canvas cv) {
            int w = getWidth(), h = getHeight(), top = h * 3 / 4;
            for (int i = 0; i < 8; i++) {
                p.setColor(BARS[i]); cv.drawRect(w * i / 8f, 0, w * (i + 1) / 8f, top, p);
                p.setColor(grey(i)); cv.drawRect(w * i / 8f, top, w * (i + 1) / 8f, h, p);
            }
            draws++;
        }
    }

    public void run(final Ctx c, Result r) throws Exception {
        final PatternView[] pv = new PatternView[1];
        c.ui(new Runnable() { public void run() { pv[0] = new PatternView(c.act); } });
        c.show(pv[0]);
        for (int i = 0; i < 40 && pv[0].draws == 0; i++) Ctx.sleep(50);
        Ctx.sleep(500);
        if (pv[0].draws == 0) { r.fail("pattern view was never drawn (window not visible?)"); return; }
        final int[] loc = new int[2]; final int[] vs = new int[2]; final int[] ds = new int[2];
        c.ui(new Runnable() { public void run() { pv[0].getLocationInWindow(loc); vs[0] = pv[0].getWidth(); vs[1] = pv[0].getHeight();
            View d = c.act.getWindow().getDecorView(); ds[0] = d.getWidth(); ds[1] = d.getHeight(); } });
        final Bitmap bm = Bitmap.createBitmap(ds[0], ds[1], Bitmap.Config.ARGB_8888);
        HandlerThread ht = new HandlerThread("pixelcopy"); ht.start();
        final CountDownLatch l = new CountDownLatch(1); final int[] res = { -1 };
        long t0 = System.nanoTime();
        PixelCopy.request(c.act.getWindow(), bm, new PixelCopy.OnPixelCopyFinishedListener() { public void onPixelCopyFinished(int rc) { res[0] = rc; l.countDown(); } }, new Handler(ht.getLooper()));
        boolean done = l.await(5, TimeUnit.SECONDS); ht.quitSafely();
        r.num("copy_ms", (System.nanoTime() - t0) / 1e6).num("pixelcopy_result", (long) res[0]).num("window_w", (long) ds[0]).num("window_h", (long) ds[1])
                .num("content_x", (long) loc[0]).num("content_y", (long) loc[1]).num("content_w", (long) vs[0]).num("content_h", (long) vs[1]);
        Display d = c.act.getDisplay();
        if (d != null) r.num("refresh_hz", d.getRefreshRate()).num("display_state", (long) d.getState());
        if (!done || res[0] != PixelCopy.SUCCESS) { r.fail("PixelCopy " + (done ? "result " + res[0] : "timed out")); return; }
        r.ev(c.savePng("display-pattern.png", bm));
        int bad = 0, maxDiff = 0; StringBuilder why = new StringBuilder();
        int w = vs[0], h = vs[1], top = h * 3 / 4;
        for (int i = 0; i < 8; i++) for (int row = 0; row < 2; row++) for (int k = 0; k < 3; k++) {
            int want = row == 0 ? BARS[i] : grey(i);
            int x = loc[0] + (int) (w * (i + 0.25f + 0.25f * k) / 8f), y = loc[1] + (row == 0 ? top * (k + 1) / 4 : top + (h - top) * (k + 1) / 4);
            int got = bm.getPixel(x, y);
            int diff = Math.max(Math.abs((got >> 16 & 255) - (want >> 16 & 255)), Math.max(Math.abs((got >> 8 & 255) - (want >> 8 & 255)), Math.abs((got & 255) - (want & 255))));
            if (diff > maxDiff) maxDiff = diff;
            if (diff > 1) { bad++; if (why.length() < 240) why.append(String.format("bar%d row%d @%d,%d got %06x want %06x; ", i, row, x, y, got & 0xffffff, want & 0xffffff)); }
        }
        r.num("probes", 48L).num("bad_probes", (long) bad).num("max_channel_diff", (long) maxDiff);
        if (bad > 0) r.fail(bad + "/48 pattern probes wrong: " + why);
        else r.pass("48/48 probes of the window copy match the pattern (max channel diff " + maxDiff + ")");
    }
}
