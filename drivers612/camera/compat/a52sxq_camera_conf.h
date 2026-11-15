/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Camera feature set of the A52s 5G (a52sxq), copied from the phone's 5.4
 * defconfig (arch/arm64/configs/vendor/lineage-a52sxq_defconfig) and
 * techpack/camera/config/yupikcameraconf.h. On 5.4 these came from Kconfig;
 * the 6.12 BSP's Kconfig does not know them, so they are force-included.
 */
#ifndef A52SXQ_CAMERA_CONF_H
#define A52SXQ_CAMERA_CONF_H

#define CONFIG_SPECTRA_CAMERA 1
#define CONFIG_SPECTRA_ISP    1
#define CONFIG_SPECTRA_SENSOR 1
#define CONFIG_SPECTRA_ICP    1
#define CONFIG_SPECTRA_JPEG   1
#define CONFIG_SPECTRA_LRME   1

#define CONFIG_SEC_A52SXQ_PROJECT 1
#define CONFIG_CAMERA_SYSFS_V2 1
#define CONFIG_CAMERA_FRAME_CNT_DBG 1
#define CONFIG_CAMERA_FRAME_CNT_CHECK 1
#define CONFIG_CAMERA_SSM_I2C_ENV 1
#define CONFIG_GC5035_MACRO_OTP_DD_AUTOLOAD 1
#define CONFIG_SAMSUNG_CAMERA_OTP 1
#define CONFIG_SAMSUNG_FRONT_EEPROM 1
#define CONFIG_SAMSUNG_OIS_MCU_STM32 1
#define CONFIG_SAMSUNG_OIS_Z_AXIS_CAL 1
#define CONFIG_SAMSUNG_REAR_DUAL 1
#define CONFIG_SAMSUNG_REAR_TRIPLE 1
#define CONFIG_SAMSUNG_REAR_QUADRA 1
#define CONFIG_SAMSUNG_SUPPORT_MULTI_MODULE 1
#define CONFIG_USE_CAMERA_HW_BIG_DATA 1
/* flash LED is the SM5714 (MFD) on this phone */
#define CONFIG_LEDS_SM5714 1

/*
 * 5.4 had these =y; they are OFF in this port until their providers exist on
 * 6.12 (see README "dependencies not yet wired"):
 *   CONFIG_SEC_ABC          sec_abc_send_event()  (Samsung ABC error reports)
 *   CONFIG_ADSP_FACTORY     gyro self-test via the ADSP factory driver
 *   CONFIG_SEC_PM
 *   CONFIG_MSM_GLOBAL_SYNX  synx; cam_sync falls back to its own fences
 */
#endif
