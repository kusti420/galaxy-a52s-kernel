package org.a52sxq.bench;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/** wifi.net: validated network, HTTPS download throughput (20 MB), 1 MB POST, Wi-Fi link info + scan result count. */
public class WifiNet extends Test {
    public String id() { return "wifi.net"; }
    public int budget(Ctx c) { return 120; }

    public void run(Ctx c, Result r) throws Exception {
        ConnectivityManager cm = (ConnectivityManager) c.app.getSystemService(Context.CONNECTIVITY_SERVICE);
        WifiManager wm = (WifiManager) c.app.getSystemService(Context.WIFI_SERVICE);
        try {
            r.num("wifi_enabled", wm.isWifiEnabled() ? 1L : 0L);
            WifiInfo wi = wm.getConnectionInfo();
            if (wi != null) { r.num("rssi_dbm", (long) wi.getRssi()).num("link_mbps", (long) wi.getLinkSpeed()).num("freq_mhz", (long) wi.getFrequency()); }
            int n = -1; try { n = wm.getScanResults().size(); } catch (Throwable t) { r.note("getScanResults: " + t); }
            r.num("wifi_scan_count", (long) n);
            if (n <= 0) r.note("0 scan results: needs ACCESS_FINE_LOCATION granted + location on, or no scan has run");
        } catch (Throwable t) { r.note("wifi info: " + t); }
        Network net = cm.getActiveNetwork();
        NetworkCapabilities nc = net == null ? null : cm.getNetworkCapabilities(net);
        if (nc == null) { r.skip("no active network"); return; }
        String tr = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? "wifi" : nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? "cellular" : nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ? "ethernet" : nc.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ? "vpn" : "other";
        r.str("transport", tr).num("down_kbps_reported", (long) nc.getLinkDownstreamBandwidthKbps());
        if (!nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) { r.skip("active network (" + tr + ") is not validated: no internet"); return; }

        String url = c.param("url", "https://speed.cloudflare.com/__down?bytes=20000000");
        long want = 20000000L; int i = url.indexOf("bytes="); if (i >= 0) try { want = Long.parseLong(url.substring(i + 6).replaceAll("[^0-9].*", "")); } catch (Exception e) { want = -1; }
        long got = 0; double dsec = 0; int code = -1;
        HttpURLConnection h = null;
        try {
            h = (HttpURLConnection) new URL(url).openConnection();
            h.setConnectTimeout(10000); h.setReadTimeout(15000); h.setRequestProperty("User-Agent", "a52bench");
            long t0 = System.nanoTime(); code = h.getResponseCode();
            long cl = h.getContentLengthLong(); if (want < 0 || !url.contains("bytes=")) want = cl;
            try (InputStream in = h.getInputStream()) {
                byte[] b = new byte[65536]; int k;
                while ((k = in.read(b)) > 0) { got += k; if (System.nanoTime() - t0 > 70e9) { r.note("download cut at 70 s"); break; } }
            }
            dsec = (System.nanoTime() - t0) / 1e9;
        } catch (Throwable t) { r.fail("download: " + t); }
        finally { if (h != null) h.disconnect(); }
        r.num("down_http", (long) code).num("down_bytes", got).num("down_seconds", dsec).num("down_mbit_s", dsec > 0 ? got * 8 / 1e6 / dsec : 0);
        if (!r.failed() && (code != 200 || got <= 0 || (want > 0 && got != want))) r.fail("download incomplete: http " + code + ", " + got + " of " + want + " bytes");

        String purl = c.param("posturl", "https://speed.cloudflare.com/__up");
        int pcode = -1; double psec = 0; int plen = 1 << 20;
        try {
            h = (HttpURLConnection) new URL(purl).openConnection();
            h.setConnectTimeout(10000); h.setReadTimeout(15000); h.setDoOutput(true); h.setRequestMethod("POST"); h.setFixedLengthStreamingMode(plen);
            h.setRequestProperty("Content-Type", "application/octet-stream"); h.setRequestProperty("User-Agent", "a52bench");
            byte[] b = new byte[65536]; for (int k = 0; k < b.length; k++) b[k] = (byte) (k * 73);
            long t0 = System.nanoTime();
            try (OutputStream o = h.getOutputStream()) { for (int s = 0; s < plen; s += b.length) o.write(b); }
            pcode = h.getResponseCode();
            try (InputStream in = pcode < 400 ? h.getInputStream() : h.getErrorStream()) { if (in != null) while (in.read(b) > 0) { } }
            psec = (System.nanoTime() - t0) / 1e9;
        } catch (Throwable t) { r.fail("upload: " + t); }
        finally { if (h != null) h.disconnect(); }
        r.num("up_http", (long) pcode).num("up_bytes", (long) plen).num("up_mbit_s", psec > 0 ? plen * 8 / 1e6 / psec : 0);
        if (!r.failed() && (pcode < 200 || pcode >= 300)) r.fail("upload POST http " + pcode);
        r.pass(tr + ": down " + String.format("%.1f", dsec > 0 ? got * 8 / 1e6 / dsec : 0) + " Mbit/s (" + got + " B), up " + String.format("%.1f", psec > 0 ? plen * 8 / 1e6 / psec : 0) + " Mbit/s");
    }
}
