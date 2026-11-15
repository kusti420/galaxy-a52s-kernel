// Records 2 s from the main microphone with AudioRecord and prints frames read, RMS and peak
// (16-bit PCM, 48 kHz mono). Silent test for the capture path on test kernels:
//   adb push rec.dex /data/local/tmp/ && adb shell app_process -cp /data/local/tmp/rec.dex / Rec
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;

public class Rec {
    public static void main(String[] a) throws Exception {
        int rate = 48000, n = rate * 2;
        int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        AudioRecord r = new AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, Math.max(min, rate));
        System.err.println("rec: state " + r.getState() + " minbuf " + min);
        short[] buf = new short[n]; int got = 0;
        r.startRecording();
        long t0 = System.currentTimeMillis();
        while (got < n && System.currentTimeMillis() - t0 < 5000) {
            int k = r.read(buf, got, n - got);
            if (k < 0) { System.err.println("rec: read error " + k); break; }
            got += k;
        }
        r.stop();
        double sum = 0; int peak = 0, nz = 0;
        for (int i = 0; i < got; i++) { int v = Math.abs(buf[i]); sum += (double) v * v; if (v > peak) peak = v; if (v != 0) nz++; }
        System.out.println("rec: frames " + got + "/" + n + " rms " + Math.round(Math.sqrt(sum / Math.max(got, 1)))
            + " peak " + peak + " nonzero " + nz + " routed " + (r.getRoutedDevice() == null ? "none" : r.getRoutedDevice().getProductName() + " type " + r.getRoutedDevice().getType()));
        r.release();
        System.exit(0);
    }
}
