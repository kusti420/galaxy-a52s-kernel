package org.a52sxq.bench;

import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.opengl.GLES30;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * The known scene: an animated plasma (fragment load) with exact-colour probes on top:
 * four scissor-cleared corner patches, a shader-drawn flat quad in the centre and a 2x2 nearest-filtered texture quad.
 */
final class Scene {
    static final String VS = "#version 300 es\nuniform vec4 r; out vec2 uv;\n"
            + "void main(){ vec2 p=vec2(float(gl_VertexID&1),float((gl_VertexID>>1)&1)); uv=p; gl_Position=vec4(mix(r.xy,r.zw,p),0.,1.); }";
    static final String FS = "#version 300 es\nprecision highp float; uniform int m; uniform vec4 col; uniform float t; uniform sampler2D tx; in vec2 uv; out vec4 o;\n"
            + "void main(){ if(m==1) o=col; else if(m==2) o=texture(tx,uv); else { float v=0.;"
            + " for(int i=0;i<8;i++){ v+=sin(uv.x*float(7+i*3)+t*float(i+1))*cos(uv.y*float(5+i*4)-t); }"
            + " o=vec4(0.5+0.5*sin(v),0.5+0.5*cos(v*1.3),0.5+0.5*sin(v*0.7+t),1.); } }";
    static final int[][] TEX = { { 255, 255, 0 }, { 0, 255, 255 }, { 255, 0, 255 }, { 128, 128, 128 } };
    static final int[][] CORNER = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 }, { 255, 255, 255 } };
    static final int[] CENTER = { 64, 128, 192 };
    final int prog, uR, uM, uCol, uT, uTx, tex;
    private final ByteBuffer px = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder());

    Scene() {
        prog = Egl.program(VS, FS);
        uR = GLES30.glGetUniformLocation(prog, "r"); uM = GLES30.glGetUniformLocation(prog, "m"); uCol = GLES30.glGetUniformLocation(prog, "col");
        uT = GLES30.glGetUniformLocation(prog, "t"); uTx = GLES30.glGetUniformLocation(prog, "tx");
        int[] t = new int[1]; GLES30.glGenTextures(1, t, 0); tex = t[0];
        ByteBuffer b = ByteBuffer.allocateDirect(16);
        for (int[] c : TEX) { b.put((byte) c[0]).put((byte) c[1]).put((byte) c[2]).put((byte) 255); }
        b.position(0);
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, tex);
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, 2, 2, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, b);
        nearest();
    }
    static void nearest() {
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);
    }
    private void rect(int w, int h, int x0, int y0, int x1, int y1) { GLES30.glUniform4f(uR, 2f * x0 / w - 1, 2f * y0 / h - 1, 2f * x1 / w - 1, 2f * y1 / h - 1); }

    /** draw one frame into the bound framebuffer of size w x h */
    void draw(int w, int h, float t) {
        GLES30.glViewport(0, 0, w, h); GLES30.glDisable(GLES30.GL_SCISSOR_TEST); GLES30.glDisable(GLES30.GL_DITHER); GLES30.glDisable(GLES30.GL_BLEND);
        GLES30.glClearColor(0, 0, 0, 1); GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
        GLES30.glUseProgram(prog);
        GLES30.glUniform1i(uM, 0); GLES30.glUniform1f(uT, t); GLES30.glUniform4f(uR, -1, -1, 1, 1);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
        GLES30.glUniform1i(uM, 1); GLES30.glUniform4f(uCol, CENTER[0] / 255f, CENTER[1] / 255f, CENTER[2] / 255f, 1f);
        rect(w, h, w * 3 / 8, h * 3 / 8, w * 5 / 8, h * 5 / 8); GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
        drawTex(tex, w, h, w / 16, h * 7 / 16, w / 16 + w / 8, h * 9 / 16);
        GLES30.glEnable(GLES30.GL_SCISSOR_TEST);
        int cw = w / 8, ch = h / 8;
        int[][] pos = { { 0, 0 }, { w - cw, 0 }, { 0, h - ch }, { w - cw, h - ch } };
        for (int i = 0; i < 4; i++) {
            GLES30.glScissor(pos[i][0], pos[i][1], cw, ch);
            GLES30.glClearColor(CORNER[i][0] / 255f, CORNER[i][1] / 255f, CORNER[i][2] / 255f, 1); GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
        }
        GLES30.glDisable(GLES30.GL_SCISSOR_TEST);
    }
    /** shader-fill the bound w x h framebuffer with rgb colour a, and its top-right 64x64 corner with colour b */
    void fill(int w, int h, int a, int b) {
        GLES30.glViewport(0, 0, w, h); GLES30.glDisable(GLES30.GL_SCISSOR_TEST); GLES30.glDisable(GLES30.GL_DITHER); GLES30.glDisable(GLES30.GL_BLEND);
        GLES30.glUseProgram(prog); GLES30.glUniform1i(uM, 1);
        GLES30.glUniform4f(uCol, ((a >> 16) & 255) / 255f, ((a >> 8) & 255) / 255f, (a & 255) / 255f, 1f);
        GLES30.glUniform4f(uR, -1, -1, 1, 1); GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
        GLES30.glUniform4f(uCol, ((b >> 16) & 255) / 255f, ((b >> 8) & 255) / 255f, (b & 255) / 255f, 1f);
        rect(w, h, w - 64, h - 64, w, h); GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
    }
    /** draw texture t (unit 0) over the pixel rectangle */
    void drawTex(int t, int w, int h, int x0, int y0, int x1, int y1) {
        GLES30.glUseProgram(prog); GLES30.glActiveTexture(GLES30.GL_TEXTURE0); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t);
        GLES30.glUniform1i(uTx, 0); GLES30.glUniform1i(uM, 2); rect(w, h, x0, y0, x1, y1); GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
    }
    int[] pixel(int x, int y) {
        px.position(0); GLES30.glReadPixels(x, y, 1, 1, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, px);
        return new int[] { px.get(0) & 255, px.get(1) & 255, px.get(2) & 255, px.get(3) & 255 };
    }
    private int chk(String name, int x, int y, int[] want, StringBuilder why) {
        int[] g = pixel(x, y);
        if (g[0] == want[0] && g[1] == want[1] && g[2] == want[2]) return 0;
        if (why != null && why.length() < 300) why.append(name).append("@").append(x).append(",").append(y).append(" got ").append(g[0]).append(",").append(g[1]).append(",").append(g[2])
                .append(" want ").append(want[0]).append(",").append(want[1]).append(",").append(want[2]).append("; ");
        return 1;
    }
    /** exact-colour check of the 9 probes in the bound read framebuffer; returns mismatches */
    int verify(int w, int h, StringBuilder why) {
        int bad = 0, cw = w / 8, ch = h / 8;
        bad += chk("corner0", cw / 2, ch / 2, CORNER[0], why); bad += chk("corner1", w - cw / 2, ch / 2, CORNER[1], why);
        bad += chk("corner2", cw / 2, h - ch / 2, CORNER[2], why); bad += chk("corner3", w - cw / 2, h - ch / 2, CORNER[3], why);
        bad += chk("center", w / 2, h / 2, CENTER, why);
        int tx0 = w / 16, tw = w / 8, ty0 = h * 7 / 16, th = h / 8;
        for (int i = 0; i < 4; i++) bad += chk("tex" + i, tx0 + tw / 4 + (i & 1) * tw / 2, ty0 + th / 4 + (i >> 1) * th / 2, TEX[i], why);
        return bad;
    }
    static Bitmap grab(int w, int h) {
        ByteBuffer b = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder());
        GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, b); b.position(0);
        Bitmap bm = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888); bm.copyPixelsFromBuffer(b);
        Matrix m = new Matrix(); m.preScale(1, -1);
        return Bitmap.createBitmap(bm, 0, 0, w, h, m, false);
    }
    /** RGBA8 texture w x h attached to a new FBO; returns {fbo, tex}, or null when incomplete / GL error (error code in err[0]) */
    static int[] fbo(int w, int h, int[] err) {
        int[] t = new int[1], f = new int[1];
        GLES30.glGenTextures(1, t, 0); GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t[0]);
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, w, h); nearest();
        GLES30.glGenFramebuffers(1, f, 0); GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, f[0]);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, t[0], 0);
        int st = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER), e = GLES30.glGetError();
        if (st != GLES30.GL_FRAMEBUFFER_COMPLETE || e != 0) {
            if (err != null) err[0] = e != 0 ? e : st;
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0); GLES30.glDeleteFramebuffers(1, f, 0); GLES30.glDeleteTextures(1, t, 0);
            while (GLES30.glGetError() != 0) { }
            return null;
        }
        return new int[] { f[0], t[0] };
    }
}
