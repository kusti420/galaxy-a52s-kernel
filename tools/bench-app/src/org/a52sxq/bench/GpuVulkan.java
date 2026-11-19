package org.a52sxq.bench;

import android.content.pm.FeatureInfo;
import android.content.pm.PackageManager;

/** No Vulkan binding exists in the Java SDK (NDK only) and this app has no native code: reports the declared features, SKIPs. */
public class GpuVulkan extends Test {
    public String id() { return "gpu.vulkan"; }
    public void run(Ctx c, Result r) {
        for (FeatureInfo f : c.app.getPackageManager().getSystemAvailableFeatures()) {
            if (f.name == null) continue;
            if (f.name.equals(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION)) r.num("vulkan_hw_version_major", (long) (f.version >> 22)).num("vulkan_hw_version_minor", (long) ((f.version >> 12) & 0x3ff));
            if (f.name.equals(PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL)) r.num("vulkan_hw_level", (long) f.version);
        }
        r.skip("Vulkan cannot be driven from pure Java (NDK only); declared feature versions reported as numbers");
    }
}
