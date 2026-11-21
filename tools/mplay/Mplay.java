// Plays a media FILE through android.media.MediaPlayer (NuPlayer: the ROM's own player path) for
// N seconds and prints the position every second. Used to see whether a long MP3/AAC file gets a
// compress-offload output (NuPlayer offloads audio-only streams longer than
// audio.offload.min.duration.secs) and whether its position advances. SILENT: sets the player
// volume to 0; the caller also keeps STREAM_MUSIC at 0.
//   app_process -cp /data/local/tmp/mplay.dex / Mplay /data/local/tmp/t.mp3 12
// Build: tools/mplay/build.sh
import android.media.AudioAttributes;
import android.media.MediaDataSource;
import android.media.MediaPlayer;
import java.io.RandomAccessFile;
import android.os.Looper;

public class Mplay {
    public static void main(String[] a) throws Exception {
        Looper.prepareMainLooper();
        int secs = a.length > 1 ? Integer.parseInt(a[1]) : 10;
        MediaPlayer mp = new MediaPlayer();
        mp.setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build());
        mp.setOnErrorListener((p, what, extra) -> { System.out.println("mplay: ERROR what=" + what + " extra=" + extra); return false; });
        // a path/fd data source needs an app Context (MediaProvider lookup): feed the file as a MediaDataSource
        final RandomAccessFile f = new RandomAccessFile(a[0], "r");
        mp.setDataSource(new MediaDataSource() {
            public int readAt(long pos, byte[] buf, int off, int size) throws java.io.IOException {
                if (pos >= f.length()) return -1;
                f.seek(pos); return f.read(buf, off, size);
            }
            public long getSize() throws java.io.IOException { return f.length(); }
            public void close() throws java.io.IOException { f.close(); }
        });
        mp.prepare();
        mp.setVolume(0f, 0f);
        System.out.println("mplay: duration " + mp.getDuration() + " ms");
        mp.start();
        int last = 0;
        for (int i = 1; i <= secs; i++) {
            Thread.sleep(1000);
            last = mp.getCurrentPosition();
            System.out.println("mplay: t=" + i + " s position " + last + " ms playing " + mp.isPlaying());
        }
        mp.stop(); mp.release();
        System.out.println("RESULT mplay " + (last >= (secs - 2) * 1000 ? "PASS" : "FAIL") + " position " + last + " ms after " + secs + " s");
        System.exit(0);
    }
}
