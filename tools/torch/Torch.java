// Torch through the camera HAL (the Quick Settings flashlight path): CameraManager.setTorchMode.
//   adb push torch.dex /data/local/tmp/ && adb shell app_process -cp /data/local/tmp/torch.dex / Torch [ms] [camId]
// Build: tools/torch/build.sh
import android.content.Context;
import android.hardware.camera2.CameraManager;
import android.os.Looper;
public class Torch {
    public static void main(String[] a) throws Exception {
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Context ctx = (Context) at.getMethod("getSystemContext").invoke(thread);
        CameraManager cm = (CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
        long ms = a.length > 0 ? Long.parseLong(a[0]) : 1000; String id = a.length > 1 ? a[1] : "0";
        cm.setTorchMode(id, true); System.out.println("torch: on (camera " + id + ")");
        Thread.sleep(ms);
        cm.setTorchMode(id, false); System.out.println("torch: off");
        System.exit(0);
    }
}
