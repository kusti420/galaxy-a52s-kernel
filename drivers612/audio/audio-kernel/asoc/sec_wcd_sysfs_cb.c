// SPDX-License-Identifier: GPL-2.0-or-later
/*
 *  sec_wcd_sysfs_cb.c
 *
 *  Copyright (c) Samsung Electronics
 *
 *  a52sxq: ported from the stock 5.4 techpack (asoc/sec_wcd_sysfs_cb.c).
 *  Feeds /sys/class/audio/earjack/{state,key_state,mic_adc,headset_state,
 *  l_impedance,r_impedance} from the WCD938x MBHC state. Values as 5.4:
 *  state 1 = headset or headphone plugged, key_state / mic_adc = MBHC button
 *  code while a button is held and -1 otherwise, headset_state 1 = 4-pole
 *  only, impedance in ohms (0 until Z-det ran).
 *  Difference to 5.4: NULL checks (the nodes can be read before the codec
 *  is up or after it went away), and the per-read log line is dev_dbg.
 */

#include <linux/input.h>
#include <sound/jack.h>
#include <sound/soc.h>
#include <sound/samsung/sec_audio_sysfs.h>
#include <asoc/wcd-mbhc-v2.h>
#include "sec_wcd_sysfs_cb.h"
#include "codecs/wcd938x/wcd938x.h"
#include "codecs/wcd938x/wcd938x-mbhc.h"
#include "codecs/wcd938x/internal.h"

static struct snd_soc_component *wcd_component;

static struct wcd_mbhc *sec_wcd_get_mbhc(void)
{
	struct snd_soc_component *component = wcd_component;
	struct wcd938x_mbhc *wcd938x_mbhc;

	if (!component)
		return NULL;

	wcd938x_mbhc = wcd938x_soc_get_mbhc(component);
	if (!wcd938x_mbhc)
		return NULL;

	return &wcd938x_mbhc->wcd_mbhc;
}

static int get_jack_status(void)
{
	struct wcd_mbhc *mbhc = sec_wcd_get_mbhc();
	int value = 0;

	if (!mbhc)
		return 0;

	if ((mbhc->hph_status == SND_JACK_HEADSET) ||
	    (mbhc->hph_status == SND_JACK_HEADPHONE))
		value = 1;

	dev_dbg(mbhc->component->dev, "%s: %d\n", __func__, value);

	return value;
}

static int get_key_status(void)
{
	struct wcd_mbhc *mbhc = sec_wcd_get_mbhc();
	int value = -1;

	if (!mbhc)
		return -1;

	if (mbhc->buttons_pressed && mbhc->mbhc_cb &&
	    mbhc->mbhc_cb->map_btn_code_to_num)
		value = mbhc->mbhc_cb->map_btn_code_to_num(mbhc->component);

	dev_dbg(mbhc->component->dev, "%s: %d\n", __func__, value);

	return value;
}

static int get_headset_status(void)
{
	struct wcd_mbhc *mbhc = sec_wcd_get_mbhc();
	int value = 0;

	if (!mbhc)
		return 0;

	if (mbhc->hph_status == SND_JACK_HEADSET)
		value = 1;

	dev_dbg(mbhc->component->dev, "%s: %d\n", __func__, value);

	return value;
}

static int get_l_impedance(void)
{
	struct wcd_mbhc *mbhc = sec_wcd_get_mbhc();

	return mbhc ? mbhc->zl : 0;
}

static int get_r_impedance(void)
{
	struct wcd_mbhc *mbhc = sec_wcd_get_mbhc();

	return mbhc ? mbhc->zr : 0;
}

void register_mbhc_jack_cb(struct snd_soc_component *component)
{
	/*
	 * The card can be bound again (ADSP restart): the callbacks stay
	 * registered in sec_audio_sysfs (-EEXIST, ignored), only the
	 * component they look at is refreshed.
	 */
	if (wcd_component) {
		wcd_component = component;
		return;
	}

	wcd_component = component;
	audio_register_jack_state_cb(get_jack_status);
	audio_register_key_state_cb(get_key_status);
	/* 5.4 registers the key callback for mic_adc as well */
	audio_register_mic_adc_cb(get_key_status);
	audio_register_headset_state_cb(get_headset_status);
	audio_register_l_impedance_cb(get_l_impedance);
	audio_register_r_impedance_cb(get_r_impedance);
}
EXPORT_SYMBOL_GPL(register_mbhc_jack_cb);

void unregister_mbhc_jack_cb(void)
{
	wcd_component = NULL;
}
EXPORT_SYMBOL_GPL(unregister_mbhc_jack_cb);
