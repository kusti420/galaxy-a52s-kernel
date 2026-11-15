#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Deterministic zip: detzip.py <out.zip> <stage dir>

Every regular file under <stage dir>, sorted by path, deflate level 9, fixed timestamp
(2008-01-01 00:00:00, as AOSP's ziptime), Unix mode 0644 (0755 for update-binary), no
directory entries, no extra fields (so no uid/gid, no host timestamps), empty comment.
The same stage always gives the same bytes (same Python/zlib)."""
import os
import shutil
import sys
import zipfile

DATE = (2008, 1, 1, 0, 0, 0)
EXEC = {"META-INF/com/google/android/update-binary"}


def main():
    out, stage = sys.argv[1], sys.argv[2]
    names = []
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p) or not os.path.isfile(p):
                sys.exit(f"detzip: not a regular file: {p}")
            names.append(os.path.relpath(p, stage).replace(os.sep, "/"))
    names.sort()
    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as z:
        for n in names:
            zi = zipfile.ZipInfo(n, DATE)
            zi.create_system = 3
            mode = 0o755 if n in EXEC else 0o644
            zi.external_attr = (0o100000 | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi._compresslevel = 9  # ZipInfo has no public per-entry level
            with open(os.path.join(stage, n), "rb") as src, z.open(zi, "w") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
    os.replace(tmp, out)


if __name__ == "__main__":
    main()
