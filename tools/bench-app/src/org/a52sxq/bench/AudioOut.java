package org.a52sxq.bench;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Plays a tone through AudioTrack in each output mode at low stream volume while AudioRecord (built-in mic) captures;
 * the FFT peak of the capture must be the tone (within 2 %) and stand well above a silent baseline at that frequency.
 * Stream volumes are restored afterwards.
 */
public class AudioOut extends Test {
    public String id() { return "audio.out"; }
    public int budget(Ctx c) { return 60; }
    static final int SR = 48000, N = 32768;
    /** Name of a connected external audio output (Bluetooth, USB, wired, HDMI), or null. A test tone must never go to
     *  someone's headphones unannounced (2026-11-21: a "silent" run played to a paired Bluetooth DAC, whose absolute
     *  volume `cmd media_session volume --set 0` does not touch). */
    public static String externalOutput(AudioManager am) {
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


    /** magnitude spectrum (N/2 bins) of N samples starting at off, Hann window */
    static double[] spectrum(short[] s, int off) {
        double[] re = new double[N], im = new double[N];
        for (int i = 0; i < N; i++) re[i] = s[off + i] / 32768.0 * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (N - 1)));
        for (int i = 1, j = 0; i < N; i++) { int bit = N >> 1; for (; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; } }
        for (int len = 2; len <= N; len <<= 1) {
            double ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang);
            for (int i = 0; i < N; i += len) { double cr = 1, ci = 0;
                for (int k = 0; k < len / 2; k++) { int a = i + k, b = a + len / 2; double xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr;
                    re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi; double n = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = n; } }
        }
        double[] m = new double[N / 2];
        for (int i = 0; i < N / 2; i++) m[i] = Math.sqrt(re[i] * re[i] + im[i] * im[i]);
        return m;
    }
    static void wav(File f, short[] s, int n) throws Exception {
        ByteBuffer b = ByteBuffer.allocate(44 + n * 2).order(ByteOrder.LITTLE_ENDIAN);
        b.put("RIFF".getBytes()).putInt(36 + n * 2).put("WAVEfmt ".getBytes()).putInt(16).putShort((short) 1).putShort((short) 1).putInt(SR).putInt(SR * 2).putShort((short) 2).putShort((short) 16)
                .put("data".getBytes()).putInt(n * 2);
        for (int i = 0; i < n; i++) b.putShort(s[i]);
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(b.array()); }
    }
    static short[] record(AudioRecord rec, int n) {
        short[] s = new short[n]; int got = 0;
        long end = System.currentTimeMillis() + n * 1000L / SR + 3000;
        while (got < n && System.currentTimeMillis() < end) { int k = rec.read(s, got, n - got); if (k <= 0) break; got += k; }
        return got == n ? s : null;
    }

    public void run(Ctx c, Result r) throws Exception {
        { String ext = AudioOut.externalOutput((AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE));
          if (ext != null) { r.skip("external audio output connected (" + ext + "): the tone would play there"); return; } }
        AudioManager am = (AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE);
        int[] streams = { AudioManager.STREAM_MUSIC, AudioManager.STREAM_VOICE_CALL }; int[] old = new int[2];
        for (int i = 0; i < 2; i++) old[i] = am.getStreamVolume(streams[i]);
        AudioRecord rec = null;
        try {
            for (int i = 0; i < 2; i++) { int max = am.getStreamMaxVolume(streams[i]); try { am.setStreamVolume(streams[i], Math.max(1, Math.round(max * 0.3f)), 0); } catch (Exception e) { r.note("setStreamVolume: " + e); } }
            r.num("music_volume_used", (long) am.getStreamVolume(AudioManager.STREAM_MUSIC)).num("music_volume_max", (long) am.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
            int min = AudioRecord.getMinBufferSize(SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            rec = new AudioRecord(MediaRecorder.AudioSource.UNPROCESSED, SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, SR));
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) { r.fail("AudioRecord did not initialise (RECORD_AUDIO granted?)"); return; }
            rec.startRecording();
            record(rec, SR / 2);                                     // settle
            short[] base = record(rec, N + 4800);
            if (base == null) { r.fail("AudioRecord delivered no data"); return; }
            double[] bs = spectrum(base, 4800);
            String[] names = { "media_deep", "media_lowlat", "voice_comm" };
            int[] usage = { AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_VOICE_COMMUNICATION };
            int[] perf = { AudioTrack.PERFORMANCE_MODE_POWER_SAVING, AudioTrack.PERFORMANCE_MODE_LOW_LATENCY, AudioTrack.PERFORMANCE_MODE_NONE };
            int[] freq = { 1000, 1500, 2000 };
            int okMedia = 0; boolean voiceOk = false; StringBuilder bad = new StringBuilder();
            for (int m = 0; m < 3; m++) {
                int n = SR * 3; short[] tone = new short[n];
                for (int i = 0; i < n; i++) { double env = Math.min(1, Math.min(i, n - i) / 2400.0); tone[i] = (short) (Math.sin(2 * Math.PI * freq[m] * i / SR) * 0.35 * 32767 * env); }
                AudioTrack tr = new AudioTrack.Builder()
                        .setAudioAttributes(new AudioAttributes.Builder().setUsage(usage[m]).setContentType(m == 2 ? AudioAttributes.CONTENT_TYPE_SPEECH : AudioAttributes.CONTENT_TYPE_MUSIC).build())
                        .setAudioFormat(new AudioFormat.Builder().setSampleRate(SR).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                        .setPerformanceMode(perf[m]).setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(n * 2).build();
                try {
                    tr.write(tone, 0, n); tr.play();
                    record(rec, SR * 6 / 10);                        // output latency + ramp
                    short[] cap = record(rec, N + SR / 2);
                    int head = tr.getPlaybackHeadPosition();
                    tr.stop();
                    if (cap == null) { r.fail(names[m] + ": capture failed"); continue; }
                    File wf = c.file("audio-out-" + names[m] + ".wav"); wav(wf, cap, cap.length); r.ev(wf);
                    double[] sp = spectrum(cap, SR / 4);
                    int lo = 300 * N / SR, hi = 8000 * N / SR, pk = lo; for (int i = lo; i < hi; i++) if (sp[i] > sp[pk]) pk = i;
                    double d = (sp[pk - 1] - sp[pk + 1]) / (2 * (sp[pk - 1] - 2 * sp[pk] + sp[pk + 1])), hz = (pk + (Double.isNaN(d) ? 0 : d)) * SR / N;
                    int tb = Math.round(freq[m] * (float) N / SR); double tone_m = 0, base_m = 1e-9;
                    for (int i = tb - 3; i <= tb + 3; i++) { tone_m = Math.max(tone_m, sp[i]); base_m = Math.max(base_m, bs[i]); }
                    double gainDb = 20 * Math.log10(tone_m / base_m), rms = 0; for (short v : cap) rms += v * v; rms = Math.sqrt(rms / cap.length);
                    r.num(names[m] + "_peak_hz", hz).num(names[m] + "_tone_over_silence_db", gainDb).num(names[m] + "_capture_rms", rms)
                            .num(names[m] + "_frames_played", (long) head).num(names[m] + "_perf_mode", (long) tr.getPerformanceMode()).num(names[m] + "_underruns", (long) tr.getUnderrunCount());
                    boolean ok = Math.abs(hz - freq[m]) / freq[m] < 0.02 && gainDb > 12 && head > SR / 2;
                    if (ok) { if (m < 2) okMedia++; else voiceOk = true; }
                    else bad.append(names[m]).append(" (want ").append(freq[m]).append(" Hz, peak ").append(Math.round(hz)).append(" Hz, tone ").append(Math.round(gainDb)).append(" dB over silence, ").append(head).append(" frames played); ");
                } finally { tr.release(); }
                record(rec, SR / 4);
            }
            r.num("media_modes_ok", (long) okMedia).num("voice_comm_ok", voiceOk ? 1L : 0L);
            if (okMedia < 2 || !voiceOk) r.fail("tone not heard by the mic: " + bad + "(wav captures are the evidence)");
            else r.pass("tone played and captured within 2 % in all 3 modes (deep buffer, low latency, voice communication)");
        } finally {
            if (rec != null) { try { rec.stop(); } catch (Exception e) { } rec.release(); }
            for (int i = 0; i < 2; i++) try { am.setStreamVolume(streams[i], old[i], 0); } catch (Exception e) { }
        }
    }
}
