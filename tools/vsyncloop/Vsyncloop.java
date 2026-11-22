// vsyncloop: keeps requesting vsync like a background app with a running animation (11-21 daily
// phone: com.instagram.android held VSyncRequest::Single every frame while the display was Dozing,
// surfaceflinger's 'app' EventThread re-armed its timer at 120 Hz and the phone never stayed asleep).
// No APK: run with app_process (any uid that may talk to SurfaceFlinger, shell is enough):
//   CLASSPATH=/data/local/tmp/vsyncloop.dex app_process / Vsyncloop [seconds=60] [report_s=10]
// Choreographer.postFrameCallback re-posted from every callback = one vsync request per frame.
// Prints frames per report interval and the mean frame interval, then exits.
import android.os.Looper;
import android.os.SystemClock;
import android.view.Choreographer;

public class Vsyncloop {
    static long frames, lastFrames, lastReport, start, firstVsync, lastVsync;
    public static void main(String[] a) {
        final long secs = a.length > 0 ? Long.parseLong(a[0]) : 60;
        final long rep = (a.length > 1 ? Long.parseLong(a[1]) : 10) * 1000;
        Looper.prepareMainLooper();
        final Choreographer c = Choreographer.getInstance();
        start = lastReport = SystemClock.uptimeMillis();
        c.postFrameCallback(new Choreographer.FrameCallback() {
            public void doFrame(long t) {
                if (firstVsync == 0) firstVsync = t;
                lastVsync = t; frames++;
                long now = SystemClock.uptimeMillis();
                if (now - lastReport >= rep) {
                    long n = frames - lastFrames;
                    System.out.printf("t=%ds frames=%d rate=%.1f/s%n", (now - start) / 1000, n, n * 1000.0 / (now - lastReport));
                    lastFrames = frames; lastReport = now;
                }
                if (now - start >= secs * 1000) {
                    System.out.printf("total frames=%d in %d ms, mean vsync interval %.3f ms%n", frames, now - start,
                            frames > 1 ? (lastVsync - firstVsync) / 1e6 / (frames - 1) : 0.0);
                    System.exit(0);
                }
                c.postFrameCallback(this);
            }
        });
        Looper.loop();
    }
}
