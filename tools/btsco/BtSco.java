// Bluetooth SCO (HFP call audio) routing from the shell, the way a VoIP/call app drives it:
// MODE_IN_COMMUNICATION + setCommunicationDevice(TYPE_BLUETOOTH_SCO), STREAM_VOICE_CALL at vol % for the SCO
// device, then it HOLDS the route for <secs> (the route belongs to this client and ends with it) and restores
// mode, device and volume. Play/record meanwhile from separate processes without an ActivityThread:
//   tools/tone "voice" (USAGE_VOICE_COMMUNICATION) and tools/rec "vc" (VOICE_COMMUNICATION source).
// (AudioTrack/AudioRecord made inside this process are rejected by AudioFlinger: with ActivityThread up the
// default attribution is package "android" for uid 2000, EX_SECURITY in createTrack.)
//   app_process -cp /data/local/tmp/btsco.dex / BtSco [secs=12] [vol=30]
// Run as the shell uid (MODIFY_AUDIO_SETTINGS). Build: tools/btsco/build.sh
import android.content.Context;
import android.media.*;

public class BtSco {
    public static void main(String[] a) throws Exception {
        int secs = 12, vol = 30;
        for (String x : a) { if (x.startsWith("vol=")) vol = Integer.parseInt(x.substring(4)); else if (x.matches("[0-9]+")) secs = Integer.parseInt(x); }
        android.os.Looper.prepareMainLooper();
        Class<?> at = Class.forName("android.app.ActivityThread");
        Object thread = at.getMethod("systemMain").invoke(null);
        Context ctx = ((Context) at.getMethod("getSystemContext").invoke(thread)).createPackageContext("com.android.shell", 0);
        AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
        // A package context made in app_process has no application context, so AudioManager.setMode (which
        // passes mApplicationContext.getOpPackageName()) would NPE: give it the package context explicitly.
        try { java.lang.reflect.Field f = AudioManager.class.getDeclaredField("mApplicationContext"); f.setAccessible(true); f.set(am, ctx); }
        catch (Throwable e) { System.out.println("btsco: mApplicationContext: " + e); }
        AudioDeviceInfo sco = null;
        for (AudioDeviceInfo d : am.getAvailableCommunicationDevices()) {
            System.out.println("btsco: comm device type " + d.getType() + " '" + d.getProductName() + "'");
            if (d.getType() == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) sco = d;
        }
        if (sco == null) { System.out.println("btsco: no BLUETOOTH_SCO communication device"); System.exit(3); }
        int oldMode = am.getMode();
        am.setMode(AudioManager.MODE_IN_COMMUNICATION);
        boolean ok = am.setCommunicationDevice(sco);
        long t0 = System.currentTimeMillis();
        while (System.currentTimeMillis() - t0 < 4000) {
            AudioDeviceInfo c = am.getCommunicationDevice();
            if (c != null && c.getType() == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) break;
            Thread.sleep(100);
        }
        AudioDeviceInfo cur = am.getCommunicationDevice();
        System.out.println("btsco: mode " + am.getMode() + " setCommunicationDevice " + ok + " -> current "
            + (cur == null ? "none" : cur.getType() + " '" + cur.getProductName() + "'") + " after " + (System.currentTimeMillis() - t0) + " ms");
        int max = am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL), before = am.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
        am.setStreamVolume(AudioManager.STREAM_VOICE_CALL, Math.max(1, Math.round(max * vol / 100f)), 0);
        System.out.println("btsco: STREAM_VOICE_CALL " + before + " -> " + am.getStreamVolume(AudioManager.STREAM_VOICE_CALL) + " of " + max);
        System.out.println("btsco: ROUTED " + new java.text.SimpleDateFormat("HH:mm:ss").format(new java.util.Date()) + ", holding " + secs + " s");
        Thread.sleep(secs * 1000L);
        am.setStreamVolume(AudioManager.STREAM_VOICE_CALL, before, 0);
        am.clearCommunicationDevice(); am.setMode(oldMode);
        System.out.println("btsco: restored mode " + am.getMode() + ", voice volume " + am.getStreamVolume(AudioManager.STREAM_VOICE_CALL));
        System.exit(0);
    }
}
