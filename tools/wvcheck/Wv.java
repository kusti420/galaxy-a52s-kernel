// Widevine smoke test without an app: MediaDrm.isCryptoSchemeSupported + open + securityLevel, with timing.
//   on the phone: app_process -cp /data/local/tmp/wv.dex / Wv      Build: tools/wvcheck/build.sh
import android.media.MediaDrm;
import java.util.UUID;
public class Wv {
    public static void main(String[] a) throws Exception {
        UUID wv = new UUID(0xEDEF8BA979D64ACEL, 0xA3C827DCD51D21EDL);
        long t0 = System.currentTimeMillis();
        boolean s = MediaDrm.isCryptoSchemeSupported(wv);
        System.out.println("wv: supported " + s + " in " + (System.currentTimeMillis() - t0) + " ms");
        t0 = System.currentTimeMillis();
        MediaDrm d = new MediaDrm(wv);
        System.out.println("wv: opened in " + (System.currentTimeMillis() - t0) + " ms, securityLevel " + d.getPropertyString("securityLevel")
            + " version " + d.getPropertyString("version") + " systemId " + d.getPropertyString("systemId"));
        d.close(); System.exit(0);
    }
}
