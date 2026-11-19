package org.a52sxq.bench;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.Random;

/** Sequential write+fsync / read+verify of --es storage_mb (256) MB and 4k random synchronous writes / reads with verification. */
public class StorageIo extends Test {
    public String id() { return "storage.io"; }
    public int budget(Ctx c) { return 150; }
    protected File target(Ctx c, Result r) { return c.dir; }

    static void fill(byte[] b, long seed) { long x = seed * 0x9E3779B97F4A7C15L + 1; for (int i = 0; i + 8 <= b.length; i += 8) { x ^= x << 13; x ^= x >>> 7; x ^= x << 17;
        b[i] = (byte) x; b[i + 1] = (byte) (x >> 8); b[i + 2] = (byte) (x >> 16); b[i + 3] = (byte) (x >> 24); b[i + 4] = (byte) (x >> 32); b[i + 5] = (byte) (x >> 40); b[i + 6] = (byte) (x >> 48); b[i + 7] = (byte) (x >> 56); } }

    public void run(Ctx c, Result r) throws Exception {
        File base = target(c, r); if (base == null) return;
        int mb = Integer.parseInt(c.param("storage_mb", "256"));
        long free = base.getUsableSpace() >> 20; r.num("free_mb", free).str("path", base.getPath());
        if (free < mb + 64) { r.skip("only " + free + " MB free, need " + (mb + 64)); return; }
        File f = new File(base, "storage-io.bin");
        byte[] buf = new byte[1 << 20], want = new byte[1 << 20];
        try {
            long t0 = System.nanoTime();
            try (RandomAccessFile raf = new RandomAccessFile(f, "rw")) {
                for (int i = 0; i < mb; i++) { fill(buf, i); raf.write(buf); }
                raf.getFD().sync();
            }
            double wS = (System.nanoTime() - t0) / 1e9;
            r.num("seq_write_mb_s", mb / wS).num("size_mb", (long) mb);
            int badBlocks = 0; t0 = System.nanoTime();
            try (RandomAccessFile raf = new RandomAccessFile(f, "r")) {
                for (int i = 0; i < mb; i++) { raf.readFully(buf); fill(want, i); if (!java.util.Arrays.equals(buf, want)) badBlocks++; }
            }
            double rS = (System.nanoTime() - t0) / 1e9;
            r.num("seq_read_verify_mb_s", mb / rS).num("seq_bad_blocks", (long) badBlocks);
            r.note("sequential read comes largely from the page cache (an app cannot drop caches): it verifies data, the write number is the storage speed");
            // 4k random: O_DSYNC writes of fresh data, then read back and verify
            int ops = 2000; Random rnd = new Random(42); long blocks = (long) mb * 256;
            long[] offs = new long[ops]; byte[] b4 = new byte[4096], w4 = new byte[4096];
            java.util.HashMap<Long, Integer> last = new java.util.HashMap<>();
            t0 = System.nanoTime();
            try (RandomAccessFile raf = new RandomAccessFile(f, "rwd")) {
                for (int i = 0; i < ops; i++) { offs[i] = (long) (rnd.nextDouble() * blocks); fill(b4, 1000000L + i); raf.seek(offs[i] * 4096); raf.write(b4); last.put(offs[i], i); }
            }
            double rwS = (System.nanoTime() - t0) / 1e9;
            int bad4 = 0; t0 = System.nanoTime();
            try (RandomAccessFile raf = new RandomAccessFile(f, "r")) {
                for (int i = 0; i < ops; i++) { raf.seek(offs[i] * 4096); raf.readFully(b4); fill(w4, 1000000L + last.get(offs[i])); if (!java.util.Arrays.equals(b4, w4)) bad4++; }
            }
            double rrS = (System.nanoTime() - t0) / 1e9;
            r.num("rand4k_sync_write_iops", ops / rwS).num("rand4k_sync_write_mb_s", ops * 4096 / 1048576.0 / rwS).num("rand4k_read_iops", ops / rrS).num("rand4k_bad", (long) bad4);
            if (badBlocks > 0) r.fail(badBlocks + " of " + mb + " sequential 1 MB blocks read back wrong");
            if (bad4 > 0) r.fail(bad4 + " of " + ops + " random 4k blocks read back wrong");
            if (mb / wS < 5) r.fail("sequential write only " + (mb / wS) + " MB/s");
            r.pass(mb + " MB written+fsynced and verified, " + ops + " random 4k sync writes verified");
        } finally { f.delete(); }
    }
}
