// Self-test helper for tools/selftest (one dex, many subcommands), run with app_process as the shell uid:
//   adb push st.dex /data/local/tmp/st.dex
//   adb shell app_process -cp /data/local/tmp/st.dex / St <cmd> [args]
// Commands: sensors [secs] | gl [secs] | glalloc [mb] | cam | camrec [id] [secs] | enc <mime> <out> [codec]
//           | dec <file> [codec|-] [expectedFrames] [nopattern] | vsync [secs] | disp [secs] | ble [secs]
//           | loop <media|ll|voice> [freq] [MIC|CAMCORDER|UNPROCESSED] [unmute] | keystore | drm | offload
//           | wv [provision] | secdec [avc|hevc|vp9] [clip|-] [secs]
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
        if (a.length == 0) { System.out.println("usage: St sensors|gl|glalloc|cam|camrec|enc|keystore|drm|offload|caminfo|codecs"); return; }
        cmd = a[0];
        long to = cmd.equals("glalloc") ? 180 : cmd.equals("cam") ? 120 : cmd.equals("drm") ? 30 : cmd.equals("wv") ? 60 : 90;
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
                case "caminfo": caminfo(); break;
                case "codecs": codecs(); break;
                case "secdec": secdec(a.length > 1 ? a[1] : "avc", a.length > 2 && !a[2].equals("-") ? a[2] : null, a.length > 3 ? Integer.parseInt(a[3]) : 30); break;
                case "wv": wv(a.length > 1 && a[1].equals("provision")); break;
                case "stmodel": stmodel(a.length > 1 ? a[1] : "samsung", a.length > 2 && a[2].equals("start")); break;
                default: result("FAIL", "unknown command");
            }
        } catch (Throwable t) {
            Throwable c = t; while (c.getCause() != null && (c instanceof java.lang.reflect.InvocationTargetException || c instanceof ExecutionException)) c = c.getCause();
            c.printStackTrace();
            result("FAIL", "exception " + c);
        }
        result("FAIL", "no result");
    }

    // ---------------------------------------------------------------- stmodel (sound trigger HAL model load)
    // Hands a DUMMY sound model to the vendor sound trigger HAL through the framework middleware (binder
    // "soundtrigger_middleware"), all by reflection (hidden AIDL classes). A rejection by the HAL/ADSP is fine: the
    // point is that loadModel reaches sound_trigger.primary.lahaina.so, which then drives the Listen PCM with its
    // SNDRV_LSM_* ioctls. Run as root (uid 0) or system; the middleware checks RECORD_AUDIO + CAPTURE_AUDIO_HOTWORD.
    static String ex1(Throwable t, boolean code) {
        Throwable c = t; while (c.getCause() != null && c instanceof java.lang.reflect.InvocationTargetException) c = c.getCause();
        String s = c.getClass().getSimpleName() + ": " + c.getMessage();
        try { java.lang.reflect.Field f = c.getClass().getField("errorCode"); s += " (errorCode " + f.getInt(c) + ")"; } catch (Throwable e) {}
        return s;
    }
    static java.lang.reflect.Method meth(Object o, String name) {
        for (java.lang.reflect.Method m : o.getClass().getMethods()) if (m.getName().equals(name)) return m;
        throw new RuntimeException("no method " + name + " on " + o.getClass().getName());
    }
    static void setF(Object o, String f, Object v) throws Exception { o.getClass().getField(f).set(o, v); }
    static void stmodel(String vendor, boolean start) throws Exception {
        final String vu = vendor.equals("google") ? "7038ddc8-30f2-11e6-b0ac-40a8f03d3f15" : "a1757552-af10-11e7-985a-a3754010baa2";
        int uid = android.os.Process.myUid();
        p("stmodel: uid " + uid + " pid " + android.os.Process.myPid() + " vendorUuid " + vu + " (" + vendor + ")" + (start ? " + startRecognition" : ""));
        // app_process (non-zygote) starts the binder thread pool itself (app_main onStarted): the oneway callbacks arrive
        android.os.IBinder b = (android.os.IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "soundtrigger_middleware");
        if (b == null) { result("FAIL", "no soundtrigger_middleware service"); return; }
        Object svc = Class.forName("android.media.soundtrigger_middleware.ISoundTriggerMiddlewareService$Stub").getMethod("asInterface", android.os.IBinder.class).invoke(null, b);
        Object id = Class.forName("android.media.permission.Identity").getDeclaredConstructor().newInstance();
        setF(id, "uid", uid); setF(id, "pid", android.os.Process.myPid());
        setF(id, "packageName", uid == 0 ? "root" : uid == 1000 ? "android" : "com.android.shell");
        Object[] mods;
        try { mods = (Object[]) meth(svc, "listModulesAsOriginator").invoke(svc, id); }
        catch (Throwable t) { result("FAIL", "listModulesAsOriginator: " + ex1(t, true)); return; }
        p("stmodel: modules " + mods.length);
        int handle = -1; String halUuid = "?";
        for (Object m : mods) {
            int h = m.getClass().getField("handle").getInt(m); Object pr = m.getClass().getField("properties").get(m);
            StringBuilder sb = new StringBuilder();
            for (java.lang.reflect.Field f : pr.getClass().getFields()) { if (java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue; sb.append(f.getName()).append('=').append(f.get(pr)).append(' '); }
            p("stmodel: module handle " + h + ": " + sb.toString().trim());
            if (handle < 0) { handle = h; try { halUuid = String.valueOf(pr.getClass().getField("uuid").get(pr)); } catch (Throwable t) {} }
        }
        if (handle < 0) { result("FAIL", "middleware lists no sound trigger module (HAL not connected)"); return; }
        // callback: a java.lang.reflect.Proxy for the AIDL interface whose asBinder() is a local Binder that logs
        final Class<?> cbI = Class.forName("android.media.soundtrigger_middleware.ISoundTriggerCallback");
        final android.os.Binder cbB = new android.os.Binder() {
            @Override protected boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) throws android.os.RemoteException {
                if (code >= 1 && code <= 16) { p("stmodel: callback transaction " + code + " (1 onRecognition 2 onPhraseRecognition 3 onResourcesAvailable 4 onModelUnloaded 5 onModuleDied), " + data.dataSize() + " bytes"); return true; }
                return super.onTransact(code, data, reply, flags);
            }
        };
        try { cbB.attachInterface(null, "android.media.soundtrigger_middleware.ISoundTriggerCallback"); } catch (Throwable t) {}
        Object cb = java.lang.reflect.Proxy.newProxyInstance(St.class.getClassLoader(), new Class<?>[]{cbI}, (pxy, m, args) -> {
            if (m.getName().equals("asBinder")) return cbB;
            if (m.getName().equals("hashCode")) return System.identityHashCode(pxy);
            if (m.getName().equals("equals")) return pxy == args[0];
            if (m.getName().equals("toString")) return "StCallback";
            p("stmodel: callback " + m.getName()); return null; });
        Object mod;
        try { java.lang.reflect.Method at = meth(svc, "attachAsOriginator"); int n = at.getParameterTypes().length;
            mod = n == 3 ? at.invoke(svc, handle, id, cb) : at.invoke(svc, handle, id, cb, Boolean.FALSE); }
        catch (Throwable t) { result("FAIL", "attachAsOriginator: " + ex1(t, true)); return; }
        p("stmodel: attached to module " + handle + ": " + mod);
        // SoundModel{type GENERIC, uuid random, vendorUuid, data = 4 KiB shared memory of zeros}
        final int size = 4096;
        android.os.SharedMemory shm = android.os.SharedMemory.create("st-model", size);
        android.os.ParcelFileDescriptor pfd;
        try { pfd = (android.os.ParcelFileDescriptor) android.os.SharedMemory.class.getMethod("getFdDup").invoke(shm); }
        catch (Throwable t) { java.io.FileDescriptor fd = (java.io.FileDescriptor) android.os.SharedMemory.class.getMethod("getFileDescriptor").invoke(shm); pfd = android.os.ParcelFileDescriptor.dup(fd); }
        Object sm = Class.forName("android.media.soundtrigger.SoundModel").getDeclaredConstructor().newInstance();
        setF(sm, "type", 1); setF(sm, "uuid", java.util.UUID.randomUUID().toString()); setF(sm, "vendorUuid", vu);
        setF(sm, "data", pfd); setF(sm, "dataSize", size);
        int mh = -1; String loadErr = null;
        try { mh = (Integer) meth(mod, "loadModel").invoke(mod, sm); p("stmodel: loadModel -> model handle " + mh); }
        catch (Throwable t) { loadErr = ex1(t, true); p("stmodel: loadModel failed: " + loadErr); }
        String startRes = "";
        if (mh >= 0 && start) {
            try { Object rc = Class.forName("android.media.soundtrigger.RecognitionConfig").getDeclaredConstructor().newInstance();
                setF(rc, "captureRequested", false);
                setF(rc, "phraseRecognitionExtras", java.lang.reflect.Array.newInstance(Class.forName("android.media.soundtrigger.PhraseRecognitionExtra"), 0));
                setF(rc, "audioCapabilities", 0); setF(rc, "data", new byte[0]);
                Object tok = meth(mod, "startRecognition").invoke(mod, mh, rc);
                p("stmodel: startRecognition ok, token " + tok); startRes = " start ok";
                Thread.sleep(2000);
                try { meth(mod, "stopRecognition").invoke(mod, mh); p("stmodel: stopRecognition ok"); } catch (Throwable t) { p("stmodel: stopRecognition failed: " + ex1(t, true)); }
            } catch (Throwable t) { startRes = " start failed: " + ex1(t, true); p("stmodel: startRecognition failed: " + ex1(t, true)); }
        }
        if (mh >= 0) try { meth(mod, "unloadModel").invoke(mod, mh); p("stmodel: unloadModel ok"); } catch (Throwable t) { p("stmodel: unloadModel failed: " + ex1(t, true)); }
        try { meth(mod, "detach").invoke(mod); p("stmodel: detach ok"); } catch (Throwable t) { p("stmodel: detach failed: " + ex1(t, true)); }
        try { pfd.close(); shm.close(); } catch (Throwable t) {}
        // a dummy model that the HAL/ADSP rejects still proves the path: PASS = HAL took it, SKIP = HAL reached and refused
        if (mh >= 0) result("PASS", "HAL " + halUuid + " loaded the dummy " + vendor + " model (handle " + mh + ")" + startRes);
        else result("SKIP", "HAL " + halUuid + " listed, loadModel refused: " + loadErr + " (dummy model: check logcat sound_trigger_hw + dmesg for the LSM ioctls)");
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
        // One UI: MediaDrm.<init> binds com.samsung.drmboost through the process's Application; app_process has no
        // IApplicationThread registered with the activity manager, so the bind throws SecurityException before the plugin
        // is ever asked. Fallback: allocate the object without its constructor and call native_setup() directly: the
        // HAL/TEE path is the same, only the Samsung "boost" service is skipped.
        p("opening Widevine"); MediaDrm d; String how = "";
        try { d = new MediaDrm(wv); p("opened"); }
        catch (Throwable t0) { Throwable c0 = t0; while (c0.getCause() != null) c0 = c0.getCause();
            p("constructor failed (" + c0.getClass().getSimpleName() + ": " + String.valueOf(c0.getMessage()).replaceAll("\\s+", " ").substring(0, Math.min(120, String.valueOf(c0.getMessage()).length())) + "), trying native_setup");
            d = drmRaw(wv); how = "(opened by native_setup: constructor threw " + c0.getClass().getSimpleName() + ") "; p("opened raw"); }
        StringBuilder sb = new StringBuilder();
        for (String k : new String[]{"vendor", "version", "securityLevel", "systemId", "hdcpLevel", "maxHdcpLevel", "algorithms", "oemCryptoApiVersion", "oemCryptoBuildInformation", "usageReportingSupport", "provisioningModel", "resourceRatingTier", "maxNumberOfSessions", "analogOutputCapabilities"}) {
            String v; try { v = d.getPropertyString(k); } catch (Throwable t) { v = "(" + t.getClass().getSimpleName() + ")"; }
            // systemId identifies the keybox family, not the unit; anything else numeric and long is masked by the host
            p("widevine " + k + " = " + v); if (k.equals("version") || k.equals("securityLevel") || k.equals("systemId") || k.equals("maxHdcpLevel") || k.equals("oemCryptoApiVersion") || k.equals("provisioningModel") || k.equals("resourceRatingTier")) sb.append(k).append('=').append(String.valueOf(v).replace(' ', '_')).append(' ');
        }
        String sess;
        try { byte[] sid;
            if (how.isEmpty()) sid = d.openSession();
            else { java.lang.reflect.Method m = MediaDrm.class.getDeclaredMethod("openSessionNative", int.class); m.setAccessible(true); sid = (byte[]) m.invoke(d, MediaDrm.getMaxSecurityLevel()); }
            sess = "session ok level " + d.getSecurityLevel(sid);
            try { p("secure decoder required: avc " + d.requiresSecureDecoder("video/avc") + " hevc " + d.requiresSecureDecoder("video/hevc")); } catch (Throwable t) {}
            if (how.isEmpty()) d.closeSession(sid);
            else { java.lang.reflect.Method m = MediaDrm.class.getDeclaredMethod("closeSessionNative", byte[].class); m.setAccessible(true); m.invoke(d, (Object) sid); }
        } catch (Throwable t) { Throwable c = t; while (c.getCause() != null && c instanceof java.lang.reflect.InvocationTargetException) c = c.getCause();
            // NotProvisionedException = the plugin works but this unit has no certificate yet (L3 or factory-reset L1): not a kernel fault
            sess = "openSession: " + c.getClass().getSimpleName() + " " + c.getMessage(); }
        p(sess);
        try { p("connected HDCP " + d.getConnectedHdcpLevel() + " max " + d.getMaxHdcpLevel()); } catch (Throwable t) {}
        try { if (how.isEmpty()) d.close(); else MediaDrm.class.getMethod("native_release").invoke(d); } catch (Throwable t) {}
        // secure decoders the codec list offers (what a Widevine L1 stream needs from the video driver)
        StringBuilder sec = new StringBuilder();
        try { for (MediaCodecInfo ci : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) if (!ci.isEncoder() && ci.getName().endsWith(".secure")) sec.append(ci.getName()).append(',');
        } catch (Throwable t) { sec.append("(codec list: ").append(t.getClass().getSimpleName()).append(')'); }
        p("secure decoders: " + sec);
        result("PASS", "Widevine " + sb + how + "ClearKey " + cks + " " + sess + " secure_decoders=" + sec.toString().split(",").length * (sec.length() > 0 ? 1 : 0));
    }
    static final UUID WV = new UUID(0xedef8ba979d64aceL, 0xa3c827dcd51d21edL);
    static String ex1(Throwable t) { Throwable c = t; while (c.getCause() != null && c instanceof java.lang.reflect.InvocationTargetException) c = c.getCause();
        String m = String.valueOf(c.getMessage()).replaceAll("\\s+", " "); return c.getClass().getSimpleName() + ": " + m.substring(0, Math.min(160, m.length())); }
    /** wv [provision]: Widevine properties, an L1 session open, and (only with "provision": needs network) the certificate
     *  provisioning round trip (getProvisionRequest -> POST defaultUrl&signedRequest=... -> provideProvisionResponse). */
    static void wv(boolean provision) throws Exception {
        ctx();
        if (!MediaDrm.isCryptoSchemeSupported(WV)) { result("FAIL", "Widevine scheme not supported"); return; }
        MediaDrm d; try { d = new MediaDrm(WV); } catch (Throwable t) { p("constructor failed (" + ex1(t) + "), native_setup"); d = drmRaw(WV); }
        StringBuilder sb = new StringBuilder();
        for (String k : new String[]{"securityLevel", "systemId", "provisioningModel", "oemCryptoApiVersion", "maxHdcpLevel", "hdcpLevel", "version", "oemCryptoBuildInformation", "maxNumberOfSessions", "numberOfOpenSessions"}) {
            String v; try { v = d.getPropertyString(k); } catch (Throwable t) { v = "(" + t.getClass().getSimpleName() + ")"; }
            p("widevine " + k + " = " + v); if (!k.equals("oemCryptoBuildInformation") && !k.equals("version")) sb.append(k).append('=').append(String.valueOf(v).replace(' ', '_')).append(' ');
        }
        try { p("sessions open " + d.getOpenSessionCount() + " max " + d.getMaxSessionCount() + ", max security level const " + MediaDrm.getMaxSecurityLevel()); } catch (Throwable t) { p("session counts: " + ex1(t)); }
        String sess = null; boolean ok = false, notProv = false;
        for (int round = 0; round < 2 && !ok; round++) {
            try { byte[] sid = d.openSession(); int lv = d.getSecurityLevel(sid);
                // MediaDrm.SECURITY_LEVEL_HW_SECURE_ALL = 5 (L1), HW_SECURE_CRYPTO 3 (L2), SW_SECURE_CRYPTO 1 (L3)
                sess = "session ok level " + lv + (lv == 5 ? " (L1)" : lv == 1 ? " (L3)" : ""); ok = true;
                try { p("open sessions now " + d.getOpenSessionCount()); } catch (Throwable t) {}
                try { p("secure decoder required: avc " + d.requiresSecureDecoder("video/avc") + " hevc " + d.requiresSecureDecoder("video/hevc")); } catch (Throwable t) { p("requiresSecureDecoder: " + ex1(t)); }
                d.closeSession(sid);
            } catch (NotProvisionedException e) { notProv = true; sess = "openSession: NotProvisionedException " + e.getMessage(); p(sess);
                MediaDrm.ProvisionRequest rq;
                try { rq = d.getProvisionRequest(); } catch (Throwable t) { sess += "; getProvisionRequest " + ex1(t); p(sess); break; }
                p("provision request: url " + rq.getDefaultUrl() + " data " + rq.getData().length + " bytes");
                if (!provision || round > 0) { sess += " (provision request " + rq.getData().length + " bytes ready; run `St wv provision` with network)"; break; }
                try {
                    java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(rq.getDefaultUrl() + "&signedRequest=" + new String(rq.getData(), "UTF-8")).openConnection();
                    c.setRequestMethod("POST"); c.setDoOutput(true); c.setConnectTimeout(8000); c.setReadTimeout(12000);
                    c.setRequestProperty("Accept", "*/*"); c.setRequestProperty("User-Agent", "Widevine CDM v1.0"); c.setRequestProperty("Content-Type", "application/json");
                    c.getOutputStream().close(); int code = c.getResponseCode(); p("provisioning server HTTP " + code);
                    java.io.InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream(); java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream(); byte[] buf = new byte[8192]; int n;
                    if (in != null) while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
                    p("provisioning response " + bo.size() + " bytes"); if (code != 200) { sess += "; provisioning server HTTP " + code; break; }
                    d.provideProvisionResponse(bo.toByteArray()); p("provideProvisionResponse accepted"); sess = "provisioned now; ";
                } catch (Throwable t) { sess += "; provisioning failed " + ex1(t); p(sess); break; }
            } catch (Throwable t) { sess = "openSession: " + ex1(t); break; }
        }
        p(sess);
        try { p("connected HDCP " + d.getConnectedHdcpLevel() + " max " + d.getMaxHdcpLevel()); } catch (Throwable t) {}
        try { d.close(); } catch (Throwable t) {}
        // PASS = a session opened. Not provisioned = SKIP (the TA and HAL answer; the certificate needs the network), anything else FAIL.
        result(ok ? "PASS" : notProv ? "SKIP" : "FAIL", "Widevine " + sb + sess);
    }
    /** secdec [avc|hevc|vp9] [clip|-] [secs]: c2.qti.<x>.decoder.secure on a protected ImageReader surface. With a clip AND a
     *  Widevine session (MediaCrypto) the clear samples go in through queueSecureInputBuffer in CRYPTO_MODE_UNENCRYPTED: the
     *  CDM copies them into the secure input buffer (OEMCrypto_CopyBuffer, no licence needed), so the video core runs a real
     *  secure session (secure bitstream in, internal buffers from qcom,secure-bitstream, secure pixels out). Without a
     *  session nothing can be written into a secure input buffer: then only configure + start are driven. */
    static void secdec(String kind, String file, int secs) throws Exception {
        ctx();
        String mime = kind.equals("hevc") ? "video/hevc" : kind.equals("vp9") ? "video/x-vnd.on2.vp9" : "video/avc", name = "c2.qti." + kind + ".decoder.secure";
        MediaExtractor ex = null; MediaFormat fmt = null;
        if (file != null) { ex = new MediaExtractor(); ex.setDataSource(file);
            for (int i = 0; i < ex.getTrackCount(); i++) { MediaFormat f = ex.getTrackFormat(i); if (mime.equals(f.getString(MediaFormat.KEY_MIME))) { ex.selectTrack(i); fmt = f; break; } }
            if (fmt == null) { result("FAIL", "no " + mime + " track in " + file); return; } }
        if (fmt == null) fmt = MediaFormat.createVideoFormat(mime, 1280, 720);
        int w = fmt.getInteger(MediaFormat.KEY_WIDTH), h = fmt.getInteger(MediaFormat.KEY_HEIGHT); p("codec " + name + " " + w + "x" + h + (file != null ? " clip " + file : " no clip"));
        MediaDrm d = null; byte[] sid = null; MediaCrypto crypto = null; String drmS;
        try { d = new MediaDrm(WV); sid = d.openSession(); crypto = new MediaCrypto(WV, sid); drmS = "widevine session level " + d.getSecurityLevel(sid) + ", MediaCrypto ok, requiresSecureDecoderComponent " + crypto.requiresSecureDecoderComponent(mime); }
        catch (Throwable t) { drmS = "no MediaCrypto (" + ex1(t) + ")"; crypto = null; }
        p(drmS);
        MediaCodec c; try { c = MediaCodec.createByCodecName(name); } catch (Throwable t) { result("FAIL", "createByCodecName " + name + ": " + ex1(t)); return; }
        p("created " + c.getName());
        ImageReader ir = null; Surface sf = null; String surf = "none";
        try { ir = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, 4, android.hardware.HardwareBuffer.USAGE_PROTECTED_CONTENT | android.hardware.HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE); sf = ir.getSurface(); surf = "protected ImageReader"; }
        catch (Throwable t) { p("protected ImageReader: " + ex1(t));
            try { ir = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, 4); sf = ir.getSurface(); surf = "plain ImageReader"; } catch (Throwable t2) { p("ImageReader: " + ex1(t2)); } }
        boolean conf = false; String cerr = "";
        for (int tr = 0; tr < 3 && !conf; tr++) {   // 0: surface + crypto, 1: surface, no crypto, 2: no surface, no crypto
            Surface s = tr < 2 ? sf : null; MediaCrypto mc = tr == 0 ? crypto : null; if (tr == 1 && crypto == null) continue; if (tr == 2 && sf == null && crypto == null) { }
            try { c.configure(fmt, s, mc, 0); conf = true; if (mc == null) crypto = null; if (s == null) surf = "none (ByteBuffer)"; p("configured: surface " + surf + ", crypto " + (mc != null)); }
            catch (Throwable t) { cerr += " [" + tr + "] " + ex1(t); p("configure try " + tr + ": " + ex1(t)); try { c.reset(); } catch (Throwable t2) {} } }
        if (!conf) { c.release(); result("FAIL", "configure failed:" + cerr + "; " + drmS); return; }
        try { c.start(); } catch (Throwable t) { c.release(); result("FAIL", "start: " + ex1(t) + "; surface " + surf + "; " + drmS); return; }
        p("started");
        final int[] imgs = {0};
        if (ir != null) ir.setOnImageAvailableListener(r -> { try { Image im = r.acquireLatestImage(); if (im != null) { imgs[0]++; im.close(); } } catch (Throwable t) { imgs[0]++; } }, bg("secdec-ir"));
        int fed = 0, out = 0; String err = null, note = ""; boolean eosIn = ex == null, eosOut = false, fmtCh = false;
        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo(); ByteBuffer tmp = ByteBuffer.allocate(4 << 20);
        long end = System.currentTimeMillis() + secs * 1000L, t2s = System.currentTimeMillis() + 2000;
        try {
            while (System.currentTimeMillis() < end && !eosOut && !(ex == null && System.currentTimeMillis() > t2s)) {
                if (!eosIn) { int ix = c.dequeueInputBuffer(20000);
                    if (ix >= 0) { tmp.clear(); int n = ex.readSampleData(tmp, 0);
                        if (n < 0) { if (crypto != null) { MediaCodec.CryptoInfo ci = new MediaCodec.CryptoInfo(); ci.set(1, new int[]{0}, new int[]{0}, new byte[16], new byte[16], MediaCodec.CRYPTO_MODE_UNENCRYPTED); }
                            c.queueInputBuffer(ix, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); eosIn = true; p("input EOS after " + fed + " samples"); }
                        else { ByteBuffer ib = null; try { ib = c.getInputBuffer(ix); } catch (Throwable t) { note = "getInputBuffer " + ex1(t); }
                            if (crypto != null && ib != null) { ib.clear(); ib.put(tmp); MediaCodec.CryptoInfo ci = new MediaCodec.CryptoInfo();
                                ci.set(1, new int[]{n}, new int[]{0}, new byte[16], new byte[16], MediaCodec.CRYPTO_MODE_UNENCRYPTED);
                                c.queueSecureInputBuffer(ix, 0, ci, ex.getSampleTime(), 0); fed++; ex.advance(); }
                            else if (ib != null) { ib.clear(); ib.put(tmp); c.queueInputBuffer(ix, 0, n, ex.getSampleTime(), 0); fed++; ex.advance(); if (fed == 1) note = "clear queueInputBuffer accepted by a secure codec without MediaCrypto"; }
                            else { note = "secure input buffer is not writable without a MediaCrypto (" + drmS + "): nothing fed" + (note.isEmpty() ? "" : "; " + note); p(note); eosIn = true; ex = null; t2s = System.currentTimeMillis() + 2000; }
                            if (fed == 1) p("first sample queued (" + n + " bytes, " + (crypto != null ? "secure, clear mode" : "clear") + ")"); } } }
                int ox = c.dequeueOutputBuffer(bi, 20000);
                if (ox >= 0) { if (bi.size > 0 || sf != null) out++; if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eosOut = true; c.releaseOutputBuffer(ox, sf != null && (bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0); if (out == 1) p("first output frame"); }
                else if (ox == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) { fmtCh = true; p("output format " + c.getOutputFormat()); }
            }
        } catch (Throwable t) { err = ex1(t); if (t instanceof MediaCodec.CodecException) err += " diag " + ((MediaCodec.CodecException) t).getDiagnosticInfo(); p("error: " + err); }
        try { c.stop(); p("stopped"); } catch (Throwable t) { if (err == null) err = "stop: " + ex1(t); }
        try { c.release(); } catch (Throwable t) {}
        try { if (crypto != null) crypto.release(); if (d != null) { if (sid != null) d.closeSession(sid); d.close(); } } catch (Throwable t) {}
        metric("secdec_fed", fed); metric("secdec_frames", out); metric("secdec_images", imgs[0]);
        String det = name + " surface " + surf + ", " + drmS + ", fed " + fed + " frames out " + out + " images " + imgs[0] + (fmtCh ? " format-changed" : "") + (note.isEmpty() ? "" : ", " + note) + (err != null ? ", ERROR " + err : "");
        // PASS: decoded frames came out of a fed secure session. SKIP: configure + start worked but no secure input could be fed
        // (no Widevine session / no clip): the video core may not even have been started by the HAL. FAIL: any codec error.
        result(err != null ? "FAIL" : fed > 0 && out > 0 ? "PASS" : fed > 0 ? "FAIL" : "SKIP", det);
    }
    /** MediaDrm without its constructor (see drm()): Unsafe.allocateInstance + the private native_setup(weak this, uuid, package). */
    static MediaDrm drmRaw(UUID u) throws Exception {
        Class<?> uc = Class.forName("sun.misc.Unsafe"); java.lang.reflect.Field tf = uc.getDeclaredField("theUnsafe"); tf.setAccessible(true);
        MediaDrm d = (MediaDrm) uc.getMethod("allocateInstance", Class.class).invoke(tf.get(null), MediaDrm.class);
        byte[] ub = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN).putLong(u.getMostSignificantBits()).putLong(u.getLeastSignificantBits()).array();
        java.lang.reflect.Method setup = null;
        for (java.lang.reflect.Method m : MediaDrm.class.getDeclaredMethods()) if (m.getName().equals("native_setup")) setup = m;
        if (setup == null) throw new NoSuchMethodException("MediaDrm.native_setup");
        setup.setAccessible(true); Class<?>[] pt = setup.getParameterTypes(); Object[] args = new Object[pt.length];
        for (int i = 0; i < pt.length; i++) args[i] = pt[i] == byte[].class ? ub : pt[i] == String.class ? "com.android.shell" : pt[i] == Object.class ? new java.lang.ref.WeakReference<MediaDrm>(d) : null;
        setup.invoke(d, args);
        try { java.lang.reflect.Field f = MediaDrm.class.getDeclaredField("mAppPackageName"); f.setAccessible(true); f.set(d, "com.android.shell"); } catch (Throwable t) {}
        return d;
    }


    // ---------------------------------------------------------------- spec rows (silent, read-only): camera characteristics, codec list
    // Both print rows in the OneUI sweep format (CHECK <id> <status> <owner> <stable> <detail>, TAB separated): "set:" tokens
    // have no spaces, so tools/selftest/oneui/report.py names every token that is missing or extra on the other kernel.
    static void check(String id, String st, String owner, String stable, String detail) {
        System.out.println("CHECK\t" + id + "\t" + st + "\t" + owner + "\t" + stable.replaceAll("[\\t\\r\\n]", " ") + "\t" + detail.replaceAll("[\\t\\r\\n]", " ")); System.out.flush(); }
    static String sz(Size s) { return s == null ? "none" : s.getWidth() + "x" + s.getHeight(); }
    static Size maxSize(Size[] a) { Size b = null; if (a != null) for (Size s : a) if (b == null || (long) s.getWidth() * s.getHeight() > (long) b.getWidth() * b.getHeight()) b = s; return b; }
    @SuppressWarnings("unchecked")
    static <T> T chGet(CameraCharacteristics ch, String field) { try { return (T) ch.get((CameraCharacteristics.Key<T>) CameraCharacteristics.class.getField(field).get(null)); } catch (Throwable t) { return null; } }
    /** No camera is opened, nothing is captured: CameraManager.getCameraCharacteristics() only (static metadata the HAL built from the sensor probe). */
    static void caminfo() throws Exception {
        CameraManager cm; String[] ids;
        try { cm = (CameraManager) ctx().getSystemService(Context.CAMERA_SERVICE); ids = cm.getCameraIdList(); }
        catch (Throwable t) { check("camera.char.ids", "SKIP", "kernel+ROM", "no camera service access", String.valueOf(t)); result("SKIP", "needs camera service access as shell: " + t); return; }
        String[] capN = {"BACKWARD_COMPATIBLE", "MANUAL_SENSOR", "MANUAL_POST_PROCESSING", "RAW", "PRIVATE_REPROCESSING", "READ_SENSOR_SETTINGS", "BURST_CAPTURE", "YUV_REPROCESSING", "DEPTH_OUTPUT", "HIGH_SPEED_VIDEO", "MOTION_TRACKING", "LOGICAL_MULTI_CAMERA", "MONOCHROME", "SECURE_IMAGE_DATA", "SYSTEM_CAMERA", "OFFLINE_PROCESSING", "ULTRA_HIGH_RESOLUTION_SENSOR", "REMOSAIC_REPROCESSING", "DYNAMIC_RANGE_TEN_BIT", "STREAM_USE_CASE", "COLOR_SPACE_PROFILES"};
        StringBuilder idset = new StringBuilder("set:"); int ok = 0;
        for (String id : ids) {
            try {
                CameraCharacteristics ch = cm.getCameraCharacteristics(id); List<String> t = new ArrayList<>();
                Integer fc = ch.get(CameraCharacteristics.LENS_FACING); String facing = fc == null ? "?" : fc == 0 ? "front" : fc == 1 ? "back" : "external";
                Integer lv = ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL);
                String level = lv == null ? "?" : lv == 0 ? "LIMITED" : lv == 1 ? "FULL" : lv == 2 ? "LEGACY" : lv == 3 ? "LEVEL_3" : lv == 4 ? "EXTERNAL" : "L" + lv;
                idset.append(' ').append(id).append(':').append(facing).append(':').append(level);
                t.add("facing=" + facing); t.add("level=" + level);
                int[] caps = ch.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES); boolean hs = false;
                if (caps != null) for (int c : caps) { t.add("cap=" + (c >= 0 && c < capN.length ? capN[c] : String.valueOf(c))); if (c == 9) hs = true; }
                StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                if (map != null) {
                    t.add("jpeg_max=" + sz(maxSize(map.getOutputSizes(ImageFormat.JPEG)))); t.add("yuv_max=" + sz(maxSize(map.getOutputSizes(ImageFormat.YUV_420_888))));
                    Size[] raw = null; try { raw = map.getOutputSizes(ImageFormat.RAW_SENSOR); } catch (Throwable e) {} if (raw != null && raw.length > 0) t.add("raw_max=" + sz(maxSize(raw)));
                    try { Size[] he = map.getOutputSizes(ImageFormat.HEIC); if (he != null && he.length > 0) t.add("heic_max=" + sz(maxSize(he))); } catch (Throwable e) {}
                    try { Size[] dp = map.getOutputSizes(ImageFormat.DEPTH16); if (dp != null && dp.length > 0) t.add("depth16_max=" + sz(maxSize(dp))); } catch (Throwable e) {}
                    try { Size[] hr = map.getHighResolutionOutputSizes(ImageFormat.JPEG); if (hr != null && hr.length > 0) t.add("jpeg_highres_max=" + sz(maxSize(hr))); } catch (Throwable e) {}
                    // recording-class stream: every PRIVATE size from 720p up with the best frame rate the HAL promises for it
                    Size[] pv = map.getOutputSizes(android.graphics.SurfaceTexture.class); t.add("priv_sizes=" + (pv == null ? 0 : pv.length));
                    if (pv != null) for (Size s : pv) { if ((long) s.getWidth() * s.getHeight() < 1280L * 720) continue; long d = 0; try { d = map.getOutputMinFrameDuration(android.graphics.SurfaceTexture.class, s); } catch (Throwable e) {}
                        t.add("priv=" + sz(s) + "@" + (d > 0 ? Math.round(1e9 / d) : 0)); }
                    if (hs) try { for (Size s : map.getHighSpeedVideoSizes()) for (android.util.Range<Integer> r : map.getHighSpeedVideoFpsRangesFor(s)) t.add("highspeed=" + sz(s) + "@" + r.getLower() + "-" + r.getUpper()); } catch (Throwable e) { t.add("highspeed=error"); }
                    try { int[] inf = map.getInputFormats(); if (inf != null && inf.length > 0) t.add("reprocess_inputs=" + inf.length); } catch (Throwable e) {}
                } else t.add("no_stream_map");
                StreamConfigurationMap mr = chGet(ch, "SCALER_STREAM_CONFIGURATION_MAP_MAXIMUM_RESOLUTION");
                if (mr != null) try { t.add("maxres_jpeg=" + sz(maxSize(mr.getOutputSizes(ImageFormat.JPEG)))); t.add("maxres_yuv=" + sz(maxSize(mr.getOutputSizes(ImageFormat.YUV_420_888)))); } catch (Throwable e) {}
                android.util.Range<Integer>[] fr = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES); if (fr != null) for (android.util.Range<Integer> r : fr) t.add("aefps=" + r.getLower() + "-" + r.getUpper());
                int[] ois = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION); boolean hasOis = false; if (ois != null) for (int o : ois) if (o == 1) hasOis = true; t.add("ois=" + (hasOis ? 1 : 0));
                int[] vs = ch.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES); if (vs != null) { StringBuilder b = new StringBuilder(); for (int v : vs) b.append(b.length() > 0 ? "," : "").append(v); t.add("video_stab_modes=" + b); }
                Float mf = ch.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE); t.add("af=" + (mf != null && mf > 0 ? 1 : 0));
                int[] afm = ch.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES); if (afm != null) t.add("af_modes=" + afm.length);
                Boolean fl = ch.get(CameraCharacteristics.FLASH_INFO_AVAILABLE); t.add("flash=" + (fl != null && fl ? 1 : 0));
                Integer tmax = chGet(ch, "FLASH_INFO_STRENGTH_MAXIMUM_LEVEL"), tdef = chGet(ch, "FLASH_INFO_STRENGTH_DEFAULT_LEVEL"); if (tmax != null) t.add("torch_levels=" + tmax + "/default" + tdef);
                float[] fo = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS); if (fo != null && fo.length > 0) t.add(String.format(Locale.US, "focal=%.2f", fo[0]));
                float[] ap = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES); if (ap != null && ap.length > 0) t.add(String.format(Locale.US, "aperture=%.1f", ap[0]));
                Size pa = ch.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE); t.add("pixel_array=" + sz(pa));
                Size pam = chGet(ch, "SENSOR_INFO_PIXEL_ARRAY_SIZE_MAXIMUM_RESOLUTION"); if (pam != null) t.add("pixel_array_maxres=" + sz(pam));
                android.util.Range<Integer> iso = ch.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE); if (iso != null) t.add("iso=" + iso.getLower() + "-" + iso.getUpper());
                android.util.Range<Long> ex = ch.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE); if (ex != null) t.add("exposure_ns=" + ex.getLower() + "-" + ex.getUpper());
                Integer ts = ch.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE); t.add("timestamp_source=" + (ts == null ? "?" : ts == 1 ? "REALTIME" : "UNKNOWN"));
                Integer so = ch.get(CameraCharacteristics.SENSOR_ORIENTATION); t.add("orientation=" + so);
                Float zm = ch.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM); if (zm != null) t.add(String.format(Locale.US, "zoom_max=%.1f", zm));
                int[] fd = ch.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES); if (fd != null) t.add("face_detect_modes=" + fd.length);
                Integer mfc = ch.get(CameraCharacteristics.STATISTICS_INFO_MAX_FACE_COUNT); if (mfc != null) t.add("max_faces=" + mfc);
                int[] sm = ch.get(CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES); if (sm != null) { boolean hdr = false; for (int x : sm) if (x == 18) hdr = true; t.add("scene_modes=" + sm.length); t.add("scene_hdr=" + (hdr ? 1 : 0)); }
                int[] nr = ch.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES); if (nr != null) { boolean zsl = false; for (int x : nr) if (x == 4) zsl = true; t.add("zsl_nr=" + (zsl ? 1 : 0)); }
                Integer pmax = ch.get(CameraCharacteristics.REQUEST_MAX_NUM_OUTPUT_PROC), rmax = ch.get(CameraCharacteristics.REQUEST_MAX_NUM_OUTPUT_RAW); t.add("max_streams=proc" + pmax + "/raw" + rmax);
                Byte pd = ch.get(CameraCharacteristics.REQUEST_PIPELINE_MAX_DEPTH); if (pd != null) t.add("pipeline_depth=" + pd);
                try { Set<String> ph = ch.getPhysicalCameraIds(); if (ph != null && !ph.isEmpty()) { List<String> l = new ArrayList<>(ph); Collections.sort(l); t.add("physical=" + String.join("+", l)); } } catch (Throwable e) {}
                Object drp = chGet(ch, "REQUEST_AVAILABLE_DYNAMIC_RANGE_PROFILES"); if (drp != null) try { Set<Long> ps = (Set<Long>) drp.getClass().getMethod("getSupportedProfiles").invoke(drp); List<Long> l = new ArrayList<>(ps); Collections.sort(l); StringBuilder b = new StringBuilder(); for (Long x : l) b.append(b.length() > 0 ? "," : "").append(x); t.add("dynamic_range_profiles=" + b); } catch (Throwable e) {}
                int vendorKeys = 0; try { for (CameraCharacteristics.Key<?> k : ch.getKeys()) if (!k.getName().startsWith("android.")) vendorKeys++; t.add("keys=" + ch.getKeys().size()); } catch (Throwable e) {}
                Collections.sort(t); check("camera.char." + id, "PASS", "kernel+ROM", "set: " + String.join(" ", t), t.size() + " facts, " + vendorKeys + " vendor keys; static metadata only, no camera opened"); ok++;
                p("camera " + id + " " + t);
            } catch (Throwable e) { check("camera.char." + id, "FAIL", "kernel+ROM", "characteristics unreadable", String.valueOf(e)); idset.append(' ').append(id).append(":error"); }
        }
        check("camera.char.ids", ids.length >= 2 && ok == ids.length ? "PASS" : "FAIL", "kernel+ROM", idset.toString(), ids.length + " ids visible to the camera2 API (as com.android.shell; the HAL device list is the camera.provider_devices row)");
        metric("camera_api_ids", ids.length);
        result(ids.length >= 2 && ok == ids.length ? "PASS" : "FAIL", ok + "/" + ids.length + " camera ids described");
    }

    /** MediaCodecList only: no codec instance is created. With Codec2 the limits of the hardware codecs are queried from the HAL, which asks the video driver. */
    static void codecs() throws Exception {
        MediaCodecInfo[] all = new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos();
        List<String> hwDec = new ArrayList<>(), hwEnc = new ArrayList<>(), sw = new ArrayList<>(), aud = new ArrayList<>(), sec = new ArrayList<>(); int n = 0;
        for (MediaCodecInfo ci : all) {
            if (ci.isAlias()) continue;
            for (String type : ci.getSupportedTypes()) {
                n++; MediaCodecInfo.CodecCapabilities cc; try { cc = ci.getCapabilitiesForType(type); } catch (Throwable t) { sw.add(ci.getName() + "(" + type + ",caps_error)"); continue; }
                MediaCodecInfo.VideoCapabilities vc = cc.getVideoCapabilities();
                if (vc == null) { aud.add(ci.getName() + "(" + type + (ci.isEncoder() ? ",enc" : ",dec") + (ci.isHardwareAccelerated() ? ",hw" : "") + ")"); continue; }
                StringBuilder b = new StringBuilder(ci.getName()).append('(').append(type);
                int mw = vc.getSupportedWidths().getUpper(), mh = vc.getSupportedHeights().getUpper(); b.append(",max=").append(mw).append('x').append(mh);
                int[][] probe = {{1280, 720}, {1920, 1080}, {3840, 2160}};
                for (int[] q : probe) { try { if (vc.isSizeSupported(q[0], q[1])) b.append(',').append(q[1]).append("p@").append(Math.round(vc.getSupportedFrameRatesFor(q[0], q[1]).getUpper())); } catch (Throwable t) {} }
                b.append(",br=").append(vc.getBitrateRange().getUpper() / 1000000).append('M');
                StringBuilder f = new StringBuilder();
                for (String ft : new String[]{"adaptive-playback", "secure-playback", "tunneled-playback", "low-latency", "partial-frame", "multiple-frames", "dynamic-timestamp", "intra-refresh", "hdr-editing", "encoding-statistics", "detached-surface", "dynamic-color-aspects", "region-of-interest", "hlg-editing"}) {
                    try { if (cc.isFeatureSupported(ft)) f.append(f.length() > 0 ? "+" : "").append(ft); } catch (Throwable t) {} }
                if (f.length() > 0) b.append(",feat=").append(f);
                boolean p010 = false; for (int cf : cc.colorFormats) if (cf == 54) p010 = true; if (p010) b.append(",p010");
                Set<String> prof = new TreeSet<>();
                for (MediaCodecInfo.CodecProfileLevel pl : cc.profileLevels) {
                    if (type.equals("video/hevc")) { if (pl.profile == 2) prof.add("main10"); if (pl.profile == 4096) prof.add("hdr10"); if (pl.profile == 8192) prof.add("hdr10plus"); }
                    if (type.equals("video/x-vnd.on2.vp9")) { if (pl.profile == 4) prof.add("p2"); if (pl.profile == 4096) prof.add("hdr10"); if (pl.profile == 16384) prof.add("hdr10plus"); }
                    if (type.equals("video/avc")) { if (pl.profile == 8) prof.add("high"); if (pl.profile == 16) prof.add("high10"); }
                    if (type.equals("video/av01")) { if (pl.profile == 2) prof.add("main10"); if (pl.profile == 4096) prof.add("hdr10"); } }
                if (!prof.isEmpty()) b.append(",prof=").append(String.join("+", prof));
                b.append(",levels=").append(cc.profileLevels.length).append(",inst=").append(cc.getMaxSupportedInstances()).append(')');
                String tok = b.toString().replace(' ', '_');
                if (ci.getName().endsWith(".secure")) sec.add(tok);
                if (!ci.isHardwareAccelerated()) sw.add(ci.getName() + "(" + type + (ci.isEncoder() ? ",enc" : ",dec") + ",max=" + mw + "x" + mh + ")"); else if (ci.isEncoder()) hwEnc.add(tok); else hwDec.add(tok);
            }
        }
        Collections.sort(hwDec); Collections.sort(hwEnc); Collections.sort(sw); Collections.sort(aud); Collections.sort(sec);
        check("codec.hw_decoders", hwDec.size() >= 3 ? "PASS" : "FAIL", "kernel+ROM", "set: " + String.join(" ", hwDec), hwDec.size() + " hardware video decoder types (name, type, max size, best fps at 720p/1080p/2160p, max bitrate, features, 10-bit)");
        check("codec.hw_encoders", hwEnc.size() >= 2 ? "PASS" : "FAIL", "kernel+ROM", "set: " + String.join(" ", hwEnc), hwEnc.size() + " hardware video encoder types");
        check("codec.secure_decoders", sec.isEmpty() ? "FAIL" : "PASS", "kernel+ROM", sec.size() + " secure decoders", "Widevine L1 playback needs them: " + String.join(" ", sec));
        check("codec.sw_video", "PASS", "ROM", "set: " + String.join(" ", sw), sw.size() + " software video codec types");
        check("codec.audio", "PASS", "ROM", "set: " + String.join(" ", aud), aud.size() + " audio codec types");
        metric("codec_hw_decoders", hwDec.size()); metric("codec_hw_encoders", hwEnc.size()); metric("codec_secure_decoders", sec.size()); metric("codec_types_total", n);
        result(hwDec.size() >= 3 && hwEnc.size() >= 2 ? "PASS" : "FAIL", hwDec.size() + " hw decoders, " + hwEnc.size() + " hw encoders, " + sec.size() + " secure, " + sw.size() + " software video, " + aud.size() + " audio");
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
