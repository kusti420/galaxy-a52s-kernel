package org.a52sxq.bench;

import android.opengl.GLES30;
import java.io.FileWriter;
import java.util.ArrayList;

/**
 * Allocates RGBA8 FBO textures in steps up to --es gpu_mb (default 1024 MB), each filled by a shader with its own colour (plus an inverted 64x64 corner), and after every step
 * draws every texture and checks its colour, then frees every other one and refills the holes with smaller textures (fragmentation),
 * and renders + verifies the known scene. Reports the largest total that verified and every GL_OUT_OF_MEMORY.
 */
public class GpuTorture extends Test {
    public String id() { return "gpu.torture"; }
    public int budget(Ctx c) { return 120; }
    static final class T { int fbo, tex, w, h, col; }
    private final ArrayList<T> live = new ArrayList<>();
    private int seq, oom, otherErr;
    private Scene scene;
    private long liveBytes;

    /** /proc/meminfo MemAvailable in kB, -1 when unreadable: the only allocation cross-check an app has (kgsl sysfs is root-only) */
    static long memAvailableKb() {
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader("/proc/meminfo"))) {
            String l; while ((l = br.readLine()) != null) if (l.startsWith("MemAvailable:")) return Long.parseLong(l.replaceAll("[^0-9]", ""));
        } catch (Exception e) { }
        return -1;
    }
    private T alloc(int w, int h) {
        int[] err = new int[1];
        int[] ft = Scene.fbo(w, h, err);
        if (ft == null) { if (err[0] == GLES30.GL_OUT_OF_MEMORY) oom++; else otherErr++; return null; }
        T t = new T(); t.fbo = ft[0]; t.tex = ft[1]; t.w = w; t.h = h; seq++;
        t.col = ((seq * 37) & 255) << 16 | ((seq * 91 + 13) & 255) << 8 | ((seq * 53 + 7) & 255);
        // real draws, not glClear, so every page of the texture is written by the GPU
        scene.fill(w, h, t.col, t.col ^ 0xFFFFFF);
        int e = GLES30.glGetError();
        if (e != 0) { if (e == GLES30.GL_OUT_OF_MEMORY) oom++; else otherErr++; free(t); while (GLES30.glGetError() != 0) { } return null; }
        live.add(t); liveBytes += (long) w * h * 4;
        return t;
    }
    private void free(T t) { GLES30.glDeleteFramebuffers(1, new int[] { t.fbo }, 0); GLES30.glDeleteTextures(1, new int[] { t.tex }, 0); }
    /** draw every live texture into the probe FBO and compare; returns mismatches */
    private int verifyAll(Scene s, int[] probe) {
        int bad = 0;
        for (T t : live) {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, probe[0]); GLES30.glViewport(0, 0, 64, 64);
            GLES30.glClearColor(0, 0, 0, 1); GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
            s.drawTex(t.tex, 64, 64, 0, 0, 64, 64);
            int[] p = s.pixel(32, 32);
            int got = p[0] << 16 | p[1] << 8 | p[2];
            // and straight from the texture's own FBO, far corner
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, t.fbo);
            int[] q = s.pixel(t.w - 1, t.h - 1);
            int got2 = q[0] << 16 | q[1] << 8 | q[2];
            if (got != t.col || got2 != (t.col ^ 0xFFFFFF)) bad++;
        }
        int e = GLES30.glGetError(); if (e == GLES30.GL_OUT_OF_MEMORY) oom++; else if (e != 0) otherErr++;
        return bad;
    }

    public void run(Ctx c, Result r) throws Exception {
        int maxMb = Integer.parseInt(c.param("gpu_mb", "1024"));
        long deadline = System.nanoTime() + 95L * 1000000000L;
        Egl e = new Egl(null);
        FileWriter log = new FileWriter(c.file("gpu-torture-steps.txt"));
        r.ev(c.file("gpu-torture-steps.txt"));
        try {
            long availStart = memAvailableKb();
            Scene s = scene = new Scene();
            int[] probe = Scene.fbo(64, 64, null), frame = Scene.fbo(1280, 720, null);
            if (probe == null || frame == null) { r.fail("cannot create probe FBOs"); return; }
            int largestOk = 0, badTotal = 0, sceneBad = 0, steps = 0; boolean stop = false;
            StringBuilder why = new StringBuilder();
            for (int target = 128; target <= maxMb && !stop; target += 128) {
                long t0 = System.nanoTime();
                while (liveBytes < target * 1048576L) { if (alloc(2048, 2048) == null) { stop = true; break; } }
                GLES30.glFinish();
                double allocMs = (System.nanoTime() - t0) / 1e6;
                int bad = verifyAll(s, probe);
                // fragment: free every other texture, refill each hole with four 1024x1024
                int freed = 0;
                for (int i = live.size() - 1; i >= 0; i -= 2) { T t = live.remove(i); liveBytes -= (long) t.w * t.h * 4; if (t.w == 2048) freed += 4; else freed += 1; free(t); }
                GLES30.glFinish();
                for (int i = 0; i < freed; i++) if (alloc(1024, 1024) == null) { stop = true; break; }
                bad += verifyAll(s, probe);
                GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, frame[0]);
                s.draw(1280, 720, steps * 0.37f); int sb = s.verify(1280, 720, why);
                int mb = (int) (liveBytes >> 20);
                String line = "step target=" + target + "MB live=" + mb + "MB textures=" + live.size() + " alloc_ms=" + Math.round(allocMs) + " bad_textures=" + bad + " scene_bad=" + sb + " oom=" + oom + " other_gl_err=" + otherErr;
                log.write(line + "\n"); log.flush(); c.log(line);
                badTotal += bad; sceneBad += sb; steps++;
                if (bad == 0 && sb == 0 && mb > largestOk) largestOk = mb;
                r.num("largest_ok_mb", (long) largestOk).num("steps", (long) steps).num("gl_out_of_memory", (long) oom).num("other_gl_errors", (long) otherErr)
                        .num("bad_textures", (long) badTotal).num("scene_bad_probes", (long) sceneBad).num("alloc_ms_step" + target, allocMs);
                if (System.nanoTime() > deadline) { r.note("time budget reached at " + mb + " MB"); break; }
            }
            long availPeak = memAvailableKb();
            if (availStart > 0 && availPeak > 0) r.num("mem_available_start_mb", availStart / 1024).num("mem_available_peak_mb", availPeak / 1024).num("mem_available_drop_mb", (availStart - availPeak) / 1024);
            long liveMbPeak = liveBytes >> 20;
            int hold = Integer.parseInt(c.param("gpu_hold_s", "0"));   // keep the peak allocated (to read dumpsys meminfo / kgsl from the host)
            if (hold > 0) { c.log("gpu.torture: holding " + (liveBytes >> 20) + " MB for " + hold + " s"); Ctx.sleep(hold * 1000L); }
            // free everything and render once more: the driver must recover
            for (T t : live) free(t); live.clear(); liveBytes = 0; GLES30.glFinish();
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, frame[0]);
            s.draw(1280, 720, 2f); int after = s.verify(1280, 720, why);
            r.ev(c.savePng("gpu-torture-final.png", Scene.grab(1280, 720)));
            r.num("after_free_bad_probes", (long) after).num("requested_mb", (long) maxMb);
            if (badTotal > 0) r.fail(badTotal + " texture(s) read back the wrong colour");
            if (sceneBad > 0 || after > 0) r.fail("known scene wrong under memory pressure: " + why);
            if (otherErr > 0) r.fail(otherErr + " GL error(s) other than OUT_OF_MEMORY");
            if (availStart > 0 && availPeak > 0 && (availStart - availPeak) / 1024 < liveMbPeak / 2)
                r.fail("system MemAvailable fell only " + (availStart - availPeak) / 1024 + " MB while " + liveMbPeak + " MB of textures were live: the driver did not really back them");
            if (largestOk < 256) r.fail("largest verified allocation only " + largestOk + " MB (< 256 MB)");
            r.pass("largest verified allocation " + largestOk + " MB of " + maxMb + " MB requested, GL_OUT_OF_MEMORY x" + oom);
        } finally { try { log.close(); } catch (Exception x) { } e.release(); }
    }
}
