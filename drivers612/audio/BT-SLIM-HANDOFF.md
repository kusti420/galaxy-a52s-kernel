# Bluetooth over SLIMbus: what the audio side needs from the board DT and the load list

2026-11-18, audio agent. OFFLINE: nothing here was loaded on a phone by this work. Evidence from
the realboot agent's own boots is quoted with its log path. I did not edit the board DT or
`drivers612/realboot/build-realboot.sh`.

State of the other side when this was written: `build-realboot.sh` already has `BTSLIM=1`
(lines 380-393 and 690-696: the four modules after stage wlanb, `fdtput qcom,wcn-btfm 1`), and
rb44 was built and booted with it. So most of the list below already exists; the points that
are new for that side are marked **NEW**.

## 1. Audio modules to take

`drivers612/audio/audio-kernel/asoc/machine_dlkm.ko` and `asoc/platform_dlkm.ko` (built
2026-11-18 21:01 / 20:56, vermagic `6.12.81-4k-g8a69376da734`). Details: `PARITY-FIXES.md`.

**NEW: meaning of `qcom,wcn-btfm` changed** in this `machine_dlkm.ko`:

| Sound node | Old machine_dlkm (s88 and earlier) | New machine_dlkm |
|---|---|---|
| no `qcom,wcn-btfm` | no BT back end | no BT back end |
| `qcom,wcn-btfm;` (empty) | no BT back end (u32 read fails) | SLIMBUS_7_RX + SLIMBUS_7_TX (the 5.4 set) |
| `qcom,wcn-btfm = <1>;` | SLIMBUS_7_RX/TX + SLIMBUS_8_TX | SLIMBUS_7_RX + SLIMBUS_7_TX (the 5.4 set) |
| `qcom,wcn-btfm = <2>;` | as `<1>` | SLIMBUS_7_RX/TX + SLIMBUS_8_TX (Qualcomm's table, FM capture) |

`BTSLIM=1` writes `<1>`: that keeps working and now gives exactly what 5.4 has. Only the
`say` text at build-realboot.sh:695 ("+ SLIMBUS_8_TX") is no longer true with the new module.
Use `<2>` only if the old 3-link behaviour is wanted.
dmesg marker of the new module: `populate_snd_card_dailinks: wcn btfm back ends: mode 1`.

## 2. DT (exact change against the 6.12 base `bsp612/devicetree/qcom/yupik.dtsi`)

Sound node `/soc/qcom,msm-audio-apr/qcom,q6core-audio/sound`:

    qcom,wcn-btfm;          /* or = <1>; both select the 5.4 back ends */

Leave `qcom,wcn-bt = <1>` as it is (ignored by the driver on purpose). Already present and
needed, do not remove: `asoc-cpu` / `asoc-cpu-names` entries `msm-dai-q6-dev.16398` (sb_7_rx),
`.16399` (sb_7_tx) (and `.16401` sb_8_tx for mode 2), nodes
`/soc/qcom,msm-dai-q6/qcom,msm-dai-q6-sb-7-rx`, `-sb-7-tx`, `-sb-8-tx`.

SLIMbus controller + BT slave (this is `drivers612/conn/bt/bt-node.dtsi:130-143`; the base has
`slim_msm` with `status = "disabled"` and no child):

    &slim_msm {                         /* /soc/slim@3ac0000, qcom,slim-ngd-v1.5.0 */
        status = "ok";
        ngd@1 {
            reg = <1>;
            #address-cells = <1>;
            #size-cells = <1>;
            btfmslim_codec: btfmslim-driver {
                compatible = "slim217,221";     /* manufacturer 0x217, product 0x221 */
                reg = <1 0>;                    /* device index 1 (PGD), instance 0 */
            };
        };
    };

BAM DMA controller the ngd takes its `dmas` from (`<&slimbam 3>, <&slimbam 4>`): the base node
`slimbam: dma-controller@3a84000` (`qcom,bam-v1.7.0`, `qcom,controlled-remotely`,
`num-channels = <31>`, `qcom,ee = <1>`, `qcom,num-ees = <2>`, `iommus = <&apps_smmu 0x1826 0x0>`)
must stay enabled; no property change needed.

Check of a built tree (rb44's merged tree decompiled): `/soc/slim@3ac0000` status ok with
`qcom,wait_for_adsp_up`, `ngd@1/btfmslim-driver` `compatible = "slim217,221"`,
`/soc/dma-controller@3a84000` without a status property, sound node `qcom,wcn-btfm = <0x01>`.
That matches this list.

Open DT point (not audio): `qcom,ea-pc`. 5.4 `slim@3ac0000` had `qcom,ea-pc = <0x3e0>`; the 6.12
yupik node has none (see the comment in bt-node.dtsi). Decide on hardware.

## 3. Module load order

    rfkill -> btpower                      (bt_fm_slim depends on btpower: btpower_register_slimdev)
    bam_dma                                (DMA provider of the ngd; without it: "Failed to request RX dma channel")
    slimbus
    slim-qcom-ngd-ctrl
    bt_fm_slim                             (depends: slimbus, btpower; alias slim:217:221:*)
    ... snd_event, apr, adsp_loader, q6, platform_dlkm, codecs ...
    machine_dlkm                           (after bt_fm_slim)

rb44's `first-stage.modules.load` has exactly this (lines 197, 205-209; machine_dlkm is in the
late audio stage). The order between bt_fm_slim and machine_dlkm is not a hard requirement
(the card defers until the codec exists), but bt_fm_slim must get loaded and its probe must
succeed.

Why the codec is there at probe time: `btfm_slim_probe` sets `is_laddr_valid`, so the slimbus
core reports the device UP right after probe (`core.c slim_device_probe`) and
`btfm_slim_status` calls `btfm_slim_register_codec` without the BT chip being powered. Seen
in `logs/verify-rb44-boot1-205242/dmesg.txt` 4.163 s: `btfm_slim_probe: name = 217:221:1:0`,
`name = btfmslim_slave`, `probe of btfmslim_slave returned 0`.

## 4. Names (settled, no change needed)

Component name is **`btfmslim_slave`** (the Kbuild passes `-DCONFIG_BTFM_SLIM`, so
`BTFMSLIM_DEV_NAME` is `"btfmslim_slave"`), DAIs `btfm_bt_sco_a2dp_slim_rx`,
`btfm_bt_sco_slim_tx`, `btfm_fm_slim_tx`, `btfm_bt_split_a2dp_slim_rx`. The dai-links in
`asoc/msm_dailink.h:906-919` already use these. Do NOT rename the codec to `btfmslim` (the
parity report and `conn/bt/STATUS.md` "Open / next" say so; that is wrong for this build). If
`bt_fm_slim` is ever rebuilt without `-DCONFIG_BTFM_SLIM`, the name becomes `btfmslim`, the
codec is no longer registered through ASoC, and the links must change with it.

## 5. Hazard

With `qcom,wcn-btfm` set, the sound card registers only when the component `btfmslim_slave`
exists. If bt_fm_slim is missing or its probe fails (btpower not loaded, slim device not
created because slim-qcom-ngd-ctrl or bam_dma is missing), the card defers for ever:
**no audio at all**. Check after every such build (test phone, pinned serial):
`adb -s <serial> shell cat /proc/asound/cards` and
`adb -s <serial> shell cat /sys/kernel/debug/devices_deferred`.

## 6. To verify on a phone

All commands on a test phone with `adb -s <serial>`.

1. `dmesg | grep -E 'btfm_slim_probe|wcn btfm back ends|slim'`; card present; deferred list empty.
2. rb44 boot 1 has `qcom,slim-ngd-ctrl 3ac0000.slim: QMI wait timeout` at 7.56 s (before the
   ADSP is up) and `qcom_slim_ngd_runtime_resume QMI handle is NULL` at 4.16 s. Check that the
   ngd comes up once the ADSP runs (`dmesg | grep -iE 'slim.*(qmi|ssr|up|capab)'`) and that the
   first SCO stream does not fail in `btfm_slim_hw_init` / `slim_stream_*`.
3. BT call (HFP) with a headset: audio in both directions; the mixer controls listed in
   `PARITY-FIXES.md` section 2 exist.
4. Framework stop + start with this set loaded (the open "silent reset after framework stop"
   bug of 19:43 is in the same area: audio HAL restart).
