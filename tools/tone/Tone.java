// Plays a 1 s 440 Hz tone (25 % amplitude) through AudioTrack, then prints how many frames the
// mixer consumed. Shell test for the audio path on test kernels, no app needed:
//   adb push tone.dex /data/local/tmp/ && adb shell app_process -cp /data/local/tmp/tone.dex / Tone
// Arg "ll": PERFORMANCE_MODE_LOW_LATENCY (fast mixer / low-latency front end).
// Build: tools/tone/build.sh
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;

public class Tone {
    public static void main(String[] a) throws Exception {
        System.err.println("tone: start");
        int rate = 48000, n = rate;
        short[] pcm = new short[n * 2];
        for (int i = 0; i < n; i++) {
            short s = (short) (Math.sin(2 * Math.PI * 440 * i / rate) * 8000);
            pcm[2 * i] = s; pcm[2 * i + 1] = s;
        }
        AudioTrack t = new AudioTrack.Builder()
            .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(pcm.length * 2).setTransferMode(AudioTrack.MODE_STATIC)
            .setPerformanceMode(a.length > 0 && a[0].equals("ll") ? AudioTrack.PERFORMANCE_MODE_LOW_LATENCY
                : AudioTrack.PERFORMANCE_MODE_NONE).build();
        System.err.println("tone: track built, state " + t.getState());
        t.write(pcm, 0, pcm.length);
        t.play();
        Thread.sleep(1500);
        System.out.println("tone: state " + t.getPlayState() + " head " + t.getPlaybackHeadPosition() + "/" + n
            + " underruns " + t.getUnderrunCount() + " routed " + (t.getRoutedDevice() == null ? "none" : t.getRoutedDevice().getProductName() + " type " + t.getRoutedDevice().getType()));
        t.stop(); t.release();
        System.exit(0);
    }
}
