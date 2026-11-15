// Mobile data on/off through ITelephony.setDataEnabledForReason(subId, USER(0), enabled, pkg), run as root:
//   adb shell app_process -cp /data/local/tmp/mdata.dex / MData <subId> on|off
import android.os.IBinder;
public class MData {
    public static void main(String[] a) throws Exception {
        int sub = Integer.parseInt(a[0]); boolean on = a[1].equals("on");
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "phone");
        Object tel = Class.forName("com.android.internal.telephony.ITelephony$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
        tel.getClass().getMethod("setDataEnabledForReason", int.class, int.class, boolean.class, String.class).invoke(tel, sub, 0, on, "com.android.shell");
        Object st = tel.getClass().getMethod("isDataEnabledForReason", int.class, int.class).invoke(tel, sub, 0);
        System.out.println("mdata: sub " + sub + " user data enabled = " + st);
        System.exit(0);
    }
}
