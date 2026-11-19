package org.a52sxq.bench;

import android.os.Environment;
import java.io.File;

/** Same as storage.io on a removable volume (the app's own dir on it: nothing else on the card is touched). */
public class StorageSd extends StorageIo {
    public String id() { return "storage.sd"; }
    @Override protected File target(Ctx c, Result r) {
        for (File d : c.app.getExternalFilesDirs(null)) {
            if (d == null) continue;
            try { if (Environment.isExternalStorageRemovable(d) && Environment.MEDIA_MOUNTED.equals(Environment.getExternalStorageState(d))) { d.mkdirs(); return d; } } catch (Exception e) { }
        }
        r.skip("no removable volume mounted"); return null;
    }
}
