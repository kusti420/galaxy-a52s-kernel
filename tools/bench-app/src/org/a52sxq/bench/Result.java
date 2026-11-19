package org.a52sxq.bench;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;

/** Result of one test: see tools/selftest/RESULT-FORMAT.md. */
public final class Result {
    public final String id;
    private final JSONObject numbers = new JSONObject(), info = new JSONObject();
    private final JSONArray evidence = new JSONArray(), notes = new JSONArray();
    private String pass, fail, skip;
    public double seconds;
    private final Ctx c;

    Result(String id, Ctx c) { this.id = id; this.c = c; }

    public synchronized Result num(String k, double v) { try { if (Double.isNaN(v) || Double.isInfinite(v)) numbers.put(k, JSONObject.NULL); else numbers.put(k, Math.round(v * 1000.0) / 1000.0); } catch (Exception e) { } return this; }
    public synchronized Result num(String k, long v) { try { numbers.put(k, v); } catch (Exception e) { } return this; }
    public synchronized Result str(String k, String v) { try { info.put(k, v); } catch (Exception e) { } return this; }
    /** evidence file (must live under c.dir) */
    public synchronized Result ev(File f) { if (f != null) evidence.put(f.getName()); return this; }
    public synchronized Result note(String s) { notes.put(s); if (c != null) c.log(id + ": " + s); return this; }
    public synchronized void pass(String why) { pass = pass == null ? why : pass + "; " + why; }
    /** sticky: any fail() makes the test FAIL */
    public synchronized void fail(String why) { fail = fail == null ? why : fail + "; " + why; if (c != null) c.log(id + " FAIL: " + why); }
    public synchronized void skip(String why) { skip = skip == null ? why : skip + "; " + why; }
    public synchronized boolean failed() { return fail != null; }

    public synchronized String status() { return fail != null ? "FAIL" : pass != null ? "PASS" : skip != null ? "SKIP" : "FAIL"; }
    public synchronized String reason() { return fail != null ? fail : pass != null ? pass : skip != null ? skip : "test ended without a verdict"; }

    public synchronized JSONObject json() {
        JSONObject o = new JSONObject();
        try {
            o.put("id", id); o.put("status", status()); o.put("reason", reason());
            o.put("seconds", Math.round(seconds * 10) / 10.0);
            o.put("numbers", new JSONObject(numbers.toString())); o.put("info", new JSONObject(info.toString()));
            o.put("evidence", new JSONArray(evidence.toString())); o.put("notes", new JSONArray(notes.toString()));
        } catch (Exception e) { }
        return o;
    }
}
