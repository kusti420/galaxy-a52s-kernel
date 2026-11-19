#!/bin/bash
# Builds out/a52bench.apk without Gradle or network, from the AOSP prebuilts in ${ANDROID_TREE:-$HOME/android}.
# Usage: tools/bench-app/build.sh        (AOSP=<tree> to override)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
AOSP=${AOSP:-$HOME/git/android}
JAR=$AOSP/prebuilts/sdk/current/public/android.jar
BIN=$AOSP/prebuilts/sdk/tools/linux/bin
JDK=$AOSP/prebuilts/jdk/jdk21/linux-x86/bin
[ -x "$JDK/javac" ] || JDK=$(dirname "$(command -v javac)")
W=$TOP/out/bench-app; OUT=$TOP/out/a52bench.apk
rm -rf "$W"; mkdir -p "$W/classes" "$W/dex"
"$JDK/javac" -nowarn -Xlint:-options --release 11 -cp "$JAR" -d "$W/classes" $(find "$HERE/src" -name '*.java') 2>&1 | grep -v '^Note:' || true
[ -f "$W/classes/org/a52sxq/bench/RunActivity.class" ] || { echo "javac failed"; exit 1; }
"$JDK/java" -cp "$AOSP/prebuilts/r8/r8.jar" com.android.tools.r8.D8 --release --min-api 30 --lib "$JAR" --output "$W/dex" $(find "$W/classes" -name '*.class')
"$BIN/aapt2" link -o "$W/base.apk" --manifest "$HERE/AndroidManifest.xml" -I "$JAR" --min-sdk-version 30 --target-sdk-version 34
(cd "$W/dex" && zip -q -j "$W/base.apk" classes.dex)
"$BIN/zipalign" -f 4 "$W/base.apk" "$W/aligned.apk"
KS=${KS:-$HOME/.config/a52sxq/bench-debug.jks}
if [ ! -f "$KS" ]; then mkdir -p "$(dirname "$KS")"; keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias bench -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=a52bench debug" >/dev/null 2>&1; fi
"$JDK/java" -jar "$AOSP/prebuilts/sdk/tools/linux/lib/apksigner.jar" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --ks-key-alias bench --out "$OUT" "$W/aligned.apk"
rm -f "$OUT.idsig"; ls -la "$OUT"
