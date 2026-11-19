package org.a52sxq.bench;

import android.content.Context;
import android.graphics.ImageFormat;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaRecorder;
import android.opengl.GLES30;
import android.os.Handler;
import android.os.HandlerThread;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Everything at once for c.secs(120) seconds: GPU 256 MB allocate/verify/free cycles + known scene, camera 0 preview,
 * (--es soak_cam <id>, default the first = rear main), hw AVC encode loop, tone playback + mic capture (FFT), accelerometer + gyroscope sampling. Any wrong pixel, black frame,
 * stalled stream, missing tone or exception is reported; one worker failing does not stop the others.
 */
public class SoakMixed extends Test {
    public String id() { return "soak.mixed"; }
    public int budget(Ctx c) { return c.secs(120) + 40; }
    volatile long end;
    final List<String> errors = new ArrayList<>();
    void err(String s) { synchronized (errors) { if (errors.size() < 12) errors.add(s); } }
    boolean live() { return System.nanoTime() < end && !Thread.currentThread().isInterrupted(); }

    public void run(final Ctx c, final Result r) throws Exception {
        final int secs = c.secs(120);
        end = System.nanoTime() + secs * 1000000000L;
        final AudioManager am = (AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE);
        final int oldVol = am.getStreamVolume(AudioManager.STREAM_MUSIC);
        List<Thread> th = new ArrayList<>();
        th.add(new Thread(new Runnable() { public void run() { try { gpu(r); } catch (Throwable t) { err("gpu: " + t); } } }, "soak-gpu"));
        th.add(new Thread(new Runnable() { public void run() { try { camera(c, r); } catch (Throwable t) { err("camera: " + t); } } }, "soak-camera"));
        th.add(new Thread(new Runnable() { public void run() { try { codec(r); } catch (Throwable t) { err("codec: " + t); } } }, "soak-codec"));
        th.add(new Thread(new Runnable() { public void run() { try { audio(am, r); } catch (Throwable t) { err("audio: " + t); } } }, "soak-audio"));
        th.add(new Thread(new Runnable() { public void run() { try { sensors(c, r); } catch (Throwable t) { err("sensors: " + t); } } }, "soak-sensors"));
        try {
            for (Thread t : th) t.start();
            for (Thread t : th) { t.join(Math.max(1, (end - System.nanoTime()) / 1000000L) + 25000); if (t.isAlive()) { err(t.getName() + " hung"); t.interrupt(); } }
        } finally { try { am.setStreamVolume(AudioManager.STREAM_MUSIC, oldVol, 0); } catch (Exception e) { } }
        r.num("seconds_run", (long) secs).num("errors", (long) errors.size());
        if (!errors.isEmpty()) r.fail(errors.size() + " problem(s): " + errors);
        else r.pass(secs + " s of concurrent GPU + camera + codec + audio + sensors without a wrong pixel, black frame, stall or exception");
    }

    void gpu(Result r) {
        Egl e = new Egl(null);
        try {
            Scene s = new Scene(); int[] frame = Scene.fbo(1280, 720, null); int cycles = 0, bad = 0, oom = 0, sceneBad = 0;
            StringBuilder why = new StringBuilder();
            while (live()) {
                List<int[]> tex = new ArrayList<>(); int[] er = new int[1];
                for (int i = 0; i < 16 && live(); i++) {
                    int[] ft = Scene.fbo(2048, 2048, er);
                    if (ft == null) { if (er[0] == GLES30.GL_OUT_OF_MEMORY) oom++; else bad++; break; }
                    int col = ((i * 37 + cycles) & 255) << 16 | (i * 11 & 255) << 8 | 51; s.fill(2048, 2048, col, col);
                    tex.add(ft);
                }
                for (int i = 0; i < tex.size(); i++) {
                    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, tex.get(i)[0]); int[] p = s.pixel(2047, 2047);
                    if (p[0] != ((i * 37 + cycles) & 255) || p[1] != (i * 11 & 255) || p[2] != 51) bad++;
                }
                for (int[] ft : tex) { GLES30.glDeleteFramebuffers(1, new int[] { ft[0] }, 0); GLES30.glDeleteTextures(1, new int[] { ft[1] }, 0); }
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, frame[0]);
                for (int k = 0; k < 20 && live(); k++) { s.draw(1280, 720, k * 0.1f); GLES30.glFinish(); }
                sceneBad += s.verify(1280, 720, why);
                cycles++;
            }
            r.num("gpu_cycles", (long) cycles).num("gpu_bad_textures", (long) bad).num("gpu_oom", (long) oom).num("gpu_scene_bad_probes", (long) sceneBad);
            if (bad > 0) err("gpu: " + bad + " wrong texture readbacks");
            if (sceneBad > 0) err("gpu: scene wrong: " + why);
            if (oom > 0) err("gpu: GL_OUT_OF_MEMORY x" + oom + " at 256 MB");
            if (cycles == 0) err("gpu: no cycle completed");
        } finally { e.release(); }
    }

    void camera(Ctx c, Result r) throws Exception {
        CameraManager cm = (CameraManager) c.app.getSystemService(Context.CAMERA_SERVICE);
        String[] ids = cm.getCameraIdList(); if (ids.length == 0) { err("camera: no cameras"); return; }
        HandlerThread ht = new HandlerThread("soak-cam"); ht.start(); Handler h = new Handler(ht.getLooper());
        final AtomicInteger frames = new AtomicInteger(), black = new AtomicInteger(); final long[] lastNs = { System.nanoTime() };
        ImageReader ir = ImageReader.newInstance(640, 480, ImageFormat.YUV_420_888, 3);
        ir.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() { public void onImageAvailable(ImageReader rd) {
            Image im = rd.acquireLatestImage(); if (im == null) return;
            try { ByteBuffer y = im.getPlanes()[0].getBuffer(); int rs = im.getPlanes()[0].getRowStride(); long sum = 0; int n = 0;
                for (int yy = 8; yy < 480; yy += 16) for (int x = 8; x < 640; x += 16) { sum += y.get(yy * rs + x) & 255; n++; }
                if (sum / (double) n < 4) black.incrementAndGet();
                frames.incrementAndGet(); lastNs[0] = System.nanoTime();
            } finally { im.close(); } } }, h);
        CameraDevice d = null; int stalls = 0;
        try {
            String cam = c.param("soak_cam", ids[0]); r.str("camera_id", cam);
            d = CameraStill.open(cm, cam, h);
            CameraCaptureSession cs = CameraStill.session(d, h, ir.getSurface());
            CaptureRequest.Builder b = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW); b.addTarget(ir.getSurface());
            cs.setRepeatingRequest(b.build(), null, h);
            long t0 = System.nanoTime(); lastNs[0] = t0;
            while (live()) { Ctx.sleep(500); if (System.nanoTime() - lastNs[0] > 3000000000L) { stalls++; lastNs[0] = System.nanoTime(); } }
            double fps = frames.get() / ((System.nanoTime() - t0) / 1e9);
            r.num("camera_frames", (long) frames.get()).num("camera_fps", fps).num("camera_black_frames", (long) black.get()).num("camera_stalls_3s", (long) stalls);
            if (frames.get() == 0) err("camera: no preview frames");
            if (stalls > 0) err("camera: preview stalled > 3 s x" + stalls);
            if (black.get() > 0) err("camera: " + black.get() + "/" + frames.get() + " black frames (mean luma < 4; a covered lens/dark room also causes this)");
        } finally { if (d != null) d.close(); ir.close(); ht.quitSafely(); }
    }

    void codec(Result r) throws Exception {
        List<String> enc = CodecRoundtrip.hw("video/avc", true);
        if (enc.isEmpty()) { err("codec: no hw avc encoder"); return; }
        CodecRoundtrip cr = new CodecRoundtrip(); int runs = 0, short_ = 0; double fps = 0;
        while (live()) { CodecRoundtrip.Enc e = cr.encode(enc.get(0), "video/avc"); if (e.frames != CodecRoundtrip.FRAMES) short_++; fps += e.fps; runs++; }
        r.num("codec_encode_runs", (long) runs).num("codec_short_runs", (long) short_).num("codec_avg_enc_fps", runs > 0 ? fps / runs : 0);
        if (runs == 0) err("codec: no encode run completed");
        if (short_ > 0) err("codec: " + short_ + " encode runs lost frames");
    }

    void audio(AudioManager am, Result r) throws Exception {
        final int SR = AudioOut.SR;
        try { am.setStreamVolume(AudioManager.STREAM_MUSIC, Math.max(1, Math.round(am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) * 0.3f)), 0); } catch (Exception e) { }
        AudioRecord rec = new AudioRecord(MediaRecorder.AudioSource.UNPROCESSED, SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, SR * 2);
        final AudioTrack tr = new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(new AudioFormat.Builder().setSampleRate(SR).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(SR).build();
        Thread w = new Thread(new Runnable() { public void run() { short[] b = new short[4800]; long n = 0;
            while (System.nanoTime() < end + 500000000L) { for (int i = 0; i < b.length; i++, n++) b[i] = (short) (Math.sin(2 * Math.PI * 1000 * n / SR) * 0.35 * 32767); if (tr.write(b, 0, b.length) < 0) break; } } }, "soak-tone");
        int windows = 0, miss = 0;
        try {
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) { err("audio: AudioRecord init failed"); return; }
            rec.startRecording(); tr.play(); w.start(); AudioOut.record(rec, SR);
            while (live()) {
                short[] cap = AudioOut.record(rec, AudioOut.N + SR / 2);
                if (cap == null) { miss++; windows++; continue; }
                double[] sp = AudioOut.spectrum(cap, SR / 4); int lo = 300 * AudioOut.N / SR, hi = 8000 * AudioOut.N / SR, pk = lo; for (int i = lo; i < hi; i++) if (sp[i] > sp[pk]) pk = i;
                double hz = pk * (double) SR / AudioOut.N; if (Math.abs(hz - 1000) > 20) miss++;
                windows++;
            }
            r.num("audio_windows", (long) windows).num("audio_tone_missing", (long) miss).num("audio_underruns", (long) tr.getUnderrunCount());
            if (windows == 0) err("audio: no capture window");
            if (miss > 0) err("audio: 1 kHz tone not the capture peak in " + miss + "/" + windows + " windows");
        } finally { try { tr.pause(); tr.flush(); } catch (Exception e) { } w.join(3000); tr.release(); try { rec.stop(); } catch (Exception e) { } rec.release(); }
    }

    void sensors(Ctx c, Result r) {
        SensorManager sm = (SensorManager) c.app.getSystemService(Context.SENSOR_SERVICE);
        final AtomicInteger acc = new AtomicInteger(), gyr = new AtomicInteger();
        HandlerThread ht = new HandlerThread("soak-sens"); ht.start();
        SensorEventListener l = new SensorEventListener() {
            public void onSensorChanged(SensorEvent e) { if (e.sensor.getType() == Sensor.TYPE_ACCELEROMETER) acc.incrementAndGet(); else gyr.incrementAndGet(); }
            public void onAccuracyChanged(Sensor s, int a) { } };
        Sensor a = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER), g = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        try {
            if (a != null) sm.registerListener(l, a, 20000, new Handler(ht.getLooper()));
            if (g != null) sm.registerListener(l, g, 20000, new Handler(ht.getLooper()));
            long t0 = System.nanoTime(); int gaps = 0, la = 0, lg = 0;
            while (live()) { Ctx.sleep(5000); int na = acc.get(), ng = gyr.get(); if ((a != null && na == la) || (g != null && ng == lg)) gaps++; la = na; lg = ng; }
            double s = (System.nanoTime() - t0) / 1e9;
            r.num("accel_hz", acc.get() / s).num("gyro_hz", gyr.get() / s).num("sensor_gaps_5s", (long) gaps);
            if (a == null || g == null) err("sensors: accelerometer/gyroscope missing");
            if (gaps > 0) err("sensors: " + gaps + " five-second windows without events");
        } finally { sm.unregisterListener(l); ht.quitSafely(); }
    }
}
