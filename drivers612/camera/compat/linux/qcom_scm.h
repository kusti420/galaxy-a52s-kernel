/* SPDX-License-Identifier: GPL-2.0-only */
/* 6.12: the header moved; the camera calls are exported by soc-repo's qcom-scm */
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/types.h>
/* exported by soc-repo's qcom-scm.ko; declared in soc-repo's copy of the header only */
extern int qcom_scm_smmu_notify_secure_lut(u64 dev_id, bool secure);
extern int qcom_scm_camera_protect_phy_lanes(bool protect, u64 regmask);
