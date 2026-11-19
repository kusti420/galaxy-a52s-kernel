package org.a52sxq.bench;

import android.content.Context;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.os.Handler;
import android.os.HandlerThread;

/** camera.flash: torch on then off through CameraManager, each verified by the TorchCallback state. */
public class CameraFlash extends Test {
    public String id() { return "camera.flash"; }
    public int budget(Ctx c) { return 20; }

    public void run(Ctx c, Result r) throws Exception {
        final CameraManager cm = (CameraManager) c.app.getSystemService(Context.CAMERA_SERVICE);
        String id = null;
        for (String i : cm.getCameraIdList()) {
            Boolean f = cm.getCameraCharacteristics(i).get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
            if (f != null && f) { id = i; break; }
        }
        if (id == null) { r.skip("no camera with FLASH_INFO_AVAILABLE"); return; }
        r.str("camera", id);
        final String fid = id;
        final Object lock = new Object();
        final Boolean[] state = { null };
        HandlerThread ht = new HandlerThread("torch"); ht.start();
        CameraManager.TorchCallback cb = new CameraManager.TorchCallback() {
            @Override public void onTorchModeChanged(String cid, boolean enabled) { if (cid.equals(fid)) synchronized (lock) { state[0] = enabled; lock.notifyAll(); } }
            @Override public void onTorchModeUnavailable(String cid) { if (cid.equals(fid)) synchronized (lock) { state[0] = null; lock.notifyAll(); } }
        };
        cm.registerTorchCallback(cb, new Handler(ht.getLooper()));
        try {
            Ctx.sleep(300);
            long t = System.nanoTime();
            cm.setTorchMode(id, true);
            boolean on = await(lock, state, true);
            r.num("on_ms", (System.nanoTime() - t) / 1e6);
            Ctx.sleep(400);
            t = System.nanoTime();
            cm.setTorchMode(id, false);
            boolean off = await(lock, state, false);
            r.num("off_ms", (System.nanoTime() - t) / 1e6);
            if (!on) r.fail("torch on: callback never reported enabled within 3 s");
            if (!off) r.fail("torch off: callback never reported disabled within 3 s");
            if (on && off) r.pass("torch on and off confirmed by TorchCallback on camera " + id);
        } finally {
            try { cm.setTorchMode(id, false); } catch (Throwable t) { }
            cm.unregisterTorchCallback(cb); ht.quitSafely();
        }
    }

    static boolean await(Object lock, Boolean[] state, boolean want) throws InterruptedException {
        long end = System.currentTimeMillis() + 3000;
        synchronized (lock) {
            while (state[0] == null || state[0] != want) {
                long left = end - System.currentTimeMillis();
                if (left <= 0) return false;
                lock.wait(left);
            }
        }
        return true;
    }
}
