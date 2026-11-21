package org.a52sxq.bench;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaRecorder;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Compressed offload: encodes a 1 kHz tone to AAC-LC (MediaCodec), and when AudioManager says AAC offload is supported plays the
 * raw AAC frames through an offloaded AudioTrack at low volume while the mic captures; the FFT peak must be the tone. SKIP when
 * the device reports no offload support.
 */
public class AudioOffload extends Test {
    public String id() { return "audio.offload"; }
    public int budget(Ctx c) { return 45; }

    public void run(Ctx c, Result r) throws Exception {
        { String ext = AudioOut.externalOutput((AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE));
          if (ext != null) { r.skip("external audio output connected (" + ext + "): the tone would play there"); return; } }
        final int SR = AudioOut.SR;
        AudioAttributes aa = new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build();
        AudioFormat aac = new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_AAC_LC).setSampleRate(SR).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build();
        AudioFormat mp3 = new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_MP3).setSampleRate(SR).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build();
        boolean sAac = AudioManager.isOffloadedPlaybackSupported(aac, aa), sMp3 = AudioManager.isOffloadedPlaybackSupported(mp3, aa);
        r.num("offload_aac_supported", sAac ? 1L : 0L).num("offload_mp3_supported", sMp3 ? 1L : 0L);
        if (!sAac) { r.skip("AudioManager.isOffloadedPlaybackSupported(AAC-LC 48k stereo) = false" + (sMp3 ? " (MP3 offload is reported, but there is no MP3 encoder to generate a stream)" : " and MP3 = false")); return; }
        // encode 6 s of 1 kHz stereo
        MediaFormat f = MediaFormat.createAudioFormat("audio/mp4a-latm", SR, 2);
        f.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC); f.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
        MediaCodec mc = MediaCodec.createEncoderByType("audio/mp4a-latm"); List<byte[]> frames = new ArrayList<>();
        try {
            mc.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); mc.start();
            MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo(); long n = 0, total = SR * 6L; boolean eos = false; long dead = System.nanoTime() + 15000000000L;
            while (!eos && System.nanoTime() < dead) {
                if (n <= total) { int ii = mc.dequeueInputBuffer(5000);
                    if (ii >= 0) { if (n >= total) { mc.queueInputBuffer(ii, 0, 0, n * 1000000L / SR, MediaCodec.BUFFER_FLAG_END_OF_STREAM); n = total + 1; }
                        else { ByteBuffer b = mc.getInputBuffer(ii); b.clear(); int k = Math.min(b.capacity() / 4, 1024); long pts = n * 1000000L / SR;
                            for (int i = 0; i < k; i++, n++) { short v = (short) (Math.sin(2 * Math.PI * 1000 * n / SR) * 0.35 * 32767); b.put((byte) v).put((byte) (v >> 8)).put((byte) v).put((byte) (v >> 8)); }
                            mc.queueInputBuffer(ii, 0, k * 4, pts, 0); } } }
                int oi = mc.dequeueOutputBuffer(bi, 5000);
                if (oi >= 0) { if (bi.size > 0 && (bi.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) { byte[] d = new byte[bi.size]; ByteBuffer b = mc.getOutputBuffer(oi); b.position(bi.offset); b.get(d); frames.add(d); }
                    if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true; mc.releaseOutputBuffer(oi, false); }
            }
        } finally { try { mc.stop(); } catch (Throwable t) { } mc.release(); }
        r.num("aac_frames", (long) frames.size());
        if (frames.size() < 100) { r.fail("AAC encoder produced only " + frames.size() + " frames"); return; }
        AudioManager am = (AudioManager) c.app.getSystemService(Context.AUDIO_SERVICE); int old = am.getStreamVolume(AudioManager.STREAM_MUSIC);
        AudioRecord rec = null; AudioTrack tr = null;
        try {
            try { am.setStreamVolume(AudioManager.STREAM_MUSIC, Math.max(1, Math.round(am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) * 0.3f)), 0); } catch (Exception e) { }
            rec = new AudioRecord(MediaRecorder.AudioSource.UNPROCESSED, SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, SR * 2);
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) { r.fail("AudioRecord init failed"); return; }
            tr = new AudioTrack.Builder().setAudioAttributes(aa).setAudioFormat(aac).setOffloadedPlayback(true).setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(65536).build();
            r.num("track_is_offloaded", tr.isOffloadedPlayback() ? 1L : 0L);
            rec.startRecording(); tr.play();
            final AudioTrack ft = tr; final List<byte[]> fr = frames;
            Thread w = new Thread(new Runnable() { public void run() { try { for (byte[] d : fr) { int o = 0; while (o < d.length) { int k = ft.write(d, o, d.length - o); if (k < 0) return; if (k == 0) Ctx.sleep(10); o += k; } } } catch (Throwable t) { } } });
            w.start();
            AudioOut.record(rec, SR * 3 / 2);
            short[] cap = AudioOut.record(rec, AudioOut.N + SR / 2);
            int head = tr.getPlaybackHeadPosition();
            try { tr.pause(); tr.flush(); } catch (Exception e) { } w.join(3000);
            if (cap == null) { r.fail("capture failed"); return; }
            File wf = c.file("audio-offload.wav"); AudioOut.wav(wf, cap, cap.length); r.ev(wf);
            double[] sp = AudioOut.spectrum(cap, SR / 4); int lo = 300 * AudioOut.N / SR, hi = 8000 * AudioOut.N / SR, pk = lo; for (int i = lo; i < hi; i++) if (sp[i] > sp[pk]) pk = i;
            double hz = pk * (double) SR / AudioOut.N; double med = 0; for (int i = lo; i < hi; i++) med += sp[i]; med /= (hi - lo);
            r.num("peak_hz", hz).num("peak_over_mean_db", 20 * Math.log10(sp[pk] / Math.max(med, 1e-9))).num("frames_played", (long) head);
            if (Math.abs(hz - 1000) > 20 || sp[pk] < med * 8) r.fail("offloaded AAC tone not heard: peak " + Math.round(hz) + " Hz (want 1000), head " + head);
            else if (!tr.isOffloadedPlayback()) r.fail("track played but is not offloaded");
            else r.pass("offloaded AAC-LC tone played and captured at " + Math.round(hz) + " Hz");
        } finally { if (tr != null) tr.release(); if (rec != null) { try { rec.stop(); } catch (Exception e) { } rec.release(); } try { am.setStreamVolume(AudioManager.STREAM_MUSIC, old, 0); } catch (Exception e) { } }
    }
}
