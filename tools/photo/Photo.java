// One JPEG still through the camera service (camera2), no app and no preview surface on screen:
// opens the camera, runs a few preview frames into an ImageReader, then one STILL_CAPTURE.
// Works while the user is still locked after a boot (no camera app can start then).
//   push photo.dex to /data/local/tmp/, then on the phone:
//   app_process -cp /data/local/tmp/photo.dex / Photo [camId] [out.jpg]
// Prints "photo: cam <id> WxH bytes N -> file" on success; exit 1 otherwise. Build: tools/photo/build.sh
import android.content.Context;
import android.graphics.ImageFormat;
import android.hardware.camera2.*;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Size;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
public class Photo {
    static CameraDevice dev; static CameraCaptureSession ses; static byte[] jpeg; static int frames;
    public static void main(String[] a) throws Exception {
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Context ctx = (Context) at.getMethod("getSystemContext").invoke(thread);
        CameraManager cm = (CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
        String id = a.length > 0 ? a[0] : "0"; String out = a.length > 1 ? a[1] : "/data/local/tmp/photo.jpg";
        System.out.println("photo: cameras " + Arrays.toString(cm.getCameraIdList()));
        CameraCharacteristics ch = cm.getCameraCharacteristics(id);
        StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        Size best = null; for (Size s : map.getOutputSizes(ImageFormat.JPEG)) if (best == null || (long) s.getWidth() * s.getHeight() > (long) best.getWidth() * best.getHeight()) best = s;
        Size pv = null; for (Size s : map.getOutputSizes(ImageFormat.YUV_420_888)) if (s.getWidth() <= 1280 && (pv == null || s.getWidth() * s.getHeight() > pv.getWidth() * pv.getHeight())) pv = s;
        HandlerThread ht = new HandlerThread("photo"); ht.start(); Handler h = new Handler(ht.getLooper());
        ImageReader jr = ImageReader.newInstance(best.getWidth(), best.getHeight(), ImageFormat.JPEG, 2);
        ImageReader yr = ImageReader.newInstance(pv.getWidth(), pv.getHeight(), ImageFormat.YUV_420_888, 3);
        final CountDownLatch opened = new CountDownLatch(1), configured = new CountDownLatch(1), got = new CountDownLatch(1), warm = new CountDownLatch(1);
        yr.setOnImageAvailableListener(r -> { Image i = r.acquireLatestImage(); if (i != null) { i.close(); if (++frames == 15) warm.countDown(); } }, h);
        jr.setOnImageAvailableListener(r -> { Image i = r.acquireNextImage(); ByteBuffer b = i.getPlanes()[0].getBuffer(); jpeg = new byte[b.remaining()]; b.get(jpeg); i.close(); got.countDown(); }, h);
        cm.openCamera(id, new CameraDevice.StateCallback() {
            public void onOpened(CameraDevice d) { dev = d; opened.countDown(); }
            public void onDisconnected(CameraDevice d) { System.out.println("photo: disconnected"); }
            public void onError(CameraDevice d, int e) { System.out.println("photo: device error " + e); opened.countDown(); }
        }, h);
        if (!opened.await(10, TimeUnit.SECONDS) || dev == null) { System.out.println("photo: open failed"); System.exit(1); }
        dev.createCaptureSession(Arrays.asList(yr.getSurface(), jr.getSurface()), new CameraCaptureSession.StateCallback() {
            public void onConfigured(CameraCaptureSession s) { ses = s; configured.countDown(); }
            public void onConfigureFailed(CameraCaptureSession s) { System.out.println("photo: configure failed"); configured.countDown(); }
        }, h);
        if (!configured.await(10, TimeUnit.SECONDS) || ses == null) { System.out.println("photo: no session"); System.exit(1); }
        CaptureRequest.Builder p = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW); p.addTarget(yr.getSurface());
        ses.setRepeatingRequest(p.build(), null, h);
        boolean w = warm.await(10, TimeUnit.SECONDS);
        System.out.println("photo: preview " + pv + " frames " + frames + (w ? "" : " (slow)"));
        CaptureRequest.Builder c = dev.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE); c.addTarget(jr.getSurface());
        c.set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_OFF); c.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
        ses.capture(c.build(), null, h);
        boolean ok = got.await(15, TimeUnit.SECONDS) && jpeg != null && jpeg.length > 2 && (jpeg[0] & 0xff) == 0xff && (jpeg[1] & 0xff) == 0xd8;
        try { ses.stopRepeating(); ses.close(); dev.close(); } catch (Exception e) { }
        if (!ok) { System.out.println("photo: no JPEG (frames " + frames + ")"); System.exit(1); }
        try (FileOutputStream f = new FileOutputStream(out)) { f.write(jpeg); }
        System.out.println("photo: cam " + id + " " + best + " bytes " + jpeg.length + " -> " + out);
        System.exit(0);
    }
}
