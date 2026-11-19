// Requests GPS-provider fixes for N seconds (default 120) and prints the GNSS status:
// satellites seen / used per constellation, best C/N0, first fix time, and fixes.
// Push gnss.dex to /data/local/tmp and run: app_process -cp /data/local/tmp/gnss.dex / Gnss [secs]
// Run as the shell uid (not root): it uses the shell package's location permission; as root
// system_server SIGKILLs the caller on the location request.
// Build: tools/gnss/build.sh
import android.content.Context;
import android.location.GnssStatus;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Handler;
import android.os.Looper;

public class Gnss {
    public static void main(String[] a) throws Exception {
        final int secs = a.length > 0 ? Integer.parseInt(a[0]) : 120;
        System.err.println("gnss: step looper"); Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Context ctx = (Context) at.getMethod("getSystemContext").invoke(thread);
        System.err.println("gnss: step context"); ctx = ctx.createPackageContext("com.android.shell", 0); LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
        System.err.println("gnss: step lm " + lm); final long t0 = System.currentTimeMillis();
        final Handler h = new Handler(Looper.myLooper());
        if (a.length > 1) {
        lm.registerGnssStatusCallback(new GnssStatus.Callback() {
            long last = 0;
            @Override public void onStarted() { System.out.println("gnss: engine started"); }
            @Override public void onFirstFix(int ms) { System.out.println("gnss: FIRST FIX after " + ms + " ms"); }
            @Override public void onSatelliteStatusChanged(GnssStatus s) {
                long now = System.currentTimeMillis(); if (now - last < 10000) return; last = now;
                int used = 0; float best = 0; StringBuilder c = new StringBuilder();
                int[] n = new int[8];
                for (int i = 0; i < s.getSatelliteCount(); i++) {
                    if (s.usedInFix(i)) used++;
                    best = Math.max(best, s.getCn0DbHz(i));
                    int t = s.getConstellationType(i); if (t >= 0 && t < 8) n[t]++;
                }
                String[] nm = {"?", "GPS", "SBAS", "GLO", "QZSS", "BDS", "GAL", "IRNSS"};
                for (int t = 1; t < 8; t++) if (n[t] > 0) c.append(nm[t]).append(':').append(n[t]).append(' ');
                System.out.println("gnss: t+" + (now - t0) / 1000 + "s seen " + s.getSatelliteCount() + " used " + used
                    + " bestCN0 " + best + " dB-Hz [" + c.toString().trim() + "]");
            }
        }, h);
        }
        System.err.println("gnss: step status cb registered"); lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0, new LocationListener() {
            int k = 0;
            @Override public void onLocationChanged(Location l) {
                if (k++ % 10 == 0) System.out.println("gnss: fix acc " + l.getAccuracy() + " m");
            }
        }, Looper.myLooper());
        System.err.println("gnss: step location requested"); h.postDelayed(() -> { System.out.println("gnss: done after " + secs + " s"); System.exit(0); }, secs * 1000L);
        Looper.loop();
    }
}
