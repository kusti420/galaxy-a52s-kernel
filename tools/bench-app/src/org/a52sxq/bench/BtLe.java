package org.a52sxq.bench;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

/** bt.le: adapter state + 8 s low-latency BLE scan, distinct advertisers and best RSSI. Never enables Bluetooth itself. */
public class BtLe extends Test {
    public String id() { return "bt.le"; }
    public int budget(Ctx c) { return 30; }

    public void run(Ctx c, Result r) throws Exception {
        BluetoothManager bm = (BluetoothManager) c.app.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter a = bm == null ? null : bm.getAdapter();
        if (a == null) { r.fail("no Bluetooth adapter"); return; }
        boolean on = a.isEnabled();
        r.num("bt_on", on ? 1L : 0L);
        if (!on) { r.skip("Bluetooth is off (the test never turns it on)"); return; }
        BluetoothLeScanner sc = a.getBluetoothLeScanner();
        if (sc == null) { r.fail("no BLE scanner although Bluetooth is on"); return; }
        final Set<String> seen = new HashSet<String>();
        final AtomicInteger events = new AtomicInteger(), best = new AtomicInteger(-200), err = new AtomicInteger(0);
        ScanCallback cb = new ScanCallback() {
            void one(ScanResult s) { events.incrementAndGet(); synchronized (seen) { seen.add(s.getDevice().getAddress()); } if (s.getRssi() > best.get()) best.set(s.getRssi()); }
            @Override public void onScanResult(int type, ScanResult s) { one(s); }
            @Override public void onBatchScanResults(List<ScanResult> l) { for (ScanResult s : l) one(s); }
            @Override public void onScanFailed(int code) { err.set(code); }
        };
        try {
            sc.startScan(null, new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb);
        } catch (SecurityException e) { r.fail("BLE scan not permitted (grant BLUETOOTH_SCAN + ACCESS_FINE_LOCATION): " + e.getMessage()); return; }
        long t0 = System.currentTimeMillis(); long first = -1;
        while (System.currentTimeMillis() - t0 < 8000 && err.get() == 0) { Ctx.sleep(100); if (first < 0 && events.get() > 0) first = System.currentTimeMillis() - t0; }
        try { sc.stopScan(cb); } catch (Throwable t) { }
        int n; synchronized (seen) { n = seen.size(); }
        r.num("advertisers", (long) n).num("adv_events", (long) events.get()).num("scan_error", (long) err.get());
        if (n > 0) r.num("best_rssi_dbm", (long) best.get()).num("first_result_ms", first);
        if (err.get() != 0) r.fail("BLE scan failed, error code " + err.get());
        else if (n == 0) r.fail("0 BLE advertisers in 8 s (may be an empty RF environment, or location off / permission missing)");
        else r.pass(n + " BLE advertisers, " + events.get() + " adv events, best " + best.get() + " dBm");
    }
}
