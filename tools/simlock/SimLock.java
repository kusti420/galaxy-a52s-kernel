// SIM PIN lock state / toggle through the phone binder service (ITelephony), run as root:
//   adb push simlock.dex /data/local/tmp/ && adb shell su -c 'app_process -cp /data/local/tmp/simlock.dex / SimLock [off|on <PIN>]'
// One attempt only; prints the result code (0 = success) and the state before/after.
import android.os.IBinder;
import java.lang.reflect.Method;
public class SimLock {
    public static void main(String[] a) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder b = (IBinder) sm.getMethod("getService", String.class).invoke(null, "phone");
        Class<?> stub = Class.forName("com.android.internal.telephony.ITelephony$Stub");
        Object tel = stub.getMethod("asInterface", IBinder.class).invoke(null, b);
        Class<?> sub = Class.forName("android.telephony.SubscriptionManager");
        int subId = System.getenv("SUBID") != null ? Integer.parseInt(System.getenv("SUBID")) : (Integer) sub.getMethod("getDefaultSubscriptionId").invoke(null);
        Method isOn = tel.getClass().getMethod("isIccLockEnabled", int.class);
        System.out.println("simlock: subId=" + subId + " lockEnabled=" + isOn.invoke(tel, subId));
        if (a.length >= 2) {
            boolean on = a[0].equals("on");
            Object r = tel.getClass().getMethod("setIccLockEnabled", int.class, boolean.class, String.class).invoke(tel, subId, on, a[1]);
            System.out.println("simlock: setIccLockEnabled(" + on + ") -> " + r + " (0 = success, >0 = attempts left)");
            System.out.println("simlock: lockEnabled=" + isOn.invoke(tel, subId));
        }
        System.exit(0);
    }
}
