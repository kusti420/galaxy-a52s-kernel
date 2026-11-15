#!/bin/bash
# pack/ -> pack-wifibt.tgz (unpacked to /p in the test kernel by run.sh)
cd "$(dirname "$0")/pack" && tar czf ../pack-wifibt.tgz --owner=0 --group=0 . && ls -la ../pack-wifibt.tgz
