package org.a52sxq.bench;

import android.content.Context;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Range;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.List;

/** camera.video: MediaRecorder H.264 + HEVC 1080p from camera 0, then hw decode of the MP4: frame count, duration, luma. */
public class CameraVideo extends Test {
    static final int W = 1920, H = 1080;
    public String id() { return "camera.video"; }
    public int budget(Ctx c) { return 90; }

    public void run(Ctx c, Result r) throws Exception {
        CameraManager cm = (CameraManager) c.app.getSystemService(Context.CAMERA_SERVICE);
        String[] ids = cm.getCameraIdList();
        if (ids.length == 0) { r.fail("no cameras"); return; }
        int secs = Math.min(c.secs(5), 15);
        HandlerThread ht = new HandlerThread("camvid"); ht.start();
        Handler h = new Handler(ht.getLooper());
        int ok = 0;
        try {
            String[][] encs = { { "avc", "video/avc" }, { "hevc", "video/hevc" } };
            for (String[] e : encs) {
                c.log("camera.video: record " + e[0] + " " + secs + " s");
                File f = c.file("camera-video-" + e[0] + ".mp4");
                f.delete();
                try {
                    record(cm, ids[0], h, f, e[0].equals("avc") ? MediaRecorder.VideoEncoder.H264 : MediaRecorder.VideoEncoder.HEVC, secs);
                    r.ev(f); r.num(e[0] + "_bytes", f.length());
                    if (verify(r, f, e[0], e[1], secs)) ok++;
                } catch (Throwable t) { r.fail(e[0] + ": " + t); }
                Ctx.sleep(300);
            }
        } finally { ht.quitSafely(); }
        if (ok == 2 && !r.failed()) r.pass("H.264 + HEVC " + W + "x" + H + " " + secs + " s recorded from camera " + ids[0] + " and decoded by the hw decoders");
    }

    @SuppressWarnings("deprecation")
    void record(CameraManager cm, String id, Handler h, File out, int enc, int secs) throws Exception {
        MediaRecorder mr = new MediaRecorder();
        CameraDevice d = null; CameraCaptureSession cs = null; boolean started = false;
        try {
            mr.setVideoSource(MediaRecorder.VideoSource.SURFACE);
            mr.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            mr.setOutputFile(out.getAbsolutePath());
            mr.setVideoEncoder(enc);
            mr.setVideoSize(W, H);
            mr.setVideoFrameRate(30);
            mr.setVideoEncodingBitRate(12000000);
            mr.prepare();
            d = CameraStill.open(cm, id, h);
            cs = CameraStill.session(d, h, mr.getSurface());
            CaptureRequest.Builder b = d.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
            b.addTarget(mr.getSurface());
            b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, new Range<>(30, 30));
            cs.setRepeatingRequest(b.build(), null, h);
            mr.start(); started = true;
            Ctx.sleep(secs * 1000L);
            mr.stop(); started = false;
        } finally {
            if (started) try { mr.stop(); } catch (Throwable t) { }
            if (cs != null) { try { cs.stopRepeating(); } catch (Throwable t) { } try { cs.close(); } catch (Throwable t) { } }
            if (d != null) d.close();
            mr.release();
        }
    }

    boolean verify(Result r, File f, String key, String mime, int secs) throws Exception {
        if (f.length() < 10000) { r.fail(key + ": MP4 is " + f.length() + " bytes"); return false; }
        MediaExtractor ex = new MediaExtractor();
        MediaCodec mc = null;
        try {
            ex.setDataSource(f.getAbsolutePath());
            MediaFormat fmt = null;
            for (int i = 0; i < ex.getTrackCount(); i++) { MediaFormat t = ex.getTrackFormat(i); String m = t.getString(MediaFormat.KEY_MIME); if (m != null && m.startsWith("video/")) { fmt = t; ex.selectTrack(i); break; } }
            if (fmt == null) { r.fail(key + ": no video track in MP4"); return false; }
            String m = fmt.getString(MediaFormat.KEY_MIME);
            if (!mime.equalsIgnoreCase(m)) { r.fail(key + ": track mime " + m + ", expected " + mime); return false; }
            double dur = fmt.containsKey(MediaFormat.KEY_DURATION) ? fmt.getLong(MediaFormat.KEY_DURATION) / 1e6 : 0;
            r.num(key + "_duration_s", dur);
            r.num(key + "_w", (long) fmt.getInteger(MediaFormat.KEY_WIDTH)); r.num(key + "_h", (long) fmt.getInteger(MediaFormat.KEY_HEIGHT));
            List<String> decs = CodecRoundtrip.hw(mime, false);
            if (decs.isEmpty()) { r.fail(key + ": no hw decoder for " + mime); return false; }
            r.str(key + "_decoder", decs.get(0));
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
            mc = MediaCodec.createByCodecName(decs.get(0));
            mc.configure(fmt, null, null, 0);
            mc.start();
            MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
            boolean inEos = false, eos = false; int frames = 0, samples = 0, dark = 0; double lumaSum = 0; int lumaN = 0;
            long t0 = System.nanoTime(), dead = t0 + 30000000000L;
            while (!eos) {
                if (System.nanoTime() > dead) { r.fail(key + ": decode timeout after " + frames + " frames"); return false; }
                if (!inEos) {
                    int ii = mc.dequeueInputBuffer(5000);
                    if (ii >= 0) {
                        int n = ex.readSampleData(mc.getInputBuffer(ii), 0);
                        if (n < 0) { mc.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true; }
                        else { mc.queueInputBuffer(ii, 0, n, ex.getSampleTime(), 0); samples++; ex.advance(); }
                    }
                }
                int oi = mc.dequeueOutputBuffer(bi, 5000);
                if (oi >= 0) {
                    if (bi.size > 0) {
                        if (frames % 10 == 0) {
                            Image img = mc.getOutputImage(oi);
                            if (img != null) {
                                Image.Plane p = img.getPlanes()[0]; ByteBuffer b = p.getBuffer(); int rs = p.getRowStride();
                                double s = 0; int n = 0;
                                for (int y = 8; y < H; y += 32) for (int x = 8; x < W; x += 32) { s += b.get(y * rs + x) & 0xff; n++; }
                                img.close();
                                double mean = s / n; lumaSum += mean; lumaN++;
                                if (mean <= 4) dark++;
                            }
                        }
                        frames++;
                    }
                    if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true;
                    mc.releaseOutputBuffer(oi, false);
                }
            }
            double ds = (System.nanoTime() - t0) / 1e9;
            r.num(key + "_frames", (long) frames); r.num(key + "_samples", (long) samples); r.num(key + "_dec_fps", frames / ds);
            r.num(key + "_rec_fps", dur > 0 ? frames / dur : 0); r.num(key + "_luma", lumaN == 0 ? 0 : lumaSum / lumaN);
            boolean good = true;
            if (fmt.getInteger(MediaFormat.KEY_WIDTH) != W || fmt.getInteger(MediaFormat.KEY_HEIGHT) != H) { r.fail(key + ": recorded size is not " + W + "x" + H); good = false; }
            if (dur < secs - 1.0 || dur > secs + 1.5) { r.fail(key + ": duration " + String.format("%.2f", dur) + " s for a " + secs + " s recording"); good = false; }
            if (frames != samples) { r.fail(key + ": decoded " + frames + " of " + samples + " samples"); good = false; }
            if (frames < secs * 12) { r.fail(key + ": only " + frames + " frames in " + secs + " s"); good = false; }
            if (lumaN > 0 && dark == lumaN) { r.fail(key + ": every sampled frame is black (a covered lens also causes this)"); good = false; }
            return good;
        } finally {
            if (mc != null) { try { mc.stop(); } catch (Throwable t) { } mc.release(); }
            ex.release();
        }
    }
}
