# 5.4 reference (OneUI 9.3.157 on its 5.4.302-bone-machine kernel, broken screen, 2026-11-22 15:17)

Read-only dump with ref54.sh (full output: logs/oneui-mods/ref54.txt, local only: it holds the UFS UN hash).
What it settles for the 6.12 modules:

| Item | 5.4 | 6.12 module |
|---|---|---|
| /sys/power/cpufreq_table | `2400000 2380800 2208000 2035200 1862400 1766400 1516800 1324800 1056000 902400 825600 758400 662400 576000 470400 403200 345600 150000` | same table derived from the 6.12 policies (identical LUT: policy0/4/7 frequency lists are equal to 6.12's) |
| cpufreq_{min,max}_limit, over_limit, limit_stat | radio:system 664 (init.samsung.rc), limit_stat 664; labels sysfs_power / sysfs_ski_power_readable | kernel modes 0644/0444 as 5.4 source, init applies the same chown/chmod, genfscon by path |
| cflm/info | `real: silver(300000 ~ 1804800), gold(691200 ~ 2400000), prime(806400 ~ 2400000)` / `virt: little(150000 ~ 902400), big(1056000 ~ 2400000)` | same format, same values from cpuinfo |
| sec/ufs/un | 20 hex chars + newline (21 bytes), prefix CE0921 (= man id 0xCE + date) | must match: compare the sha256 line of ref54.sh on 6.12 |
| sec/ufs lt / lc / man_id | 1 / 0 / 01ce | read from the device the same way |
| sec/ufs transferred_cnt | real counter | 0 (no 6.12 counter) |
| sec/ufs wb_* / lp_wb_* / sec_wb_support / wb_state | present (root 664, label sysfs) | not created (Samsung WB policy tunables; nothing in OneUI reads them) |
| scsi_host/host0/unique_number | ABSENT | absent by default (legacy_shost_un=0) |
| host0 SEC_UFS_* + sense_err_* | present, all "0" counters | present, all 0 |
| input_booster class | enable_event/debug_level/sendevent 0644 root, 9 device dirs; NO ib_mode_state | same + ib_mode_state (store-only extra, chowned by init.rc, named by HYPER config) |
| input_booster tables | key 500/0, touchkey 1/500, multitouch 200/800 2035200/1324800, keyboard 130/130, MOUSE 200/300 489600, mouse_wheel 200/0, pen_hover 200/300, pen 200/600 1766400/1056000, all = built-in table | touch head/tail read 130/500 on 5.4 = HYPER's runtime write (mtime after boot, level never written); built-in DT default 200/300 |
| /dev/usb_mtp_gadget | 10:83 system:mtp 0660 mtp_device; misc/guid present | misc device + guid |
| /dev/android_ssusbcon | 10:85 system:system 0660 usb_device | misc device (+ bInterfaceProtocol attr, extra) |
| configfs functions | ss_mon.mtp, ss_mon.ptp, conn_gadget.0 (+ Qualcomm ones); b.1 = ffs.mtp, ffs.adb, ss_mon.mtp in MTP mode | same function names |
| avc denials for these paths | 0 | to be checked on 6.12 |
