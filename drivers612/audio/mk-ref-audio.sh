#!/bin/bash
# A tested kexec ramdisk (the REF of drivers612/realboot/build-realboot.sh) with ONLY some audio
# stage modules replaced by new builds of drivers612/audio (stripped like the stage, llvm-strip
# --strip-debug). build-realboot.sh takes every module byte for byte from REF, so this is how a
# fixed audio .ko gets into the real boot's vendor add-on (/vendor/lib/modules/6.12):
#   drivers612/audio/mk-ref-audio.sh <ref-rd.cpio.gz> <out-rd.cpio.gz> <new.ko>...
#   e.g. drivers612/androidboot/out/s76-rd.cpio.gz drivers612/androidboot/out/s76vc-rd.cpio.gz \
#        drivers612/audio/audio-kernel/dsp/q6_dlkm.ko        (then REF=s76vc build-realboot.sh)
# The replacement is a second newc archive appended to the first (later files replace earlier ones,
# for the kernel's initramfs unpacker and for realboot/tools/cpiox.py alike); the original stream
# is kept byte for byte. Checks: the module exists in a52/mods/audio, same vermagic, a different
# file, identical export/import CRC sections (the other audio modules still bind), read-back
# differs from the REF only in the replaced files. Packs only; nothing is run.
set -euo pipefail
IN=${1:?ref-rd.cpio.gz}; OUT=${2:?out-rd.cpio.gz}; shift 2; [ $# -gt 0 ] || { echo "no .ko given" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
CB=${ANDROID_TREE:-$HOME/android}/prebuilts/clang/host/linux-x86/clang-r547379/bin
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }
[ "$(realpath "$IN")" != "$(realpath -m "$OUT")" ] || fail "IN = OUT"
W=$(mktemp -d "${TMPDIR:-/tmp}/refaudio.XXXXXX"); trap 'rm -rf "$W"' EXIT
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$IN" "$W/a" > /dev/null
vm() { strings "$1" | sed -n 's/^vermagic=//p' | head -1; }
mkdir -p "$W/new"; NAMES=()
for KO in "$@"; do
	b=$(basename "$KO"); old=$W/a/a52/mods/audio/$b
	[ -f "$old" ] || fail "$IN has no a52/mods/audio/$b"
	"$CB/llvm-strip" --strip-debug -o "$W/new/$b" "$KO"
	[ "$(vm "$old")" = "$(vm "$W/new/$b")" ] || fail "$b: vermagic differs: $(vm "$old") vs $(vm "$W/new/$b")"
	cmp -s "$old" "$W/new/$b" && fail "$b is the REF's own file (not the new build?)"
	# RELINK=1 (opt-in): the given modules may change their exports/imports/depends together (a patch that adds
	# an export, or changes a prototype that a sibling in the same call imports). This script then does NOT prove
	# that they still bind: build-realboot.sh's tools/loadsim.py must (CRCs vs exporters, duplicates, load order).
	SECS="__kcrctab __kcrctab_gpl __versions __ksymtab_strings .modinfo"
	[ "${RELINK:-0}" = 1 ] && { SECS=""; echo "$b: RELINK=1: CRC/import/modinfo sections not compared (loadsim.py checks binding)"; }
	for s in $SECS; do
		"$CB/llvm-objcopy" -O binary --only-section=$s "$old" "$W/o.bin" 2>/dev/null || : > "$W/o.bin"
		"$CB/llvm-objcopy" -O binary --only-section=$s "$W/new/$b" "$W/n.bin" 2>/dev/null || : > "$W/n.bin"
		cmp -s "$W/o.bin" "$W/n.bin" || fail "$b section $s differs (CRCs/imports/modinfo changed: rebuild the dependent modules too)"
	done
	NAMES+=("$b")
done
python3 -I - "$IN" "$W/new" "$W/out.cpio.gz" "${NAMES[@]}" <<'EOF'
import gzip, os, sys
src, newdir, out, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
raw = gzip.open(src).read()
def ent(name, mode, body, ino):
    n = name.encode() + b'\0'
    h = b'070701' + b''.join(b'%08X' % v for v in (ino, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(n), 0))
    e = h + n; e += b'\0' * (-len(e) % 4); e += body; e += b'\0' * (-len(e) % 4)
    return e
app = b''.join(ent('a52/mods/audio/' + b, 0o100644, open(os.path.join(newdir, b), 'rb').read(), 0x5a000 + i)
               for i, b in enumerate(names)) + ent('TRAILER!!!', 0, b'', 0)
raw += b'\0' * (-len(raw) % 4)
with gzip.GzipFile(out, 'wb', mtime=0) as fh: fh.write(raw + app)
EOF
python3 -I "$TOP/drivers612/realboot/tools/cpiox.py" "$W/out.cpio.gz" "$W/c" > /dev/null
diff -r -q "$W/a" "$W/c" | sort > "$W/d.txt" || true
for b in "${NAMES[@]}"; do echo "Files $W/a/a52/mods/audio/$b and $W/c/a52/mods/audio/$b differ"; done | sort > "$W/want.txt"
cmp -s "$W/d.txt" "$W/want.txt" || { cat "$W/d.txt"; fail "read-back differs beyond the replaced modules"; }
for b in "${NAMES[@]}"; do cmp -s "$W/c/a52/mods/audio/$b" "$W/new/$b" || fail "read-back $b"; done
mv "$W/out.cpio.gz" "$OUT"
for b in "${NAMES[@]}"; do
	echo "$OUT: a52/mods/audio/$b $(sha256sum < "$W/a/a52/mods/audio/$b" | cut -c1-16) -> $(sha256sum < "$W/new/$b" | cut -c1-16) $( [ "${RELINK:-0}" = 1 ] && echo "(vermagic identical; RELINK: binding left to loadsim)" || echo "(vermagic + CRC/import sections identical)")"
done
