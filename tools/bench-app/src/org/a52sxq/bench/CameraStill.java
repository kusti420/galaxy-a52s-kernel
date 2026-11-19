package org.a52sxq.bench;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.view.Surface;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/** camera.still: every camera ID: open, YUV preview frames (count, luma mean/stddev), JPEG at max and smallest size, decode check. */
public class CameraStill extends Test {
    static final long WAIT_MS = 5000;
    public String id() { return "camera.still"; }
    public int budget(Ctx c) { return 150; }

    static final class Stats { volatile int frames; volatile long firstNs, lastNs; volatile double mean, std; }

    public void run(Ctx c, Result r) throws Exception {
        CameraManager cm = (CameraManager) c.app.getSystemService(Context.CAMERA_SERVICE);
        String[] ids = cm.getCameraIdList();
        r.num("cameras", (long) ids.length);
        if (ids.length == 0) { r.fail("CameraManager lists no cameras"); return; }
        HandlerThread ht = new HandlerThread("cam"); ht.start();
        Handler h = new Handler(ht.getLooper());
        int ok = 0;
        try {
            for (String id : ids) {
                c.log("camera.still: camera " + id);
                try { if (one(c, r, cm, id, h)) ok++; }
                catch (Throwable t) { r.fail("cam" + id + ": " + t); }
                Ctx.sleep(300);
            }
        } finally { ht.quitSafely(); }
        r.num("cameras_ok", (long) ok);
        if (ok == ids.length && !r.failed()) r.pass(ok + " cameras: preview frames live, JPEG max + small captured and decoded");
    }

    static CameraDevice open(CameraManager cm, String id, Handler h) throws Exception {
        final BlockingQueue<Object> q = new ArrayBlockingQueue<>(4);
        cm.openCamera(id, new CameraDevice.StateCallback() {
            @Override public void onOpened(CameraDevice d) { q.offer(d); }
            @Override public void onDisconnected(CameraDevice d) { d.close(); q.offer("disconnected"); }
            @Override public void onError(CameraDevice d, int e) { d.close(); q.offer("open error " + e); }
        }, h);
        Object o = q.poll(WAIT_MS, TimeUnit.MILLISECONDS);
        if (o == null) throw new RuntimeException("openCamera timeout");
        if (!(o instanceof CameraDevice)) throw new RuntimeException(String.valueOf(o));
        return (CameraDevice) o;
    }

    @SuppressWarnings("deprecation")
    static CameraCaptureSession session(CameraDevice d, Handler h, Surface... s) throws Exception {
        final BlockingQueue<Object> q = new ArrayBlockingQueue<>(4);
        d.createCaptureSession(Arrays.asList(s), new CameraCaptureSession.StateCallback() {
            @Override public void onConfigured(CameraCaptureSession cs) { q.offer(cs); }
            @Override public void onConfigureFailed(CameraCaptureSession cs) { q.offer("configure failed"); }
        }, h);
        Object o = q.poll(WAIT_MS, TimeUnit.MILLISECONDS);
        if (o == null) throw new RuntimeException("createCaptureSession timeout");
        if (!(o instanceof CameraCaptureSession)) throw new RuntimeException("session " + o);
        return (CameraCaptureSession) o;
    }

    static Size pick(Size[] sizes, boolean largest) {
        Size best = null;
        for (Size s : sizes) {
            long a = (long) s.getWidth() * s.getHeight();
            if (best == null) { best = s; continue; }
            long b = (long) best.getWidth() * best.getHeight();
            if (largest ? a > b : a < b) best = s;
        }
        return best;
    }

    /** one JPEG through its own session (preview stream kept running so 3A converges); returns true when captured + decoded */
    boolean jpeg(Ctx c, Result r, CameraDevice d, Handler h, String id, Size ys, Size js, String tag, Stats st) throws Exception {
        String k = "cam" + id;
        ImageReader yr = ImageReader.newInstance(ys.getWidth(), ys.getHeight(), ImageFormat.YUV_420_888, 3);
        ImageReader jr = ImageReader.newInstance(js.getWidth(), js.getHeight(), ImageFormat.JPEG, 2);
        final BlockingQueue<byte[]> jq = new ArrayBlockingQueue<>(2);
        final Stats s = st == null ? new Stats() : st;
        yr.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
            public void onImageAvailable(ImageReader rd) {
                Image im = null;
                try {
                    im = rd.acquireLatestImage(); if (im == null) return;
                    long now = System.nanoTime();
                    if (s.frames == 0) s.firstNs = now;
                    s.lastNs = now;
                    Image.Plane p = im.getPlanes()[0]; ByteBuffer b = p.getBuffer(); int rs = p.getRowStride(), w = im.getWidth(), hh = im.getHeight();
                    double sum = 0, sq = 0; int n = 0;
                    for (int y = 4; y < hh; y += 8) for (int x = 4; x < w; x += 8) { int v = b.get(y * rs + x) & 0xff; sum += v; sq += v * v; n++; }
                    double m = sum / n; s.mean = m; s.std = Math.sqrt(Math.max(0, sq / n - m * m));
                    s.frames++;
                } catch (Throwable t) { } finally { if (im != null) im.close(); }
            }
        }, h);
        jr.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
            public void onImageAvailable(ImageReader rd) {
                Image im = null;
                try { im = rd.acquireNextImage(); if (im == null) return; ByteBuffer b = im.getPlanes()[0].getBuffer(); byte[] a = new byte[b.remaining()]; b.get(a); jq.offer(a); }
                catch (Throwable t) { } finally { if (im != null) im.close(); }
            }
        }, h);
        CameraCaptureSession cs = null;
        try {
            cs = session(d, h, yr.getSurface(), jr.getSurface());
            CaptureRequest.Builder pb = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            pb.addTarget(yr.getSurface());
            cs.setRepeatingRequest(pb.build(), null, h);
            if (st != null) {
                // preview measurement: wait for the first frame (max 5 s), then count for 2 s
                long end = System.currentTimeMillis() + WAIT_MS;
                while (s.frames == 0 && System.currentTimeMillis() < end) Ctx.sleep(20);
                if (s.frames == 0) { r.fail(k + ": no preview frame within 5 s"); return false; }
                int f0 = s.frames; long t0 = System.nanoTime();
                Ctx.sleep(2000);
                double fps = (s.frames - f0) / ((System.nanoTime() - t0) / 1e9);
                r.num(k + "_preview_fps", fps); r.num(k + "_preview_frames", (long) s.frames); r.num(k + "_luma", s.mean); r.num(k + "_luma_std", s.std);
                if (s.frames - f0 < 5) r.fail(k + ": preview stalled, " + (s.frames - f0) + " frames in 2 s");
                if (s.mean <= 4) r.fail(k + ": preview black (mean luma " + String.format("%.1f", s.mean) + "; a covered lens or dark room also causes this)");
                else if (s.std <= 1) r.fail(k + ": preview uniform (luma stddev " + String.format("%.2f", s.std) + "; a covered lens also causes this)");
            } else {
                long end = System.currentTimeMillis() + WAIT_MS;
                while (s.frames < 5 && System.currentTimeMillis() < end) Ctx.sleep(20);
            }
            CaptureRequest.Builder sb = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
            sb.addTarget(jr.getSurface());
            sb.set(CaptureRequest.JPEG_QUALITY, (byte) 90);
            long t = System.nanoTime();
            cs.capture(sb.build(), null, h);
            byte[] jp = jq.poll(8000, TimeUnit.MILLISECONDS);
            if (jp == null) { r.fail(k + ": no JPEG (" + tag + " " + js + ") within 8 s"); return false; }
            r.num(k + "_jpeg_" + tag + "_ms", (System.nanoTime() - t) / 1e6);
            r.num(k + "_jpeg_" + tag + "_bytes", (long) jp.length);
            File f = c.file("camera-" + id + "-" + tag + ".jpg");
            try (FileOutputStream o = new FileOutputStream(f)) { o.write(jp); }
            r.ev(f);
            BitmapFactory.Options op = new BitmapFactory.Options();
            op.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(jp, 0, jp.length, op);
            int fw = op.outWidth, fh = op.outHeight;
            op = new BitmapFactory.Options();
            int ss = 1; while ((long) js.getWidth() * js.getHeight() / (ss * ss) > 4000000L) ss *= 2;
            op.inSampleSize = ss;
            Bitmap bm = BitmapFactory.decodeByteArray(jp, 0, jp.length, op);
            if (bm == null) { r.fail(k + ": JPEG " + tag + " does not decode"); return false; }
            r.num(k + "_jpeg_" + tag + "_w", (long) fw); r.num(k + "_jpeg_" + tag + "_h", (long) fh);
            // decoded content: not black / not flat
            double sum = 0, sq = 0; int n = 0;
            for (int y = bm.getHeight() / 16; y < bm.getHeight(); y += Math.max(1, bm.getHeight() / 32)) for (int x = bm.getWidth() / 16; x < bm.getWidth(); x += Math.max(1, bm.getWidth() / 32)) {
                int p = bm.getPixel(x, y); double v = 0.299 * ((p >> 16) & 0xff) + 0.587 * ((p >> 8) & 0xff) + 0.114 * (p & 0xff); sum += v; sq += v * v; n++;
            }
            bm.recycle();
            double m = sum / n, sd = Math.sqrt(Math.max(0, sq / n - m * m));
            r.num(k + "_jpeg_" + tag + "_luma", m); r.num(k + "_jpeg_" + tag + "_luma_std", sd);
            boolean good = true;
            if (fw != js.getWidth() || fh != js.getHeight()) { r.fail(k + ": JPEG " + tag + " is " + fw + "x" + fh + ", asked " + js); good = false; }
            if (m <= 4 || sd <= 1) { r.fail(k + ": JPEG " + tag + " black/uniform (luma " + String.format("%.1f", m) + " std " + String.format("%.2f", sd) + "; a covered lens also causes this)"); good = false; }
            return good;
        } finally {
            if (cs != null) { try { cs.stopRepeating(); } catch (Throwable t) { } try { cs.close(); } catch (Throwable t) { } }
            Ctx.sleep(150);
            yr.close(); jr.close();
        }
    }

    boolean one(Ctx c, Result r, CameraManager cm, String id, Handler h) throws Exception {
        String k = "cam" + id;
        CameraCharacteristics ch = cm.getCameraCharacteristics(id);
        Integer facing = ch.get(CameraCharacteristics.LENS_FACING);
        r.str(k + "_facing", facing == null ? "?" : facing == CameraCharacteristics.LENS_FACING_FRONT ? "front" : facing == CameraCharacteristics.LENS_FACING_BACK ? "back" : "external");
        StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        if (map == null) { r.fail(k + ": no stream configuration map"); return false; }
        Size[] yuv = map.getOutputSizes(ImageFormat.YUV_420_888), jpg = map.getOutputSizes(ImageFormat.JPEG);
        if (yuv == null || yuv.length == 0 || jpg == null || jpg.length == 0) { r.fail(k + ": no YUV or JPEG output sizes"); return false; }
        Size ys = null;
        for (Size s : yuv) if (s.getWidth() == 640 && s.getHeight() == 480) ys = s;
        if (ys == null) ys = pick(yuv, false);
        Size jmax = pick(jpg, true), jmin = pick(jpg, false);
        r.str(k + "_sizes", "yuv " + ys + " jpeg max " + jmax + " small " + jmin);
        long t = System.nanoTime();
        CameraDevice d = open(cm, id, h);
        r.num(k + "_open_ms", (System.nanoTime() - t) / 1e6);
        try {
            int before = failCount(r);
            boolean a = jpeg(c, r, d, h, id, ys, jmax, "max", new Stats());
            boolean b = jpeg(c, r, d, h, id, ys, jmin, "small", null);
            return a && b && failCount(r) == before;
        } finally { d.close(); }
    }

    /** number of fail reasons so far (reason() joins them with "; " only when failed) */
    static int failCount(Result r) { return r.failed() ? r.reason().split("; ").length : 0; }
}
