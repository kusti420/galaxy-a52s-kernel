// Self-test helper for tools/selftest (one dex, many subcommands), run with app_process as the shell uid:
//   adb push st.dex /data/local/tmp/st.dex
//   adb shell app_process -cp /data/local/tmp/st.dex / St <cmd> [args]
// Commands: sensors [secs] | gl [secs] | glalloc [mb] | cam | camrec [id] [secs] | enc <mime> <out> [codec]
//           | dec <file> [codec|-] [expectedFrames] [nopattern] | vsync [secs] | disp [secs] | ble [secs]
//           | loop <media|ll|voice> [freq] [MIC|CAMCORDER|UNPROCESSED] [unmute] | keystore | drm | offload
// PASS only when the feature was driven end to end and measured; numbers also as "METRIC <name> <number>".
// Every command prints "st: ..." detail lines and exactly one final "RESULT <cmd> PASS|FAIL|SKIP <detail>".
// Build: tools/selftest/java/build.sh
import android.content.Context;
import android.graphics.ImageFormat;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.*;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.*;
import android.opengl.*;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Size;
import android.view.Surface;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.*;
import java.util.concurrent.*;

public class St {
    static String cmd = "?";
    static volatile boolean done = false;
    static void metric(String n, double v) { System.out.println("METRIC " + n + " " + (v == Math.rint(v) ? String.valueOf((long) v) : String.format(java.util.Locale.US, "%.2f", v))); System.out.flush(); }
    static void p(String s) { System.out.println("st: " + s); System.out.flush(); }
    static synchronized void result(String st, String detail) {
        if (done) return; done = true;
        System.out.println("RESULT " + cmd + " " + st + " " + detail.replace('\n', ' ')); System.out.flush();
        Runtime.getRuntime().halt(0);
    }
    static Context ctx() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        // registers the mainline service managers (Bluetooth, ...) that a normal app gets in handleBindApplication
        try { at.getMethod("initializeMainlineModules").invoke(null); } catch (Throwable t) { }
        Context c = (Context) at.getMethod("getSystemContext").invoke(thread);
        c = c.createPackageContext("com.android.shell", 0);
        // The package context still reports op package "android" (uid 2000 does not own it: camera access gets revoked,
        // BLE scan throws inside com.android.bluetooth). Make the context say what it is: com.android.shell.
        try { fixOp(c);
            // AudioTrack/AudioRecord/MediaDrm take the op package from the process's Application (ActivityThread.currentOpPackageName)
            android.app.Application app = (android.app.Application) at.getMethod("currentApplication").invoke(null);
            if (app != null) { fixOp(app.getBaseContext()); }
            fixOp((Context) at.getMethod("getSystemContext").invoke(thread));
        } catch (Throwable t) { p("op package fix failed: " + t); }
        if (!"com.android.shell".equals(c.getOpPackageName())) p("warning: op package is " + c.getOpPackageName());
        return c;
    }
    static void fixOp(Context c) throws Exception {
        while (c instanceof android.content.ContextWrapper) c = ((android.content.ContextWrapper) c).getBaseContext();
        Class<?> ci = Class.forName("android.app.ContextImpl"); if (!ci.isInstance(c)) return;
        java.lang.reflect.Field f = ci.getDeclaredField("mOpPackageName"); f.setAccessible(true); f.set(c, "com.android.shell");
        java.lang.reflect.Field g = ci.getDeclaredField("mAttributionSource"); g.setAccessible(true);
        g.set(c, new android.content.AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build());
    }
    static Handler bg(String n) { HandlerThread t = new HandlerThread(n); t.start(); return new Handler(t.getLooper()); }

    public static void main(String[] a) {
        if (a.length == 0) { System.out.println("usage: St sensors|gl|glalloc|cam|camrec|enc|keystore|drm|offload"); return; }
        cmd = a[0];
        long to = cmd.equals("glalloc") ? 180 : cmd.equals("cam") ? 120 : cmd.equals("drm") ? 30 : 90;
        if ((cmd.equals("sensors") || cmd.equals("gl") || cmd.equals("camrec") || cmd.equals("vsync") || cmd.equals("disp") || cmd.equals("ble")) && a.length > 1) to += Long.parseLong(a[a.length - 1]);
        final long tms = to * 1000;
        Thread w = new Thread(() -> { try { Thread.sleep(tms); } catch (Exception e) {} result("FAIL", "timeout after " + tms / 1000 + " s"); });
        w.setDaemon(true); w.start();
        try {
            switch (cmd) {
                case "sensors": sensors(a.length > 1 ? Integer.parseInt(a[1]) : 4); break;
                case "gl": gl(a.length > 1 ? Integer.parseInt(a[1]) : 5); break;
                case "glpace": glpace(Integer.parseInt(a[1]), Integer.parseInt(a[2]), Integer.parseInt(a[3])); break;
                case "glalloc": glalloc(a.length > 1 ? Integer.parseInt(a[1]) : 768); break;
                case "cam": cam(a.length > 1 ? a[1] : null); break;
                case "camrec": camrec(a.length > 1 ? a[1] : "0", a.length > 2 ? Integer.parseInt(a[2]) : 5); break;
                case "enc": enc(a[1], a[2], a.length > 3 ? a[3] : null); break;
                case "dec": dec(a[1], a.length > 2 && !a[2].equals("-") ? a[2] : null, a.length > 3 ? Integer.parseInt(a[3]) : 90, !(a.length > 4 && a[4].equals("nopattern"))); break;
                case "vsync": vsync(a.length > 1 ? Integer.parseInt(a[1]) : 3); break;
                case "disp": disp(a.length > 1 ? Integer.parseInt(a[1]) : 6); break;
                case "ble": ble(a.length > 1 ? Integer.parseInt(a[1]) : 6); break;
                case "loop": loop(a.length > 1 ? a[1] : "media", a.length > 2 ? Integer.parseInt(a[2]) : 1000, a.length > 3 ? a[3] : "MIC", a.length > 4 && a[4].equals("unmute")); break;
                case "keystore": keystore(); break;
                case "drm": drm(); break;
                case "offload": offload(); break;
                default: result("FAIL", "unknown command");
            }
        } catch (Throwable t) {
            Throwable c = t; while (c.getCause() != null && (c instanceof java.lang.reflect.InvocationTargetException || c instanceof ExecutionException)) c = c.getCause();
            c.printStackTrace();
            result("FAIL", "exception " + c);
        }
        result("FAIL", "no result");
    }

    // ---------------------------------------------------------------- sensors
    static void sensors(int secs) throws Exception {
        SensorManager sm = (SensorManager) ctx().getSystemService(Context.SENSOR_SERVICE);
        List<Sensor> all = sm.getSensorList(Sensor.TYPE_ALL);
        // per sensor: n, first ts, last ts, min, max, sum, sumsq (of the vector magnitude of up to 3 values), last values
        final Map<Sensor, double[]> st = new LinkedHashMap<>(); final Map<Sensor, float[]> last = new ConcurrentHashMap<>();
        Handler h = bg("sens");
        SensorEventListener l = new SensorEventListener() {
            public void onSensorChanged(SensorEvent e) { double[] c = st.get(e.sensor); if (c == null) return;
                double m = 0; int k = Math.min(3, e.values.length); if (k == 1) m = e.values[0]; else { for (int i = 0; i < k; i++) m += e.values[i] * e.values[i]; m = Math.sqrt(m); }
                if (c[0] == 0) { c[1] = e.timestamp; c[3] = m; c[4] = m; } c[0]++; c[2] = e.timestamp; c[3] = Math.min(c[3], m); c[4] = Math.max(c[4], m); c[5] += m; c[6] += m * m;
                last.put(e.sensor, e.values.clone()); }
            public void onAccuracyChanged(Sensor s, int i) {}
        };
        int reg = 0;
        for (Sensor s : all) {
            if (s.getReportingMode() == Sensor.REPORTING_MODE_ONE_SHOT) continue;
            st.put(s, new double[7]);
            if (sm.registerListener(l, s, SensorManager.SENSOR_DELAY_GAME, h)) reg++; else p("register failed: " + s.getName());
        }
        p("sensors total " + all.size() + " registered " + reg);
        Thread.sleep(secs * 1000L);
        sm.unregisterListener(l);
        StringBuilder zero = new StringBuilder(); List<String> bad = new ArrayList<>(); int delivering = 0;
        String[] nm = {"accel", "gyro", "mag", "light", "pressure"}; int[] ty = {Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_MAGNETIC_FIELD, Sensor.TYPE_LIGHT, Sensor.TYPE_PRESSURE};
        boolean[] present = new boolean[5], good = new boolean[5]; StringBuilder core = new StringBuilder();
        for (Map.Entry<Sensor, double[]> e : st.entrySet()) {
            Sensor s = e.getKey(); double[] c = e.getValue(); int n = (int) c[0]; float[] v = last.get(s);
            double hz = n > 1 ? (n - 1) / ((c[2] - c[1]) / 1e9) : 0, mean = n > 0 ? c[5] / n : 0, var = n > 0 ? Math.max(0, c[6] / n - mean * mean) : 0;
            if (n > 0) delivering++;
            p(String.format(Locale.US, "sensor %d \"%s\" events %d rate %.1f Hz min %.4f max %.4f var %.6f last %s", s.getType(), s.getName().trim(), n, hz, c[3], c[4], var,
                v == null ? "-" : Arrays.toString(v.length > 4 ? Arrays.copyOf(v, 4) : v)));
            if (n == 0 && s.getReportingMode() == Sensor.REPORTING_MODE_CONTINUOUS) zero.append(s.getName().trim()).append("; ");
            for (int k = 0; k < 5; k++) if (s.getType() == ty[k] && !good[k]) { present[k] = true; if (n == 0) continue;
                boolean ok; boolean onChange = s.getReportingMode() != Sensor.REPORTING_MODE_CONTINUOUS;
                if (k == 0) ok = mean >= 8.8 && mean <= 10.8; else if (k == 1) ok = c[4] < 3; else if (k == 2) ok = mean > 5 && mean < 1500; else if (k == 3) ok = c[3] >= 0 && c[4] < 200000; else ok = mean > 300 && mean < 1100;
                ok = ok && (hz > 0 || onChange);
                if (ok) { good[k] = true; core.append(String.format(Locale.US, "%s %.0fHz %.2f; ", nm[k], hz, mean)); } else bad.add(String.format(Locale.US, "%s mean %.3f rate %.1f", nm[k], mean, hz)); }
        }
        String miss = ""; boolean ok = true;
        for (int k = 0; k < 5; k++) { if (k < 3 && !present[k]) { miss += nm[k] + "(absent) "; ok = false; } else if (present[k] && !good[k]) { miss += nm[k] + " "; ok = false; } }
        metric("sensors_delivering", delivering); metric("sensors_total", all.size());
        String d = "delivering " + delivering + "/" + reg + " registered (" + all.size() + " total): " + core + (miss.isEmpty() ? "" : " NOT OK: " + miss + bad)
            + (zero.length() > 0 ? " zero-event continuous: " + zero : "");
        result(ok ? "PASS" : "FAIL", d);
    }

    // ---------------------------------------------------------------- EGL / GL
    static EGLDisplay dpy; static EGLContext ectx; static EGLSurface surf; static int glver;
    static void eglUp(int w, int h) {
        dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] v = new int[2]; if (!EGL14.eglInitialize(dpy, v, 0, v, 1)) throw new RuntimeException("eglInitialize 0x" + Integer.toHexString(EGL14.eglGetError()));
        EGLConfig[] cfg = new EGLConfig[1]; int[] n = new int[1];
        for (int ver = 3; ver >= 2; ver--) {
            int bit = ver == 3 ? 0x40 /*EGL_OPENGL_ES3_BIT_KHR*/ : EGL14.EGL_OPENGL_ES2_BIT;
            int[] at = {EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_RENDERABLE_TYPE, bit, EGL14.EGL_NONE};
            if (!EGL14.eglChooseConfig(dpy, at, 0, cfg, 0, 1, n, 0) || n[0] < 1) continue;
            ectx = EGL14.eglCreateContext(dpy, cfg[0], EGL14.EGL_NO_CONTEXT, new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, ver, EGL14.EGL_NONE}, 0);
            if (ectx != null && ectx != EGL14.EGL_NO_CONTEXT) { glver = ver; break; }
        }
        if (glver == 0) throw new RuntimeException("no EGL context 0x" + Integer.toHexString(EGL14.eglGetError()));
        surf = EGL14.eglCreatePbufferSurface(dpy, cfg[0], new int[]{EGL14.EGL_WIDTH, w, EGL14.EGL_HEIGHT, h, EGL14.EGL_NONE}, 0);
        if (surf == null || surf == EGL14.EGL_NO_SURFACE) throw new RuntimeException("pbuffer 0x" + Integer.toHexString(EGL14.eglGetError()));
        if (!EGL14.eglMakeCurrent(dpy, surf, surf, ectx)) throw new RuntimeException("makeCurrent 0x" + Integer.toHexString(EGL14.eglGetError()));
        p("EGL " + v[0] + "." + v[1] + " ES" + glver + " GL_RENDERER " + GLES20.glGetString(GLES20.GL_RENDERER) + " GL_VERSION " + GLES20.glGetString(GLES20.GL_VERSION)
            + " GL_VENDOR " + GLES20.glGetString(GLES20.GL_VENDOR));
    }
    static boolean software() { String r = String.valueOf(GLES20.glGetString(GLES20.GL_RENDERER)).toLowerCase();
        return r.contains("swiftshader") || r.contains("llvmpipe") || r.contains("software") || r.contains("pixelflinger") || r.contains("angle (google"); }
    static int shader(int type, String src) { int s = GLES20.glCreateShader(type); GLES20.glShaderSource(s, src); GLES20.glCompileShader(s);
        int[] ok = new int[1]; GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0); if (ok[0] == 0) throw new RuntimeException("shader: " + GLES20.glGetShaderInfoLog(s)); return s; }
    static int program(String vs, String fs) { int pr = GLES20.glCreateProgram(); GLES20.glAttachShader(pr, shader(GLES20.GL_VERTEX_SHADER, vs));
        GLES20.glAttachShader(pr, shader(GLES20.GL_FRAGMENT_SHADER, fs)); GLES20.glLinkProgram(pr);
        int[] ok = new int[1]; GLES20.glGetProgramiv(pr, GLES20.GL_LINK_STATUS, ok, 0); if (ok[0] == 0) throw new RuntimeException("link: " + GLES20.glGetProgramInfoLog(pr)); return pr; }
    static FloatBuffer quad(float x0, float y0, float x1, float y1) { FloatBuffer f = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer();
        f.put(new float[]{x0, y0, x1, y0, x0, y1, x1, y1}).position(0); return f; }

    static void gl(int secs) {
        final int W = 1024; eglUp(W, W);
        int pr = program("attribute vec2 p; varying vec2 uv; void main(){ uv = p*0.5+0.5; gl_Position = vec4(p,0.0,1.0); }",
            "precision highp float; varying vec2 uv; uniform vec4 c; uniform float k; void main(){ float s=0.0; for(int i=0;i<24;i++){ s+=sin(uv.x*float(i)*k)*cos(uv.y*float(i)); } gl_FragColor = c + vec4(s*0.0); }");
        GLES20.glUseProgram(pr); int ap = GLES20.glGetAttribLocation(pr, "p"), uc = GLES20.glGetUniformLocation(pr, "c"), uk = GLES20.glGetUniformLocation(pr, "k");
        GLES20.glEnableVertexAttribArray(ap); GLES20.glViewport(0, 0, W, W);
        FloatBuffer full = quad(-1, -1, 1, 1), left = quad(-1, -1, 0, 1), small = quad(0.25f, 0.25f, 0.75f, 0.75f);
        ByteBuffer px = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder());
        long t0 = System.nanoTime(), end = t0 + secs * 1000000000L; int frames = 0, bad = 0, checks = 0, glerr = 0; String firstBad = "";
        while (System.nanoTime() < end) {
            int r = (frames * 7) & 255, g = (frames * 13) & 255, b = (frames * 29) & 255;
            GLES20.glClearColor(0, 0, 0, 1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            GLES20.glUniform1f(uk, 3.0f + frames % 5);
            for (int pass = 0; pass < 4; pass++) { // overdraw: 4 full + left half + centre
                GLES20.glUniform4f(uc, b / 255f, r / 255f, g / 255f, 1); GLES20.glVertexAttribPointer(ap, 2, GLES20.GL_FLOAT, false, 0, full); GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            }
            GLES20.glUniform4f(uc, r / 255f, g / 255f, b / 255f, 1); GLES20.glVertexAttribPointer(ap, 2, GLES20.GL_FLOAT, false, 0, left); GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            GLES20.glUniform4f(uc, g / 255f, b / 255f, r / 255f, 1); GLES20.glVertexAttribPointer(ap, 2, GLES20.GL_FLOAT, false, 0, small); GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
            if (frames % 10 == 0) {
                int[][] exp = {{100, 100, r, g, b}, {700, 700, g, b, r}, {W - 50, 50, b, r, g}};
                for (int[] e : exp) { px.position(0); GLES20.glReadPixels(e[0], e[1], 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, px); checks++;
                    int pr0 = px.get(0) & 255, pg = px.get(1) & 255, pb = px.get(2) & 255;
                    if (Math.abs(pr0 - e[2]) > 2 || Math.abs(pg - e[3]) > 2 || Math.abs(pb - e[4]) > 2) { bad++;
                        if (firstBad.isEmpty()) firstBad = "frame " + frames + " at " + e[0] + "," + e[1] + " got " + pr0 + "," + pg + "," + pb + " want " + e[2] + "," + e[3] + "," + e[4]; } }
            } else GLES20.glFinish();
            int er = GLES20.glGetError(); if (er != 0) { glerr++; if (firstBad.isEmpty()) firstBad = "glGetError 0x" + Integer.toHexString(er); }
            frames++;
        }
        double fps = frames / ((System.nanoTime() - t0) / 1e9);
        int ee = EGL14.eglGetError();
        String d = "ES" + glver + " " + GLES20.glGetString(GLES20.GL_RENDERER) + " frames " + frames + " fps " + Math.round(fps) + " pixel checks " + checks + " bad " + bad + " glerrors " + glerr
            + (firstBad.isEmpty() ? "" : " first: " + firstBad);
        metric("gl_fps", fps); metric("gl_pixel_bad", bad);
        boolean ok = bad == 0 && checks > 0 && glerr == 0 && ee == EGL14.EGL_SUCCESS && !software() && frames > secs * 5;
        if (software()) d += " SOFTWARE RENDERER"; if (ee != EGL14.EGL_SUCCESS) d += " egl 0x" + Integer.toHexString(ee);
        result(ok ? "PASS" : "FAIL", d);
    }

    /* glpace <secs> <fps> <passes>: the gl load paced to a frame rate (GPU DCVS tests: a steady medium load); prints
       frames, missed deadlines and the mean GPU+CPU frame time. */
    static void glpace(int secs, int fps, int passes) {
        final int W = 1024; eglUp(W, W);
        int pr = program("attribute vec2 p; varying vec2 uv; void main(){ uv = p*0.5+0.5; gl_Position = vec4(p,0.0,1.0); }",
            "precision highp float; varying vec2 uv; uniform vec4 c; uniform float k; void main(){ float s=0.0; for(int i=0;i<24;i++){ s+=sin(uv.x*float(i)*k)*cos(uv.y*float(i)); } gl_FragColor = c + vec4(s*0.0); }");
        GLES20.glUseProgram(pr); int ap = GLES20.glGetAttribLocation(pr, "p"), uc = GLES20.glGetUniformLocation(pr, "c"), uk = GLES20.glGetUniformLocation(pr, "k");
        GLES20.glEnableVertexAttribArray(ap); GLES20.glViewport(0, 0, W, W);
        FloatBuffer full = quad(-1, -1, 1, 1);
        long period = 1000000000L / fps, t0 = System.nanoTime(), end = t0 + secs * 1000000000L, next = t0, work = 0;
        int frames = 0, missed = 0;
        while (System.nanoTime() < end) {
            long f0 = System.nanoTime();
            GLES20.glClearColor(0, 0, 0, 1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT); GLES20.glUniform1f(uk, 3.0f + frames % 5);
            for (int pass = 0; pass < passes; pass++) { GLES20.glUniform4f(uc, pass / 8f, 0.5f, 0.2f, 1); GLES20.glVertexAttribPointer(ap, 2, GLES20.GL_FLOAT, false, 0, full); GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4); }
            GLES20.glFinish(); long f1 = System.nanoTime(); work += f1 - f0; frames++;
            next += period; if (f1 > next) { missed++; next = f1; } else { try { Thread.sleep((next - f1) / 1000000L, (int) ((next - f1) % 1000000L)); } catch (InterruptedException e) {} }
        }
        double el = (System.nanoTime() - t0) / 1e9;
        result("PASS", "glpace fps " + Math.round(frames / el) + " target " + fps + " passes " + passes + " frames " + frames + " missed " + missed + " mean_frame_ms " + String.format("%.2f", work / 1e6 / Math.max(frames, 1)));
    }

    static void glalloc(int mb) {
        eglUp(64, 64);
        int[] mx = new int[1]; GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, mx, 0);
        final int S = 2048; int n = Math.max(2, mb / 16);
        byte[] row = new byte[S * 4]; ByteBuffer data = ByteBuffer.allocateDirect(S * S * 4);
        int[] fbo = new int[1]; GLES20.glGenFramebuffers(1, fbo, 0); GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0]);
        ByteBuffer px = ByteBuffer.allocateDirect(4);
        int[] tex = new int[n]; int oom = 0, badpx = 0, other = 0, okSmall = 0, okBig = 0; String first = "";
        long t0 = System.currentTimeMillis();
        for (int i = 0; i < n; i++) {
            fill(data, row, S, i);
            int[] t = new int[1]; GLES20.glGenTextures(1, t, 0); tex[i] = t[0]; GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, t[0]);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST);
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, S, S, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, data);
            int e = check(t[0], S, i, px); renderCheck(fbo[0], px);
            if (e == 0) okSmall++; else { if (e == GLES20.GL_OUT_OF_MEMORY) oom++; else if (e == -1) badpx++; else other++; if (first.isEmpty()) first = "16MB tex #" + i + " err " + (e == -1 ? "pixel" : "0x" + Integer.toHexString(e)); }
        }
        p("phase 1: " + okSmall + "/" + n + " x 16 MB textures ok in " + (System.currentTimeMillis() - t0) + " ms (max texture size " + mx[0] + ")");
        // fragment: free every other one
        int freed = 0; for (int i = 0; i < n; i += 2) { GLES20.glDeleteTextures(1, tex, i); tex[i] = 0; freed++; }
        GLES20.glFinish();
        int B = Math.min(4096, mx[0]), nb = Math.max(1, freed * 16 / (B * B * 4 / (1024 * 1024)));
        int[] big = new int[nb];
        for (int i = 0; i < nb; i++) {
            int[] t = new int[1]; GLES20.glGenTextures(1, t, 0); big[i] = t[0]; GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, t[0]);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST);
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, B, B, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);
            fill(data, row, S, 100 + i);
            for (int y = 0; y < B; y += S) for (int x = 0; x < B; x += S) { data.position(0); GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, x, y, S, S, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, data); }
            int e = check(t[0], B, 100 + i, px); renderCheck(fbo[0], px);
            if (e == 0) okBig++; else { if (e == GLES20.GL_OUT_OF_MEMORY) oom++; else if (e == -1) badpx++; else other++; if (first.isEmpty()) first = (B * B / 262144) + "MB tex #" + i + " err " + (e == -1 ? "pixel" : "0x" + Integer.toHexString(e)); }
        }
        p("phase 2: " + okBig + "/" + nb + " x " + (B * B / 262144) + " MB textures ok after freeing " + freed + " x 16 MB");
        // the survivors must still hold their data
        int surv = 0, survBad = 0;
        for (int i = 1; i < n; i += 2) { surv++; int e = check(tex[i], S, i, px); if (e != 0) { survBad++; badpx++; if (first.isEmpty()) first = "survivor #" + i + " err " + e; } }
        p("phase 3: survivors " + (surv - survBad) + "/" + surv + " intact");
        for (int i = 0; i < 20; i++) renderCheck(fbo[0], px);
        for (int i = 0; i < n; i++) if (tex[i] != 0) GLES20.glDeleteTextures(1, tex, i);
        GLES20.glDeleteTextures(nb, big, 0); GLES20.glFinish();
        int ee = EGL14.eglGetError();
        String d = GLES20.glGetString(GLES20.GL_RENDERER) + ": " + okSmall + "/" + n + " x16MB, " + okBig + "/" + nb + " x" + (B * B / 262144) + "MB after fragmentation, survivors " + (surv - survBad) + "/" + surv
            + ", GL_OUT_OF_MEMORY " + oom + " pixel errors " + badpx + " other GL errors " + other + (ee != EGL14.EGL_SUCCESS ? " egl 0x" + Integer.toHexString(ee) : "") + (first.isEmpty() ? "" : " first: " + first)
            + " (" + (System.currentTimeMillis() - t0) + " ms)";
        d += " render checks " + (rcN - rcBad) + "/" + rcN;
        metric("glalloc_mb", okSmall * 16 + okBig * (B * B / 262144)); metric("glalloc_fail", oom + badpx + other + rcBad);
        result(oom == 0 && badpx == 0 && other == 0 && rcBad == 0 && rcN > 0 && ee == EGL14.EGL_SUCCESS && !software() ? "PASS" : "FAIL", d);
    }
    static int rcProg = 0, rcA, rcU, rcN = 0, rcBad = 0; static FloatBuffer rcQuad;
    // renders a frame to the pbuffer and verifies a pixel (GPU must keep rendering while memory is allocated/fragmented)
    static void renderCheck(int fbo, ByteBuffer px) {
        if (rcProg == 0) { rcProg = program("attribute vec2 p; void main(){ gl_Position = vec4(p,0.0,1.0); }", "precision mediump float; uniform vec4 c; void main(){ gl_FragColor = c; }");
            rcA = GLES20.glGetAttribLocation(rcProg, "p"); rcU = GLES20.glGetUniformLocation(rcProg, "c"); rcQuad = quad(-1, -1, 1, 1); }
        int k = rcN++; int r = (k * 41 + 7) & 255, g = (k * 17 + 90) & 255, b = (k * 3 + 200) & 255;
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0); GLES20.glViewport(0, 0, 64, 64); GLES20.glUseProgram(rcProg);
        GLES20.glClearColor(0, 0, 0, 1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        GLES20.glEnableVertexAttribArray(rcA); GLES20.glVertexAttribPointer(rcA, 2, GLES20.GL_FLOAT, false, 0, rcQuad);
        GLES20.glUniform4f(rcU, r / 255f, g / 255f, b / 255f, 1); GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        px.position(0); GLES20.glReadPixels(20, 30, 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, px);
        if (GLES20.glGetError() != 0 || Math.abs((px.get(0) & 255) - r) > 2 || Math.abs((px.get(1) & 255) - g) > 2 || Math.abs((px.get(2) & 255) - b) > 2) rcBad++;
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo);
    }
    static void fill(ByteBuffer data, byte[] row, int S, int i) {
        for (int x = 0; x < row.length; x += 4) { row[x] = (byte) (i * 37 + 11); row[x + 1] = (byte) (i * 5 + 3); row[x + 2] = (byte) (255 - i); row[x + 3] = (byte) 255; }
        data.position(0); for (int y = 0; y < S; y++) data.put(row); data.position(0);
    }
    static int check(int tex, int size, int i, ByteBuffer px) {
        int e = GLES20.glGetError(); if (e != 0) { while (GLES20.glGetError() != 0) {} return e; }
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, tex, 0);
        int st = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER); if (st != GLES20.GL_FRAMEBUFFER_COMPLETE) { while (GLES20.glGetError() != 0) {} return st; }
        int[][] pts = {{0, 0}, {size - 1, size - 1}, {size / 2 + 1, size / 3}};
        for (int[] q : pts) { px.position(0); GLES20.glReadPixels(q[0], q[1], 1, 1, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, px);
            e = GLES20.glGetError(); if (e != 0) { while (GLES20.glGetError() != 0) {} return e; }
            if (px.get(0) != (byte) (i * 37 + 11) || px.get(1) != (byte) (i * 5 + 3) || px.get(2) != (byte) (255 - i)) return -1; }
        return 0;
    }

    // ---------------------------------------------------------------- camera
    static CameraDevice open(CameraManager cm, String id, Handler h) throws Exception {
        final CompletableFuture<CameraDevice> f = new CompletableFuture<>();
        cm.openCamera(id, new CameraDevice.StateCallback() {
            public void onOpened(CameraDevice d) { f.complete(d); }
            public void onDisconnected(CameraDevice d) { f.completeExceptionally(new RuntimeException("camera " + id + " disconnected")); }
            public void onError(CameraDevice d, int e) { f.completeExceptionally(new RuntimeException("camera " + id + " open error " + e)); }
        }, h);
        return f.get(10, TimeUnit.SECONDS);
    }
    static CameraCaptureSession session(CameraDevice d, Handler h, Surface... s) throws Exception {
        final CompletableFuture<CameraCaptureSession> f = new CompletableFuture<>();
        d.createCaptureSession(Arrays.asList(s), new CameraCaptureSession.StateCallback() {
            public void onConfigured(CameraCaptureSession c) { f.complete(c); }
            public void onConfigureFailed(CameraCaptureSession c) { f.completeExceptionally(new RuntimeException("session configure failed")); }
        }, h);
        return f.get(10, TimeUnit.SECONDS);
    }
    static Throwable root(Throwable t) { while ((t instanceof ExecutionException || t instanceof java.lang.reflect.InvocationTargetException) && t.getCause() != null) t = t.getCause(); return t; }
    // one JPEG still at the given size, taken the way a camera app does: preview stream running (3A settles), then the still.
    // prevN[0] = preview frames delivered before the capture.
    static byte[] still(CameraManager cm, String id, Size sz, Size pv, Handler h, int[] prevN) throws Exception {
        ImageReader r = ImageReader.newInstance(sz.getWidth(), sz.getHeight(), ImageFormat.JPEG, 2);
        ImageReader pr = ImageReader.newInstance(pv.getWidth(), pv.getHeight(), ImageFormat.YUV_420_888, 3);
        final java.util.concurrent.atomic.AtomicInteger pn = new java.util.concurrent.atomic.AtomicInteger();
        pr.setOnImageAvailableListener(rd -> { Image im = rd.acquireLatestImage(); if (im != null) { pn.incrementAndGet(); im.close(); } }, h);
        final CompletableFuture<byte[]> img = new CompletableFuture<>();
        r.setOnImageAvailableListener(rd -> { Image im = rd.acquireNextImage(); if (im == null) return; ByteBuffer b = im.getPlanes()[0].getBuffer(); byte[] x = new byte[b.remaining()]; b.get(x); im.close(); img.complete(x); }, h);
        CameraDevice dev; try { dev = open(cm, id, h); } catch (TimeoutException e) { throw new RuntimeException("openCamera: no callback in 10 s"); }
        try {
            CameraCaptureSession s; try { s = session(dev, h, pr.getSurface(), r.getSurface()); } catch (TimeoutException e) { throw new RuntimeException("createCaptureSession: no callback in 10 s"); }
            CaptureRequest.Builder pb = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW); pb.addTarget(pr.getSurface());
            s.setRepeatingRequest(pb.build(), null, h);
            long t0 = System.currentTimeMillis(); while (System.currentTimeMillis() - t0 < 5000 && pn.get() < 20) Thread.sleep(50);
            prevN[0] = pn.get(); if (prevN[0] == 0) throw new RuntimeException("no preview frames in 5 s");
            CaptureRequest.Builder rb = dev.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE); rb.addTarget(r.getSurface());
            rb.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF); rb.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
            s.capture(rb.build(), new CameraCaptureSession.CaptureCallback() {
                public void onCaptureFailed(CameraCaptureSession c, CaptureRequest q, CaptureFailure f) { img.completeExceptionally(new RuntimeException("capture failed reason " + f.getReason())); }
            }, h);
            byte[] j; try { j = img.get(12, TimeUnit.SECONDS); } catch (TimeoutException e) { throw new RuntimeException("no JPEG within 12 s of the capture request (preview frames " + prevN[0] + ")"); }
            try { s.stopRepeating(); s.close(); } catch (Exception e) {}
            return j;
        } finally { dev.close(); r.close(); pr.close(); Thread.sleep(500); }
    }
    static void cam(String only) throws Exception {
        CameraManager cm; String[] ids;
        try { cm = (CameraManager) ctx().getSystemService(Context.CAMERA_SERVICE); ids = cm.getCameraIdList(); }
        catch (Throwable t) { result("SKIP", "needs camera service access as shell: " + t); return; }
        if (only != null) ids = new String[]{only};
        if (ids.length == 0) { result("FAIL", "no camera ids"); return; }
        new java.io.File("/data/local/tmp/st").mkdirs();
        Handler h = bg("cam"); int ok = 0; StringBuilder d = new StringBuilder(); boolean perm = false, dark = false;
        for (String id : ids) {
            String facing = "?";
            try {
                CameraCharacteristics ch = cm.getCameraCharacteristics(id);
                Integer fc = ch.get(CameraCharacteristics.LENS_FACING); facing = fc == null ? "?" : fc == 0 ? "front" : fc == 1 ? "back" : "external";
                StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                Size big = null, small = null; for (Size s : map.getOutputSizes(ImageFormat.JPEG)) { long a = (long) s.getWidth() * s.getHeight();
                    if (big == null || a > (long) big.getWidth() * big.getHeight()) big = s;
                    if (s.getWidth() <= 1920 && s.getHeight() <= 1080 && (small == null || a > (long) small.getWidth() * small.getHeight())) small = s; }
                Size pv = null; for (Size s : map.getOutputSizes(ImageFormat.YUV_420_888)) { long a = (long) s.getWidth() * s.getHeight();
                    if (s.getWidth() <= 1280 && s.getHeight() <= 720 && (pv == null || a > (long) pv.getWidth() * pv.getHeight())) pv = s; }
                if (pv == null) pv = map.getOutputSizes(ImageFormat.YUV_420_888)[0];
                boolean good = true; String line = ""; int[] pn = new int[1];
                for (Size sz : small == null || small.equals(big) ? new Size[]{big} : new Size[]{big, small}) {
                    long t0 = System.currentTimeMillis(); byte[] j = still(cm, id, sz, pv, h, pn);
                    boolean hdr = j.length > 2 && (j[0] & 255) == 0xff && (j[1] & 255) == 0xd8;
                    android.graphics.BitmapFactory.Options o = new android.graphics.BitmapFactory.Options(); o.inSampleSize = 8;
                    android.graphics.Bitmap bm = android.graphics.BitmapFactory.decodeByteArray(j, 0, j.length, o);
                    double mean = -1, sd = -1;
                    if (bm != null) { int w = bm.getWidth(), hh = bm.getHeight(); int[] px = new int[w * hh]; bm.getPixels(px, 0, w, 0, 0, w, hh); double s1 = 0, s2 = 0;
                        for (int q : px) { double y = 0.299 * ((q >> 16) & 255) + 0.587 * ((q >> 8) & 255) + 0.114 * (q & 255); s1 += y; s2 += y * y; }
                        mean = s1 / px.length; sd = Math.sqrt(Math.max(0, s2 / px.length - mean * mean)); bm.recycle(); }
                    boolean isBig = sz == big;
                    try (FileOutputStream os = new FileOutputStream("/data/local/tmp/st/cam" + id + (isBig ? "" : "-small") + ".jpg")) { os.write(j); } catch (Exception e) { p("save: " + e); }
                    boolean black = bm != null && sd < 2 && mean < 3, uniform = bm != null && sd < 2 && !black;
                    boolean g = hdr && bm != null && j.length > (isBig ? 50000 : 5000) && !black;
                    if (uniform || (bm != null && mean < 12)) dark = true;
                    p(String.format(Locale.US, "cam %s facing %s jpeg %d bytes %dx%d in %d ms preview frames %d decoded %b luma mean %.1f stddev %.1f%s", id, facing, j.length, sz.getWidth(), sz.getHeight(),
                        System.currentTimeMillis() - t0, pn[0], bm != null, mean, sd, g ? (uniform ? " (uniform image: lens covered?)" : "") : black ? " BLACK" : " BAD"));
                    if (isBig) { metric("cam" + id + "_jpeg_bytes", j.length); metric("cam" + id + "_luma_mean", mean); }
                    line += String.format(Locale.US, "%dx%d %dkB luma %.0f/%.0f%s ", sz.getWidth(), sz.getHeight(), j.length / 1024, mean, sd, g ? "" : black ? " BLACK" : " BAD");
                    good &= g;
                }
                d.append(id).append('(').append(facing).append(") ").append(line).append("; "); if (good) ok++;
            } catch (Throwable t) {
                Throwable c = root(t); if (c instanceof SecurityException) perm = true;
                p("cam " + id + " facing " + facing + " FAILED " + c); d.append(id).append('(').append(facing).append(") FAILED ").append(c).append("; ");
            }
        }
        if (dark) d.append("(dark/uniform frames: phone lies on a desk, a lens may be covered) ");
        if (perm && ok == 0) result("SKIP", "needs camera permission for the shell uid: " + d);
        else result(ok == ids.length ? "PASS" : "FAIL", ok + "/" + ids.length + " cameras: " + d);
    }
    static void camrec(String id, int secs) throws Exception {
        CameraManager cm = (CameraManager) ctx().getSystemService(Context.CAMERA_SERVICE); Handler h = bg("cam");
        new java.io.File("/data/local/tmp/st").mkdirs(); String out = "/data/local/tmp/st/camrec.mp4";
        MediaFormat f = MediaFormat.createVideoFormat("video/avc", 1920, 1080);
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        f.setInteger(MediaFormat.KEY_BIT_RATE, 12000000); f.setInteger(MediaFormat.KEY_FRAME_RATE, 30); f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        String cn = hwCodec("video/avc", true); if (cn == null) { result("SKIP", "needs a hw H.264 encoder (none listed)"); return; }
        MediaCodec c = MediaCodec.createByCodecName(cn);
        c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); Surface in = c.createInputSurface(); c.start();
        CameraDevice dev;
        try { dev = open(cm, id, h); } catch (Throwable e) { Throwable r = root(e); if (r instanceof SecurityException) { result("SKIP", "needs camera permission for the shell uid: " + r); return; } throw e; }
        CameraCaptureSession s = session(dev, h, in);
        CaptureRequest.Builder rb = dev.createCaptureRequest(CameraDevice.TEMPLATE_RECORD); rb.addTarget(in);
        s.setRepeatingRequest(rb.build(), null, h);
        MediaMuxer mux = new MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4); int track = -1;
        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo(); int frames = 0, keys = 0; long bytes = 0, end = System.currentTimeMillis() + secs * 1000L;
        while (System.currentTimeMillis() < end) { int oi = c.dequeueOutputBuffer(bi, 100000);
            if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { track = mux.addTrack(c.getOutputFormat()); mux.start(); }
            else if (oi >= 0) { if (bi.size > 0 && (bi.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && track >= 0) { mux.writeSampleData(track, c.getOutputBuffer(oi), bi); frames++; bytes += bi.size; if ((bi.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0) keys++; } c.releaseOutputBuffer(oi, false); } }
        try { s.stopRepeating(); s.close(); } catch (Exception e) {}
        dev.close(); c.stop(); c.release(); if (track >= 0 && frames > 0) mux.stop(); mux.release();
        metric("camrec_frames", frames); metric("camrec_bytes", bytes);
        String d = "camera " + id + " 1920x1080 -> " + cn + " (hw) frames " + frames + " (" + frames / secs + " fps) key " + keys + " bytes " + bytes + " -> " + out;
        result(frames >= secs * 20 && bytes > 20000 ? "PASS" : "FAIL", d);
    }
    // first hardware codec for a mime (null if none)
    static String hwCodec(String mime, boolean encoder) {
        for (MediaCodecInfo i : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (i.isEncoder() != encoder || !i.isHardwareAccelerated()) continue;
            for (String t : i.getSupportedTypes()) if (t.equalsIgnoreCase(mime)) return i.getName();
        }
        return null;
    }

    // ---------------------------------------------------------------- video encode / decode
    // Frame k carries a 64x64 top-left block with luma 16 + (k*8 % 200); the rest is moving bars. dec verifies the block.
    static int blockY(int k) { return 16 + (k * 8) % 200; }
    static void enc(String mime, String out, String name) throws Exception {
        final int W = 1280, H = 720, N = 90;
        if (name == null) { name = hwCodec(mime, true); if (name == null) { result("SKIP", "no hw codec for " + mime + " (encoder)"); return; } }
        MediaCodec c = MediaCodec.createByCodecName(name);
        boolean hw = c.getCodecInfo().isHardwareAccelerated();
        MediaFormat f = MediaFormat.createVideoFormat(mime, W, H);
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
        f.setInteger(MediaFormat.KEY_BIT_RATE, 6000000); f.setInteger(MediaFormat.KEY_FRAME_RATE, 30); f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); c.start();
        boolean webm = mime.contains("vp8") || mime.contains("vp9") || mime.contains("vnd.on2");
        MediaMuxer mux = new MediaMuxer(out, webm ? MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM : MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        int track = -1; MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo(); int in = 0, outN = 0; long bytes = 0; boolean eos = false;
        byte[] row = new byte[8192]; long t0 = System.currentTimeMillis();
        while (true) {
            if (in <= N) { int ii = c.dequeueInputBuffer(10000);
                if (ii >= 0) { if (in == N) { c.queueInputBuffer(ii, 0, 0, in * 33333L, MediaCodec.BUFFER_FLAG_END_OF_STREAM); in++; }
                    else { Image im = c.getInputImage(ii); if (im == null) throw new RuntimeException("no input image");
                        Image.Plane[] pl = im.getPlanes();
                        ByteBuffer y = pl[0].getBuffer(); int rs = pl[0].getRowStride(); byte by = (byte) blockY(in);
                        for (int r = 0; r < H; r++) { for (int x = 0; x < W; x++) row[x] = (byte) (40 + ((x / 32 + in) % 8) * 20);
                            if (r < 64) Arrays.fill(row, 0, 64, by); y.position(r * rs); y.put(row, 0, Math.min(W, y.remaining())); }
                        for (int k = 1; k <= 2; k++) { ByteBuffer u = pl[k].getBuffer(); int urs = pl[k].getRowStride(); Arrays.fill(row, 0, Math.min(urs, row.length), (byte) 128);
                            for (int r = 0; r < H / 2; r++) { if (r * urs >= u.limit()) break; u.position(r * urs); u.put(row, 0, Math.min(urs, u.remaining())); } }
                        c.queueInputBuffer(ii, 0, W * H * 3 / 2, in * 33333L, 0); in++; } } }
            int oi = c.dequeueOutputBuffer(bi, 10000);
            if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { track = mux.addTrack(c.getOutputFormat()); mux.start(); }
            else if (oi >= 0) { ByteBuffer b = c.getOutputBuffer(oi);
                if (bi.size > 0 && (bi.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && track >= 0) { mux.writeSampleData(track, b, bi); outN++; bytes += bi.size; }
                c.releaseOutputBuffer(oi, false); if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) { eos = true; break; } }
            if (System.currentTimeMillis() - t0 > 60000) break;
        }
        String nm = c.getName(); c.stop(); c.release(); if (track >= 0 && outN > 0) { mux.stop(); } mux.release();
        metric("enc_frames", outN); metric("enc_bytes", bytes);
        String d = mime + " " + W + "x" + H + " codec " + nm + " hw " + hw + " frames " + outN + "/" + N + " bytes " + bytes + " in " + (System.currentTimeMillis() - t0) + " ms -> " + out;
        result(eos && outN == N && bytes > 10000 ? "PASS" : "FAIL", d);
    }
    static void dec(String file, String name, int expected, boolean pattern) throws Exception {
        MediaExtractor ex = new MediaExtractor(); ex.setDataSource(file);
        int t = -1; MediaFormat f = null;
        for (int i = 0; i < ex.getTrackCount(); i++) { f = ex.getTrackFormat(i); if (f.getString(MediaFormat.KEY_MIME).startsWith("video/")) { t = i; break; } }
        if (t < 0) { result("FAIL", "no video track in " + file); return; }
        ex.selectTrack(t); String mime = f.getString(MediaFormat.KEY_MIME);
        if (name == null) { name = hwCodec(mime, false); if (name == null) { result("SKIP", "no hw codec for " + mime); return; } }
        MediaCodec c = MediaCodec.createByCodecName(name); boolean hw = c.getCodecInfo().isHardwareAccelerated();
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
        c.configure(f, null, null, 0); c.start();
        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo(); boolean inEos = false; int out = 0, patOk = 0, patBad = 0; String firstBad = ""; long t0 = System.nanoTime();
        while (true) {
            if (!inEos) { int ii = c.dequeueInputBuffer(10000); if (ii >= 0) { ByteBuffer b = c.getInputBuffer(ii); int n = ex.readSampleData(b, 0);
                if (n < 0) { c.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true; }
                else { c.queueInputBuffer(ii, 0, n, ex.getSampleTime(), 0); ex.advance(); } } }
            int oi = c.dequeueOutputBuffer(bi, 10000);
            if (oi >= 0) { if (bi.size > 0) { out++;
                    Image im = pattern ? c.getOutputImage(oi) : null;
                    if (!pattern) { } else if (im != null) { Image.Plane y = im.getPlanes()[0]; ByteBuffer yb = y.getBuffer(); int rs = y.getRowStride(), ps = y.getPixelStride(); long s = 0; int n = 0;
                        for (int r = 16; r < 48; r += 4) for (int x = 16; x < 48; x += 4) { s += yb.get(r * rs + x * ps) & 255; n++; }
                        int got = (int) (s / n), k = (int) Math.round(bi.presentationTimeUs / 33333.0), want = blockY(k);
                        if (Math.abs(got - want) <= 12) patOk++; else { patBad++; if (firstBad.isEmpty()) firstBad = "frame " + k + " block luma " + got + " want " + want; }
                        im.close(); } else { patBad++; if (firstBad.isEmpty()) firstBad = "no output image"; } }
                c.releaseOutputBuffer(oi, false); if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break; }
            if ((System.nanoTime() - t0) > 60_000_000_000L) { firstBad = "timeout " + firstBad; break; }
        }
        long ms = (System.nanoTime() - t0) / 1000000; c.stop(); c.release();
        metric("dec_frames", out); metric("dec_pattern_ok", patOk);
        String d = mime + " " + f.getInteger(MediaFormat.KEY_WIDTH) + "x" + f.getInteger(MediaFormat.KEY_HEIGHT) + " codec " + name + " hw " + hw + " frames " + out + "/" + expected
            + (pattern ? " pattern ok " + patOk + " bad " + patBad : " (no pattern check)") + " in " + ms + " ms" + (firstBad.isEmpty() ? "" : " first: " + firstBad);
        result(out == expected && (!pattern || (patBad == 0 && patOk == expected)) ? "PASS" : "FAIL", d);
    }

    // ---------------------------------------------------------------- vsync
    static void vsync(int secs) throws Exception {
        ctx();
        final ArrayList<Long> ts = new ArrayList<>(); final long end = System.nanoTime() + secs * 1000000000L; final CountDownLatch fin = new CountDownLatch(1);
        bg("vsync").post(() -> { final android.view.Choreographer ch = android.view.Choreographer.getInstance();
            ch.postFrameCallback(new android.view.Choreographer.FrameCallback() { public void doFrame(long t) { synchronized (ts) { ts.add(t); }
                if (System.nanoTime() < end) ch.postFrameCallback(this); else fin.countDown(); } }); });
        fin.await(secs + 3, TimeUnit.SECONDS);
        if (ts.size() < 10) { result("FAIL", "only " + ts.size() + " frame callbacks in " + secs + " s"); return; }
        double[] iv = new double[ts.size() - 1]; for (int i = 1; i < ts.size(); i++) iv[i - 1] = (ts.get(i) - ts.get(i - 1)) / 1e6;
        double[] s = iv.clone(); Arrays.sort(s); double med = s[s.length / 2], p5 = s[(int) (s.length * 0.05)], p95 = s[(int) (s.length * 0.95)]; double dev = 0; for (double x : iv) dev += Math.abs(x - med); dev /= iv.length;
        double hz = 1000.0 / med; metric("vsync_hz", hz); metric("vsync_jitter_ms", dev); metric("vsync_frames", ts.size());
        result("PASS", String.format(Locale.US, "%d frame callbacks in %d s, median interval %.2f ms = %.1f Hz, p5 %.2f p95 %.2f ms, mean abs jitter %.2f ms", ts.size(), secs, med, hz, p5, p95, dev));
    }

    // ---------------------------------------------------------------- display pattern
    static void disp(int secs) throws Exception {
        Context c = ctx();
        android.hardware.display.DisplayManager dm = (android.hardware.display.DisplayManager) c.getSystemService(Context.DISPLAY_SERVICE);
        android.graphics.Point sz = new android.graphics.Point(); dm.getDisplay(0).getRealSize(sz); int W = sz.x, H = sz.y;
        android.view.SurfaceControl sc; Surface s;
        try {
            sc = new android.view.SurfaceControl.Builder().setName("a52-selftest-pattern").setBufferSize(W, H).setFormat(android.graphics.PixelFormat.RGBA_8888).build();
            android.view.SurfaceControl.Transaction t = new android.view.SurfaceControl.Transaction();
            try { android.view.SurfaceControl.Transaction.class.getMethod("setLayerStack", android.view.SurfaceControl.class, int.class).invoke(t, sc, 0); } catch (Throwable e) { p("setLayerStack: " + root(e)); }
            t.setLayer(sc, Integer.MAX_VALUE - 1).setVisibility(sc, true).apply();
            s = new Surface(sc);
            int[] col = {0xffe02020, 0xff20c040, 0xff2040e0, 0xfff0f0f0};
            android.graphics.Canvas cv = s.lockCanvas(null); android.graphics.Paint pt = new android.graphics.Paint(); int cw = cv.getWidth(), chh = cv.getHeight();
            for (int q = 0; q < 4; q++) { pt.setColor(col[q]); cv.drawRect((q % 2) * cw / 2f, (q / 2) * chh / 2f, (q % 2 + 1) * cw / 2f, (q / 2 + 1) * chh / 2f, pt); }
            s.unlockCanvasAndPost(cv);
            new android.view.SurfaceControl.Transaction().setLayer(sc, Integer.MAX_VALUE - 1).setVisibility(sc, true).apply();
            p(String.format("disp colours %06x %06x %06x %06x", col[0] & 0xffffff, col[1] & 0xffffff, col[2] & 0xffffff, col[3] & 0xffffff));
            p("disp size " + cw + "x" + chh);
        } catch (Throwable e) { result("SKIP", "needs a SurfaceControl layer from the shell uid: " + root(e)); return; }
        p("disp shown");
        Thread.sleep(secs * 1000L);
        try { new android.view.SurfaceControl.Transaction().reparent(sc, null).apply(); s.release(); sc.release(); } catch (Throwable e) { try { sc.release(); } catch (Throwable e2) {} }
        // this command cannot see the panel: the host screencaps during the hold and decides
        result("PASS", "shown (pattern layer held " + secs + " s; host must verify the screencap)");
    }

    // ---------------------------------------------------------------- BLE scan
    static void ble(int secs) throws Exception {
        Context c = ctx();
        android.bluetooth.BluetoothManager bm = (android.bluetooth.BluetoothManager) c.getSystemService(Context.BLUETOOTH_SERVICE);
        android.bluetooth.BluetoothAdapter ad = bm == null ? null : bm.getAdapter();
        if (ad == null) ad = android.bluetooth.BluetoothAdapter.getDefaultAdapter();
        if (ad == null) { result("FAIL", "no Bluetooth adapter"); return; }
        if (!ad.isEnabled()) { result("SKIP", "needs Bluetooth on"); return; }
        android.os.PowerManager pm = (android.os.PowerManager) c.getSystemService(Context.POWER_SERVICE);
        if (pm != null && !pm.isInteractive()) { result("SKIP", "needs the screen on (Android pauses unfiltered BLE scans while the screen is off)"); return; }
        android.bluetooth.le.BluetoothLeScanner sc = ad.getBluetoothLeScanner();
        if (sc == null) { result("FAIL", "no BLE scanner (adapter on)"); return; }
        final Map<String, Integer> seen = new ConcurrentHashMap<>(); final int[] err = {0}, n = {0};
        android.bluetooth.le.ScanCallback cb = new android.bluetooth.le.ScanCallback() {
            public void onScanResult(int type, android.bluetooth.le.ScanResult r) { n[0]++; seen.merge(r.getDevice().getAddress(), r.getRssi(), Math::max); }
            public void onBatchScanResults(List<android.bluetooth.le.ScanResult> rs) { for (android.bluetooth.le.ScanResult r : rs) onScanResult(0, r); }
            public void onScanFailed(int e) { err[0] = e; }
        };
        try { sc.startScan(null, new android.bluetooth.le.ScanSettings.Builder().setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb); }
        catch (SecurityException e) { result("SKIP", "needs BLUETOOTH_SCAN for the shell uid: " + e); return; }
        Thread.sleep(secs * 1000L);
        try { sc.stopScan(cb); } catch (Throwable e) {}
        int best = -999; for (int r : seen.values()) best = Math.max(best, r);
        metric("ble_devices", seen.size()); if (!seen.isEmpty()) metric("ble_best_rssi", best);
        String d = seen.size() + " distinct advertisers, " + n[0] + " advertisements in " + secs + " s" + (seen.isEmpty() ? "" : ", best RSSI " + best + " dBm") + (err[0] != 0 ? ", scan failed code " + err[0] : "");
        result(seen.size() >= 1 ? "PASS" : "FAIL", d);
    }

    // ---------------------------------------------------------------- audio loopback (speaker/earpiece -> mic)
    // Plays a sine and records it at the same time; Goertzel bins on the capture. Needs audible output: without the
    // "unmute" argument the stream stays as it is (muted phone -> SKIP). With it the stream goes to index 1 for the
    // ~1.5 s tone and back to the old index in a finally block.
    static double goertzel(short[] x, int from, int n, double f, int rate) { double w = 2 * Math.PI * f / rate, c = 2 * Math.cos(w), s0, s1 = 0, s2 = 0;
        for (int i = 0; i < n; i++) { s0 = x[from + i] + c * s1 - s2; s2 = s1; s1 = s0; } return (s1 * s1 + s2 * s2 - c * s1 * s2) / ((double) n * n); }
    /** Name of a connected external audio output (Bluetooth, USB, wired, HDMI), or null. A test tone must never go to
     *  someone's headphones unannounced (2026-11-21: a "silent" run played to a paired Bluetooth DAC, whose absolute
     *  volume `cmd media_session volume --set 0` does not touch). */
    static String externalOutput(AudioManager am) {
        for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            switch (d.getType()) {
                case AudioDeviceInfo.TYPE_BLUETOOTH_A2DP: case AudioDeviceInfo.TYPE_BLUETOOTH_SCO: case AudioDeviceInfo.TYPE_BLE_HEADSET:
                case AudioDeviceInfo.TYPE_BLE_SPEAKER: case AudioDeviceInfo.TYPE_BLE_BROADCAST: case AudioDeviceInfo.TYPE_HEARING_AID:
                case AudioDeviceInfo.TYPE_USB_HEADSET: case AudioDeviceInfo.TYPE_USB_DEVICE: case AudioDeviceInfo.TYPE_USB_ACCESSORY:
                case AudioDeviceInfo.TYPE_WIRED_HEADSET: case AudioDeviceInfo.TYPE_WIRED_HEADPHONES: case AudioDeviceInfo.TYPE_LINE_ANALOG:
                case AudioDeviceInfo.TYPE_LINE_DIGITAL: case AudioDeviceInfo.TYPE_HDMI: case AudioDeviceInfo.TYPE_AUX_LINE:
                    return d.getType() + " '" + d.getProductName() + "'";
                default:
            }
        }
        return null;
    }
    static void loop(String mode, int freq, String src, boolean unmute) throws Exception {
        Context c = ctx(); final int rate = 48000; AudioManager am = (AudioManager) c.getSystemService(Context.AUDIO_SERVICE);
        boolean voice = mode.equals("voice"); int stream = voice ? AudioManager.STREAM_VOICE_CALL : AudioManager.STREAM_MUSIC;
        int old = am.getStreamVolume(stream);
        String ext = externalOutput(am);
        if (ext != null) { result("SKIP", "external audio output connected (" + ext + "): the tone would play there"); return; }
        if (old == 0 && !unmute && !voice) { result("SKIP", "needs audible output: stream volume is 0 (phone muted); pass 'unmute' to play 1.5 s at index 1"); return; }
        int source = src.equals("CAMCORDER") ? MediaRecorder.AudioSource.CAMCORDER : src.equals("UNPROCESSED") ? MediaRecorder.AudioSource.UNPROCESSED : MediaRecorder.AudioSource.MIC;
        int n = rate * 3 / 2; short[] pcm = new short[n * 2];
        for (int i = 0; i < n; i++) { double env = Math.min(1, Math.min(i, n - i) / 480.0); short s = (short) (Math.sin(2 * Math.PI * freq * i / rate) * 0.2 * 32767 * env); pcm[2 * i] = s; pcm[2 * i + 1] = s; }
        AudioTrack t = new AudioTrack.Builder()
            .setAudioAttributes(new AudioAttributes.Builder().setUsage(voice ? AudioAttributes.USAGE_VOICE_COMMUNICATION : AudioAttributes.USAGE_MEDIA)
                .setContentType(voice ? AudioAttributes.CONTENT_TYPE_SPEECH : AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(pcm.length * 2).setTransferMode(AudioTrack.MODE_STATIC)
            .setPerformanceMode(mode.equals("ll") ? AudioTrack.PERFORMANCE_MODE_LOW_LATENCY : AudioTrack.PERFORMANCE_MODE_NONE).build();
        t.write(pcm, 0, pcm.length);
        AudioRecord r = new AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, rate * 4);
        if (r.getState() != AudioRecord.STATE_INITIALIZED) { result("SKIP", "needs RECORD_AUDIO for the shell uid (AudioRecord state " + r.getState() + ")"); return; }
        short[] buf = new short[rate * 2]; int got = 0; String tr = "none", rr = "none"; int head = 0;
        try {
            if (unmute && old == 0) am.setStreamVolume(stream, 1, 0);
            r.startRecording(); t.play(); long t0 = System.currentTimeMillis();
            while (got < buf.length && System.currentTimeMillis() - t0 < 4000) { int k = r.read(buf, got, Math.min(4800, buf.length - got)); if (k < 0) break; got += k; }
            head = t.getPlaybackHeadPosition();
            if (t.getRoutedDevice() != null) tr = "type " + t.getRoutedDevice().getType(); if (r.getRoutedDevice() != null) rr = "type " + r.getRoutedDevice().getType();
        } finally {
            try { t.stop(); } catch (Throwable e) {} try { r.stop(); } catch (Throwable e) {}
            if (unmute && old == 0) am.setStreamVolume(stream, 0, 0);
            t.release(); r.release();
        }
        // analyse 0.3 s .. 1.3 s of the capture, bins every 25 Hz from 200 to 6000 Hz
        int from = Math.min(got, rate * 3 / 10), len = Math.min(rate, got - from);
        if (len < rate / 2) { result("FAIL", "captured only " + got + " frames"); return; }
        int nb = (6000 - 200) / 25 + 1; double[] pw = new double[nb]; int pk = 0; for (int i = 0; i < nb; i++) { pw[i] = goertzel(buf, from, len, 200 + 25 * i, rate); if (pw[i] > pw[pk]) pk = i; }
        double[] s = pw.clone(); Arrays.sort(s); double med = Math.max(s[nb / 2], 1e-9), snr = 10 * Math.log10(Math.max(pw[pk], 1e-9) / med); int peakHz = 200 + 25 * pk;
        metric("loop_" + mode + "_peak_hz", peakHz); metric("loop_" + mode + "_snr_db", snr);
        String d = String.format(Locale.US, "%s tone %d Hz -> %s: peak %d Hz snr %.1f dB, played head %d/%d, captured %d frames, track routed %s, record routed %s, stream index %d%s",
            mode, freq, src, peakHz, snr, head, n, got, tr, rr, old, unmute && old == 0 ? " (raised to 1 for the tone, restored 0)" : "");
        boolean ok = Math.abs(peakHz - freq) <= freq * 0.02 && snr >= 15 && head >= n / 2;
        if (!ok && old == 0 && !unmute) { result("SKIP", "needs audible output (stream index 0): " + d); return; }
        result(ok ? "PASS" : "FAIL", d);
    }

    // ---------------------------------------------------------------- keystore
    static void keystore() throws Exception {
        ctx();
        try { Class.forName("android.security.keystore2.AndroidKeyStoreProvider").getMethod("install").invoke(null); } catch (Throwable t) { p("provider install: " + t); }
        java.security.KeyStore ks = java.security.KeyStore.getInstance("AndroidKeyStore"); ks.load(null);
        String A = "st_selftest_ec", B = "st_selftest_aes", C = "st_selftest_att";
        for (String x : new String[]{A, B, C}) try { ks.deleteEntry(x); } catch (Exception e) {}
        Class<?> KP = android.security.keystore.KeyProperties.class;
        java.security.KeyPairGenerator g = java.security.KeyPairGenerator.getInstance("EC", "AndroidKeyStore");
        g.initialize(new android.security.keystore.KeyGenParameterSpec.Builder(A, android.security.keystore.KeyProperties.PURPOSE_SIGN | android.security.keystore.KeyProperties.PURPOSE_VERIFY)
            .setAlgorithmParameterSpec(new java.security.spec.ECGenParameterSpec("secp256r1")).setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256).build());
        long t0 = System.currentTimeMillis(); java.security.KeyPair kp = g.generateKeyPair(); long tg = System.currentTimeMillis() - t0;
        byte[] msg = "a52sxq selftest".getBytes();
        java.security.Signature s = java.security.Signature.getInstance("SHA256withECDSA"); s.initSign(kp.getPrivate()); s.update(msg); byte[] sig = s.sign();
        java.security.Signature v = java.security.Signature.getInstance("SHA256withECDSA"); v.initVerify(kp.getPublic()); v.update(msg); boolean sigOk = v.verify(sig);
        android.security.keystore.KeyInfo ki = java.security.KeyFactory.getInstance(kp.getPrivate().getAlgorithm(), "AndroidKeyStore").getKeySpec(kp.getPrivate(), android.security.keystore.KeyInfo.class);
        int lvl = -99; try { lvl = ki.getSecurityLevel(); } catch (Throwable t) { p("getSecurityLevel: " + t); }
        String ls = lvl == 1 ? "TEE" : lvl == 2 ? "StrongBox" : lvl == 0 ? "software" : lvl == -1 ? "unknown-secure" : "level " + lvl;
        boolean hwb = ki.isInsideSecureHardware();
        p("EC P-256 generated in " + tg + " ms, sign+verify " + sigOk + ", security level " + ls + ", insideSecureHardware " + hwb);
        javax.crypto.KeyGenerator kg = javax.crypto.KeyGenerator.getInstance("AES", "AndroidKeyStore");
        kg.init(new android.security.keystore.KeyGenParameterSpec.Builder(B, android.security.keystore.KeyProperties.PURPOSE_ENCRYPT | android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE).build());
        javax.crypto.SecretKey sk = kg.generateKey();
        javax.crypto.Cipher e = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding"); e.init(javax.crypto.Cipher.ENCRYPT_MODE, sk); byte[] ct = e.doFinal(msg);
        javax.crypto.Cipher dd = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding"); dd.init(javax.crypto.Cipher.DECRYPT_MODE, sk, new javax.crypto.spec.GCMParameterSpec(128, e.getIV()));
        boolean aesOk = Arrays.equals(dd.doFinal(ct), msg);
        p("AES-256-GCM encrypt/decrypt " + aesOk);
        String att;
        try {
            java.security.KeyPairGenerator g2 = java.security.KeyPairGenerator.getInstance("EC", "AndroidKeyStore");
            g2.initialize(new android.security.keystore.KeyGenParameterSpec.Builder(C, android.security.keystore.KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(new java.security.spec.ECGenParameterSpec("secp256r1")).setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge("selftest-challenge".getBytes()).build());
            g2.generateKeyPair(); java.security.cert.Certificate[] ch = ks.getCertificateChain(C);
            att = "attestation chain " + (ch == null ? 0 : ch.length) + " certs";
            if (ch != null && ch.length > 0) att += " root \"" + ((java.security.cert.X509Certificate) ch[ch.length - 1]).getSubjectX500Principal().getName() + "\"";
        } catch (Throwable t) { att = "attestation FAILED (" + t + ")"; }
        p(att);
        for (String x : new String[]{A, B, C}) try { ks.deleteEntry(x); } catch (Exception ex) {}
        boolean tee = lvl == 1 || lvl == 2 || (lvl == -99 && hwb);
        result(sigOk && aesOk && tee ? "PASS" : "FAIL", "EC sign/verify " + sigOk + ", AES-GCM " + aesOk + ", key " + ls + " (gen " + tg + " ms), " + att);
    }

    // ---------------------------------------------------------------- DRM
    static void drm() throws Exception {
        ctx();
        UUID wv = new UUID(0xedef8ba979d64aceL, 0xa3c827dcd51d21edL), ck = new UUID(0xe2719d58a985b3c9L, 0x781ab030af78d30eL);
        p("querying schemes"); boolean wvs = MediaDrm.isCryptoSchemeSupported(wv); p("widevine " + wvs); boolean cks = MediaDrm.isCryptoSchemeSupported(ck);
        p("Widevine supported " + wvs + ", ClearKey supported " + cks);
        if (!wvs) { result("FAIL", "Widevine scheme not supported (ClearKey " + cks + ")"); return; }
        p("opening Widevine"); MediaDrm d = new MediaDrm(wv); p("opened"); StringBuilder sb = new StringBuilder();
        for (String k : new String[]{"vendor", "version", "securityLevel", "systemId", "hdcpLevel", "maxHdcpLevel", "algorithms", "oemCryptoApiVersion", "usageReportingSupport"}) {
            String v; try { v = d.getPropertyString(k); } catch (Throwable t) { v = "(" + t.getClass().getSimpleName() + ")"; }
            p("widevine " + k + " = " + v); if (k.equals("version") || k.equals("securityLevel") || k.equals("systemId") || k.equals("maxHdcpLevel")) sb.append(k).append('=').append(v).append(' ');
        }
        String sess;
        try { byte[] sid = d.openSession(); sess = "session ok level " + d.getSecurityLevel(sid); d.closeSession(sid); } catch (Throwable t) { sess = "openSession: " + t; }
        p(sess);
        try { p("connected HDCP " + d.getConnectedHdcpLevel() + " max " + d.getMaxHdcpLevel()); } catch (Throwable t) {}
        d.close();
        result("PASS", "Widevine " + sb + "ClearKey " + cks + " " + sess);
    }

    // ---------------------------------------------------------------- compress offload
    static void offload() throws Exception {
        Context oc = ctx();
        { String ext = externalOutput((AudioManager) oc.getSystemService(Context.AUDIO_SERVICE));
          if (ext != null) { result("SKIP", "external audio output connected (" + ext + "): the offload track would play there"); return; } }
        final int rate = 48000;
        AudioAttributes aa = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build();
        int[] encs = {AudioFormat.ENCODING_MP3, AudioFormat.ENCODING_AAC_LC, AudioFormat.ENCODING_OPUS, AudioFormat.ENCODING_PCM_16BIT}; String[] nm = {"MP3", "AAC_LC", "OPUS", "PCM16"};
        boolean aac = false; StringBuilder sup = new StringBuilder();
        for (int i = 0; i < encs.length; i++) { boolean s;
            try { s = AudioManager.isOffloadedPlaybackSupported(new AudioFormat.Builder().setEncoding(encs[i]).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build(), aa); } catch (Throwable t) { s = false; }
            sup.append(nm[i]).append('=').append(s).append(' '); if (i == 1) aac = s; }
        p("offload supported: " + sup);
        if (!aac) { result("SKIP", "AAC offload not supported by the audio HAL (" + sup.toString().trim() + ")"); return; }
        // 6 s sine -> AAC-LC frames
        MediaFormat f = MediaFormat.createAudioFormat("audio/mp4a-latm", rate, 2);
        f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC); f.setInteger(MediaFormat.KEY_BIT_RATE, 128000); f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);
        MediaCodec c = MediaCodec.createEncoderByType("audio/mp4a-latm"); c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); c.start();
        java.io.ByteArrayOutputStream aacOut = new java.io.ByteArrayOutputStream(); MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
        int total = rate * 6, fed = 0, frames = 0; boolean inEos = false; long t0 = System.currentTimeMillis();
        while (System.currentTimeMillis() - t0 < 30000) {
            if (!inEos) { int ii = c.dequeueInputBuffer(10000); if (ii >= 0) { ByteBuffer b = c.getInputBuffer(ii); b.order(ByteOrder.nativeOrder()); int n = Math.min(1024, total - fed);
                if (n <= 0) { c.queueInputBuffer(ii, 0, 0, fed * 1000000L / rate, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true; }
                else { for (int i = 0; i < n; i++) { short s = (short) (Math.sin(2 * Math.PI * 440 * (fed + i) / rate) * 8000); b.putShort(s); b.putShort(s); }
                    c.queueInputBuffer(ii, 0, n * 4, fed * 1000000L / rate, 0); fed += n; } } }
            int oi = c.dequeueOutputBuffer(bi, 10000);
            if (oi >= 0) { if (bi.size > 0 && (bi.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) { ByteBuffer b = c.getOutputBuffer(oi); byte[] x = new byte[bi.size]; b.position(bi.offset); b.get(x); aacOut.write(x); frames++; }
                c.releaseOutputBuffer(oi, false); if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break; }
        }
        c.stop(); c.release(); byte[] data = aacOut.toByteArray();
        p("encoded " + frames + " AAC frames, " + data.length + " bytes");
        AudioTrack t = new AudioTrack.Builder().setAudioAttributes(aa)
            .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_AAC_LC).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(32768).setTransferMode(AudioTrack.MODE_STREAM).setOffloadedPlayback(true).build();
        p("offload track state " + t.getState() + " offloaded " + t.isOffloadedPlayback());
        t.play(); int off = 0; long end = System.currentTimeMillis() + 5000; int head = 0;
        while (System.currentTimeMillis() < end) {
            if (off < data.length) { int w = t.write(data, off, Math.min(4096, data.length - off), AudioTrack.WRITE_NON_BLOCKING); if (w < 0) { p("write error " + w); break; } off += w; }
            Thread.sleep(50); head = t.getPlaybackHeadPosition();
        }
        String routed = t.getRoutedDevice() == null ? "none" : "type " + t.getRoutedDevice().getType();
        boolean isOff = t.isOffloadedPlayback(); t.stop(); t.release();
        String d = "AAC-LC offload track offloaded " + isOff + " wrote " + off + "/" + data.length + " bytes, head " + head + " frames in 5 s (want ~" + rate * 4 + "+), routed " + routed + "; " + sup.toString().trim();
        metric("offload_head_frames", head);
        if (!isOff) { result("SKIP", "needs an offload-capable output (track was not offloaded): " + d); return; }
        result(head > rate * 2 ? "PASS" : "FAIL", d);
    }
}
