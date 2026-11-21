// Plays a 1 s 440 Hz tone (25 % amplitude) through AudioTrack, then prints how many frames the
// mixer consumed. Shell test for the audio path on test kernels, no app needed:
//   adb push tone.dex /data/local/tmp/ && adb shell app_process -cp /data/local/tmp/tone.dex / Tone
// Arg "ll": PERFORMANCE_MODE_LOW_LATENCY (fast mixer / low-latency front end). A number N: play N seconds
// (default 1); "voice" = USAGE_VOICE_COMMUNICATION, 16 kHz mono (the call / SCO path); "hz=F" sets the frequency; "vol=P" first sets STREAM_MUSIC on the current output device to P % of
// its maximum (AudioManager.setStreamVolume as the shell) and prints the index before and after; only together
// with 0 seconds ("Tone 0 vol=60"), then play with a second call.
// Build: tools/tone/build.sh
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;

public class Tone {
    static void setVol(int pct) throws Exception {
        if (android.os.Looper.myLooper() == null) android.os.Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        android.content.Context ctx = ((android.content.Context) at.getMethod("getSystemContext").invoke(thread)).createPackageContext("com.android.shell", 0);
        android.media.AudioManager am = (android.media.AudioManager) ctx.getSystemService(android.content.Context.AUDIO_SERVICE);
        int max = am.getStreamMaxVolume(3), before = am.getStreamVolume(3), idx = Math.round(max * pct / 100f);
        am.setStreamVolume(3, idx, 0);
        System.out.println("tone: STREAM_MUSIC " + before + " -> " + am.getStreamVolume(3) + " of " + max + " (asked " + pct + " %)");
    }
    public static void main(String[] a) throws Exception {
        System.err.println("tone: start");
        int rate = 48000, secs = 1; double hz = 440; boolean ll = false, voice = false, volSet = false;
        for (String x : a) { if (x.equals("ll")) ll = true; else if (x.equals("voice")) voice = true; else if (x.startsWith("hz=")) hz = Double.parseDouble(x.substring(3)); else if (x.matches("[0-9]+")) secs = Integer.parseInt(x); else if (x.startsWith("vol=")) { setVol(Integer.parseInt(x.substring(4))); volSet = true; } }
        if (secs == 0) System.exit(0);   // "0 vol=P": only set the volume
        if (volSet) { System.out.println("tone: vol= works only with 0 seconds (after ActivityThread is up, AudioFlinger rejects this process's track: attribution 'android' for uid 2000); run Tone 0 vol=P, then Tone N"); System.exit(2); }
        int ch = voice ? 1 : 2; if (voice) rate = 16000;
        int n = rate * secs;
        short[] pcm = new short[n * ch];
        for (int i = 0; i < n; i++) {
            short s = (short) (Math.sin(2 * Math.PI * hz * i / rate) * 8000);
            if (ch == 1) pcm[i] = s; else { pcm[2 * i] = s; pcm[2 * i + 1] = s; }
        }
        AudioTrack t = new AudioTrack.Builder()
            .setAudioAttributes(new AudioAttributes.Builder().setUsage(voice ? AudioAttributes.USAGE_VOICE_COMMUNICATION : AudioAttributes.USAGE_MEDIA)
                .setContentType(voice ? AudioAttributes.CONTENT_TYPE_SPEECH : AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate).setChannelMask(voice ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(pcm.length * 2).setTransferMode(AudioTrack.MODE_STATIC)
            .setPerformanceMode(ll ? AudioTrack.PERFORMANCE_MODE_LOW_LATENCY
                : AudioTrack.PERFORMANCE_MODE_NONE).build();
        System.err.println("tone: track built, state " + t.getState());
        t.write(pcm, 0, pcm.length);
        t.play();
        Thread.sleep(secs * 1000L + 500);
        System.out.println("tone: state " + t.getPlayState() + " head " + t.getPlaybackHeadPosition() + "/" + n
            + " underruns " + t.getUnderrunCount() + " routed " + (t.getRoutedDevice() == null ? "none" : t.getRoutedDevice().getProductName() + " type " + t.getRoutedDevice().getType()));
        t.stop(); t.release();
        System.exit(0);
    }
}
