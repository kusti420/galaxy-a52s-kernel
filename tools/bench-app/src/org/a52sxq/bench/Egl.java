package org.a52sxq.bench;

import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES30;
import android.view.Surface;

/** Minimal EGL14 + GLES3 context: window surface when a Surface is given, else a 16x16 pbuffer. */
public final class Egl {
    public EGLDisplay dpy; public EGLContext ctx; public EGLSurface surf; public EGLConfig cfg;

    public Egl(Surface window) {
        dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] v = new int[2];
        if (!EGL14.eglInitialize(dpy, v, 0, v, 1)) throw new RuntimeException("eglInitialize failed");
        int[] attr = { EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, 0x40 /* EGL_OPENGL_ES3_BIT */, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT | EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE };
        EGLConfig[] cfgs = new EGLConfig[1]; int[] n = new int[1];
        if (!EGL14.eglChooseConfig(dpy, attr, 0, cfgs, 0, 1, n, 0) || n[0] == 0) throw new RuntimeException("no ES3 RGBA8888 EGL config");
        cfg = cfgs[0];
        ctx = EGL14.eglCreateContext(dpy, cfg, EGL14.EGL_NO_CONTEXT, new int[] { EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE }, 0);
        if (ctx == null || ctx == EGL14.EGL_NO_CONTEXT) throw new RuntimeException("eglCreateContext ES3 failed 0x" + Integer.toHexString(EGL14.eglGetError()));
        if (window != null) surf = EGL14.eglCreateWindowSurface(dpy, cfg, window, new int[] { EGL14.EGL_NONE }, 0);
        else surf = EGL14.eglCreatePbufferSurface(dpy, cfg, new int[] { EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE }, 0);
        if (surf == null || surf == EGL14.EGL_NO_SURFACE) throw new RuntimeException("eglCreateSurface failed 0x" + Integer.toHexString(EGL14.eglGetError()));
        if (!EGL14.eglMakeCurrent(dpy, surf, surf, ctx)) throw new RuntimeException("eglMakeCurrent failed 0x" + Integer.toHexString(EGL14.eglGetError()));
    }
    public boolean swap() { return EGL14.eglSwapBuffers(dpy, surf); }
    public void interval(int i) { EGL14.eglSwapInterval(dpy, i); }
    public int width() { int[] v = new int[1]; EGL14.eglQuerySurface(dpy, surf, EGL14.EGL_WIDTH, v, 0); return v[0]; }
    public int height() { int[] v = new int[1]; EGL14.eglQuerySurface(dpy, surf, EGL14.EGL_HEIGHT, v, 0); return v[0]; }
    public void release() {
        try {
            EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            if (surf != null) EGL14.eglDestroySurface(dpy, surf);
            if (ctx != null) EGL14.eglDestroyContext(dpy, ctx);
            EGL14.eglReleaseThread();
        } catch (Throwable t) { }
    }

    public static int program(String vs, String fs) {
        int v = shader(GLES30.GL_VERTEX_SHADER, vs), f = shader(GLES30.GL_FRAGMENT_SHADER, fs), p = GLES30.glCreateProgram();
        GLES30.glAttachShader(p, v); GLES30.glAttachShader(p, f); GLES30.glLinkProgram(p);
        int[] ok = new int[1]; GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) throw new RuntimeException("link: " + GLES30.glGetProgramInfoLog(p));
        return p;
    }
    static int shader(int type, String src) {
        int s = GLES30.glCreateShader(type); GLES30.glShaderSource(s, src); GLES30.glCompileShader(s);
        int[] ok = new int[1]; GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) throw new RuntimeException("shader: " + GLES30.glGetShaderInfoLog(s));
        return s;
    }
}
