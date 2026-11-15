#!/bin/bash
# Regenerates src/ from the phone's 5.4 Samsung vibrator drivers (read-only) and applies the 6.12
# changes: class_create() lost its owner argument (6.4), platform_driver .remove returns void (6.11).
set -e
H=$(cd "$(dirname "$0")" && pwd); K=${K:-$HOME/git/android/kernel/samsung/sm7325}
rm -rf "$H/src"; mkdir -p "$H/src/include/linux/vibrator"
cp "$K/drivers/vibrator/common/sec_vibrator.c" "$K/drivers/vibrator/dc/dc_vibrator.c" "$K/drivers/vibrator/dc/dc_vibrator.h" "$H/src/"
cp "$K/include/linux/vibrator/sec_vibrator.h" "$K/include/linux/vibrator/sec_vibrator_notifier.h" "$H/src/include/linux/vibrator/"
python3 - "$H/src" <<'PY'
import sys, re
d = sys.argv[1]
p = d + '/sec_vibrator.c'; s = open(p).read()
s = s.replace('class_create(THIS_MODULE, "timed_output")', 'class_create("timed_output")'); open(p, 'w').write(s)
p = d + '/dc_vibrator.c'; s = open(p).read()
m = re.search(r'static int dc_vib_remove\(struct platform_device \*pdev\)\n\{(.*?)\n\}', s, re.S)
body = re.sub(r'\n\treturn 0;\s*$', '', m.group(1))
s = s[:m.start()] + 'static void dc_vib_remove(struct platform_device *pdev)\n{' + body + '\n}' + s[m.end():]
open(p, 'w').write(s)
PY
cp "$H/Kbuild.src" "$H/src/Kbuild"
