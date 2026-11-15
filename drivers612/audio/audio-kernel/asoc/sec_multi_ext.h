/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * a52sxq 6.12 port: 5.4 had SOC_SINGLE_MULTI_EXT and snd_soc_info_multi_ext() in the kernel
 * (Qualcomm addition to sound/soc.h and soc-ops.c). GKI 6.12 does not; the legacy techpack
 * carries a private copy per file. Same copy (from msm-pcm-voice-v2.c) for the Samsung files.
 */
#ifndef __SEC_MULTI_EXT_H
#define __SEC_MULTI_EXT_H

#define SOC_SINGLE_MULTI_EXT(xname, xreg, xshift, xmax, xinvert, xcount, \
	xhandler_get, xhandler_put) \
{	.iface = SNDRV_CTL_ELEM_IFACE_MIXER, .name = xname, \
	.info = snd_soc_info_multi_ext, \
	.get = xhandler_get, .put = xhandler_put, \
	.private_value = (unsigned long)&(struct soc_mixer_control) { \
		.reg = xreg, .shift = xshift, .rshift = xshift, .max = xcount, \
		.platform_max = xmax, .invert = xinvert \
	} \
}

static int snd_soc_info_multi_ext(struct snd_kcontrol *kcontrol,
	struct snd_ctl_elem_info *uinfo)
{
	struct soc_mixer_control *mc =
		(struct soc_mixer_control *)kcontrol->private_value;
	int platform_max;

	if (!mc->platform_max)
		mc->platform_max = mc->max;
	platform_max = mc->platform_max;

	if (platform_max == 1 && !strnstr(kcontrol->id.name, " Volume", 30))
		uinfo->type = SNDRV_CTL_ELEM_TYPE_BOOLEAN;
	else
		uinfo->type = SNDRV_CTL_ELEM_TYPE_INTEGER;

	uinfo->count = mc->max;
	uinfo->value.integer.min = 0;
	uinfo->value.integer.max = platform_max;
	return 0;
}

#endif /* __SEC_MULTI_EXT_H */
