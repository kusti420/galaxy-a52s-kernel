package org.a52sxq.bench;

import android.media.MediaDrm;
import android.media.NotProvisionedException;
import java.util.UUID;

/** drm.widevine: MediaDrm Widevine plugin properties, security level and provisioning state. */
public class DrmWidevine extends Test {
    public String id() { return "drm.widevine"; }
    public int budget(Ctx c) { return 30; }
    static final UUID WV = UUID.fromString("edef8ba9-79d6-4ace-a3c8-27dcd51d21ed");

    public void run(Ctx c, Result r) throws Exception {
        c.log("drm.widevine: step isCryptoSchemeSupported"); r.str("last_step", "isCryptoSchemeSupported");
        if (!MediaDrm.isCryptoSchemeSupported(WV)) { r.fail("Widevine crypto scheme not supported (no DRM HAL plugin)"); return; }
        c.log("drm.widevine: step new MediaDrm"); r.str("last_step", "new MediaDrm");
        MediaDrm d = new MediaDrm(WV);
        c.log("drm.widevine: step properties"); r.str("last_step", "getPropertyString");
        try {
            int got = 0; String level = null;
            for (String p : new String[] { "securityLevel", "systemId", "version", "vendor", "description", "algorithms", "maxHdcpLevel", "hdcpLevel", "oemCryptoApiVersion" }) {
                try { String v = d.getPropertyString(p); r.str(p, v); got++; if (p.equals("securityLevel")) level = v; } catch (Throwable t) { r.str(p, "ERR " + t.getClass().getSimpleName()); }
            }
            if (level != null && level.startsWith("L")) { try { r.num("security_level", Long.parseLong(level.substring(1))); } catch (Exception e) { } }
            try { r.num("system_id", Long.parseLong(d.getPropertyString("systemId"))); } catch (Throwable t) { }
            int prov = -1;
            c.log("drm.widevine: step openSession"); r.str("last_step", "openSession");
            try { byte[] s = d.openSession(); prov = 1; try { r.num("session_security_level", (long) d.getSecurityLevel(s)); } catch (Throwable t) { } d.closeSession(s); }
            catch (NotProvisionedException e) { prov = 0; }
            catch (Throwable t) { r.note("openSession: " + t); }
            r.num("provisioned", (long) prov);
            if (level == null || got < 2) r.fail("Widevine properties not readable (" + got + " read)");
            else r.pass("Widevine " + level + ", provisioned=" + prov + (prov < 0 ? " (openSession error)" : ""));
        } finally { try { d.close(); } catch (Throwable t) { } }
    }
}
