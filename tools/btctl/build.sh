#!/bin/sh
# Builds btctl.dex (see BtCtl.java) with the system javac and AOSP's d8 + android.jar.
set -e; cd "$(dirname "$0")"; P=${ANDROID_TREE:-$HOME/android}/prebuilts
rm -rf cls; mkdir cls; javac --release 11 -cp $P/sdk/current/public/android.jar -d cls BtCtl.java 2>&1 | grep -v warning || true
java -cp $P/r8/r8.jar com.android.tools.r8.D8 --min-api 30 --lib $P/sdk/current/public/android.jar --output . cls/*.class && mv classes.dex btctl.dex && rm -rf cls && ls -la btctl.dex
