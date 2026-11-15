// Decodes the first video track of a file with MediaCodec (ByteBuffer output, no surface) and
// prints the codec used, frames decoded and time. Hardware decode test for test kernels:
//   adb push vdec.dex /data/local/tmp/ && adb shell app_process -cp /data/local/tmp/vdec.dex / Vdec <file> [codec-name]
// Build: tools/vdec/build.sh
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import java.nio.ByteBuffer;
public class Vdec {
    public static void main(String[] a) throws Exception {
        MediaExtractor ex = new MediaExtractor(); ex.setDataSource(a[0]);
        int t = -1; MediaFormat f = null;
        for (int i = 0; i < ex.getTrackCount(); i++) { f = ex.getTrackFormat(i); if (f.getString(MediaFormat.KEY_MIME).startsWith("video/")) { t = i; break; } }
        if (t < 0) { System.out.println("vdec: no video track"); System.exit(1); }
        ex.selectTrack(t);
        String mime = f.getString(MediaFormat.KEY_MIME);
        MediaCodec c = a.length > 1 ? MediaCodec.createByCodecName(a[1]) : MediaCodec.createDecoderByType(mime);
        System.out.println("vdec: " + mime + " " + f.getInteger(MediaFormat.KEY_WIDTH) + "x" + f.getInteger(MediaFormat.KEY_HEIGHT) + " codec " + c.getName()
            + " hw " + c.getCodecInfo().isHardwareAccelerated());
        c.configure(f, null, null, 0); c.start();
        MediaCodec.BufferInfo bi = new MediaCodec.BufferInfo();
        boolean inEos = false; int out = 0; long t0 = System.nanoTime();
        while (true) {
            if (!inEos) { int ii = c.dequeueInputBuffer(10000); if (ii >= 0) { ByteBuffer b = c.getInputBuffer(ii); int n = ex.readSampleData(b, 0);
                if (n < 0) { c.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inEos = true; }
                else { c.queueInputBuffer(ii, 0, n, ex.getSampleTime(), 0); ex.advance(); } } }
            int oi = c.dequeueOutputBuffer(bi, 10000);
            if (oi >= 0) { if (bi.size > 0) out++; c.releaseOutputBuffer(oi, false); if ((bi.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break; }
            if ((System.nanoTime() - t0) > 60_000_000_000L) { System.out.println("vdec: timeout"); break; }
        }
        System.out.println("vdec: frames " + out + " in " + (System.nanoTime() - t0) / 1000000 + " ms");
        c.stop(); c.release(); System.exit(0);
    }
}
