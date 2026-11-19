package org.a52sxq.bench;

import android.opengl.GLES30;
import android.view.Surface;

/** GLES3 known scene offscreen (1920x1080 FBO) and on screen, exact-colour glReadPixels verification, fps. */
public class GpuRender extends Test {
    public String id() { return "gpu.render"; }
    public int budget(Ctx c) { return c.secs(10) * 2 + 20; }

    public void run(Ctx c, Result r) throws Exception {
        int secs = c.secs(10);
        // ---- offscreen ----
        Egl e = new Egl(null);
        try {
            r.str("gl_renderer", GLES30.glGetString(GLES30.GL_RENDERER)).str("gl_version", GLES30.glGetString(GLES30.GL_VERSION)).str("gl_vendor", GLES30.glGetString(GLES30.GL_VENDOR));
            Scene s = new Scene();
            int w = 1920, h = 1080; int[] err = new int[1];
            int[] fb = Scene.fbo(w, h, err);
            if (fb == null) { r.fail("offscreen FBO 1920x1080 failed 0x" + Integer.toHexString(err[0])); return; }
            StringBuilder why = new StringBuilder(); int frames = 0, bad = 0, checks = 0;
            long t0 = System.nanoTime(), end = t0 + secs * 1000000000L;
            while (System.nanoTime() < end) {
                s.draw(w, h, frames * 0.016f);
                if (frames % 20 == 0) { bad += s.verify(w, h, why); checks++; } else GLES30.glFinish();
                frames++;
            }
            s.draw(w, h, 1.0f); bad += s.verify(w, h, why); checks++;
            double fps = frames / ((System.nanoTime() - t0) / 1e9);
            r.ev(c.savePng("gpu-render-offscreen.png", Scene.grab(w, h)));
            int ge = GLES30.glGetError();
            r.num("offscreen_fps", fps).num("offscreen_frames", (long) frames).num("offscreen_bad_probes", (long) bad).num("offscreen_checks", (long) checks).num("offscreen_gl_error", (long) ge);
            if (bad > 0) r.fail("offscreen: " + bad + " wrong probe pixel(s): " + why);
            if (ge != 0) r.fail("offscreen GL error 0x" + Integer.toHexString(ge));
            if (fps < 5) r.fail("offscreen fps " + fps);
        } finally { e.release(); }
        // ---- on screen ----
        Surface sf = c.surface();
        if (sf == null) { r.fail("no on-screen surface (activity not visible?)"); return; }
        e = new Egl(sf);
        try {
            Scene s = new Scene(); e.interval(1);
            int w = e.width(), h = e.height();
            StringBuilder why = new StringBuilder(); int frames = 0, bad = 0, checks = 0, swapFail = 0;
            long t0 = System.nanoTime(), end = t0 + secs * 1000000000L;
            while (System.nanoTime() < end) {
                s.draw(w, h, frames * 0.016f);
                if (frames % 30 == 0) { bad += s.verify(w, h, why); checks++; }
                if (!e.swap()) swapFail++;
                frames++;
            }
            double fps = frames / ((System.nanoTime() - t0) / 1e9);
            s.draw(w, h, 1.0f); bad += s.verify(w, h, why); checks++;
            r.ev(c.savePng("gpu-render-onscreen.png", Scene.grab(w, h))); e.swap();
            int ge = GLES30.glGetError();
            r.num("onscreen_fps", fps).num("onscreen_frames", (long) frames).num("onscreen_w", (long) w).num("onscreen_h", (long) h)
                    .num("onscreen_bad_probes", (long) bad).num("onscreen_checks", (long) checks).num("onscreen_swap_fail", (long) swapFail).num("onscreen_gl_error", (long) ge);
            if (bad > 0) r.fail("onscreen: " + bad + " wrong probe pixel(s): " + why);
            if (swapFail > 0) r.fail("eglSwapBuffers failed " + swapFail + "x");
            if (ge != 0) r.fail("onscreen GL error 0x" + Integer.toHexString(ge));
            if (fps < 20) r.fail("onscreen fps " + fps);
        } finally { e.release(); }
        r.pass("known scene exact on FBO and window; fps measured");
    }
}
