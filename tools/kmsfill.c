// SPDX-License-Identifier: GPL-2.0-only
/*
 * kmsfill: minimal DRM/KMS test for the bring-up shell. Picks the first connected connector,
 * its first (or argv[1]-th) mode, makes a dumb buffer, paints eight colour bars with a white
 * frame and sets it on the CRTC with the legacy SETCRTC call. Then sleeps argv[2] seconds
 * (default 20). Static, built with the kernel's nolibc. Prints every step.
 */
#include <drm/drm.h>
#include <drm/drm_mode.h>

static int xioctl(int fd, unsigned long req, void *arg, const char *what)
{
	int r = ioctl(fd, req, arg);
	if (r < 0) { printf("kmsfill: %s failed: errno %d\n", what, errno); }
	return r;
}

int main(int argc, char **argv)
{
	static uint32_t crtcs[16], conns[16], encs[16], cencs[16];
	static struct drm_mode_modeinfo modes[32];
	struct drm_mode_card_res res = { 0 };
	struct drm_mode_get_connector c;
	struct drm_mode_get_encoder e = { 0 };
	struct drm_mode_create_dumb d = { 0 };
	struct drm_mode_map_dumb m = { 0 };
	struct drm_mode_fb_cmd f = { 0 };
	struct drm_mode_crtc s = { 0 };
	int want = argc > 1 ? atoi(argv[1]) : 0, secs = argc > 2 ? atoi(argv[2]) : 20;
	int fd = open("/dev/dri/card0", O_RDWR), i, found = -1;
	uint32_t crtc = 0, x, y, *px;
	static const uint32_t bar[8] = { 0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x202020 };

	if (fd < 0) { printf("kmsfill: open /dev/dri/card0: errno %d\n", errno); return 1; }
	res.crtc_id_ptr = (uint64_t)(unsigned long)crtcs; res.count_crtcs = 16;
	res.connector_id_ptr = (uint64_t)(unsigned long)conns; res.count_connectors = 16;
	res.encoder_id_ptr = (uint64_t)(unsigned long)encs; res.count_encoders = 16;
	if (xioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res, "GETRESOURCES") < 0) return 1;
	printf("kmsfill: %u crtcs, %u connectors, %u encoders\n", res.count_crtcs, res.count_connectors, res.count_encoders);
	for (i = 0; i < (int)res.count_connectors && i < 16; i++) {
		memset(&c, 0, sizeof(c));
		c.connector_id = conns[i];
		c.modes_ptr = (uint64_t)(unsigned long)modes; c.count_modes = 32;
		c.encoders_ptr = (uint64_t)(unsigned long)cencs; c.count_encoders = 16;
		if (xioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c, "GETCONNECTOR") < 0) continue;
		printf("kmsfill: connector %u type %u connection %u modes %u encoder %u\n", c.connector_id,
		       c.connector_type, c.connection, c.count_modes, c.encoder_id);
		if (c.connection == 1 && c.count_modes && found < 0) { found = i; break; }
	}
	if (found < 0) { printf("kmsfill: no connected connector with modes\n"); return 1; }
	if (want >= (int)c.count_modes) want = 0;
	printf("kmsfill: mode %d: %s %ux%u@%u\n", want, modes[want].name, modes[want].hdisplay, modes[want].vdisplay, modes[want].vrefresh);
	e.encoder_id = c.encoder_id ? c.encoder_id : cencs[0];
	if (xioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e, "GETENCODER") < 0) return 1;
	crtc = e.crtc_id;
	for (i = 0; !crtc && i < (int)res.count_crtcs && i < 16; i++)
		if (e.possible_crtcs & (1u << i)) crtc = crtcs[i];
	printf("kmsfill: encoder %u possible_crtcs %#x -> crtc %u\n", e.encoder_id, e.possible_crtcs, crtc);
	d.width = modes[want].hdisplay; d.height = modes[want].vdisplay; d.bpp = 32;
	if (xioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &d, "CREATE_DUMB") < 0) return 1;
	f.width = d.width; f.height = d.height; f.pitch = d.pitch; f.bpp = 32; f.depth = 24; f.handle = d.handle;
	if (xioctl(fd, DRM_IOCTL_MODE_ADDFB, &f, "ADDFB") < 0) return 1;
	m.handle = d.handle;
	if (xioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m, "MAP_DUMB") < 0) return 1;
	px = mmap(0, d.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
	if (px == MAP_FAILED) { printf("kmsfill: mmap failed: errno %d\n", errno); return 1; }
	for (y = 0; y < d.height; y++)
		for (x = 0; x < d.width; x++) {
			uint32_t v = bar[(y * 8) / d.height];
			if (x < 12 || y < 12 || x >= d.width - 12 || y >= d.height - 12) v = 0xffffff;
			px[y * (d.pitch / 4) + x] = v;
		}
	printf("kmsfill: fb %u painted (%ux%u pitch %u), SETCRTC...\n", f.fb_id, d.width, d.height, d.pitch);
	s.crtc_id = crtc; s.fb_id = f.fb_id; s.set_connectors_ptr = (uint64_t)(unsigned long)&c.connector_id;
	s.count_connectors = 1; s.mode = modes[want]; s.mode_valid = 1;
	if (xioctl(fd, DRM_IOCTL_MODE_SETCRTC, &s, "SETCRTC") < 0) return 1;
	printf("kmsfill: SETCRTC ok, holding %d s\n", secs);
	sleep(secs);
	return 0;
}
