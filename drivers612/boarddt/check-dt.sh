#!/bin/bash
# check-dt.sh: regenerate, build and verify the a52sxq board device tree for the 6.12 base, and
# print "phone 5.4 merged tree vs our 6.12 merged tree" by subsystem.
#   SRC=rom (default)  body from the ROM kernel's Samsung dts (= downstream-dt/a52sxq-r0x.dts)
#   SRC=stock1|stock2  body from the dtbo dumped from test phone 1 / 2
#   REINDEX=1          rebuild the driver compatible index (out/compat-index.txt)
#   NOAGENTS=1         do not try other agents' a52sxq-<name>.dtsi, placeholders only
# Writes only inside this directory. Touches no phone.
set -u
cd "$(dirname "$(readlink -f "$0")")"
P=$(cd ../.. && pwd)
BASE=$P/bsp612/out/dist/dtb/yupik.dtb
MKDTBO=$HOME/git/android/system/libufdt/utils/src/mkdtboimg.py
SAMSUNG=$HOME/git/android/kernel/samsung/sm7325/arch/arm64/boot/dts/samsung/a52/a52sxq
STOCK1=$P/testdev-PHONE1/dtbo.img
STOCK2=$P/testdev-PHONE2/dtbo.img
SRC=${SRC:-rom}
AGENTS="display touch power audio camera conn secure gpu-video"
REVS="r00 r01 r02"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "ok:   $*"; }
B=out/build
rm -rf $B out/stock out/src; mkdir -p $B/agents out/stock/1 out/stock/2 out/src out/phone
dtc -q -I dts -O dtb -o out/phone/a52sxq-r02.dtb "$P/downstream-dt/a52sxq-r02.dts" 2>/dev/null

echo "== 1. inputs"
[ -f "$BASE" ] || { echo "no base dtb $BASE"; exit 1; }
python3 "$MKDTBO" dump "$STOCK1" -b out/stock/1/e > out/stock/1/table.txt || exit 1
python3 "$MKDTBO" dump "$STOCK2" -b out/stock/2/e > out/stock/2/table.txt || exit 1
# stock entry -> revision name, by qcom,board-id = <0x22 N>
for s in 1 2; do for e in out/stock/$s/e.*; do
	n=$(fdtget -t u "$e" / qcom,board-id | awk '{print $2}')
	cp "$e" out/stock/$s/r0$n.dtbo
done; done
case $SRC in
rom) for r in $REVS; do dtc -q -I dts -O dtb -o out/src/$r.dtbo "$SAMSUNG/a52sxq_kor_single_w00_$r.dts" || exit 1; done ;;
stock1) cp out/stock/1/r0?.dtbo out/src/ ;;
stock2) cp out/stock/2/r0?.dtbo out/src/ ;;
*) echo "SRC=$SRC?"; exit 1 ;;
esac
echo "body source: $SRC; selection properties: stock dtbo of test phone 1 (PHONE1)"

echo "== 2. generate source tree"
: > $B/skip-labels.txt
gen() { python3 tools/gen.py "$BASE" . --skip-labels=$B/skip-labels.txt r00=out/src/r00.dtbo r01=out/src/r01.dtbo r02=out/src/r02.dtbo; }
gen || exit 1
for r in $REVS; do
	{
	echo "// SPDX-License-Identifier: GPL-2.0"
	echo "/*"
	echo " * Samsung Galaxy A52s 5G (a52sxq), dtbo entry $r: overlay on Qualcomm's 6.12 yupik.dtb."
	echo " * WRITTEN BY check-dt.sh. Root properties: verbatim from the stock dtbo entry with the"
	echo " * same qcom,board-id (the ABL selects by qcom,board-id = <0x22 N>, N <= hardware revision)."
	echo " * a52sxq-agents-{labels,nodes}.dtsi are written by check-dt.sh into out/build/."
	echo " */"
	echo "/dts-v1/;"
	echo "/plugin/;"
	echo
	echo "/ {"
	python3 tools/rootprops.py out/stock/1/$r.dtbo
	echo "};"
	echo
	echo '/include/ "a52sxq-agents-labels.dtsi"'
	echo '/include/ "a52sxq-common.dtsi"'
	echo '/include/ "a52sxq-agents-nodes.dtsi"'
	echo "/include/ \"a52sxq-$r.dtsi\""
	echo '/include/ "a52sxq-bsp612-fixups.dtsi"'
	echo "/include/ \"a52sxq-$r-fixups.dtsi\""
	} > a52sxq-$r-overlay.dts
done
if [ "${REINDEX:-0}" = 1 ] || [ ! -s out/compat-index.txt ]; then
	( cd "$P" && for d in bsp612/kernel/drivers bsp612/kernel/sound bsp612/soc-repo bsp612/techpacks samsung612 drivers612 modules; do
		[ -d $d ] && grep -rIoE --include='*.c' --include='*.h' 'compatible\s*=\s*"[^"]+"' $d 2>/dev/null
	done | sed -E 's/^([^:]+):.*"([^"]+)"$/\2\t\1/' | sort -u ) > out/compat-index.txt
fi

python3 tools/bindings.py out/nodes-compat.tsv out/compat-index.txt BINDINGS.md	# whole phone tree, before agents replace parts

echo "== 3. agent fragments"
write_agents() {	# $1 = agents whose real fragment is used
	: > $B/a52sxq-agents-labels.dtsi; : > $B/a52sxq-agents-nodes.dtsi
	local f x
	# labels an integrated fragment defines itself are left out of our generated files
	for x in $1; do grep -oE '[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*[A-Za-z0-9,._+@-]+[[:space:]]*\{' $B/agents/$x.dtsi | sed -E 's/:.*//'; done | sort -u > $B/skip-labels.txt
	rm -f placeholders/*.dtsi; gen > $B/gen.log || return 1
	for f in placeholders/a52sxq-*-labels.dtsi; do
		[ -f "$f" ] && echo "/include/ \"$f\"" >> $B/a52sxq-agents-labels.dtsi
	done
	for x in $AGENTS; do
		case " $1 " in
		*" $x "*) echo "/include/ \"agents/$x.dtsi\"" >> $B/a52sxq-agents-nodes.dtsi
			[ -s $B/agents/$x-extra-labels.dtsi ] && echo "/include/ \"agents/$x-extra-labels.dtsi\"" >> $B/a52sxq-agents-labels.dtsi ;;
		*) [ -f placeholders/a52sxq-$x-placeholder.dtsi ] && echo "/include/ \"placeholders/a52sxq-$x-placeholder.dtsi\"" >> $B/a52sxq-agents-nodes.dtsi ;;
		esac
	done
}
build_one() {	# $1 = rev; -> $B/$1.dtbo, $B/merged-$1.dtb
	dtc -@ -q -I dts -O dtb -i $B -i . -o $B/$1.dtbo a52sxq-$1-overlay.dts 2> $B/$1.dtc.log || return 1
	fdtoverlay -i "$BASE" -o $B/merged-$1.dtb $B/$1.dtbo 2> $B/$1.apply.log || return 2
}
real=""
: > out/agents-status.txt
for a in $AGENTS; do
	f=../$a/a52sxq-$a.dtsi
	if [ "${NOAGENTS:-0}" = 1 ] || [ ! -f $f ]; then
		echo "$a: placeholder (no drivers612/$a/a52sxq-$a.dtsi)" | tee -a out/agents-status.txt; continue
	fi
	if ! cpp -P -x assembler-with-cpp -nostdinc -undef -I "$P/bsp612/soc-repo/include" -I "$P/bsp612/kernel/include" \
		-I "$P/bsp612/devicetree" -I "$(dirname $f)" $f 2> $B/agents/$a.log | sed 's|^/ {|\&{/} {|' > $B/agents/$a.dtsi && [ -s $B/agents/$a.dtsi ]; then
		echo "$a: placeholder (fragment does not preprocess: $(head -1 $B/agents/$a.log))" | tee -a out/agents-status.txt; continue
	fi
	write_agents "$real $a"
	build_one r02; rc=$?
	if [ $rc = 2 ]; then
		# labels that only our replaced placeholder defined (or that nobody defines yet): stub them
		miss=$(python3 - "$BASE" $B/r02.dtbo <<'PY'
import sys; sys.path.insert(0, "tools"); import fdt
bs = fdt.symbols(fdt.load(sys.argv[1])); fx = fdt.load(sys.argv[2]).children["__fixups__"].props
print(" ".join(l for l in fx if l not in bs))
PY
)
		if [ -n "$miss" ]; then
			{ echo "/* labels that drivers612/$a/a52sxq-$a.dtsi (or a node it replaces) leaves undefined: placeholders, TODO-binding */"
			  echo "&soc { a52sxq-todo-$a-extra { a52sxq,todo-binding;"
			  for l in $miss; do echo "	$l: $l { a52sxq,placeholder-for = \"$l\"; };"; done
			  echo "}; };"; } > $B/agents/$a-extra-labels.dtsi
			write_agents "$real $a"; build_one r02; rc=$?
		fi
	fi
	if [ $rc = 0 ]; then
		real="$real $a"; echo "$a: INTEGRATED drivers612/$a/a52sxq-$a.dtsi (replaces the placeholder${miss:+; undefined labels stubbed: $miss})" | tee -a out/agents-status.txt
	else
		rm -f $B/agents/$a-extra-labels.dtsi
		{ cat $B/r02.dtc.log $B/r02.apply.log 2>/dev/null; echo "undefined labels: ${miss:-}"; } > $B/agents/$a.log 2>&1
		echo "$a: placeholder (fragment present but does not integrate yet: $(grep -m1 . $B/agents/$a.log | cut -c1-150); full log out/build/agents/$a.log)" | tee -a out/agents-status.txt
	fi
	miss=""
done
write_agents "$real"

echo "== 4. build + bootloader constraints"
strings "$BASE" | grep -qx __symbols__ && ok "base has __symbols__" || bad "base has no __symbols__"
for r in $REVS; do
	build_one $r; rc=$?
	[ $rc = 1 ] && { bad "$r: dtc: $(head -3 $B/$r.dtc.log)"; continue; }
	[ $rc = 2 ] && { bad "$r: fdtoverlay does not apply: $(cat $B/$r.apply.log)"; continue; }
	strings $B/$r.dtbo | grep -qx __fixups__ || bad "$r: no __fixups__"
	python3 - "$BASE" $B/$r.dtbo <<'PY' || bad "$r: overlay references labels the base lacks"
import sys; sys.path.insert(0, "tools"); import fdt
bs = fdt.symbols(fdt.load(sys.argv[1])); fx = fdt.load(sys.argv[2]).children["__fixups__"].props
m = [l for l in fx if l not in bs]
print("      %d base labels used, %d missing %s" % (len(fx), len(m), m)); sys.exit(1 if m else 0)
PY
	diff <(python3 tools/rootprops.py out/stock/1/$r.dtbo) <(python3 tools/rootprops.py $B/$r.dtbo) > /dev/null || bad "$r: root properties differ from the stock entry"
	sz=$(stat -c %s $B/merged-$r.dtb)
	[ $sz -lt 2097152 ] || bad "$r: merged dtb $sz >= 2 MB"
	for n in /soc/qcom,wdt@17c10000 /soc/timer /chosen /reserved-memory; do
		fdtget -p $B/merged-$r.dtb $n > /dev/null 2>&1 || bad "$r: merged tree lacks $n"
	done
	fdtget -p $B/merged-$r.dtb /memory > /dev/null 2>&1 || fdtget -l $B/merged-$r.dtb / | grep -q '^memory' || bad "$r: no /memory"
	for l in soc intc reserved_memory aliases firmware wdog arch_timer qcom_tzlog; do
		fdtget -t s $B/merged-$r.dtb /__symbols__ $l > /dev/null 2>&1 || bad "$r: merged tree lost label $l"
	done
	[ "$(fdtget -t x $B/$r.dtbo / dtbo-version 2>/dev/null)" = 0 ] || bad "$r: no dtbo-version in the overlay root"
	[ "$(fdtget -t x $B/merged-$r.dtb /reserved-memory/kaslr_region@A0001000 reg 2>/dev/null)" = "0 a0001000 0 1000" ] || bad "$r: kaslr region"
	[ "$(fdtget -t x $B/merged-$r.dtb /reserved-memory/adsp@86700000 reg)" = "0 84700000 0 4800000" ] || bad "$r: ADSP region is not Samsung's"
	fdtget -t u $B/merged-$r.dtb /soc/pinctrl@f000000 qcom,gpios-reserved | grep -q '56 57 58 59' || bad "$r: secure gpios 56..59 not reserved"
	ok "$r: dtbo $(stat -c %s $B/$r.dtbo) bytes, applies, merged $sz bytes, board-id <$(fdtget -t x $B/$r.dtbo / qcom,board-id)> hw_rev $(fdtget -t x $B/$r.dtbo / dtbo-hw_rev)..$(fdtget -t x $B/$r.dtbo / dtbo-hw_rev_end)"
done

python3 tools/regcheck.py "$P/downstream-dt/regulators-r02.txt" out/phone/a52sxq-r02.dtb $B/merged-r02.dtb REGULATORS.md || bad "RPMh regulators differ from the phone (REGULATORS.md)"

echo "== 5. dtbo table image (entry order and header as stock test phone 1)"
order=$(for e in out/stock/1/e.*; do echo "r0$(fdtget -t u $e / qcom,board-id | awk '{print $2}')"; done)
python3 "$MKDTBO" create out/dtbo-a52sxq-bsp612-$SRC.img --page_size=4096 $(for r in $order; do echo $B/$r.dtbo; done) > /dev/null || bad "mkdtboimg"
python3 "$MKDTBO" dump out/dtbo-a52sxq-bsp612-$SRC.img > out/dtbo-table.txt
if diff <(grep -vE 'total_size|dt_size|dt_offset' out/stock/1/table.txt) <(grep -vE 'total_size|dt_size|dt_offset' out/dtbo-table.txt) > /dev/null; then
	ok "table header/entries equal stock (magic, 3 entries, page 4096, version 0, id/rev/custom 0), order: $(echo $order)"
else bad "dtbo table differs from stock"; fi
isz=$(stat -c %s out/dtbo-a52sxq-bsp612-$SRC.img); [ $isz -le $(stat -c %s "$STOCK1") ] && ok "image $isz bytes <= dtbo partition $(stat -c %s "$STOCK1")" || bad "dtbo image larger than the partition"

echo "== 6. phone 5.4 merged tree vs our 6.12 merged tree (r02 = hardware revisions 2..32)"
for r in $REVS; do
	[ -f $B/merged-$r.dtb ] || continue
	dtc -q -I dts -O dtb -o out/phone/a52sxq-$r.dtb "$P/downstream-dt/a52sxq-$r.dts" 2>/dev/null
	python3 tools/dtdiff.py out/phone/a52sxq-$r.dtb $B/merged-$r.dtb out/units.tsv out/dt-diff-$r.txt > out/dt-diff-$r.summary
done
cat out/dt-diff-r02.summary
echo "details: out/dt-diff-r0{0,1,2}.txt; binding table: BINDINGS.md; agents: out/agents-status.txt"

echo "== 7. board description sources compared (5.4 base + entry vs downstream-dt/a52sxq-r02.dts)"
dtc -q -I dts -O dtb -o out/phone/yupik-base54.dtb "$P/downstream-dt/yupik-base.dts" 2>/dev/null
for s in 1 2; do
	if fdtoverlay -i out/phone/yupik-base54.dtb -o out/phone/stock$s-r02.dtb out/stock/$s/r02.dtbo 2>/dev/null; then
		python3 tools/dtdiff.py out/phone/a52sxq-r02.dtb out/phone/stock$s-r02.dtb out/units.tsv out/src-diff-stock$s-r02.txt | tail -2 | head -1 | awk -v s=$s '{print "test phone " s " dtbo r02 vs ROM tree: nodes missing " $3 ", props missing " $5 ", props differing " $6 "  (out/src-diff-stock" s "-r02.txt)"}'
	else echo "test phone $s r02: does not apply on the 5.4 base"; fi
done
[ $fail = 0 ] && echo "RESULT: all checks passed" || echo "RESULT: FAILED"
exit $fail
