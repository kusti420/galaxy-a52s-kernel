package org.a52sxq.bench;

import android.graphics.Rect;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

/** codec.roundtrip: every hw video encoder encodes a synthetic moving pattern, every hw decoder of that mime decodes it; PSNR(Y) vs source. */
public class CodecRoundtrip extends Test {
    static final int W = 1280, H = 720, FRAMES = 60, FPS = 30;
    static final long FRAME_US = 1000000L / FPS;
    static final double MIN_PSNR = 28.0;
    static final String[][] MIMES = { { "video/avc", "avc" }, { "video/hevc", "hevc" }, { "video/x-vnd.on2.vp8", "vp8" }, { "video/x-vnd.on2.vp9", "vp9" } };

    public String id() { return "codec.roundtrip"; }
    public int budget(Ctx c) { return 120; }

    /** luma of source frame f */
    static void lumaFrame(int f, byte[] y) {
        int bx = (f * 8) % (W - 200), by = (f * 4) % (H - 200);
        for (int r = 0; r < H; r++) {
            int base = 40 + r * 40 / H, o = r * W;
            for (int x = 0; x < W; x++) y[o + x] = (byte) (base + x * 120 / W);
            if (r >= by && r < by + 200) for (int x = bx; x < bx + 200; x++) y[o + x] = (byte) (((x - bx) / 25 + (r - by) / 25) % 2 == 0 ? 225 : 60);
        }
    }

    static void fill(Image img, byte[] y, int f) {
        Image.Plane[] p = img.getPlanes();
        ByteBuffer yb = p[0].getBuffer(); int rs = p[0].getRowStride();
        for (int r = 0; r < H; r++) { yb.position(r * rs); yb.put(y, r * W, W); }
        for (int pl = 1; pl <= 2; pl++) {
            ByteBuffer b = p[pl].getBuffer(); int crs = p[pl].getRowStride(), ps = p[pl].getPixelStride();
            for (int r = 0; r < H / 2; r++) {
                int o = r * crs;
                if (pl == 1) for (int x = 0; x < W / 2; x++) b.put(o + x * ps, (byte) (90 + x * 80 / (W / 2)));
                else { byte v = (byte) (90 + r * 80 / (H / 2) + (f & 7)); for (int x = 0; x < W / 2; x++) b.put(o + x * ps, v); }
            }
        }
    }

    static final class Enc { List<byte[]> data = new ArrayList<>(); List<Long> pts = new ArrayList<>(); List<Integer> flags = new ArrayList<>(); MediaFormat fmt; double fps; int frames; }

    static List<String> hw(String mime, boolean encoder) {
        List<String> l = new ArrayList<>();
        for (MediaCodecInfo i : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (i.isEncoder() != encoder || !i.isHardwareAccelerated() || i.isAlias() || i.getName().contains(".secure")) continue;
            for (String t : i.getSupportedTypes()) if (t.equalsIgnoreCase(mime)) l.add(i.getName());
        }
        return l;
    }

    Enc encode(String name, String mime) throws Exception {
        Enc e = new Enc();
        MediaFormat f = MediaFormat.createVideoFormat(mime, W, H);
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
        f.setInteger(MediaFormat.KEY_BIT_RATE, 6000000);
        f.setInteger(MediaFormat.KEY_FRAME_RATE, FPS);
        f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        MediaCodec mc = MediaCodec.createByCodecName(name);
        try {
            mc.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            mc.start();
            MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
            byte[] y = new byte[W * H];
            int in = 0; boolean eos = false; long t0 = System.nanoTime(), dead = t0 + 25000000000L;
            while (!eos) {
                if (System.nanoTime() > dead) throw new RuntimeException("encode timeout after " + e.frames + " frames out, " + in + " in");
                if (in <= FRAMES) {
                    int ii = mc.dequeueInputBuffer(5000);
                    if (ii >= 0) {
                        if (in == FRAMES) mc.queueInputBuffer(ii, 0, 0, in * FRAME_US, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                        else {
                            Image img = mc.getInputImage(ii);
                            if (img == null) throw new RuntimeException("getInputImage null");
                            lumaFrame(in, y); fill(img, y, in);
                            mc.queueInputBuffer(ii, 0, W * H * 3 / 2, in * FRAME_US, 0);
                        }
                        in++;
                    }
                }
                int oi = mc.dequeueOutputBuffer(bi, 5000);
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) e.fmt = mc.getOutputFormat();
                else if (oi >= 0) {
                    if (bi.size > 0) {
                        ByteBuffer b = mc.getOutputBuffer(oi); byte[] d = new byte[bi.size];
                        b.position(bi.offset); b.get(d);
                        e.data.add(d); e.pts.add(bi.presentationTimeUs); e.flags.add(bi.flags);
                        if ((bi.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) e.frames++;
                    }
                    if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true;
                    mc.releaseOutputBuffer(oi, false);
                }
            }
            e.fps = e.frames / ((System.nanoTime() - t0) / 1e9);
            if (e.fmt == null) e.fmt = mc.getOutputFormat();
        } finally { try { mc.stop(); } catch (Throwable t) { } mc.release(); }
        return e;
    }

    /** returns { frames, fps, psnr } */
    double[] decode(String name, String mime, Enc e) throws Exception {
        MediaFormat f = MediaFormat.createVideoFormat(mime, W, H);
        for (String k : new String[] { "csd-0", "csd-1", "csd-2" }) if (e.fmt != null && e.fmt.containsKey(k)) f.setByteBuffer(k, e.fmt.getByteBuffer(k).duplicate());
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible);
        MediaCodec mc = MediaCodec.createByCodecName(name);
        int frames = 0; double sse = 0; long n = 0, cmpNs = 0; double worst = 999;
        long t0 = System.nanoTime(), dead = t0 + 25000000000L;
        try {
            mc.configure(f, null, null, 0);
            mc.start();
            MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
            byte[] y = new byte[W * H], row = new byte[W];
            int in = 0; boolean eos = false;
            while (!eos) {
                if (System.nanoTime() > dead) throw new RuntimeException("decode timeout after " + frames + " frames");
                if (in <= e.data.size()) {
                    int ii = mc.dequeueInputBuffer(5000);
                    if (ii >= 0) {
                        if (in == e.data.size()) mc.queueInputBuffer(ii, 0, 0, FRAMES * FRAME_US, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                        else {
                            byte[] d = e.data.get(in); ByteBuffer b = mc.getInputBuffer(ii); b.clear(); b.put(d);
                            mc.queueInputBuffer(ii, 0, d.length, e.pts.get(in), e.flags.get(in) & (MediaCodec.BUFFER_FLAG_CODEC_CONFIG | MediaCodec.BUFFER_FLAG_KEY_FRAME));
                        }
                        in++;
                    }
                }
                int oi = mc.dequeueOutputBuffer(bi, 5000);
                if (oi >= 0) {
                    if (bi.size > 0) {
                        long c0 = System.nanoTime();
                        Image img = mc.getOutputImage(oi);
                        if (img == null) throw new RuntimeException("getOutputImage null");
                        Rect cr = img.getCropRect();
                        if (cr.width() != W || cr.height() != H) throw new RuntimeException("decoded size " + cr.width() + "x" + cr.height());
                        int fi = (int) ((bi.presentationTimeUs + FRAME_US / 2) / FRAME_US);
                        if (fi < 0 || fi >= FRAMES) throw new RuntimeException("bad pts " + bi.presentationTimeUs);
                        lumaFrame(fi, y);
                        Image.Plane p = img.getPlanes()[0]; ByteBuffer yb = p.getBuffer(); int rs = p.getRowStride();
                        double fs = 0; int fn = 0;
                        for (int r = 0; r < H; r += 2) {
                            yb.position((cr.top + r) * rs + cr.left); yb.get(row, 0, W);
                            int o = r * W;
                            for (int x = 0; x < W; x += 2) { int d = (row[x] & 0xff) - (y[o + x] & 0xff); fs += d * d; fn++; }
                        }
                        img.close();
                        sse += fs; n += fn;
                        double fp = fs == 0 ? 99 : 10 * Math.log10(255.0 * 255.0 * fn / fs);
                        if (fp < worst) worst = fp;
                        frames++;
                        cmpNs += System.nanoTime() - c0;
                    }
                    if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) eos = true;
                    mc.releaseOutputBuffer(oi, false);
                }
            }
        } finally { try { mc.stop(); } catch (Throwable t) { } mc.release(); }
        double secs = Math.max(1e-3, (System.nanoTime() - t0 - cmpNs) / 1e9);
        double psnr = n == 0 ? 0 : sse == 0 ? 99 : 10 * Math.log10(255.0 * 255.0 * n / sse);
        return new double[] { frames, frames / secs, psnr, worst };
    }

    public void run(Ctx c, Result r) throws Exception {
        int pairs = 0, okPairs = 0, encoders = 0;
        StringBuilder names = new StringBuilder();
        for (String[] m : MIMES) {
            List<String> encs = hw(m[0], true), decs = hw(m[0], false);
            if (encs.isEmpty()) { r.note(m[1] + ": no hw encoder (hw decoders: " + decs.size() + ")"); continue; }
            int ei = 0;
            for (String en : encs) {
                String key = m[1] + (ei == 0 ? "" : "_" + ei); ei++; encoders++;
                names.append(en).append(' ');
                c.log("codec.roundtrip: encode " + en);
                Enc e;
                try { e = encode(en, m[0]); } catch (Throwable t) { r.fail(en + " encode: " + t); continue; }
                long bytes = 0; for (byte[] d : e.data) bytes += d.length;
                r.num(key + "_enc_fps", e.fps); r.num(key + "_enc_frames", (long) e.frames); r.num(key + "_enc_kbps", bytes * 8.0 * FPS / FRAMES / 1000.0);
                if (e.frames != FRAMES) { r.fail(en + ": encoded " + e.frames + "/" + FRAMES + " frames"); if (e.frames == 0) continue; }
                if (decs.isEmpty()) { r.fail(m[1] + ": hw encoder but no hw decoder"); continue; }
                int di = 0;
                for (String dn : decs) {
                    String dk = key + (di == 0 ? "" : "_dec" + di); di++; pairs++;
                    c.log("codec.roundtrip: decode " + dn);
                    try {
                        double[] d = decode(dn, m[0], e);
                        r.num(dk + "_dec_fps", d[1]); r.num(dk + "_dec_frames", (long) d[0]); r.num(dk + "_psnr", d[2]); r.num(dk + "_psnr_worst_frame", d[3]);
                        if ((int) d[0] != e.frames) r.fail(en + " -> " + dn + ": decoded " + (int) d[0] + "/" + e.frames + " frames");
                        else if (d[2] < MIN_PSNR) r.fail(en + " -> " + dn + ": PSNR " + String.format("%.1f", d[2]) + " dB < " + MIN_PSNR);
                        else okPairs++;
                    } catch (Throwable t) { r.fail(en + " -> " + dn + " decode: " + t); }
                }
            }
        }
        r.str("encoders", names.toString().trim());
        r.num("encoders", (long) encoders); r.num("pairs", (long) pairs); r.num("pairs_ok", (long) okPairs);
        if (encoders == 0) { r.skip("no hardware video encoder listed by MediaCodecList"); return; }
        if (!r.failed() && okPairs == pairs && pairs > 0) r.pass(okPairs + " encoder/decoder pairs, " + FRAMES + " frames " + W + "x" + H + " each, PSNR(Y) > " + MIN_PSNR + " dB");
    }
}
