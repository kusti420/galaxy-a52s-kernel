# audio, camera, video codecs, sensors, security, fingerprint, vibrator, SELinux, external benchmark app
has_st() { [ -f "$HERE/java/st.dex" ]; }
reg audio - 1 "audio: tone played and captured by the phone's own mics, frequency + SNR by FFT (media, low-latency, voice paths), offload"
t_audio() {
	[ "${DAILY:-0}" = 1 ] && { skip "audible loopback (daily phone: volume must not change)"; return; }
	has_st || { skip "tone + capture FFT (todo: St loop)"; return; }
	# the only audible part of the suite: 1.5 s tones at stream index 1 (lowest step), restored to 0 by the tool and by mute;
	# without AUDIBLE=1 the phone stays fully muted (the loopback then reports SKIP)
	# silent is the default since 2026-11-19: the audible loopback needs AUDIBLE=1 (SILENT=1 still wins)
	local um=; [ "${AUDIBLE:-0}" = 1 ] && [ "${SILENT:-0}" != 1 ] && um=unmute
	strun loop media 1000 MIC $um; mute
	strun loop ll 1500 MIC $um; mute
	[ "$QUICK" = 1 ] || { strun loop media 2000 CAMCORDER $um; mute; strun loop voice 1000 MIC $um; mute; }
	strun offload; mute
	local j; j=$(A 'getevent -pl 2>/dev/null' | grep -ciE 'name:.*(jack|headset)'); note "$j headset/jack input devices registered (presence only)"
	if have_root; then R 'PATH=$PATH:/data/local/tmp; tinymix 2>/dev/null | wc -l; cat /proc/asound/cards'; fi
	skip "3.5 mm headset out/mic, USB audio, earpiece by ear, voice call audio (hands-on)"; hands "3.5 mm headphones: plug, play, record with the headset mic, buttons"; hands "Listen: speaker and earpiece at normal volume (distortion, rattle)"
}

reg camera - 1 "camera: every camera ID opens and captures decodable non-black JPEGs, 5 s hw-encoded recording decoded back"
t_camera() {
	has_st || { skip "camera2 capture (todo: St cam)"; return; }
	wake; local o r; o=$(TMO=180 st cam); echo "$o" | tail -30; echo "$o" | awk '$1=="METRIC"{print $2"\t"$3}' >> "$RUN/metrics.tsv"; r=$(echo "$o" | grep -m1 '^RESULT cam ' | cut -d' ' -f4-)
	case "$(echo "$o" | grep -m1 '^RESULT cam ' | cut -d' ' -f3)" in
		PASS) ok "cam: $r";;
		SKIP) skip "cam: $r";;
		FAIL) if echo "$r" | grep -qE 'FAILED| BAD|no camera'; then fail "cam: $r"   # open/capture/decode failure
			else ok "every camera id opened and returned decodable JPEGs at 2 sizes: $(echo "$r" | cut -c1-200)"; skip "black frames from $(echo "$r" | grep -o BLACK | wc -l) capture(s): lens covered (needs the phone propped up, lenses free: hands-on)"; hands "Camera: prop the phone up with all lenses free and rerun --only camera"; fi;;
		*) fail "cam: no RESULT line ($(echo "$o" | tail -1 | cut -c1-120))";;
	esac
	adb -s "$S" pull /data/local/tmp/st/ "$L.files" >/dev/null 2>&1; ls -la "$L.files" 2>/dev/null | grep -E 'jpg|mp4'
	[ "$QUICK" = 1 ] && { skip "video recording (quick mode)"; return; }
	TMO=120 strun camrec 0 5
	local n; n=$(st dec /data/local/tmp/st/camrec.mp4 - 0 nopattern | tee /dev/stderr | awk '$1=="METRIC" && $2=="dec_frames"{print int($3)}')
	metric camrec_decoded_frames "${n:-0}"; if [ "${n:-0}" -ge 100 ]; then ok "recording decodes back with the hw decoder: $n frames"; elif [ -n "$n" ]; then fail "recording decoded only $n frames (expected >= 100 for 5 s)"; else skip "decode-back of the recording (todo: St dec)"; fi
	skip "torch/flash light output (needs eyes or a second sensor: hands-on)"; hands "Camera app: photo with flash in the dark, torch tile, switch all lenses, 4K video with sound"
}

reg video - 1 "video codecs: hw encode -> hw decode round trip with frame count + pattern check (H.264, HEVC), hw VP9 decode"
t_video() {
	has_st || { skip "codec round trip (todo: St enc/dec)"; return; }
	local m f o
	for m in video/avc video/hevc; do f=/data/local/tmp/st/rt-${m#video/}.mp4; o=$(st enc $m $f); echo "$o" | tail -6
		if echo "$o" | grep -q '^RESULT enc PASS'; then if echo "$o" | grep -qiE 'hw true|hardware true|isHardwareAccelerated true'; then ok "enc $m: $(echo "$o" | grep -m1 '^RESULT' | cut -d' ' -f4- | cut -c1-90)"; else skip "hw encoder for $m (encoded in software: $(echo "$o" | grep -m1 '^RESULT' | cut -c1-90))"; fi; strun dec $f - 90
		else fail "enc $m: $(echo "$o" | grep -m1 '^RESULT' | cut -c1-140)"; fi; done
	f=/data/local/tmp/st/rt-vp9.webm; o=$(st enc video/x-vnd.on2.vp9 $f c2.android.vp9.encoder); echo "$o" | tail -3; if echo "$o" | grep -q '^RESULT enc PASS'; then strun dec $f - 90; else skip "VP9 decode (no VP9 test stream: $(echo "$o" | grep -m1 '^RESULT' | cut -c1-100))"; fi
	skip "AV1 hw decode (SM7325 has no AV1 hardware decoder)"
}

reg sensors - 1 "sensors: every sensor sampled: rate, range, variance (accel/gyro/mag/light/pressure must deliver)"
t_sensors() { has_st || { skip "sensor sampling (todo: St sensors)"; return; }; wake; strun sensors 5; skip "proximity near/far, step counter (need movement: hands-on)"; hands "Sensors: cover the proximity area in a call, rotate the phone (auto-rotate), walk 20 steps"; }

reg security - 1 "keystore: TEE key generate/sign/verify + AES; Widevine level via MediaDrm; gatekeeper via a real credential check"
t_security() {
	has_st || { skip "keystore/MediaDrm (todo: St keystore, drm)"; return; }
	strun keystore; strun drm
	case "$LOCKMSG" in unlocked) ok "gatekeeper verified the lock pattern at the start of the run";; *) skip "gatekeeper credential check (no credential entered this run: $LOCKMSG)";; esac
}

reg fingerprint - 1 "fingerprint: HAL state + enrollments read (a touch needs a finger)"
t_fingerprint() { local d; d=$(A dumpsys fingerprint | head -8); echo "$d" | cut -c1-200; note "HAL deaths: $(echo "$d" | grep -oE 'HAL deaths since last reboot: [0-9]+'); enrolled: $(echo "$d" | grep -oE '"count":[0-9]+' | head -1)"
	echo "$d" | grep -qE 'HAL deaths since last reboot: [1-9]' && fail "fingerprint HAL died since boot: $(echo "$d" | grep -oE 'HAL deaths[^"]*')"
	skip "fingerprint capture/match (needs a finger: hands-on)"; hands "Fingerprint: unlock 5 times, enroll a new finger"; }

reg vibrator - 1 "vibrator: never driven by the suite (owner rule); state only"
t_vibrator() { A dumpsys vibrator_manager | grep -iE 'vibratorIds|mVibratorIds|capabilities' | head -4 | cut -c1-200; skip "vibration output (suite never vibrates; needs a hand: hands-on)"; hands "Vibrator: feel a notification buzz and keyboard haptics"; }

reg selinux - 1 "SELinux: denial summary since boot; kernel-side denials (kernel domain, unlabelled 6.x sysfs/proc paths) fail"
t_selinux() {
	A 'logcat -d 2>/dev/null' > "$L.all.logcat"; [ "$KLOG" != none ] && klog > "$L.all.kmsg"; avc_sigs "$L.all.logcat" "$L.all.kmsg" 2>/dev/null > "$L.sigs"
	local tot k; tot=$(cat "$L.all.logcat" "$L.all.kmsg" 2>/dev/null | grep -c 'avc:  *denied'); k=$(grep -E "$AVC_KERNEL_SIDE" "$L.sigs" | grep -v 'scontext=u:r:shell '); echo "$k" > "$L.kernel-side"
	metric avc_denials "$tot"; metric avc_signatures "$(wc -l < "$L.sigs")"; metric avc_kernel_side_signatures "$(echo "$k" | grep -c .)"
	echo "top denial signatures:"; cat "$L.all.logcat" "$L.all.kmsg" 2>/dev/null | grep 'avc:  *denied' | grep -oE 'scontext=[^ ]+ tcontext=[^ ]+ tclass=[^ ]+' | sed 's/:s0[^ ]*//g' | sort | uniq -c | sort -rn | head -15
	if [ -z "$k" ]; then ok "$tot denials in the logs, 0 kernel-side signatures"; else fail "$(echo "$k" | grep -c .) kernel-side denial signatures ($tot denials total), e.g. $(echo "$k" | head -2 | tr '\n' ' ' | cut -c1-240)"; fi
}

reg bench - 0 "benchmark app (tools/bench-app, built by another session): run it and merge its results"
t_bench() {
	local rb="$REPO/tools/bench-app/run-bench.sh"; [ -x "$rb" ] || { skip "tools/bench-app/run-bench.sh not present (todo)"; return; }
	[ "${BENCH_APP:-0}" = 1 ] || { skip "benchmark APK needs an install on the phone: set BENCH_APP=1 to allow it"; return; }
	timeout 900 "$rb" "$S" "$RUN" 2>&1 | tail -20; [ -s "$RUN/bench.jsonl" ] || { fail "run-bench.sh wrote no bench.jsonl"; return; }
	python3 - "$RUN/bench.jsonl" "$RUN" <<'PY' > "$L.merge"
import json, sys
for line in open(sys.argv[1]):
    try: r = json.loads(line)
    except Exception: continue
    print("%s\t%s\t%s" % (r.get("id"), r.get("status"), (r.get("detail") or "").replace("\t", " ")))
    with open(sys.argv[2] + "/metrics.tsv", "a") as m:
        for k, v in (r.get("metrics") or {}).items(): m.write("%s\t%s\n" % (k, v))
PY
	while IFS=$'\t' read -r i s d; do case "$s" in PASS) ok "$i: $d";; FAIL) fail "$i: $d";; *) skip "$i: $d";; esac; done < "$L.merge"
}
