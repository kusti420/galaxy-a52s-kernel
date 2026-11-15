// Sends one SMS through the isms binder (ISms.sendTextForSubscriber), run as root:
//   adb shell app_process -cp /data/local/tmp/sms.dex / Sms <subId> <number> <text>
// Test tool for the kernel port (cellular path on new kernels). Prints only the result, not the number.
import android.os.IBinder;
import java.lang.reflect.Method;
public class Sms {
    public static void main(String[] a) throws Exception {
        int sub = Integer.parseInt(a[0]);
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "isms");
        Object isms = Class.forName("com.android.internal.telephony.ISms$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
        Method send = null;
        for (Method m : isms.getClass().getMethods()) if (m.getName().equals("sendTextForSubscriber")) send = m;
        if (send == null) { System.out.println("sms: no sendTextForSubscriber"); System.exit(1); }
        Class<?>[] p = send.getParameterTypes();
        Object[] args = new Object[p.length];
        // (int subId, String callingPkg, String callingAttributionTag, String destAddr, String scAddr, String text,
        //  PendingIntent sent, PendingIntent delivery, boolean persist, long messageId[, ...])
        int s = 0;
        for (int i = 0; i < p.length; i++) {
            if (p[i] == int.class) args[i] = sub;
            else if (p[i] == boolean.class) args[i] = true;
            else if (p[i] == long.class) args[i] = 0L;
            else if (p[i] == String.class) { args[i] = new String[]{"com.android.shell", null, a[1], null, a[2]}[Math.min(s, 4)]; s++; }
            else args[i] = null;
        }
        send.invoke(isms, args);
        System.out.println("sms: submitted (" + p.length + " args)");
        System.exit(0);
    }
}
