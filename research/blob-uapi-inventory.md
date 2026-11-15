# a52sxq vendor-blob kernel UAPI inventory

Date: 2026-11-11. Scope: which kernel interfaces the closed vendor userspace on the Galaxy A52s 5G
(a52sxq, SM7325) depends on, so that drivers forward-ported to ACK `android17-6.18` can present
the same interfaces.

## 0. How this was produced, and how to read it

Evidence tags used below:

- **[live]** read from the running phone `DAILYPHONE` (IchthysOS, kernel `5.4.302-qgki #35`, root via
  `su`). Read-only commands only: `lsmod`, `cat /proc/devices`, `/proc/misc`, `ls -lZ /dev`,
  `ls /sys/class/...`, `ls -l /proc/<pid>/fd`, `grep /proc/<pid>/maps`, `/proc/net/{netlink,unix}`,
  `dmesg`.
- **[strings]** `strings -a -n 5` over every `.so` and `bin/*` in the two blob trees, filtered for
  `/dev/ /sys/ /proc/ /d/ /efs/` paths (script `blob-uapi-evidence/scan.sh`, result
  `blob-uapi-evidence/paths.tsv`, grouped in `byfile.txt`). A string in a binary proves the code
  knows the path, not that it uses it on this phone.
- **[src]** the 5.4 kernel tree `$ANDROID_TREE/kernel/samsung/sm7325` (paths below are relative to
  it) and the ROM device trees.
- **[inference]** my conclusion, not directly observed.

"Closed" vs "open" was decided per file: a binary or library is **closed** if it exists in
`vendor/samsung/{a52sxq,sm7325-common}/proprietary` (list: `blob-uapi-evidence/bloblist.txt`, 1,115
files); otherwise the ROM builds it from source. Per running HAL process, the loaded libraries were
split the same way (`blob-uapi-evidence/proc_libs.txt`, from `/proc/<pid>/maps`).

Ioctl counts are `grep -cE '_IO(R|W|WR)?\('` on the UAPI header unless stated.

Raw evidence is saved in `research/blob-uapi-evidence/`.

Verdict column values:
- **KEEP** = must keep UAPI byte-identical (closed consumer).
- **OPEN** = consumer is open source in the ROM tree; userspace can be adapted.
- **UNUSED** = present in the kernel or named in a blob, but nothing uses it on this phone.

### Facts that shape everything else

1. **There are no closed kernel modules.** `find vendor/samsung/*/proprietary -name '*.ko'` returns
   nothing. All 87 modules in `/vendor/lib/modules` are built from the kernel tree (section 15).
   `techpack/datarmnet-ext` (rmnet_shs, rmnet_offload) is in source form but obfuscated
   (identifiers like `DATARMNETecc643c219`).
2. **debugfs is not mounted** [live: `ls /sys/kernel/debug` → "No such file or directory", no debugfs
   line in `mount`]. Every `/sys/kernel/debug/...` and `/d/...` string in the blobs is dead on this
   phone. No debugfs interface needs porting for the blobs.
3. **The phone uses legacy ION only.** `/dev/ion` is misc minor 127; there is no `/dev/dma_heap`
   [live]. Every closed consumer that allocates memory goes through `/dev/ion`.
4. **Remote processors are loaded by the downstream PIL/subsystem-restart framework**, not
   remoteproc: `/sys/class/remoteproc` is empty, `/sys/bus/msm_subsys/devices/subsys0..6` and
   `/dev/subsys_*` exist [live]. Closed code opens `/dev/subsys_*` and reads
   `/sys/bus/msm_subsys/devices` (section 6).
5. **No IPA userspace runs.** There is no `ipacm`, `netmgrd`, `qmuxd`, `port-bridge` or `qti`
   binary in `/vendor/bin` [live `ls /vendor/bin`]; only `ipacm-diag`. Samsung's `rild` does data
   call setup itself. The 104 + 23 IPA ioctls have no userspace caller on this phone (section 6).

---

## 1. Camera (CamX / CHI, Samsung unihal)

**Consumer.** `android.hardware.camera.provider-service.samsung` is built from source but loads
143 closed libraries [live maps], including `camera.qcom.so`, `com.qti.chi.override.so`,
`camera.unihal.default.so`, `unihal_main@2.15.so`, `libcamxstatscore.so`, sensor modules
`com.samsung.sensor.{s5kgw1p,imx616,s5k3l6,gc5035,gc5035_macro}.so`, `com.samsung.ois.mcu_stm32g.so`,
`libsynx.so`, `libcdsprpc.so`, `libgsl.so`, `libcvp2_1.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/video0` (name `cam-req-mgr`) | [live fd], v4l name from `/sys/class/video4linux/*/name` | `techpack/camera/drivers/cam_req_mgr/cam_req_mgr_dev.c` | `techpack/camera/include/uapi/camera/media/cam_req_mgr.h`, `cam_defs.h` | KEEP |
| `/dev/video1` (`cam_sync`) | [live fd] | `techpack/camera/drivers/cam_sync/` | `cam_sync.h` (1 private ioctl, `struct cam_private_ioctl_arg`, sync opcodes, 2 V4L2 private events) | KEEP |
| `/dev/v4l-subdev0..23` — all 24 held open | [live fd] names: cam-cpas, cam-isp, 5× cam-csiphy-driver, cam-actuator-driver, 6× cam-sensor-driver, 5× cam-eeprom, cam-flash-dev, cam-icp, cam-jpeg, cam-lrme, cam-ois | `techpack/camera/drivers/{cam_cpas,cam_isp,cam_sensor_module/*,cam_icp,cam_jpeg,cam_lrme}` | `cam_cpas.h cam_isp.h cam_isp_ife.h cam_isp_vfe.h cam_sensor.h cam_icp.h cam_jpeg.h cam_lrme.h` (+ `cam_ope.h cam_tfe.h cam_fd.h cam_custom.h cam_isp_sfe.h cam_isp_tfe.h` present, no device node on this phone) | KEEP |
| `/dev/media0`, `/dev/media1` | [strings] `camera.qcom.so`: `/dev/media%d`, `/dev/%s`; nodes exist [live], not held open (enumeration at start) [inference] | media controller core + cam_req_mgr / cam_sync entities | `linux/media.h`; entity function IDs in the cam headers | KEEP |
| `/dev/ion` (2 fds) | [live fd] | section 12 | section 12 | KEEP |
| `/sys/class/camera/{rear,front,flash,ois,af,ssm,dual}/*` (154 attributes on the phone) | [strings] `camera.qcom.so`, `com.qti.chi.override.so`, `unihal_main@2.15.so`, `com.samsung.node.uniplugin_*.so`; [live] directory listing | `techpack/camera/drivers/cam_sensor_module/cam_sensor_utils/cam_sysfs_init.c` (Samsung) | sysfs, names listed in `byfile.txt` lines for those libraries | KEEP |
| `/sys/class/sec/ufs/sec_wb_enable`, `/sys/kernel/mm/vmscan/mem_boost_mode` | [strings] `com.qti.chi.override.so` | `drivers/scsi/ufs/ufs-qcom.c`, `mm/vmscan.c` (Samsung additions) | sysfs | KEEP (best effort; inference: failure to open is tolerated) |
| `/sys/devices/soc0/soc_id`, `/sys/firmware/devicetree/base/memory/ddr_device_{type,rank_ch0}` | [strings] camera.qcom.so and 27 `com.qti.feature2.*.so` | `drivers/soc/qcom/socinfo.c`; DT property filled by the bootloader | sysfs / DT | KEEP (soc_id value must stay 475-family "yupik" value; inference) |
| `/efs/FactoryApp/camera_ois_gyro_cal`, `camera_tilt_calibration_info_1_4`, `/mnt/vendor/efs/camera/...` | [strings] `camera.qcom.so` | filesystem only | — | KEEP (files) |
| 1 socket of unknown family in the provider | [live; not unix/netlink/inet → inference: AF_QIPCRTR, via `libqmi_cci.so`/`libsnsapi.so` for gyro from SSC] | `net/qrtr` | `linux/qrtr.h` | KEEP |
| `/dev/synx_device` | node exists (major 504) [live]; `libsynx.so` loaded; **not open** in the snapshot | `drivers/media/platform/msm/synx/` | `include/uapi/media/synx.h` (1 ioctl, multiplexed) | KEEP (inference: opened on demand) |
| `/dev/cvp`, `/dev/video34`, `/dev/video37` | [strings] `libcvp2_1.so`, `libcvpcpuRev_skel.so`; **nodes do not exist** [live `/dev` listing] | `drivers/media/platform/msm/cvp/` | — | UNUSED on this phone |

**UAPI size.** One ioctl, `VIDIOC_CAM_CONTROL = _IOWR('V', BASE_VIDIOC_PRIVATE, struct cam_control)`,
multiplexes everything: 69 opcode `#define`s, 181 structs, 4,855 lines across 17 headers
(`techpack/camera/include/uapi/camera/media/`). The payloads are versioned packets
(`cam_packet`, command buffers, generic blobs) whose inner layout is defined partly in those
headers and partly only in CamX (register-level ISP/IPE/BPS blobs passed through to the hardware
or to the ICP firmware). `cam_req_mgr` also allocates and maps buffers for userspace
(`CAM_REQ_MGR_ALLOC_BUF`/`MAP_BUF`), calling `ion_alloc()` in the kernel
(`cam_req_mgr/cam_mem_mgr.c:474,504`), so the camera driver itself needs the ION compat layer.

**Kernel module.** `camera.ko` (8.4 MB, loaded, 26 users) [live lsmod].

**Firmware.** `CAMERA_ICP_170.elf` (loaded at boot: dmesg `cam_a5_download_fw: Downloading firmware
CAMERA_ICP_170.elf`), `CAMERA_ICP.elf` shipped but not requested; `ois_mcu_stm32g_fw.bin` (dmesg
`cam_ois_read_phone_ver: OIS FW : ois_mcu_stm32g_fw.bin`). All in `vendor/firmware/` of the a52sxq
blob tree.

---

## 2. Display (SDE DRM, composer, gralloc, colour)

**Consumers.**
- `vendor.qti.hardware.display.composer-service`: binary and `libsdmcore.so`, `libsdedrm.so`,
  `libdrmutils.so`, `libsdmutils.so`, `libgralloc*.so` are **open** (`hardware/qcom-caf/sm8350/display`).
  It loads 22 **closed** libraries: `libsdmextension.so`, `libsdm-color.so`,
  `libsdm-colormgr-algo.so`, `libsnapdragoncolor-manager.so`, `libdpps.so`, `libqseed3.so`,
  `libhdr_tm.so`, `libdisp-aba.so`, `libdisplayqos.so`, `libdisplayskuutils.so`, `librcmask.so`,
  `libgsl.so`, `libadreno_utils.so` and others [live maps].
- `vendor.qti.hardware.display.allocator-service` (gralloc): open, plus closed `libgsl.so`,
  `libadreno_utils.so`.
- `vendor.display.color@1.0-service`: closed binary; holds no device node [live fd].
- `vendor.lineage.livedisplay-service.samsung-qcom`, Samsung lights/display init scripts: open.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/dri/card0` (6 fds), `anon_inode:sync_file` (10) | [live fd] composer | `techpack/display/msm/` (msm_drv.c, sde/*, dsi/*) | `include/uapi/drm/msm_drm.h` (11 `DRM_IOCTL_MSM_*`), `techpack/display/include/uapi/display/drm/sde_drm.h` (6: `SDE_WB_CONFIG`, `MSM_REGISTER_EVENT`, `MSM_DEREGISTER_EVENT`, `MSM_RMFB2`, `MSM_POWER_CTRL`, `MSM_DISPLAY_HINT`; 20 structs), `msm_drm_pp.h` (27 structs for colour blobs: PCC, GAMUT, IGC, PGC, dither, LTM, AD4, RC mask, …) | **KEEP** in practice: the caller of the ioctls is open, but the closed libraries generate the property blob contents (`msm_drm_pp.h` structs, QSEED3 scaler config in `sde_drm.h`) and read the SDE capability text blobs. Inference from library names + open `libsdedrm` source; not disassembled. |
| DRM atomic custom properties and "capabilities" info blobs (plane/crtc/connector) | [src] open `libsdedrm`; consumed by closed `libsdmextension.so` (strategy, resource limits) [inference] | `techpack/display/msm/sde/sde_{crtc,plane,connector,kms}.c` | property names + key=value text; not in a header | KEEP |
| `/dev/ion` (1 fd), 55 dmabuf fds | [live fd] composer; [strings] `libdpps.so`: `/dev/ion` | section 12 | section 12 | KEEP |
| `/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/backlight/panel0-backlight/brightness` | [live fd] composer; [strings] `libdpps.so` `/sys/class/backlight/panel0-backlight/` | `techpack/display/msm/sde/sde_connector.c` (backlight device) | sysfs | KEEP (path incl. `ae00000.qcom,mdss_mdp` is what is opened; `/sys/class/backlight/panel0-backlight` symlink is what the blob names) |
| uevent netlink (protocol 15) | [live `/proc/net/netlink`] composer pid | DRM hotplug / panel-dead uevents | uevent strings | OPEN (parsed in open code) |
| 1 socket of unknown family in composer | [live → inference: AF_QIPCRTR via closed `libqrtr.so`/`libqrtrclient.so` for `libdisplayqos`] | `net/qrtr` | `linux/qrtr.h` | KEEP |
| `/sys/class/drm/card0/device/power/control` | [strings] `libops.so` (loaded by qseecomd) | driver core | sysfs | KEEP (trivial) |
| `/sys/class/drm/card0-DSI-1/modes`, `/sys/class/graphics/fb0/modes` | [strings] `libperfconfig.so` | DRM connector sysfs | sysfs | KEEP (connector must be named `DSI-1`) |
| `/sys/devices/platform/soc/soc:qfprom@0/`, `/sys/class/uio` | [strings] `libdisplayskuutils.so` | `drivers/nvmem/qfprom.c` | sysfs/nvmem | KEEP (inference: SKU feature detection; failure path unknown) |
| `/sys/class/lcd/panel/*` (95 attrs), `/sys/class/mdnie/mdnie/*`, `/sys/class/backlight/panel/*` | [live]; users: init scripts (`init.samsung.display.rc`: 115 lines touching `/sys/class/lcd/panel`), open livedisplay HAL (`hardware/samsung/hidl/livedisplay`), open fingerprint HAL (`mask_brightness`, `fp_green_circle`), closed `libbauthserver.so` (`/sys/class/lcd/panel`), closed `libsec-ril.so` (`/sys/class/lcd/panel/mipi_switch`) | `techpack/display/msm/samsung/ss_dsi_panel_sysfs.c`, `ss_dsi_mdnie_lite_common.c` | sysfs | mostly OPEN; **KEEP** for the directory `/sys/class/lcd/panel` (closed fingerprint lib) |
| `/dev/self_display`, `/dev/sec_display_debug` (misc 112, 113) | [live] nodes exist, owner system; no process had them open | `techpack/display/msm/samsung/SELF_DISPLAY/self_display_FC3.c` (9 ioctls in `self_display.h`), `ss_dsi_panel_debug.c` | — | UNUSED by blobs here (AOD self-display is a One UI framework feature) [inference] |
| `/dev/msm_hdcp` (major 497), `/sys/class/hdcp` | [live] node exists; no user found | `techpack/display/hdcp/msm_hdcp.c` | UAPI header not located (not checked further) | UNUSED (no DP/HDMI HDCP daemon runs) |

**Kernel modules.** Display is built in (no `msm_drm` in lsmod). `hdmi_dlkm` loaded (audio side).

**Firmware.** None via `request_firmware` for the panel (panel data is in the DT). Colour data in
`/mnt/vendor/persist/display`, `/vendor/etc` (userspace files).

---

## 3. GPU (KGSL + Adreno 642L userspace)

**Consumers.** Closed `libgsl.so` (loaded into surfaceflinger, every app, allocator, composer,
camera provider), `libGLESv2_adreno.so`, `vulkan.adreno.so`, `libllvm-qcom.so`, `libadreno_utils.so`,
`libCB.so` (OpenCL), `libgpudataproducer.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/kgsl-3d0` | [live fd] surfaceflinger + apps; [strings] `libgsl.so` | `drivers/gpu/msm/kgsl.c`, `kgsl_ioctl.c`, `adreno_ioctl.c`, `kgsl_sync.c`, `kgsl_timeline.c` | `include/uapi/linux/msm_kgsl.h` — **62 ioctls** (`IOCTL_KGSL_*`), incl. GPU objects, sparse/VBO, timelines, sync sources, perfcounters, 32-bit compat (`kgsl_compat.c`; the phone runs 32-bit apps) | KEEP |
| `/dev/ion` | [strings] `libgsl.so` | section 12 | | KEEP |
| `/sys/class/kgsl/kgsl-3d0/*` (58 attrs): `gpu_model`, `gpuclk`, `max_gpuclk`, `gpu_available_frequencies`, `snapshot`, `devfreq/*`, `force_clk_on`, `force_no_nap`, `force_rail_on`, `idle_timer`, `default_pwrlevel`, `min/max_pwrlevel` | [strings] `libadreno_utils.so`, `libgsl.so`, `libsdmextension.so`, `libqti-perfd.so`, `thermal-engine`, perf XML | `drivers/gpu/msm/adreno_sysfs.c`, `kgsl_pwrctrl.c`, `kgsl_pwrscale.c` | sysfs | KEEP (`gpu_model` read by gralloc path via `libadreno_utils`; the rest is tuning) |
| `/sys/class/kgsl/kgsl/proc/%d/state` | perf XML | `kgsl_sharedmem.c` | sysfs | KEEP (optional) |
| `/sys/kernel/gpu/*` (9 attrs) | [live]; users: Samsung open scripts/HALs | Samsung addition in `drivers/gpu/msm` | sysfs | OPEN |
| `/sys/devices/system/cpu/{online,present}`, `cpu%d/cpu_capacity`, `cpufreq/cpuinfo_max_freq`, `/sys/class/power_supply/battery/{current_now,voltage_now}` | [strings] `libGLESv2_adreno.so`, `vulkan.adreno.so` | generic | sysfs | KEEP (generic, exists upstream except battery naming → section 10) |
| `/sys/kernel/debug/kgsl/proc/%d/mem`, `/sys/kernel/debug/clk/gfx3d_clk_src_v2/rate` | [strings] | — | debugfs | UNUSED (debugfs not mounted) |
| `/dev/kgsl-2d0`, `/dev/kgsl-2d1` | [strings] only; nodes absent | — | — | UNUSED |

**Kernel modules.** KGSL built in. `subsys_a660_zap` (PIL) loads the zap shader.

**Firmware.** `a660_sqe.fw`, `a660_gmu.bin` (blob tree `vendor/firmware/`), `a660_zap.{mdt,b*}` from
the firmware partition (`/vendor/firmware_mnt/image`), loaded through PIL (dmesg: `subsys-pil-tz
soc:qcom,kgsl-hyp: a660_zap: Brought out of reset`).

---

## 4. Audio (ADSP + Samsung audio HAL)

**Consumer.** `android.hardware.audio.service` is open, but the primary HAL
**`audio.primary.lahaina.so` is closed (Samsung)**, with 26 more closed libraries: `libacdbloader.so`,
`libacdbrtac.so`, `libadiertac.so`, `libaudcal.so`, `libacdb-fts.so`, `libadm.so`,
`libsndmonitor.so`, `libspeakercalibration.so`, `libaudio_soundtrigger.so`, `libhfp.so`,
`liba2dpoffload.so`, `libbthost_if.so`, `libsecaudioinfo.so`, SoundAlive/recording libs [live maps].
`libtinyalsa.so`, `libtinycompress.so`, `libaudioroute.so` are open.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| ALSA card 0 `lahaina-yupikidp-snd-card`: `/dev/snd/controlC0` (2 fds), ~60 PCM devices, 7 compress devices (`comprC0D{7,11,25,26,27,28,37}`) | [live fd, `ls /dev/snd`, `/proc/asound/cards`] | `techpack/audio/asoc/` (`lahaina.c` machine, `msm-pcm-routing-v2.c`, `msm-pcm-q6-v2.c`, `msm-compress-q6-v2.c`, …) | Standard ALSA ioctls + **mixer control names/enums** + PCM device numbering + `techpack/audio/include/uapi/audio/sound/{devdep_params.h (17), audio_effects.h, audio_compressed_formats.h, voice_params.h}` | **KEEP**: the closed HAL addresses controls by name and PCM/compress devices by number (inference from it being a tinyalsa client; the device-number table is in the closed HAL and in `/vendor/etc/audio_platform_info*.xml`). The mixer-path XMLs are editable, the names compiled into the HAL are not. |
| `/dev/snd/hwC0D1000` (hwdep "Codec w…") | [live fd; `/proc/asound/hwdep`] | `techpack/audio/asoc/codecs/` (wcd938x/bolero hwdep cal) | `sound/msmcal-hwdep.h` (2 ioctls) | KEEP |
| `/dev/snd/hwC0D3013`, `hwC0D3029` | [live nodes] hwdep for LSM/sound-trigger [inference]; [strings] `sound_trigger.primary.lahaina.so` `/dev/snd/hwC%uD%u` | `techpack/audio/asoc/msm-lsm-client.c` | `sound/lsm_params.h` (20 ioctls) | KEEP |
| `/dev/msm_audio_cal` (misc 109) | [live fd]; [strings] `libacdbloader.so`, `libspkrprot.so` | `techpack/audio/dsp/audio_calibration.c`, `audio_cal_utils.c` | `linux/msm_audio_calibration.h` (18 ioctls; cal blocks carry ION fds) | KEEP |
| `/dev/msm_rtac` (misc 108) | [live fd]; [strings] `libacdbrtac.so` | `techpack/audio/dsp/rtac.c` | ioctls in `linux/msm_audio.h` / rtac section | KEEP |
| `/dev/ion` (1 fd) + 27 dmabufs | [live fd] | `techpack/audio/dsp/msm_audio_ion.c` (kernel side) | section 12 | KEEP |
| `/proc/asound/card0/state`, `/proc/asound/cards`, `card%s/cpe0_state`, `/proc/asound/card%d/codecs/{wcd938x,wcd937x}/variant`, `/proc/asound/pcm` | [live fd `card0/state`]; [strings] `libsndmonitor.so`, `audio.primary.lahaina.so`, `libadm.so` | `techpack/audio/asoc/msm-audio-*`, codec info entries (`snd_info_create_*`) | procfs text | KEEP |
| uevents (`SWITCH_STATE`, snd card online/offline) | [strings] libsndmonitor (inotify + proc) | `techpack/audio/soc/snd_event.c` | — | KEEP |
| `/dev/msm_{aac,mp3,amrnb,amrwb,amrwbplus,evrc,qcelp,wma,wmapro,alac,ape,g711*,multi_aac}[_in]`, `/dev/msm_hweffects` (misc 85–106) | [live nodes]; **no process holds them**; listed in ueventd | `techpack/audio/dsp/codecs/*.c` | `linux/msm_audio.h` (64–74 ioctls) + 13 per-codec headers | UNUSED at runtime in the snapshot. Inference: legacy tunnel/NT decode path; the HAL uses compress-offload instead. Not proven for every use case (VoIP, FM, voice memo). |
| `/dev/tas256x`, `/dev/tas_calib` (misc 107, 84), `/sys/class/tas25xx/*`, `/efs/tas25xx/*` | [live nodes, root-only]; [strings] `libspeakercalibration.so` (`/efs/tas25xx/calib_re`, …) | `techpack/audio/asoc/codecs/tas256x/` | driver-private | KEEP for the sysfs/efs calibration path; char nodes unused by blobs [inference: permissions root:root 0600] |
| `/sys/class/audio/{amp,codec,earjack}/*` | [live]; [strings] Samsung thermal HAL (`/sys/class/audio/amp/curr_temperature_1`), init scripts | `sound/soc/samsung/sec_audio_sysfs.c` + `techpack/audio/asoc/sec_wcd_sysfs_cb.c`, `codecs/tas256x/bigdata_tas_sysfs_cb.c` | sysfs | KEEP (thermal HAL is closed) |
| `/dev/btfmslim` (major 482) | [strings] `libbthost_if.so` | `drivers/bluetooth/btfm_slim.c` | 0 ioctls in header (driver-private cmds) | KEEP (BT SCO/A2DP over SLIMbus) |
| `/dev/wcd_dsp0_control`, `/dev/wcd-dsp-glink`, `/dev/msm_cirrus_playback`, `/sys/class/cirrus/*`, `/sys/class/dsm/*`, `/sys/class/nxp/*`, `/sys/class/richtek_spm/*` | [strings] only; nodes absent | — | — | UNUSED (other amp/codec vendors) |
| `/sys/kernel/boot_adsp/{boot,ssr}`, `/sys/kernel/boot_cdsp/boot` | [live]; written by `init.qcom.rc`; `ssr` named in closed `libssc.so` | `techpack/audio/dsp/adsp-loader.c`, `cdsp-loader.c` | sysfs | KEEP |
| `/dev/apr_apps2` (glinkpkt) | [live node, root:root] | `drivers/soc/qcom/glink_pkt.c` | read/write | UNUSED by blobs [inference] |

**Kernel modules (all loaded).** `q6_dlkm`, `apr_dlkm`, `adsp_loader_dlkm`, `q6_notifier_dlkm`,
`q6_pdr_dlkm`, `snd_event_dlkm`, `platform_dlkm`, `native_dlkm`, `stub_dlkm`, `machine_dlkm`,
`bolero_cdc_dlkm`, `rx_macro_dlkm`, `tx_macro_dlkm`, `va_macro_dlkm`, `wcd_core_dlkm`,
`wcd9xxx_dlkm`, `wcd938x_dlkm`, `wcd938x_slave_dlkm`, `mbhc_dlkm`, `swr_dlkm`, `swr_ctrl_dlkm`,
`swr_dmic_dlkm`, `pinctrl_lpi_dlkm`, `pinctrl_wcd_dlkm`, `hdmi_dlkm`, `tas256x_dlkm`,
`sec_audio_sysfs`, `slimbus`, `slimbus_ngd`, `bt_fm_slim`.

**Firmware.** `adsp.{mdt,b*}` + `adspr.jsn`, `adsps.jsn`, `adspua.jsn` (firmware partition), ADSP
dynamic modules in `/vendor/firmware_mnt/image/*.so.1` and `/vendor/dsp` (partition `dsp`, loaded
by the DSP through `adsprpcd`), ACDB files in `/vendor/etc/acdbdata`, `dax_param.bin` (blob tree).

---

## 5. Sensors (SSC on the ADSP)

**Consumer.** `android.hardware.sensors-service.samsung-multihal` (open wrapper,
`hardware/samsung/sensors`) loads closed `sensors.ssc.so`, `sensors.grip.so`, `libssc.so`,
`libsnsapi.so`, `libsns_fastRPC_util.so`, `libqmi_cci.so`. Also closed: `sscrpcd`, `factory.ssc`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| 3 sockets of unknown family in the HAL, 2 in `factory.ssc` | [live → inference AF_QIPCRTR; `factory_ssc.te` has `allow factory_ssc self:qipcrtr_socket`] | `net/qrtr/` (+ `qrtr-ns` userspace name service, closed binary) | `linux/qrtr.h`; QMI "sns client" service over it | KEEP (socket family + address format; upstream QRTR has the same `sockaddr_qrtr`, but upstream moved the name service into the kernel — the closed `qrtr-ns` then conflicts; see section 6) |
| `/dev/adsprpc-smd-secure` + `/dev/ion` in `sscrpcd` | [live fd] | `drivers/char/adsprpc.c` | `drivers/char/adsprpc_shared.h` + `include/uapi/linux/fastrpc.h` (20 `FASTRPC_IOCTL_*`) | KEEP |
| `/sys/class/sensors/ssc_core/{operation_mode,sbm_init,ssr_reset,ar_mode,lcd_onoff,abs_lcd_onoff,remove_sysfs}`, `light_sensor/{brightness,lcd_onoff,boled_enable,hallic_info}`, `barometer_sensor/calibration`, `grip_sensor/{motion,grip_register_recover,…}`, `sensor_dev/flush` | [strings] `sensors.ssc.so`, `sensors.grip.so`; [live] `/sys/class/sensors` = accelerometer, flip_cover_detector, grip, gyro, light, magnetic, sensor_dev, ssc_core | `drivers/adsp_factory/{adsp_factory.c,ssc_core.c,*}`, `drivers/sensors/sensors_core.c`, `sx9360.c` | sysfs | KEEP |
| Netlink protocol 23 `NETLINK_ADSP_FAC` | [live `/proc/net/netlink`: `factory.ssc`]; [src] `include/linux/adsp/adsp_ft_common.h:19` | `drivers/adsp_factory/adsp_factory.c:356` | driver-private message structs | KEEP |
| `/dev/input/event{1,2,3,5,7}` = `meta_event`, `grip_sensor`, `grip_notifier`, `hall`, `sec_touchproximity` | [live fd + `/proc/bus/input/devices`] | `drivers/sensors/sensors_core.c` (meta_event), `sx9360.c`, `drivers/input/misc/hall/hall_ic.c`, `drivers/input/sec_input/stm/` | evdev; device **names** and event codes | KEEP (`sensors.grip.so` scans `/dev/input` and `/sys/class/input/` by name) |
| `/sys/class/sensor_event/symlink/`, `/sys/bus/iio/devices/`, `/dev/iio:device%d` | [strings] `sensors.grip.so`; `/dev/iio:device0` exists | `drivers/sensors/sensors_core.c` | sysfs | KEEP |
| `/sys/class/sec/tsp/{cmd,ear_detect_enable}`, `…/input6/fod_pressed` (held open) | [strings] `sensors.grip.so`; [live fd] | `drivers/input/sec_input/stm/stm_{core,fn,cmd}.c`, `sec_cmd.c` | sysfs (`cmd` is a text command protocol) | KEEP |
| `/sys/devices/virtual/sec/hall_ic/{hall_detect,certify_hall_detect}` | [strings] `sensors.grip.so` | `drivers/input/misc/hall/hall_ic.c` | sysfs | KEEP |
| `/sys/kernel/boot_slpi`, `/sys/kernel/boot_adsp/ssr` | [strings] `sscrpcd`, `libssc.so`, `libsns_fastRPC_util.so`; `boot_slpi` absent on the phone | `techpack/audio/dsp/adsp-loader.c` | sysfs | KEEP (`boot_adsp/ssr`); UNUSED (`boot_slpi`) |
| `/efs/FactoryApp/baro_delta`, `baro_sw_offset`; `/mnt/vendor/persist/sensors/` | [strings] | files | — | KEEP (files) |
| `/sys/power/wake_lock`, `wake_unlock` | [live fd] | `kernel/power/` (CONFIG_PM_WAKELOCKS) | sysfs | KEEP (exists in ACK) |

**Kernel modules.** adsp_factory and sensors core are built in. No sensor `.ko`.

**Firmware.** Sensor drivers live inside the ADSP image (`adsp.*`); registry/config JSON in
`/vendor/etc/sensors/config` and `/mnt/vendor/persist/sensors/registry` (read by the DSP via
`sscrpcd` remote file system).

---

## 6. Modem, RIL, IPA, rmnet, QRTR, remote-processor plumbing

**Consumers (all closed):** `rild` + `libsec-ril.so` (Samsung), `libril_sem.so`, `qrtr-ns`,
`pd-mapper`, `pm-service`, `pm-proxy`, `rmt_storage`, `tftp_server`, `time_daemon`, `ipacm-diag`,
`libmdmdetect.so`, `libqmi_cci.so`, `libqrtr.so`. Open: `sehradiomanager`, `librmnetctl.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| **AF_QIPCRTR sockets**: rild 122, tftp_server 12, gnss HAL 5, thermal-engine 3, xtra-daemon 3, cnss-daemon 3, time_daemon 2, factory.ssc 2, qrtr-ns 1, pd-mapper 1, pm-service 1, rmt_storage 1 | [live: sockets that are not in `/proc/net/{unix,netlink,tcp,udp,…}` → **inference** that they are QRTR; consistent with `libqrtr`/`libqmi_cci` being loaded] | `net/qrtr/{qrtr.c,smd.c,…}`; no in-kernel name server used — `qrtr-ns` userspace binary runs | `include/uapi/linux/qrtr.h` (`sockaddr_qrtr`, control packets) | KEEP. Upstream differences to handle: in-kernel `qrtr ns` (bind to the control port will clash with the closed `qrtr-ns`), and downstream extras (`QRTR_TYPE_*` additions, node-ID routing for multiple endpoints). |
| `/dev/drb` (misc 120, system:radio) | [live fd rild]; [strings] `libsec-ril.so` | `drivers/misc/drb/dev_ril_bridge.c` (Samsung "dev RIL bridge": read/write/poll, no ioctls; kernel drivers send notifications to RIL and back, e.g. SAR/grip, charger) | driver-private message struct (`include/linux/dev_ril_bridge.h`) | KEEP |
| `/dev/subsys_modem` | [live fd `pm-service`]; [strings] `libmdmdetect.so` `/dev/subsys_%s`, `/sys/bus/msm_subsys/devices`, `/sys/bus/esoc/devices` | `drivers/soc/qcom/msm_subsystem_restart.c` (open = keep subsystem up; 0 ioctls) | sysfs `name`, `state`, `firmware_name`, `restart_level` per `subsysN` | **KEEP** — there is no upstream equivalent; a shim on top of remoteproc is needed. Also used by `libadsprpc.so` (`/dev/subsys_adsp`, `/dev/subsys_cdsp`) and `ssr_setup`. |
| `/dev/uio0` + `/sys/class/uio/uio%u/{name,version,maps/map0/{addr,size}}` | [live fd `rmt_storage`]; [strings] | `drivers/uio/msm_sharedmem/msm_sharedmem.c` | UIO mmap | KEEP (upstream uses `qcom,rmtfs-mem` + `/dev/qcom_rmtfs_mem*` and the open `rmtfs`; the closed `rmt_storage` wants the UIO device) |
| `/dev/block/sda{1,2,3}`, `sdf1` (modemst1/2, fsg, fsc) | [live fd `rmt_storage`] | UFS | block | KEEP (generic) |
| rmnet: netlink route (protocol 0, rild ×2), `rmnet_ipa0` + `rmnet_data*` netdevs, `SIOCDEVPRIVATE` extended ioctls | [live netlink + `ip link`]; [strings] `libsec-ril.so`: `librmnetctl.so`, `ReadRmnetIoctlExtendedV2`, `enabling new rmnet driver` | `techpack/datarmnet/core/` (`rmnet_core.ko`, `rmnet_ctl.ko`), `techpack/dataipa/.../rmnet_ipa.c` | `include/uapi/linux/msm_rmnet.h` (76 `RMNET_IOCTL_*` defines, struct `rmnet_ioctl_extended_s`), `linux/if_link.h` `IFLA_RMNET_*` + downstream extra attrs; genl family `RMNET_CORE_GENL` (`techpack/datarmnet/core/rmnet_genl.c`) and rmnet_shs genl | KEEP |
| `/dev/ipa`, `/dev/wwan_ioctl`, `/dev/ipaNatTable`, `/dev/ipaIpv6CTTable`, `/dev/ipa_odl_ctl`, `/dev/ipa_adpl`, `/dev/ipa_tethering_bridge` | [live nodes]; **no process holds any**; no ipacm/netmgrd/adpl process | `techpack/dataipa/drivers/platform/msm/ipa/ipa_v3/` | `include/uapi/linux/msm_ipa.h` (104 ioctls), `rmnet_ipa_fd_ioctl.h` (23) | **UNUSED by userspace.** IPA still matters in-kernel: it is the modem data path and speaks QMI to the modem itself. Inference: upstream `drivers/net/ipa` + upstream rmnet can replace it only if rild's rmnet ioctl/netlink usage is satisfied. |
| `/dev/smd7`, `smd8`, `smd4`, `smd11`, `smdcntl8`, `at_mdm0`, `apr_apps2` (glinkpkt, major 236) | [live nodes]; none open in the snapshot; `smd7` is bluetooth:bluetooth, `smd11`/`smdcntl8`/`at_mdm0` radio | `drivers/soc/qcom/glink_pkt.c` (1 ioctl) | read/write + `TIOCMGET`-style | KEEP for `at_mdm0`/`smd11` [inference: AT/DUN and Samsung factory paths]; unverified |
| `/dev/rdbg_{adsp,cdsp,modem,wcnss}` | [live nodes root-only] | `drivers/char/rdbg.c` (`rdbg.ko`) | — | UNUSED |
| `/sys/class/remoteproc/`, `/dev/esoc-0`, `/sys/bus/esoc/devices`, `/dev/modem_br`, `/dev/ramdump_memshare`, `/sys/bus/mhi/devices/*/time` | [strings] `libsec-ril.so`, `libmdmdetect.so`, `time_daemon`; nodes absent | — | — | UNUSED (external-modem paths) |
| `/dev/rtc0` | [strings] `time_daemon`, `libsec-ril.so` | `drivers/rtc/rtc-pm8xxx.c` | RTC ioctls | KEEP (generic) |
| `/proc/sys/net/ipv4/{tcp_netpm,tcp_netpm_ifdevs}`, `/proc/sys/net/core/support_dropdump`, `/proc/sys/net/optr`, `/proc/net/xt_qtaguid/iface_stat_fmt`, `/sys/class/xt_hardidletimer/timers/idleness_indicator` | [strings] `libsec-ril.so` | Samsung/Qualcomm net additions | procfs | KEEP if cheap; inference: optional (not all exist on 5.4 either — `/sys/class/xt_idletimer` exists, `xt_hardidletimer` does not) |
| `/sys/class/nfc_sec/nfc_support`, `/sys/class/lcd/panel/mipi_switch`, `/sys/class/power_supply/battery/voltage_now` | [strings] `libsec-ril.so` | sections 13, 2, 10 | sysfs | KEEP |
| `/efs/imei/*`, `/efs/FactoryApp/{serial_no,keystr,eID}`, `/mnt/vendor/efs/{nv_data.bin,telephony.prop,factory.prop,esim.prop,…}`, `/dev/block/param` | [strings] `libsec-ril.so` | partitions `efs`, `sec_efs`, `param` | files / raw block | KEEP |
| `/dev/socket/qmux_radio`, `qmux_bluetooth`, `netmgr`, `ipacm_log_file` | [live] directories/sockets created by rc files | — | — | userspace only |

**Kernel modules (loaded).** `rmnet_core`, `rmnet_ctl`, `rmnet_offload`, `rmnet_shs`, `rdbg`. IPA,
QRTR, glink, PIL are built in.

**Firmware.** `modem.{mdt,b02…b28}` from `/vendor/firmware-modem` (partition `modem`). Note: on
this boot `request_firmware` failed directly and used the **sysfs fallback** (dmesg: `Direct firmware
load for modem.mdt failed with error -2 … Falling back to sysfs fallback`), so ueventd's
`firmware_directories` serves it — the port needs `CONFIG_FW_LOADER_USER_HELPER` or a firmware path
that includes the modem mount. `yupik_ipa_fws.{mdt,b*}` (IPA firmware, via PIL
`subsys_yupik_ipa_fws`).

---

## 7. Wi-Fi (WCN6750, "wpss")

**Consumers.** Open: `android.hardware.wifi-service` + `libwifi-hal.so` (qcom), `wpa_supplicant`,
`hostapd`, `libcld80211.so`. Closed: `cnss-daemon`, `lowi-server`, `macloader` (Samsung).

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| nl80211 (generic netlink, protocol 16) incl. QCA vendor commands | [live netlink: wifi HAL 3, supplicant 4, cnss-daemon 5, lowi 2] | `drivers/staging/qcacld-3.0` (`qca_cld3_wlan.ko`, module name `wlan`) | nl80211 + QCA vendor subcommands (OUI 00:13:74) | OPEN for HAL/supplicant; KEEP for `cnss-daemon`/`lowi-server` only if they are kept |
| genl family `cld80211` | [strings] `lowi-server` (`cld80211_cli_*`); [src] | `drivers/net/wireless/cnss_genl/cnss_nl.c` | `include/net/cnss_nl.h` | KEEP only with the closed daemons |
| genl family ICNSS (`icnss2/genl.c`), QMI over QRTR to the WLAN firmware | [live] cnss-daemon 3 unknown-family sockets [inference QRTR] | `drivers/soc/qcom/icnss2/` | — | same |
| `/sys/wifi/{mac_addr,ant,pm,qcwlanstate,softap,wifiver,feature,wificable,memdump}` | [live]; [strings] `macloader`; rc `wifi_sec.rc` | `drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_sysfs.c` (Samsung additions) | sysfs | KEEP for `macloader` (writes the MAC from `/mnt/vendor/efs/wifi/.mac.info`); small, and `macloader` is easy to replace |
| `/sys/kernel/icnss/wpss_boot` | [strings] `macloader`; [live] | `drivers/soc/qcom/icnss2/main.c` | sysfs | KEEP (same remark) |
| `/dev/wlan` (major 487 `qcwlanstate`, wifi:wifi) | [live node]; written by init scripts | `wlan_hdd_main.c` | write "ON"/"OFF" | OPEN |
| `/sys/class/net/%s/queues/rx-%d/rps_cpus`, `/proc/sys/net/ipv4/tcp_{adv_win_scale,delack_seg,limit_output_bytes,use_userconfig}` | [strings] `cnss-daemon` | generic + Qualcomm tcp additions | — | optional |

**Verdict for the subsystem:** OPEN. If the port uses upstream ath11k for WCN6750, drop
`cnss-daemon`, `lowi-server` and replace `macloader`; nothing else closed depends on the
downstream WLAN UAPI. (GNSS `lowi` Wi-Fi positioning is lost.)

**Kernel module.** `qca_cld3_wlan.ko` (loaded as `wlan`).

**Firmware.** `wpss.{mdt,b00–b07}` — per-hardware-revision sets under
`vendor/firmware/wlan/a528b/rev{2..11}`, bind-mounted over `/vendor/firmware/wpss.*` at boot (see
`device/samsung/a52sxq/init/wifi_firmware.rc`); `qca6750/bdwlan.elf{,1,2,10}`, `qca6750/regdb.bin`,
`qca6750/qdss_trace_config.cfg`, `Data.msc`; config `WCNSS_qcom_cfg.ini`.

---

## 8. Bluetooth

**Consumer.** Closed `android.hardware.bluetooth@1.0-service-qti` +
`android.hardware.bluetooth@1.0-impl-qti.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/ttyHS0` | [live fd] | `drivers/tty/serial/msm_geni_serial.c` | tty + termios; downstream clock-vote ioctls (`TIOCPMGET/PUT`-style in `msm_geni_serial`), `include/uapi/linux/msm_geni_serial.h` has 0 `_IO` defines | KEEP (node name `ttyHS0` and the power ioctls; upstream names it `ttyHS*` only with `CONFIG_SERIAL_QCOM_GENI` aliases — check) |
| `/dev/btpower` (major 489, bluetooth:system) | [strings]; [live node] | `drivers/bluetooth/btpower.c` (`btpower.ko`) | `include/linux/btpower.h`: 7 raw command numbers `BT_CMD_SLIM_TEST 0xbfac … BT_CMD_GETVAL_POWER_SRCS 0xbfb1`, `BT_CMD_SET_IPA_TCS_INFO` | KEEP |
| `/sys/class/rfkill/rfkill%d/{type,state,device/extldo}` | [strings] | `drivers/bluetooth/btpower.c` (rfkill) | sysfs | KEEP |
| `/dev/btfmslim` | section 4 | `btfm_slim.c` (`bt_fm_slim.ko`) | | KEEP |
| `/dev/smd2`, `/dev/smd3` | [strings] only; absent | — | — | UNUSED |
| `/mnt/vendor/efs/bluetooth/bt_addr` | [strings] | file | — | KEEP |
| `/sys/power/wake_lock` | [live fd] | generic | | KEEP |

**Firmware.** `msbtfw11.mbn`, `msbtfw11.tlv`, `msnv11.bin`, `bt_nvm_loading.xml` — downloaded by
the HAL over the UART, not by the kernel [inference from the HAL owning the tty and no
`request_firmware` line in dmesg].

Alternative: upstream `hci_qca` + the open AOSP Bluetooth HAL replaces all of this. Then only
SLIMbus/SCO audio routing (section 4, `libbthost_if.so`) still expects `/dev/btfmslim`.

---

## 9. GNSS

**Consumers (closed).** `android.hardware.gnss@2.1-service-qti`, `loc_launcher`, `xtra-daemon`,
`lowi-server`, `libloc_api_v02.so`, `libgps.utils.so`.

| Interface | Evidence | Driver | Verdict |
|---|---|---|---|
| QMI LOC over AF_QIPCRTR (5 sockets in the HAL, 3 in xtra-daemon) | [live → inference] | `net/qrtr` | KEEP (same as section 6) |
| `/dev/subsys_modem`, `/sys/bus/msm_subsys/devices` via `libmdmdetect.so` / `libperipheral_client.so` | [maps + strings] | subsystem restart | KEEP |
| `/sys/devices/soc0/{chip_name,images,serial_number,nproduct_id}` | [strings] gnss impl, xtra-daemon | `drivers/soc/qcom/socinfo.c` (downstream attribute set) | KEEP (upstream socinfo lacks `images`, `chip_name`, `nproduct_id`, `hw_platform`, `platform_subtype_id`, `pmic_model`) |
| `/sys/class/power_supply/battery/gps` | [strings] `libloc_api_v02.so` | `drivers/battery/common/sec_battery_sysfs.c` | KEEP (Samsung battery attr) |
| `/dev/gnss*`, `/sys/class/gnss` | class exists, empty [live] | `drivers/gnss/core.c` | UNUSED |

No kernel module, no kernel-loaded firmware (GNSS runs in the modem image).

---

## 10. Video codec (Venus, msm_vidc)

**Consumer.** Closed `vendor.qti.media.c2@1.0-service` with `libqcodec2_{core,base,basecodec,
v4l2codec,platform,utils,hooks}.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/video32` (decoder), `/dev/video33` (encoder) | [strings] `libqcodec2_v4l2codec.so`; [live] nodes exist (video_device, system:camera); opened per session | `techpack/video/msm/vidc/` (`msm_v4l2_vidc.c`, `msm_vdec.c`, `msm_venc.c`, `msm_vidc_ctrls`, HFI) — built in | Standard V4L2 M2M ioctls, **0 private ioctls**, but: 58 private control IDs `V4L2_CID_MPEG_VIDC_*` (`techpack/video/include/uapi/vidc/media/msm_vidc_utils.h`), private events, private pixel formats (UBWC NV12/TP10/P010, in the downstream `videodev2.h`), extradata planes, buffer size math in `msm_media_info.h` | **KEEP**. Upstream `venus` (and `iris`) is V4L2-stateful-compliant and does not accept this dialect; the closed Codec2 will not run on it. |
| `/dev/ion` (2 fds), dmabuf | [live fd] | `msm_smem.c` | section 12; secure sessions use `ION_SECURE_HEAP_ID` + `ION_FLAG_CP_BITSTREAM/PIXEL/NON_PIXEL` | KEEP |
| `/dev/subsys_venus` | [live node] | PIL | — | kernel-internal |
| `/sys/devices/soc0/soc_id` | — | socinfo | | KEEP |

Alternative (inference): replace the closed Codec2 with the open `v4l2_codec2` HAL on upstream
venus/iris; loses HDR10+/UBWC extras but removes this surface. Decision for the port owner.

**Firmware.** `vpu20_1v.{mdt,mbn,b*}` (firmware partition; `subsys_venus` fw name switches to
`vpu20_1v` per dmesg).

---

## 11. Secure world: QSEECOM, smcinvoke, keymaster, gatekeeper, Widevine, fingerprint

**Consumers.** `qseecomd` (closed; 9 fds each on `/dev/qseecom` and `/dev/ion`), closed
`libQSEEComAPI.so` loaded by: keymaster (`libskeymaster4device.so`, `libkeymaster_helper.so` —
closed; service binary open), gatekeeper (`gatekeeper.mdfpp.so` closed), fingerprint
(`libbauthserver.so`, `libbauthtzcommon.so`, `libegis_fp_normal_sensor_test.so` closed; service
binary open, `hardware/samsung/aidl/fingerprint`), `vendor.qti.hardware.qseecom@1.0-service`
(closed). Widevine: closed `android.hardware.drm@1.3-service.widevine` + `libwvhidl.so`.

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/qseecom` (major 508, system:drmrpc) | [live fd] qseecomd ×9, keymaster, gatekeeper, fingerprint | `drivers/misc/qseecom.c` (built in) | `include/uapi/linux/qseecom.h` — 31 `QSEECOM_IOCTL_*` (35 `_IO` lines): app load/unload, send cmd/modfd (ION fd patched into the request), listener register/receive/send-resp (qseecomd serves RPMB, SFS, time, GP listeners), key management, FDE/PFE, QTEEC | **KEEP** |
| `/dev/ion` with heap `ION_QSECOM_HEAP_ID` (bit 7) and `ION_QSECOM_TA_HEAP_ID` (bit 1) | [live fd in all of the above]; DT heaps `qcom,ion-heap@27` (reg 0x80), `@19` (reg 0x02) | section 12 | | KEEP |
| `/dev/smcinvoke` (major 238) → `anon_inode:smcinvoke` (3 fds in Widevine) | [live fd]; [strings] `libminkdescriptor.so` | `drivers/soc/qcom/smcinvoke.c` | `include/uapi/linux/smcinvoke.h` — 5 `SMCINVOKE_IOCTL_*` (invoke, accept, server, ack, log); object-capability marshalling with dmabuf memory objects | **KEEP** (upstream has only the new, different `qcomtee` TEE driver from 6.18-rc; ABI is not the same) |
| `/dev/block/sda4` (held by qseecomd), `/dev/0:0:0:49476`, `/dev/ufs-bsg0`, `/dev/sg*` | [live fd; strings `librpmb.so`] | `drivers/scsi/ufs/ufs_bsg.c`, SCSI bsg/sg | SG_IO / bsg v4 for RPMB frames; the device **name** `/dev/0:0:0:49476` (bsg node of the RPMB W-LUN, context `vendor_bsg_device`) | KEEP (upstream names bsg nodes the same way `H:C:T:L`; verify LUN 49476 naming on 6.18) |
| `/dev/qce` (major 491, system:drmrpc) | [strings] `libcpion.so`; node exists; not open in the snapshot | `drivers/crypto/msm/qcedev.c` | `include/uapi/linux/qcedev.h` (11 ioctls) | KEEP [inference: content-protection copy; who loads `libcpion.so` not observed] |
| `/dev/spcom`, `/dev/qsee_ipc_irq_spss`, `/dev/sp_*` | [strings] `libspl.so`; nodes absent (no SPU on SM7325) | — | — | UNUSED |
| `/dev/esfp0` (major 152 `egis_fingerprint`, system:system) | [live fd fingerprint HAL]; [strings] `libbauthserver.so`, `libegis_fp_normal_sensor_test.so` | `drivers/fingerprint/et7xx-spi.c`, `et7xx-spi_data_transfer.c`, `fingerprint_common_qcom.c` | `drivers/fingerprint/et7xx.h`: **raw ioctl numbers** (not `_IO`-encoded) — 46 `FP_*`/`INT_TRIGGER_*` command values (`FP_SENSOR_RESET 0x04`, `FP_POWER_CONTROL 0x05`, `FP_SET_SPI_CLOCK 0x06`, `FP_CPU_SPEEDUP 0x11`, `FP_MODEL_INFO 0x1f`, `INT_TRIGGER_POLLING 0xa7`, …) plus `EGIS_IOC_MESSAGE(N)` with `struct egis_ioc_transfer`; `poll()` for the finger interrupt | **KEEP** |
| `/sys/class/fingerprint/fingerprint/{adm,name,type_check,…}` (21 attrs touched by rc) | [strings] `libbauthserver.so`; rc `init.fingerprint.rc` | `drivers/fingerprint/fingerprint_sysfs.c` | sysfs | KEEP |
| `/sys/class/lcd/panel` (+ `mask_brightness`, `fp_green_circle` from the open HAL), `/sys/power/cpufreq_max_limit`, `/sys/class/power_supply/battery/temp` | [strings] `libbauthserver.so` | sections 2, 13, 10 | sysfs | KEEP |
| `/efs/biometrics/meta/*`, `/data/vendor/biometrics` | [strings] | files | — | KEEP |
| `/mnt/vendor/efs/DAK/*` (attestation key boxes), `/dev/ssp` (absent) | [strings] `libkeymaster_helper.so` | files | — | KEEP (files) |
| `/proc/self/integrity/proca_certificate`, `/dev/socket/vaultkeeper/vaultkeeper` | [strings] `libvkmanager_vendor.so` (loaded by rild) | Samsung PROCA (`security/proca`) | procfs | UNUSED on IchthysOS [inference: no vaultkeeper daemon; file absent is tolerated since the RIL runs today — check whether PROCA is enabled in the 5.4 config before dropping] |
| `/dev/dek_{evt,req,log}` (misc 124–126), netlink 28 (`SDP_FS_HANDLER_NETLINK`), 29 (`NETLINK_FIPS_CRYPTO`), 27 (`NETLINK_KFREECESS`), 30 | [live `/proc/misc`, `/proc/net/netlink` — kernel-side sockets only, **no userspace pid bound**] | `security/sdp/` (12 ioctls in `include/sdp/dek_ioctl.h`), kfreecess | — | UNUSED (Samsung Knox SDP / freecess; no AOSP-side consumer) |

**Trusted apps loaded at boot** (dmesg `QSEECOM: … App (…)`): `skeymast` (keymaster), `dualfp`
(fingerprint), `authhat`. Widevine TA goes through smcinvoke. TA images live on the firmware
partition (`/vendor/firmware_mnt/image/{skeymast,dualfp,authhat,widevine,hdcp*,soter64,…}`), not
in the blob tree.

**Kernel modules.** None (qseecom, smcinvoke, et7xx built in). `sec_secure_touch.ko` loaded (TUI
touch hand-off, no blob consumer seen).

---

## 12. ION / dma-buf / secure heaps

| Interface | Evidence | 5.4 driver | UAPI | Verdict |
|---|---|---|---|---|
| `/dev/ion` (misc 127, mode 0664 system:system) | [live fd]: qseecomd ×9, camera provider ×2, c2 ×2, audio, composer, allocator, adsprpcd, cdsprpcd, sscrpcd, keymaster, gatekeeper, fingerprint, surfaceflinger, mediaswcodec, apps | `drivers/staging/android/ion/{ion.c,ion_buffer.c,ion_dma_buf.c}`, `heaps/{msm_ion.c,ion_msm_system_heap.c,ion_system_secure_heap.c,ion_cma_heap.c,ion_carveout_heap.c,ion_secure_util.c,msm_ion_dma_buf.c}` | `include/uapi/linux/ion.h`: `ION_IOC_ALLOC` (`struct ion_allocation_data{len,heap_id_mask,flags,fd,unused}`), `ION_IOC_HEAP_QUERY`, `ION_IOC_ABI_VERSION`; `include/uapi/linux/msm_ion.h`: `ION_IOC_PREFETCH`, `ION_IOC_DRAIN`, flags `ION_FLAG_SECURE` (bit 31), `ION_FLAG_CP_*` (bits 15–30), heap types 16–21; `msm_ion_ids.h`: heap id bits | **KEEP**. `libion.so` itself is open, but closed callers pass hard-coded heap-id masks and CP flags (`libgsl.so`, `libdpps.so`, `libQSEEComAPI.so` users, CamX, codec2, `libadsprpc.so`). |
| Heap IDs that exist on this board | [src] `downstream-dt/a52sxq-r02.dts` `qcom,ion-heap@N` reg masks | | system = bit 25 (`MSM_SYSTEM`), secure (`SYSTEM_SECURE`, `ION_SECURE_HEAP_ID`) = bit 10, secure display (`HYP_CMA`) = bit 11, secure carveout = bit 15, QSEECOM = bit 7 (DMA), QSEECOM TA = bit 1 (DMA), user contig = bit 6 (DMA), audio ML = bit 5 (DMA) | KEEP ids and semantics |
| dma-buf fds from ION | [live `/dmabuf:` links everywhere] | `ion_dma_buf.c`, `msm_ion_dma_buf.c` | `linux/dma-buf.h` (`DMA_BUF_IOCTL_SYNC`, `DMA_BUF_SET_NAME`); downstream in-kernel hooks: `dma_buf_get_flags`, `dma_buf_lookup` by name, secure-VMID in `dma_buf->flags` | KEEP (userspace part is upstream; the kernel-side secure-VMID convention is what camera/vidc/kgsl/qseecom drivers rely on) |
| `/dev/membuf` (major 239) | [live node system:system]; no user seen | `drivers/soc/qcom/mem-buf.c` | `linux/mem-buf.h` (3 ioctls) | UNUSED (no VM on this device) [inference] |
| `/sys/kernel/ion/{total_heaps_kb,total_pools_kb}` | [live]; memtrack HAL (open) | `ion.c` | sysfs | OPEN |
| `/dev/ashmem` + `/dev/ashmem<uuid>` | [live fd] audio, sensors, power, c2 via libcutils | `drivers/staging/android/ashmem.c` | 10 ioctls | KEEP if any closed lib calls ashmem directly — not determined; libcutils falls back to memfd on new kernels |

**In-kernel `ion_alloc()` callers that the forward-ported drivers bring along** [src]:
`techpack/camera/.../cam_mem_mgr.c`, `drivers/char/adsprpc.c`, `techpack/audio/dsp/msm_audio_ion.c`,
`drivers/media/platform/msm/cvp/msm_smem.c`, `drivers/soc/qcom/mem-buf.c`. So the "ION compat
module" has two faces: the `/dev/ion` char device for userspace and the `ion_alloc()` /
heap-id / secure-flag kernel API for these drivers.

---

## 13. Thermal, power, performance

**Consumers.** Closed: `thermal-engine`, `vendor.samsung.hardware.thermal@1.0-service`,
`vendor.qti.hardware.perf@2.2-service` (+ `libqti-perfd.so`), `libqti-perfd-client.so` in several
HALs. Open: `android.hardware.power-service.pixel-libperfmgr` (`powerhint.json`), init scripts.

| Interface | Evidence | 5.4 driver | Verdict |
|---|---|---|---|
| `/sys/devices/virtual/thermal/thermal_zone*/temp` — 49 zones held open; `type`, `mode`, `policy`, `trip_point_N_{temp,hyst,type}`, `cdevN_*`; `cooling_deviceN/{type,cur_state,max_state}` | [live fd thermal-engine; strings] | `drivers/thermal/` + `drivers/thermal/qcom/*` (tsens, QMI cooling, cpu isolate, `msm_lmh_dcvs`, bcl) | KEEP: zone and cooling-device **type names** are matched against `/vendor/etc/thermal-engine.conf`. 77 zones, see `blob-uapi-evidence/thermal.txt`. `mode`/`policy` exist upstream; names differ unless the DT keeps the downstream labels. |
| uevent netlink (15) + 3 QRTR sockets (QMI thermal mitigation / sensor service to modem, ADSP, CDSP) | [live] thermal-engine | `drivers/thermal/qcom/qmi_cooling.c` etc. | KEEP |
| `/dev/socket/thermal-{send,recv}-*` | [strings] | userspace | — |
| `/sys/class/kgsl/kgsl-3d0/{gpuclk,max_gpuclk,gpu_available_frequencies}`, `/sys/class/devfreq/`, `/sys/class/leds/lcd-backlight/{brightness,max_brightness}`, `/sys/class/power_supply/battery/system_temp_level`, `/sys/devices/soc0/{hw_platform,platform_subtype_id,pmic_model,revision,soc_id}` | [strings] thermal-engine | kgsl, socinfo, sec_battery | KEEP (socinfo attributes are how thermal-engine picks its config) |
| `/sys/module/msm_thermal/*`, `/sys/devices/virtual/graphics/fb0/msm_fb_thermal_level`, `/sys/module/msm_isense_cdsp/data`, `/dev/block/by-name/limits-cdsp` | [strings] | absent on 5.4 too | UNUSED |
| `/sys/power/cpufreq_max_limit` (held open), `cpufreq_min_limit`, `cpufreq_table`, `over_limit`, `limit_stat` | [live fd Samsung thermal HAL; strings `libbauthserver.so`] | `drivers/cpufreq/cpufreq_limit.c` (Samsung) | KEEP |
| `/sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/siop_level` (held open), `/sys/class/power_supply/battery/{temp,chg_temp,usb_temp,blkt_temp,dchg_temp,sub_bat_temp}`, `/sys/class/sec/sec-{ap,pa,wf,…}-thermistor/temperature`, `/sys/class/audio/amp/curr_temperature_1`, `/sys/class/switch/uart3/state`, `/proc/stat` | [live fd + strings] Samsung thermal HAL | `drivers/battery/common/sec_battery_sysfs.c`, `drivers/hwmon/sec_thermistor/sec_thermistor.c`, `sec_audio_sysfs.c`, `drivers/switch/switch_class.c` | KEEP (note the full platform path `samsung_mobile_device:battery` is what is open, reached through the class symlink) |
| `/sys/module/msm_performance/events/cpu_hotplug` (held open), `parameters/{cpu_max_freq,cpu_min_freq,core_ctl_register,…}` | [live fd perf HAL] | `drivers/soc/qcom/msm_performance.c` | KEEP |
| WALT: `/proc/sys/kernel/sched_{boost,upmigrate,downmigrate,group_upmigrate,group_downmigrate,busy_hyst_ns,coloc_*,min_task_util_for_*,prefer_spread,user_hint,window_stats_policy,ravg_window_nr_ticks,lib_name,lib_mask_force,…}`, `walt_*`, `/proc/%d/sched_group_id`, `/proc/%d/{sched_boost,sched_low_latency}`, `/sys/devices/system/cpu/cpu%d/core_ctl/{min_cpus,max_cpus,…}`, `cpufreq/policyN/schedutil/{hispeed_freq,hispeed_load,pl,rtg_boost_freq,*_rate_limit_us}`, `/dev/stune/*`, `/dev/cpuctl/*uclamp*` | [strings] `libqti-perfd.so`; 179 node templates in `vendor/etc/perf/{commonresourceconfigs,commonsysnodesconfigs,targetresourceconfigs}.xml` (`blob-uapi-evidence/perf_nodes.txt`); [live] 47 `sched_*`/`walt_*` sysctls exist | `kernel/sched/walt/*`, `kernel/sysctl.c`, `core_ctl.c`, `qc_vas.c` | **KEEP only if the perf HAL is kept.** Inference: perfd tolerates missing nodes (many listed nodes, e.g. `interactive/*`, `ondemand/*`, `/proc/sys/walt/*`, do not exist on 5.4 either). The HAL and its node table are XML-driven, so nodes can be remapped without touching the binary. Realistic plan: stub or drop the QTI perf HAL; libperfmgr already does the boosting. |
| devfreq: `soc:qcom,cpu-cpu-llcc-bw`, `cpu-llcc-ddr-bw`, `cpuN-cpu-llcc-lat`, `cpuN-llcc-ddr-lat`, `cpuN-cpu-ddr-latfloor`, `18590100.qcom,cpu7-cpu-l3-latfloor`, `snoop-l3-bw`, `kgsl-busmon`, `3d00000.qcom,kgsl-3d0`, `1d84000.ufshc` (+ `bw_hwmon/*`, `mem_latency/*`) | [live `/sys/class/devfreq`]; perf XML; `libsysmon_cdsp_skel.so` names `soc:qcom,l3-cdsp/userspace/set_freq` (absent) | `drivers/devfreq/{bimc-bwmon,governor_bw_hwmon,arm-memlat-mon,governor_memlat,…}` | same as above (tuning only) |
| `/dev/cpu_dma_latency`, `/dev/network_throughput`, `/dev/bias_hyst` (PM QoS misc) | [live misc 118, 116, 117]; perf XML uses `cpu_dma_latency` | `kernel/power/qos.c` | KEEP `cpu_dma_latency` (upstream has it); others UNUSED |
| `/dev/perf_manager` (misc 119), `/sys/class/input_booster/*`, `/sys/kernel/gpu/*`, `sec_argos` | [live] | `drivers/perf_mgr/perf_mgr.c`, `drivers/input/input_boost/*`, `drivers/samsung/misc/sec_argos.c` | UNUSED by blobs on IchthysOS (One UI framework consumers) [inference] |
| `/sys/class/mmc_host/mmc0/clk_scaling/enable`, `/sys/class/scsi_host/host0/../../../clkscale_enable`, `/sys/kernel/mm/ksm/*`, `/sys/kernel/mem-offline`, `/sys/module/app_setting/parameters/lib_name`, `/dev/socket/msm_irqbalance` | [strings] `libqti-perfd.so` | misc | optional |

**Kernel modules.** `llcc_perfmon`, `tcp_htcp`, `tcp_westwood`, `ssg_iosched`, `blk_sec_stats`
(loaded; no blob dependency).

---

## 14. Charger / battery / health / USB

**Consumers.** All open: `android.hardware.health-service.samsung`,
`vendor.lineage.health-service.default`, `android.hardware.usb-service.samsung`,
`android.hardware.usb.gadget-service.samsung` (`hardware/samsung/aidl/…`). Closed readers of
battery sysfs: Samsung thermal HAL, `thermal-engine`, `libGLESv2_adreno.so`/`vulkan.adreno.so`,
`liblearningmodule.so` (perf), `libloc_api_v02.so`, `libsec-ril.so`, `libbauthserver.so`.
`hvdcp_opti` (closed, in the blob tree) is **not running** and its `qcom-battery`/`qbg` classes do
not exist.

| Interface | Evidence | 5.4 driver | Verdict |
|---|---|---|---|
| `/sys/class/power_supply/battery/` — 209 attributes; closed code reads `capacity`, `status`, `temp`, `current_now`, `voltage_now`, `siop_level`, `system_temp_level`, `chg_temp`, `usb_temp`, `blkt_temp`, `dchg_temp`, `sub_bat_temp`, `gps` | [live count; strings] | `drivers/battery/common/sec_battery.c`, `sec_battery_sysfs.c`, `sec_battery_thermal.c` | KEEP the 13 named attributes under a supply named exactly `battery`; the other ~195 are OPEN/unused |
| supplies `ac`, `usb`, `wireless`, `otg`, `pogo`, `sm5714-charger`, `sm5714-fuelgauge`, `sm5714-otg`, `pca9468-charger`, `sec-direct-charger` | [live] | `drivers/battery/charger/sm5714_charger`, `fuelgauge/sm5714_fuelgauge`, `charger/pca9468_charger`, `common/sec_direct_charger.c` | OPEN |
| uevent netlink | [live] health, usb HALs | power_supply core, typec | OPEN |
| `/sys/class/typec/`, `/sys/class/udc/`, `/sys/class/usb_notify/usb_control/*`, `/sys/devices/virtual/sec/ccic/water`, configfs gadget | [src hardware/samsung] | `drivers/usb/typec/common/`, `drivers/usb/notify/` | OPEN (closed `audio.primary.lahaina.so` reads `/sys/class/usb_notify/usb_control/cards` → KEEP that one file) |
| `/dev/ccic_misc` (misc 111) | [live node root-only] | `drivers/usb/typec/common/pdic_misc.c` | UNUSED |
| Kernel cmdline parameters `sec-battery.*`, `sm5714_*.factory_mode`, `sec_mparam.*`, `androidboot.*param.offset` | [live cmdline] | module params fed by the Samsung bootloader | keep parsers or ignore; not UAPI |

---

## 15. Vibrator, NFC

| Subsystem | Consumer | Interface | 5.4 driver | Verdict |
|---|---|---|---|---|
| Vibrator | `android.hardware.vibrator-service.samsung` — open (`hardware/samsung/aidl/vibrator`) | `/sys/class/timed_output/vibrator/{enable,intensity,…}` | `drivers/vibrator/common/sec_vibrator.c` + DC motor driver | OPEN |
| NFC | `android.hardware.nfc-service.sec` + `nfc_nci_sec.so` — both built from source (`hardware/samsung/nfc`) | `/dev/sec-nfc` (misc 110, nfc:nfc) [live fd]; `/sys/class/nfc_sec/nfc_support` (also read by closed `libsec-ril.so`) | `drivers/nfc/sec_nfc.c` (`nfc_sec.ko`), `sec_nfc.h`: 7 ioctls | OPEN (keep `nfc_support` for the RIL) |

NFC firmware `nfc/sec_s3nrn4v_firmware.bin` (chip S3NRN4V) is downloaded by the HAL through
`/dev/sec-nfc`, not by `request_firmware`.

---

## 16. Samsung-specific kernel surfaces

| Interface | Closed consumer? | 5.4 driver | Verdict |
|---|---|---|---|
| `/sys/class/sec/` (26 devices: `tsp`, `hall_ic`, `switch`, `ccic`, `muic`, `ufs`, `sec-*-thermistor`, `sec_debug`, `sec_hw_param`, `sec_misc`, `sec_abc`, `sec_nad`, `sec_reset_reason`, `sec_sysup`, `bsp`, `sdcard`, `typec_manager`, …; 294 lines of attributes) | yes for `tsp/{cmd,ear_detect_enable}` (sensors.grip), `hall_ic/*` (sensors.grip), `sec-*-thermistor/temperature` (thermal HAL), `ufs/sec_wb_enable` (CamX) | `drivers/samsung/sec_class.c` + each driver | KEEP those four groups; rest OPEN/UNUSED |
| `/dev/sec_misc` (misc 123), `/sys/class/sec/sec_misc` | none found | `drivers/samsung/misc/sec_misc.c` | UNUSED |
| `sec_param` (param partition access, `/dev/block/param`) | `libsec-ril.so` opens `/dev/block/param` directly | `drivers/samsung/…sec_param`; block symlink from ueventd | KEEP the block node + by-name symlink only |
| `sec_debug`, `/proc/reset_reason*`, `/proc/store_lastkmsg`, `/proc/auto_comment`, `/proc/extra`, `/sys/module/sec_debug/*`, `/sys/kernel/dload/*` | init scripts only (open) | `drivers/samsung/debug/*` | OPEN / drop |
| `/efs` (sda9, ext4), `/mnt/vendor/efs` (sda6), `/mnt/vendor/persist` (sda5) | RIL, keymaster (`DAK`), camera, sensors, BT, Wi-Fi MAC, fingerprint, speaker cal | filesystems | KEEP mounts and paths |
| `/dev/drb` | rild | `drivers/misc/drb/dev_ril_bridge.c` | KEEP (section 6) |
| Touch: `stm_ts.ko`, `sec_cmd.ko`, `sec_common_fn.ko`, `sec_tclm_v2.ko`, `sec_tsp_log.ko`, `sec_tsp_dumpkey.ko`, `sec_secure_touch.ko`; inputs `sec_touchscreen`, `sec_touchproximity` | sensors.grip (names, `fod_pressed`, `cmd`) | `drivers/input/sec_input/` | KEEP names + those attributes; firmware `tsp_stm/fts5cu56a_a52sxq.bin` |
| Input boosters `/sys/class/input_booster`, evdev hooks | none | `drivers/input/input_boost/` | UNUSED |
| Hall `hall` input + `/sys/class/sec/hall_ic`; grip `grip_sensor`, `grip_notifier` inputs, `/sys/class/sensors/grip_sensor/*` (48 rc lines) | sensors.grip.so | `drivers/input/misc/hall/hall_ic.c`, `drivers/sensors/sx9360.c` | KEEP |
| `/sys/class/switch/{uart3,dock,ccic_dock}` | thermal HAL reads `uart3/state` | `drivers/switch/switch_class.c`, muic | KEEP `uart3/state` |
| Knox/SDP (`dek_*`, netlink 28/29), kfreecess (27), PROCA | none on IchthysOS | `security/sdp`, `security/proca` | UNUSED |
| `/dev/dun` (misc 122), `/dev/ttyGS*`, `/dev/ttyHS8` (`androidboot.sec_atd.tty`) | Samsung AT daemon is not shipped; `libsec-ril.so` may use `at_mdm0` | `drivers/usb/gadget/function/f_cdev.c` | UNUSED [inference] |

---

## 17. Vendor kernel modules

`/vendor/lib/modules` holds 87 `.ko` + 4 `modules.*` files [live]; `lsmod` shows 87 loaded
(`blob-uapi-evidence/lsmod.txt`). All are built from the kernel tree. By group:

- Camera: `camera`
- Audio (30): listed in section 4
- Wi-Fi/BT/NFC: `qca_cld3_wlan` (as `wlan`), `btpower`, `bt_fm_slim`, `nfc_sec`
- Data: `rmnet_core`, `rmnet_ctl`, `rmnet_offload`, `rmnet_shs`
- Touch/Samsung input: `stm_ts`, `sec_cmd`, `sec_common_fn`, `sec_tclm_v2`, `sec_tsp_log`,
  `sec_tsp_dumpkey`, `sec_secure_touch`, `hid_aksys`
- Misc: `rdbg`, `llcc_perfmon`, `ssg_iosched`, `blk_sec_stats`, `tcp_htcp`, `tcp_westwood`
- **Dead weight, loaded but useless on this phone (34):** DVB/analog TV tuner modules `e4000`,
  `si2157`, `fc0011/12/13`, `fc2580`, `it913x`, `tda9887`, `tda182xx`, `m88rs6000t`, `mc44s803`,
  `mxl*`, `mt20xx…`, `qm1d1*`, `qt1010`, `r820t`, `tea576x`, `tua9001`, `tuner_*`, `xc4000/5000`,
  `max2165`, `msi001`. No blob needs them.

---

## 18. Firmware summary (who needs what, where it lives)

| Consumer | Files | Source |
|---|---|---|
| Modem PIL | `modem.{mdt,b02–b28}` | partition `modem` → `/vendor/firmware-modem` (not in blob tree) |
| ADSP, CDSP PIL | `adsp.*`, `cdsp.*`, `*.jsn`, DSP modules `*.so.1`, `fastrpc_shell_0` | partition → `/vendor/firmware_mnt/image`; `/vendor/dsp` |
| Venus | `vpu20_1v.*` | firmware partition |
| GPU | `a660_zap.*` (firmware partition); `a660_sqe.fw`, `a660_gmu.bin` (blob tree) | |
| IPA | `yupik_ipa_fws.*` | firmware partition |
| Wi-Fi | `wpss.*` per board revision, `qca6750/{bdwlan.elf*,regdb.bin}`, `Data.msc` | blob tree (a52sxq) |
| BT | `msbtfw11.{mbn,tlv}`, `msnv11.bin` | blob tree; userspace download |
| Camera | `CAMERA_ICP_170.elf`, `ois_mcu_stm32g_fw.bin` | blob tree |
| Touch | `tsp_stm/fts5cu56a_a52sxq.bin` | blob tree |
| NFC | `nfc/sec_s3nrn4v_firmware.bin` | blob tree; userspace download |
| Audio | `dax_param.bin`, `multical.bin`(?) | blob tree; consumer of `multical.bin` not determined |
| TrustZone apps | `skeymast`, `dualfp`, `authhat`, `widevine`, `hdcp*`, `soter64`, `sec_fr`, `mst`, … | firmware partition, loaded via qseecom / smcinvoke |
| `evass.*`, `evass-lt.*` | CVP ("EVA") firmware; `/dev/cvp` does not exist | blob tree; UNUSED on this phone |

---

## 19. Ranked: hardest UAPI surfaces to keep identical

1. **Camera (`camera.ko` ↔ CamX).** 143 closed libraries; one multiplexed ioctl with 69 opcodes
   and 181 structs, plus packet payloads whose layout only CamX knows; 26 device nodes; ICP
   firmware protocol; kernel-side ION allocation; 154 Samsung sysfs attributes. Largest by far.
2. **KGSL (62 ioctls, 32- and 64-bit) ↔ closed Adreno GL/Vulkan/CL.** In every graphical process.
   No upstream equivalent; must be carried whole (plus GMU/HFI, zap shader via PIL, bus scaling).
3. **msm_vidc V4L2 dialect ↔ closed Codec2.** No private ioctls, but 58 private controls, private
   formats/events/extradata and secure-buffer behaviour that upstream venus/iris rejects.
4. **Audio ASoC control namespace ↔ closed Samsung `audio.primary.lahaina.so`.** Hundreds of mixer
   control names (not counted here), PCM/compress device numbering, hwdep cal, `msm_audio_cal`
   (18 ioctls), RTAC, APR/Q6 v2 DSP ABI. Upstream q6apm/q6afe exposes none of it.
5. **QSEECOM (31 ioctls) + smcinvoke (5) + ION-fd patching.** Keymaster, gatekeeper, fingerprint,
   Widevine, qseecomd listeners (RPMB via UFS bsg). No upstream driver with this ABI.
6. **ION `/dev/ion` + MSM heap ids + CP flags**, and the matching in-kernel `ion_alloc`/secure
   dma-buf conventions used by camera, vidc, kgsl, adsprpc, audio, qseecom.
7. **SDE DRM**: 17 driver ioctls, custom atomic properties, capability blobs and the
   `msm_drm_pp.h`/QSEED3 struct layouts consumed or produced by closed `libsdmextension`,
   `libsdm-color`, `libqseed3`, `libdpps`.
8. **Subsystem-restart/PIL userspace face** (`/dev/subsys_*`, `/sys/bus/msm_subsys`), the UIO
   shared-memory device for `rmt_storage`, downstream QRTR with userspace `qrtr-ns`, downstream
   `socinfo` attributes. Small each, but they sit under every Qualcomm daemon.
9. **adsprpc/FastRPC (20 ioctls)** for `adsprpcd`, `cdsprpcd`, `sscrpcd`, CamX CDSP offload.
   Upstream `drivers/misc/fastrpc.c` has a different ioctl set and node names.
10. **rmnet + Samsung RIL**: `rmnet_ioctl_extended` over `SIOCDEVPRIVATE`, rmnet netlink, `/dev/drb`.
11. **Samsung sysfs used by closed code**: sensors (`ssc_core`, grip, hall, netlink 23), thermal
    HAL (battery/thermistor/`cpufreq_max_limit`), fingerprint (`/dev/esfp0` raw ioctls, sysfs).
    Many files, each simple.
12. **Thermal zone / cooling-device naming** for `thermal-engine`.

Low effort or avoidable: Wi-Fi (open HAL; drop cnss-daemon), Bluetooth (7 ioctls, or switch to
`hci_qca`), NFC, vibrator, health, USB (all open), WALT/perf nodes (XML-driven, tolerant), IPA
userspace ABI (no user).

---

## 20. Not determined

- **Exact ioctl subsets actually issued** by each closed library. Counts above are what the header
  defines, not what the blob calls; no disassembly or tracing was done (tracing would have meant
  attaching to processes on the owner's phone).
- **Socket families**: sockets were classified by elimination (not unix, netlink or inet ⇒ assumed
  AF_QIPCRTR). `/proc/net/protocols` shows `QIPCRTR 0` because that proto does not maintain the
  counter, so there is no direct confirmation.
- **Generic netlink families registered at runtime** (no `genl` tool on the phone); the list in
  sections 6–7 is from source.
- **Mixer control names / PCM device ids** compiled into `audio.primary.lahaina.so`: not extracted.
- **Which SDE properties and blob layouts** the closed display libraries touch: inferred from
  library roles, not verified.
- **Camera in use**: everything was captured with the camera idle (provider holds all subdevs
  open at idle). Nodes opened only during capture (`/dev/synx_device`, `/dev/qce`, secure heaps,
  `/dev/adsprpc-smd*` from the provider) were not observed.
- **Per-session devices** never open in the snapshot: `/dev/video32/33`, `/dev/msm_*` codec nodes,
  `/dev/at_mdm0`, `/dev/smd*`, `/dev/btpower`, `/dev/qce`, `/dev/self_display`. Their verdicts rest
  on strings and permissions.
- **`libcpion.so` (`/dev/qce`) and `multical.bin`**: loader/consumer not identified.
- **Whether PROCA / `proca_certificate` matters** to `libvkmanager_vendor.so` inside rild.
- **In-call, VoLTE/IMS, tethering, Wi-Fi hotspot, DP-alt-mode, secure video playback** paths were
  not exercised; an idle phone was observed.
- **Failure tolerance** of closed code when an optional sysfs node is missing is inferred, not
  tested, wherever the text says "optional".
- The `product/` and `system_ext/` parts of the blob tree (apps, frameworks) were scanned for path
  strings only through `.so` files; no APK was unpacked.

## 21. Incident note

While the live data was being collected, the phone `DAILYPHONE` restarted once (about 18:14 EET).
The previous-boot kernel log (`/sys/fs/pstore/console-ramoops-0`) shows an orderly shutdown:
`reboot: Restarting system with command 'shell'`, i.e. something ran the `reboot` program; it was
not a kernel panic. No command issued for this inventory contains a reboot (the commands running
at that moment were `grep` over `/proc/<pid>/maps` and `ls -l /proc/<pid>/fd`).
`persist.sys.boot.reason.history` lists two earlier `reboot,shell` entries from 2026-11-10, so
this pattern predates this work. The cause was not identified from here. Data captured before
(open fds, lsmod, /dev) and after the restart (library maps, sockets, dmesg) are consistent.
