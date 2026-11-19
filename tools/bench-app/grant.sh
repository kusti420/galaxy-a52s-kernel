#!/bin/bash
# Grants every runtime permission the bench app uses (no dialogs on the phone). Usage: grant.sh <serial>
S=${1:?serial}
for p in CAMERA RECORD_AUDIO ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION BLUETOOTH_SCAN BLUETOOTH_CONNECT NEARBY_WIFI_DEVICES BODY_SENSORS ACTIVITY_RECOGNITION; do
  adb -s "$S" shell pm grant org.a52sxq.bench android.permission.$p 2>&1 | grep -v '^$' | sed "s/^/grant $p: /" | head -1
done
exit 0
