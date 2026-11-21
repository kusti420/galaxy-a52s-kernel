// Bluetooth from the shell (app_process as the SHELL uid, which holds BLUETOOTH_SCAN/CONNECT):
//   app_process -cp /data/local/tmp/btctl.dex / BtCtl <cmd> [args]
//   state                      adapter state, bonded devices, A2DP/HFP connection state + A2DP codec
//   scan [secs=15]             classic discovery, prints name / address / class / rssi
//   bond <addr> [secs=40]      createBond, waits for BONDED, then for A2DP/HFP to connect (the remote or the
//                              stack's PhonePolicy connects them); prints every bond/profile state change
//   pair <name> [secs=120]     discovery + LE scan until a device called <name> shows up (full address from the LE
//                              scan callback), then bond over BR/EDR and poll as "bond" does
//   setcodec <SBC|AAC|LDAC|APTX|APTX_HD> [rate] [bits]   setCodecConfigPreference (rate 44100|48000|88200|96000,
//                              bits 16|24|32; default: let the stack choose) on the active A2DP device (needs
//                              BLUETOOTH_PRIVILEGED: run as uid 1000, e.g. `su 1000 -c app_process ...`)
//   connect <addr>             BluetoothDevice.connect() (hidden; needs BLUETOOTH_PRIVILEGED: may be refused)
//   codec                      A2DP codec status of the active device (hidden API by reflection)
// Never removes a bond. Build: tools/btctl/build.sh
import android.bluetooth.*;
import android.content.*;
import android.os.*;
import java.lang.reflect.Method;
import java.util.*;

public class BtCtl {
    static Context ctx; static BluetoothAdapter ad; static BluetoothA2dp a2dp; static BluetoothHeadset hfp;
    static void p(String s) { System.out.println("btctl: " + s); }
    static String bs(int s) { return s == BluetoothDevice.BOND_BONDED ? "BONDED" : s == BluetoothDevice.BOND_BONDING ? "BONDING" : "NONE"; }
    static String cs(int s) { return s == 2 ? "CONNECTED" : s == 1 ? "CONNECTING" : s == 3 ? "DISCONNECTING" : "DISCONNECTED"; }

    public static void main(String[] a) throws Exception {
        Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        // app_process never runs ActivityThread.initializeMainlineModules(): without it the Bluetooth module's
        // service manager is unset and BluetoothManager.getAdapter() returns null.
        try { at.getMethod("initializeMainlineModules").invoke(null); } catch (Throwable e) { p("initializeMainlineModules: " + e); }
        ctx = ((Context) at.getMethod("getSystemContext").invoke(thread)).createPackageContext(android.os.Process.myUid() == 1000 ? "android" : "com.android.shell", 0);
        BluetoothManager bm = (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        // The cached manager carries the system context's attribution ("android"); calls such as startDiscovery
        // then fail with "Package android does not belong to 2000". Make an adapter attributed to the shell.
        try {
            AttributionSource src = new AttributionSource.Builder(android.os.Process.myUid()).setPackageName(android.os.Process.myUid() == 1000 ? "android" : "com.android.shell").build();
            Method cm = BluetoothAdapter.class.getDeclaredMethod("createAdapter", Context.class);
            cm.setAccessible(true); ad = (BluetoothAdapter) cm.invoke(null, ctx);
            java.lang.reflect.Field f = BluetoothAdapter.class.getDeclaredField("mAttributionSource");
            f.setAccessible(true); f.set(ad, src);
            p("adapter attributed to " + ((AttributionSource) f.get(ad)).getPackageName());
        } catch (Throwable e) { p("createAdapter: " + e); ad = null; }
        if (ad == null) ad = bm != null ? bm.getAdapter() : null;
        if (ad == null) ad = BluetoothAdapter.getDefaultAdapter();
        if (ad == null) { p("no BluetoothAdapter (manager " + bm + ")"); System.exit(3); }
        final Handler h = new Handler(Looper.myLooper());
        ad.getProfileProxy(ctx, new BluetoothProfile.ServiceListener() {
            public void onServiceConnected(int prof, BluetoothProfile pr) { if (prof == BluetoothProfile.A2DP) a2dp = (BluetoothA2dp) pr; else hfp = (BluetoothHeadset) pr; }
            public void onServiceDisconnected(int prof) {}
        }, BluetoothProfile.A2DP);
        ad.getProfileProxy(ctx, new BluetoothProfile.ServiceListener() {
            public void onServiceConnected(int prof, BluetoothProfile pr) { if (prof == BluetoothProfile.HEADSET) hfp = (BluetoothHeadset) pr; }
            public void onServiceDisconnected(int prof) {}
        }, BluetoothProfile.HEADSET);
        final String cmd = a.length > 0 ? a[0] : "state";
        final String[] args = a;
        h.postDelayed(() -> { try { run(cmd, args, h); } catch (Throwable e) { p("ERROR " + e); e.printStackTrace(System.out); System.exit(2); } }, 1500);
        Looper.loop();
    }

    static void state() {
        p("adapter state " + ad.getState() + " name " + ad.getName() + " discovering " + ad.isDiscovering());
        for (BluetoothDevice d : ad.getBondedDevices())
            p("bonded " + d.getAddress() + " '" + d.getName() + "' class " + Integer.toHexString(d.getBluetoothClass().getDeviceClass())
              + " a2dp " + (a2dp == null ? "?" : cs(a2dp.getConnectionState(d))) + " hfp " + (hfp == null ? "?" : cs(hfp.getConnectionState(d))));
        codec();
    }

    static void codec() {
        if (a2dp == null) { p("codec: no A2DP proxy"); return; }
        for (BluetoothDevice d : a2dp.getConnectedDevices()) {
            try {
                Method m = BluetoothA2dp.class.getMethod("getCodecStatus", BluetoothDevice.class);
                Object st = m.invoke(a2dp, d);
                p("a2dp connected " + d.getAddress() + " codec status " + st);
            } catch (Throwable e) { p("a2dp connected " + d.getAddress() + " (codec status refused: " + e.getCause() + ")"); }
        }
    }

    static Object bondBredr(BluetoothDevice d) {
        try { return BluetoothDevice.class.getMethod("createBond", int.class).invoke(d, BluetoothDevice.TRANSPORT_BREDR) + " (BR/EDR)"; }
        catch (Throwable e) { p("createBond(BREDR) refused (" + e.getCause() + "), plain createBond"); return d.createBond(); }
    }

    static void run(String cmd, String[] a, Handler h) throws Exception {
        if (cmd.equals("state") || cmd.equals("codec")) { state(); System.exit(0); }
        if (cmd.equals("scan")) {
            int secs = a.length > 1 ? Integer.parseInt(a[1]) : 15;
            final Set<String> seen = new HashSet<>();
            ctx.registerReceiver(new BroadcastReceiver() { public void onReceive(Context c, Intent i) {
                BluetoothDevice d = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                short rssi = i.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE);
                if (d != null && seen.add(d.getAddress())) p("found " + d.getAddress() + " '" + d.getName() + "' class "
                    + (d.getBluetoothClass() == null ? "?" : Integer.toHexString(d.getBluetoothClass().getDeviceClass())) + " rssi " + rssi + " type " + d.getType());
            }}, new IntentFilter(BluetoothDevice.ACTION_FOUND), null, h);
            p("discovery start " + ad.startDiscovery());
            // ACTION_FOUND broadcasts do not reach an app_process receiver (registered as package "android"), so
            // also run an LE scan, whose results come back through a binder callback.
            final android.bluetooth.le.ScanCallback cb = new android.bluetooth.le.ScanCallback() {
                public void onScanResult(int type, android.bluetooth.le.ScanResult r) {
                    BluetoothDevice d = r.getDevice();
                    String n = r.getScanRecord() != null ? r.getScanRecord().getDeviceName() : null;
                    if (seen.add(d.getAddress())) p("le " + d.getAddress() + " '" + n + "' rssi " + r.getRssi());
                }
                public void onScanFailed(int e) { p("le scan failed " + e); }
            };
            ad.getBluetoothLeScanner().startScan(cb);
            h.postDelayed(() -> { ad.cancelDiscovery(); try { ad.getBluetoothLeScanner().stopScan(cb); } catch (Throwable e) {} p("discovery done, " + seen.size() + " devices"); System.exit(0); }, secs * 1000L);
            return;
        }
        if (cmd.equals("bond")) {
            final BluetoothDevice d = ad.getRemoteDevice(a[1].toUpperCase());
            int secs = a.length > 2 ? Integer.parseInt(a[2]) : 40;
            IntentFilter f = new IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
            f.addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED); f.addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED);
            f.addAction(BluetoothDevice.ACTION_PAIRING_REQUEST);
            ctx.registerReceiver(new BroadcastReceiver() { public void onReceive(Context c, Intent i) {
                BluetoothDevice x = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                if (x == null || !x.getAddress().equals(d.getAddress())) return;
                String act = i.getAction();
                if (act.equals(BluetoothDevice.ACTION_BOND_STATE_CHANGED)) p("bond " + bs(i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) + " (reason " + i.getIntExtra("android.bluetooth.device.extra.REASON", -1) + ")");
                else if (act.equals(BluetoothDevice.ACTION_PAIRING_REQUEST)) p("pairing request variant " + i.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1) + " key " + i.getIntExtra(BluetoothDevice.EXTRA_PAIRING_KEY, -1));
                else p((act.contains("a2dp") ? "a2dp " : "hfp ") + cs(i.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)));
            }}, f, null, h);
            ad.cancelDiscovery();
            p("device '" + d.getName() + "' bond state " + bs(d.getBondState()) + "; createBond " + (d.getBondState() == BluetoothDevice.BOND_BONDED ? "skipped" : bondBredr(d)));
            final long t0 = System.currentTimeMillis(); final String[] last = {""};
            final Runnable poll = new Runnable() { public void run() {
                String now = "bond " + bs(d.getBondState()) + " a2dp " + (a2dp == null ? "?" : cs(a2dp.getConnectionState(d))) + " hfp " + (hfp == null ? "?" : cs(hfp.getConnectionState(d)));
                if (!now.equals(last[0])) { p("+" + (System.currentTimeMillis() - t0) + " ms " + now); last[0] = now; }
                h.postDelayed(this, 500);
            }};
            h.post(poll);
            h.postDelayed(() -> { state(); System.exit(0); }, secs * 1000L);
            return;
        }
        if (cmd.equals("pair")) {
            final String want = a[1]; final int secs = a.length > 2 ? Integer.parseInt(a[2]) : 120;
            final boolean[] done = {false};
            final android.bluetooth.le.ScanCallback cb = new android.bluetooth.le.ScanCallback() {
                public void onScanResult(int type, android.bluetooth.le.ScanResult r) {
                    String n = r.getScanRecord() != null ? r.getScanRecord().getDeviceName() : null;
                    if (done[0] || n == null || !n.equals(want)) return;
                    done[0] = true; BluetoothDevice d = r.getDevice();
                    p("found '" + n + "' " + d.getAddress() + " rssi " + r.getRssi() + " addrtype " + r.getDevice().getType());
                    ad.getBluetoothLeScanner().stopScan(this); ad.cancelDiscovery();
                    h.postDelayed(() -> { try { run("bond", new String[]{"bond", d.getAddress(), "60"}, h); } catch (Throwable e) { p("ERROR " + e); System.exit(2); } }, 1500);
                }
            };
            ad.getBluetoothLeScanner().startScan(cb); p("looking for '" + want + "' (LE scan + discovery " + ad.startDiscovery() + ")");
            h.postDelayed(new Runnable() { public void run() { if (!done[0]) { if (!ad.isDiscovering()) ad.startDiscovery(); h.postDelayed(this, 5000); } } }, 5000);
            h.postDelayed(() -> { if (!done[0]) { p("'" + want + "' not found in " + secs + " s"); System.exit(4); } }, secs * 1000L);
            return;
        }
        if (cmd.equals("setcodec")) {
            String n = a[1].toUpperCase();
            int t = n.equals("SBC") ? BluetoothCodecConfig.SOURCE_CODEC_TYPE_SBC : n.equals("AAC") ? BluetoothCodecConfig.SOURCE_CODEC_TYPE_AAC
                : n.equals("LDAC") ? BluetoothCodecConfig.SOURCE_CODEC_TYPE_LDAC : n.equals("APTX") ? BluetoothCodecConfig.SOURCE_CODEC_TYPE_APTX
                : BluetoothCodecConfig.SOURCE_CODEC_TYPE_APTX_HD;
            BluetoothDevice d = a2dp.getConnectedDevices().get(0);
            BluetoothCodecConfig.Builder cb = new BluetoothCodecConfig.Builder().setCodecType(t)
                .setCodecPriority(BluetoothCodecConfig.CODEC_PRIORITY_HIGHEST);
            if (a.length > 2) { int r = Integer.parseInt(a[2]); cb.setSampleRate(r == 44100 ? BluetoothCodecConfig.SAMPLE_RATE_44100
                : r == 48000 ? BluetoothCodecConfig.SAMPLE_RATE_48000 : r == 88200 ? BluetoothCodecConfig.SAMPLE_RATE_88200 : BluetoothCodecConfig.SAMPLE_RATE_96000); }
            if (a.length > 3) { int b = Integer.parseInt(a[3]); cb.setBitsPerSample(b == 16 ? BluetoothCodecConfig.BITS_PER_SAMPLE_16
                : b == 24 ? BluetoothCodecConfig.BITS_PER_SAMPLE_24 : BluetoothCodecConfig.BITS_PER_SAMPLE_32); }
            BluetoothCodecConfig c = cb.build();
            try { BluetoothA2dp.class.getMethod("setCodecConfigPreference", BluetoothDevice.class, BluetoothCodecConfig.class).invoke(a2dp, d, c); p("setCodecConfigPreference " + n + " sent"); }
            catch (Throwable e) { p("setCodecConfigPreference refused: " + (e.getCause() != null ? e.getCause() : e)); }
            h.postDelayed(() -> { state(); System.exit(0); }, 4000);
            return;
        }
        if (cmd.equals("connect")) {
            BluetoothDevice d = ad.getRemoteDevice(a[1].toUpperCase());
            try { Object r = BluetoothDevice.class.getMethod("connect").invoke(d); p("connect() = " + r); }
            catch (Throwable e) { p("connect() refused: " + e.getCause()); }
            h.postDelayed(() -> { state(); System.exit(0); }, 8000);
            return;
        }
        p("unknown command " + cmd); System.exit(1);
    }
}
