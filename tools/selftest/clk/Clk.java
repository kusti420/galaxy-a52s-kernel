// Prints the two Android clocks; their difference is the total time the kernel spent suspended since boot
// (elapsedRealtime counts suspend, uptimeMillis does not). Works as the shell uid, no root:
//   app_process -cp /data/local/tmp/st/clk.dex / Clk   ->  "clk: elapsed <ms> uptime <ms> suspended <ms>"
// Build: tools/selftest/clk/build.sh
import android.os.SystemClock;
public class Clk {
    public static void main(String[] a) {
        long e = SystemClock.elapsedRealtime(), u = SystemClock.uptimeMillis();
        System.out.println("clk: elapsed " + e + " uptime " + u + " suspended " + (e - u));
        System.exit(0);
    }
}
