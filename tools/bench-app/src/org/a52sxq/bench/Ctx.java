package org.a52sxq.bench;

import android.content.Context;
import android.graphics.Bitmap;
import android.os.Bundle;
import android.util.Log;
import android.view.Surface;
import android.view.View;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** What a test gets: context, output dir, parameters, the on-screen stage. */
public final class Ctx {
    public static final String TAG = "A52BENCH";
    public final RunActivity act;
    public final Context app;
    /** evidence + results dir: /sdcard/Android/data/org.a52sxq.bench/files */
    public final File dir;
    /** --ei seconds N (0 = not given: each test uses its default) */
    public final int seconds;
    final Bundle extras;

    Ctx(RunActivity a, File dir, int seconds, Bundle extras) { act = a; app = a.getApplicationContext(); this.dir = dir; this.seconds = seconds; this.extras = extras == null ? new Bundle() : extras; }

    /** seconds to run a timed phase: the --ei seconds value, else def */
    public int secs(int def) { return seconds > 0 ? seconds : def; }
    /** string extra (--es key value), else def */
    public String param(String key, String def) { String v = extras.getString(key); return v == null ? def : v; }
    public File file(String name) { return new File(dir, name); }
    public void log(String s) { Log.i(TAG, s); act.status(s); }

    /** run on the UI thread and wait (max 5 s) */
    public void ui(final Runnable r) {
        final CountDownLatch l = new CountDownLatch(1);
        act.runOnUiThread(new Runnable() { public void run() { try { r.run(); } finally { l.countDown(); } } });
        try { l.await(5, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
    /** put a fullscreen view on the stage (above the GL surface, below nothing: the status text is hidden) */
    public void show(final View v) { ui(new Runnable() { public void run() { act.stage.removeAllViews(); act.stage.addView(v, -1, -1); act.scroll.setVisibility(View.GONE); } }); }
    public void clearStage() { ui(new Runnable() { public void run() { act.stage.removeAllViews(); act.scroll.setVisibility(View.VISIBLE); } }); }
    /** the on-screen SurfaceView surface (for EGL window surfaces, camera preview, codec output); null when not available */
    public Surface surface() { return act.waitSurface(); }
    public int surfaceW() { return act.sv.getWidth(); }
    public int surfaceH() { return act.sv.getHeight(); }

    public File savePng(String name, Bitmap b) {
        File f = file(name);
        try (FileOutputStream o = new FileOutputStream(f)) { b.compress(Bitmap.CompressFormat.PNG, 100, o); } catch (Exception e) { Log.w(TAG, "savePng " + e); }
        return f;
    }
    public static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); } }
}
