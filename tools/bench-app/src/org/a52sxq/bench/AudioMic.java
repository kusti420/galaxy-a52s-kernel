package org.a52sxq.bench;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** audio.mic: every input source: 1.5 s capture at 48 kHz mono, RMS / peak / noise floor, non-zero check. */
public class AudioMic extends Test {
    public String id() { return "audio.mic"; }
    public int budget(Ctx c) { return 60; }
    static final int SR = 48000;

    static void wav(File f, short[] s, int n) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(44 + n * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + n * 2).put("WAVEfmt ".getBytes()).putInt(16).putShort((short) 1).putShort((short) 1).putInt(SR).putInt(SR * 2).putShort((short) 2).putShort((short) 16).put("data".getBytes()).putInt(n * 2);
        for (int i = 0; i < n; i++) b.putShort(s[i]);
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(b.array()); }
    }

    public void run(Ctx c, Result r) throws Exception {
        AudioManager am = (AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE);
        StringBuilder devs = new StringBuilder();
        try { for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_INPUTS)) devs.append(d.getType()).append(d.getAddress() == null || d.getAddress().isEmpty() ? "" : "(" + d.getAddress() + ")").append(' '); } catch (Throwable t) { }
        r.str("input_device_types", devs.toString().trim());
        int[] src = { MediaRecorder.AudioSource.MIC, MediaRecorder.AudioSource.CAMCORDER, MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.VOICE_COMMUNICATION, MediaRecorder.AudioSource.UNPROCESSED };
        String[] name = { "mic", "camcorder", "voice_recognition", "voice_communication", "unprocessed" };
        int good = 0;
        for (int k = 0; k < src.length; k++) {
            AudioRecord rec = null;
            try {
                int min = AudioRecord.getMinBufferSize(SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                rec = new AudioRecord(src[k], SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, SR));
                if (rec.getState() != AudioRecord.STATE_INITIALIZED) { r.fail(name[k] + ": AudioRecord not initialised (permission RECORD_AUDIO?)"); continue; }
                rec.startRecording();
                if (rec.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) { r.fail(name[k] + ": did not start recording"); continue; }
                int total = SR * 3 / 2; short[] buf = new short[total]; int n = 0; long t0 = System.nanoTime();
                while (n < total && System.nanoTime() - t0 < 5e9) { int g = rec.read(buf, n, Math.min(4800, total - n)); if (g <= 0) break; n += g; }
                rec.stop();
                int skipN = Math.min(n, SR / 5);   // first 200 ms: start-up transient
                double sq = 0; int peak = 0, nz = 0; double minWin = Double.MAX_VALUE;
                for (int i = skipN; i < n; i++) { int v = buf[i]; sq += (double) v * v; if (Math.abs(v) > peak) peak = Math.abs(v); if (v != 0) nz++; }
                for (int w = skipN; w + 2400 <= n; w += 2400) { double s = 0; for (int i = w; i < w + 2400; i++) s += (double) buf[i] * buf[i]; minWin = Math.min(minWin, Math.sqrt(s / 2400)); }
                int cnt = Math.max(1, n - skipN);
                double rms = Math.sqrt(sq / cnt);
                r.num(name[k] + "_samples", (long) n).num(name[k] + "_rms_dbfs", rms > 0 ? 20 * Math.log10(rms / 32768.0) : -120)
                 .num(name[k] + "_peak", (long) peak).num(name[k] + "_nonzero_pct", 100.0 * nz / cnt)
                 .num(name[k] + "_noise_floor_dbfs", minWin > 0 && minWin < Double.MAX_VALUE ? 20 * Math.log10(minWin / 32768.0) : -120);
                try { AudioDeviceInfo rd = rec.getRoutedDevice(); if (rd != null) r.num(name[k] + "_routed_type", (long) rd.getType()); } catch (Throwable t) { }
                if (k == 0 && n > 0) { File f = c.file("audio_mic_mic.wav"); wav(f, buf, n); r.ev(f); }
                if (n < total * 9 / 10) r.fail(name[k] + ": short read, " + n + " of " + total + " samples");
                else if (nz == 0) r.fail(name[k] + ": all samples are zero (silenced or dead input)");
                else good++;
            } catch (Throwable t) { r.fail(name[k] + ": " + t); }
            finally { if (rec != null) try { rec.release(); } catch (Throwable t) { } }
            Ctx.sleep(150);
        }
        r.num("sources_ok", (long) good).num("sources_total", (long) src.length);
        if (good == src.length) r.pass(good + "/" + src.length + " input sources delivered non-zero audio");
    }
}
