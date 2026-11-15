# qfprom-sys (5.4 driver, ported to the 6.12 BSP)

Exposes fuse cells as sysfs files under `/sys/devices/platform/soc/soc:qfprom@0/`
(`feat_conf_m7`, `feat_conf_m9`), node `qcom,qfprom-sys` (already in the full board tree).
The closed QTI display composer reads `feat_conf_m9` (`sku_utils::ReadFuse`) to decide the
allowed frame rate; without the file `DisplayBase::Init: comp manager registration failed`,
the primary display is never created and SurfaceFlinger waits forever (found 2026-11-12 by
strace of the composer in the 6.12 test Android). On the phone's 5.4 kernel the file reads
`00 20 07 00`.
