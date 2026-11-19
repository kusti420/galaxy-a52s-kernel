package org.a52sxq.bench;

/** One benchmark/test. Class name = id with segments capitalised (gpu.render -> GpuRender), public no-arg ctor. */
public abstract class Test {
    public abstract String id();
    /** hard time budget in seconds (the runner fails the test when it overruns budget + 15 s) */
    public int budget(Ctx c) { return 60; }
    /** Runs on a worker thread. Must end in r.pass/fail/skip; an exception = FAIL. */
    public abstract void run(Ctx c, Result r) throws Exception;
}
