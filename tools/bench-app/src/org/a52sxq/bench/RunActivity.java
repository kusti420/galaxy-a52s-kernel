package org.a52sxq.bench;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.Surface;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.graphics.Insets;
import android.widget.ScrollView;
import android.widget.FrameLayout;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * adb shell am start -n org.a52sxq.bench/.RunActivity --es tests all|id,id --ei seconds N
 * Writes <external files>/results.json + evidence, logs "A52BENCH DONE".
 */
public class RunActivity extends Activity {
    /** run order; "all" = everything except soak.mixed */
    static final String[] IDS = { "gpu.render", "gpu.torture", "gpu.vulkan", "display.pattern", "display.refresh", "audio.out", "audio.mic",
            "audio.offload", "camera.still", "camera.video", "camera.flash", "codec.roundtrip", "sensors.all", "wifi.net", "bt.le", "storage.io",
            "storage.sd", "crypto.keystore", "drm.widevine", "cpu.perf", "thermal.load", "gnss.fix", "soak.mixed" };
    SurfaceView sv; FrameLayout stage; TextView statusView; ScrollView scroll;
    private volatile boolean running;
    private final StringBuilder lines = new StringBuilder();

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        setShowWhenLocked(true); setTurnScreenOn(true);
        final FrameLayout root = new FrameLayout(this); root.setBackgroundColor(Color.BLACK);
        sv = new SurfaceView(this); root.addView(sv, -1, -1);
        stage = new FrameLayout(this); root.addView(stage, -1, -1);
        statusView = new TextView(this); statusView.setTextColor(Color.GREEN); statusView.setTextSize(11);
        statusView.setPadding(16, 16, 16, 16);
        scroll = new ScrollView(this); scroll.setBackgroundColor(0x80000000); scroll.setFillViewport(false);
        scroll.addView(statusView, new FrameLayout.LayoutParams(-1, -2));
        root.addView(scroll, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        // everything (GL surface, test stage, status text) stays inside the safe area: system bars + cutout become root padding
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() { public WindowInsets onApplyWindowInsets(View v, WindowInsets wi) {
            Insets in = wi.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            v.setPadding(in.left, in.top, in.right, in.bottom);
            return WindowInsets.CONSUMED;
        } });
        setContentView(root);
        getWindow().setDecorFitsSystemWindows(false);
        WindowInsetsController wc = getWindow().getInsetsController();
        if (wc != null) { wc.hide(WindowInsets.Type.systemBars()); wc.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE); }
        start(getIntent());
    }
    @Override protected void onNewIntent(Intent i) { super.onNewIntent(i); setIntent(i); start(i); }

    void status(final String s) {
        runOnUiThread(new Runnable() { public void run() {
            lines.append(s).append('\n');
            if (lines.length() > 20000) lines.delete(0, lines.indexOf("\n", lines.length() - 15000) + 1);
            statusView.setText(lines);
            int maxH = getWindow().getDecorView().getHeight() / 2;
            android.view.ViewGroup.LayoutParams lp = scroll.getLayoutParams();
            statusView.measure(View.MeasureSpec.makeMeasureSpec(Math.max(1, scroll.getWidth()), View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED);
            int want = statusView.getMeasuredHeight() > maxH && maxH > 0 ? maxH : -2;
            if (lp.height != want) { lp.height = want; scroll.setLayoutParams(lp); }
            scroll.post(new Runnable() { public void run() { scroll.fullScroll(View.FOCUS_DOWN); } });
        } });
    }
    Surface waitSurface() {
        for (int i = 0; i < 60; i++) { Surface s = sv.getHolder().getSurface(); if (s != null && s.isValid() && sv.getWidth() > 0) return s; Ctx.sleep(50); }
        return null;
    }

    private void start(final Intent in) {
        if (running) { Log.w(Ctx.TAG, "run already in progress, ignoring new intent"); return; }
        running = true;
        new Thread(new Runnable() { public void run() { try { runAll(in); } catch (Throwable t) { Log.e(Ctx.TAG, "runner died", t); Log.i(Ctx.TAG, "A52BENCH DONE error=" + t); } finally { running = false; } } }, "bench-runner").start();
    }

    static String className(String id) {
        StringBuilder sb = new StringBuilder("org.a52sxq.bench.");
        for (String p : id.split("\\.")) sb.append(Character.toUpperCase(p.charAt(0))).append(p.substring(1));
        return sb.toString();
    }

    private void runAll(Intent in) throws Exception {
        String sel = in.getStringExtra("tests"); if (sel == null || sel.isEmpty()) sel = "all";
        int seconds = in.getIntExtra("seconds", 0);
        File dir = getExternalFilesDir(null); dir.mkdirs();
        File[] old = dir.listFiles(); if (old != null) for (File f : old) if (f.isFile()) f.delete();
        final Ctx c = new Ctx(this, dir, seconds, in.getExtras());
        List<String> ids = new ArrayList<>();
        if (sel.equals("all")) { for (String s : IDS) if (!s.equals("soak.mixed")) ids.add(s); }
        else for (String s : sel.split(",")) { s = s.trim(); if (s.isEmpty()) continue; boolean hit = false;
            for (String k : IDS) if (k.equals(s) || k.startsWith(s + ".")) { ids.add(k); hit = true; }
            if (!hit) ids.add(s); }
        JSONObject top = new JSONObject();
        top.put("suite", "a52bench"); top.put("format", 1); top.put("started_ms", System.currentTimeMillis());
        JSONObject dev = new JSONObject();
        dev.put("model", Build.MODEL); dev.put("device", Build.DEVICE); dev.put("fingerprint", Build.FINGERPRINT); dev.put("sdk", Build.VERSION.SDK_INT);
        dev.put("kernel", System.getProperty("os.version")); dev.put("serial_hint", Build.HARDWARE);
        android.os.Vibrator vib = (android.os.Vibrator) getSystemService(VIBRATOR_SERVICE);
        dev.put("has_vibrator", vib != null && vib.hasVibrator());   // INFO only: this app never vibrates
        top.put("device", dev); top.put("selection", sel); top.put("seconds", seconds);
        JSONArray tests = new JSONArray(); top.put("tests", tests);
        c.log("A52 Kernel Bench: " + ids.size() + " tests, kernel " + System.getProperty("os.version"));
        waitSurface();
        int pass = 0, fail = 0, skip = 0;
        for (String id : ids) {
            final Result r = new Result(id, c);
            Test t0 = null;
            try { t0 = (Test) Class.forName(className(id)).getDeclaredConstructor().newInstance(); }
            catch (ClassNotFoundException e) { r.skip("not implemented in this build"); }
            catch (Throwable e) { r.fail("cannot instantiate: " + e); }
            if (t0 != null) {
                final Test t = t0;
                int budget = t.budget(c);
                c.log("> " + id + " (budget " + budget + " s)");
                // placeholder: if the process dies inside the test, results.json says so
                JSONObject ph = new JSONObject(); ph.put("id", id); ph.put("status", "FAIL"); ph.put("reason", "process died during this test");
                ph.put("numbers", new JSONObject()); ph.put("evidence", new JSONArray());
                tests.put(ph); write(dir, top); tests.remove(tests.length() - 1);
                long t1 = System.nanoTime();
                Thread th = new Thread(new Runnable() { public void run() {
                    try { t.run(c, r); }
                    catch (Throwable e) { Log.e(Ctx.TAG, r.id + " threw", e); StackTraceElement[] st = e.getStackTrace();
                        r.fail("exception: " + e + (st.length > 0 ? " at " + st[0] : "")); }
                } }, "test-" + id);
                th.start(); th.join((budget + 15) * 1000L);
                if (th.isAlive()) { r.fail("timeout: still running after budget " + budget + " s + 15 s"); th.interrupt(); th.join(3000); }
                r.seconds = (System.nanoTime() - t1) / 1e9;
                c.clearStage();
            }
            String st = r.status();
            if (st.equals("PASS")) pass++; else if (st.equals("FAIL")) fail++; else skip++;
            tests.put(r.json()); write(dir, top);
            c.log(st + " " + id + ": " + r.reason());
            Log.i(Ctx.TAG, "RESULT " + r.json());
        }
        top.put("finished_ms", System.currentTimeMillis()); top.put("pass", pass); top.put("fail", fail); top.put("skip", skip);
        write(dir, top);
        c.log("DONE pass=" + pass + " fail=" + fail + " skip=" + skip);
        Log.i(Ctx.TAG, "A52BENCH DONE pass=" + pass + " fail=" + fail + " skip=" + skip);
    }
    private static void write(File dir, JSONObject top) throws Exception {
        File tmp = new File(dir, "results.json.tmp");
        try (FileOutputStream o = new FileOutputStream(tmp)) { o.write(top.toString(1).getBytes("UTF-8")); o.getFD().sync(); }
        tmp.renameTo(new File(dir, "results.json"));
    }
}
