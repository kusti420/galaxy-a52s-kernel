/* lsmioctl: does the PCM core let the sound trigger HAL's private ioctls through?
 *
 * The phone's closed sound trigger HAL (sound_trigger.primary.lahaina.so) drives the ADSP listen
 * sessions with SNDRV_LSM_* ioctls (magic 'U') on the fd of a "Listen N Audio Service" capture PCM
 * (drivers612/SPEC/02 row AUD-50). 5.4 QGKI hands them to msm-lsm-client; the GKI 6.12 PCM core
 * answers -ENOTTY unless the kernel / the driver was fixed. This tool opens that PCM the way
 * tinyalsa does and issues the same ioctl numbers the HAL blob issues, choosing arguments that the DRIVER rejects or stores without
 * talking to the ADSP. Per ioctl: name, number, return, errno. ENOTTY on a 'U' ioctl = refused by
 * the PCM core; anything else (0, EINVAL, EFAULT, ENXIO ...) = it reached the driver.
 *
 * Numbers the blob issues (disassembly of vendor/lib{,64}/hw/sound_trigger.primary.lahaina.so, sha256
 * 0934b902... / d4f72d1e...; 32-bit value / 64-bit value where the argument holds a pointer):
 *   SET_SESSION_DATA_V2 0x40185512, SET_PORT 0x550d, SET_INPUT_HW_PARAMS 0x40085511,
 *   SET_MODULE_PARAMS_V2 0x400c5513 / 0x40105513 (sound model, confidence levels, mode, custom params,
 *   deregistration), SET_FWK_MODE_CONFIG 0x4004550e, START 0x40045504, EVENT_STATUS_V3 0x400c550f
 *   (blocking wait in the callback thread), GET_MODULE_PARAMS 0xc0165514, LAB_CONTROL 0x40045508,
 *   STOP_LAB 0x5509, ABORT_EVENT 0x40045503, STOP 0x40045505. Not issued by this blob:
 *   SET_SESSION_DATA (v1) 0x40045506, REG_SND_MODEL_V2 0x40145507 / 0x40205507, SET_PARAMS,
 *   SET_MODULE_PARAMS (v1), DEREG_SND_MODEL, OUT_FORMAT_CFG, EVENT_STATUS (v1).
 *
 * No sound, no capture start (no PREPARE/START/read), needs root (or the audio group).
 * Build both ABIs (the stock audio HAL process is 32-bit = compat ioctl path, LineageOS' may be
 * 64-bit): ./build.sh -> lsmioctl (aarch64), lsmioctl32 (armv7). Static, no libc.
 *
 *   lsmioctl [-c card] [-d device | -n "name substring"] [--no-hwparams] [--session] [--port] [--model] | --list
 *     --list         print the ioctl numbers of this ABI and exit
 *     default        PCM_INFO, one 'U' ioctl BEFORE hw_params (shows whether the fix needs arming),
 *                    HW_PARAMS (16 kHz mono S16, 320 frames x 8; a driver-side fix arms itself there),
 *                    then SET_INPUT_HW_PARAMS (stored only), SET_SESSION_DATA + _V2 with an invalid
 *                    app id (driver: -EINVAL "Invalid App id"), SET_FWK_MODE_CONFIG 0 (no-op: mode
 *                    already 0), SET_MODULE_PARAMS_V2 with num_params 15 (driver: -EINVAL), an unknown
 *                    'U' number 0x7f (control: the driver's own error, not ENOTTY), HW_FREE, close.
 *                    Nothing of this reaches the ADSP.
 *     --no-hwparams  skip HW_PARAMS (tests an image-side fix without arming)
 *     --session      ALSO a valid SET_SESSION_DATA_V2 (app id 2, 1 stage, app_type 5, LPI): the driver
 *                    opens a real ADSP LSM session (q6lsm_open); closed again with the PCM
 *     --port         ALSO SET_PORT (ADSP set-param; only meaningful after --session)
 *     --model        ALSO a deliberately invalid REG_SND_MODEL_V2 (255 confidence levels, no data:
 *                    -EINVAL before any allocation)
 *   exit 0 = every 'U' ioctl after hw_params reached the driver, 1 = at least one refused, 2 = setup error
 */
#if defined(__aarch64__)
#define NR_openat 56
#define NR_close 57
#define NR_read 63
#define NR_write 64
#define NR_ioctl 29
#define NR_exit 93
static long sc(long n, long a, long b, long c, long d) {
	register long x8 __asm__("x8") = n, x0 __asm__("x0") = a, x1 __asm__("x1") = b,
		      x2 __asm__("x2") = c, x3 __asm__("x3") = d;
	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define ABI "aarch64"
#elif defined(__arm__)
#define NR_openat 322
#define NR_close 6
#define NR_read 3
#define NR_write 4
#define NR_ioctl 54
#define NR_exit 1
static long sc(long n, long a, long b, long c, long d) {
	register long r7 __asm__("r7") = n, r0 __asm__("r0") = a, r1 __asm__("r1") = b,
		      r2 __asm__("r2") = c, r3 __asm__("r3") = d;
	__asm__ volatile("svc 0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3) : "memory");
	return r0;
}
#define ABI "arm32 (compat)"
#else
#error arch
#endif

typedef unsigned int u32; typedef unsigned short u16; typedef unsigned char u8;
void *memset(void *d, int c, unsigned long n) { u8 *p = d; while (n--) *p++ = (u8)c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { u8 *p = d; const u8 *q = s; while (n--) *p++ = *q++; return d; }
static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static int seq(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return *a == *b; }
static const char *sfind(const char *h, const char *n) {
	unsigned long l = slen(n);
	for (; *h; h++) { unsigned long i = 0; while (i < l && h[i] == n[i]) i++; if (i == l) return h; }
	return 0;
}
static char ob[512]; static unsigned on;
static void flush(void) { if (on) sc(NR_write, 1, (long)ob, on, 0); on = 0; }
static void pc(char c) { if (on == sizeof ob) flush(); ob[on++] = c; }
static void ps(const char *s) { while (*s) pc(*s++); }
static void pu(unsigned long v) { char t[24]; int i = 0; do { t[i++] = '0' + v % 10; v /= 10; } while (v); while (i) pc(t[--i]); }
static void pd(long v) { if (v < 0) { pc('-'); v = -v; } pu((unsigned long)v); }
static void px(u32 v) { int i; ps("0x"); for (i = 28; i >= 0; i -= 4) pc("0123456789abcdef"[(v >> i) & 15]); }
static const char *ename(long e) {
	switch (e) {
	case 0: return "OK"; case 1: return "EPERM"; case 2: return "ENOENT"; case 5: return "EIO";
	case 6: return "ENXIO"; case 9: return "EBADF"; case 11: return "EAGAIN"; case 12: return "ENOMEM";
	case 13: return "EACCES"; case 14: return "EFAULT"; case 16: return "EBUSY"; case 19: return "ENODEV";
	case 22: return "EINVAL"; case 25: return "ENOTTY"; case 32: return "EPIPE"; case 77: return "EBADFD";
	case 110: return "ETIMEDOUT"; case 515: return "ENOIOCTLCMD"; default: return "?";
	}
}

#define IOC(dir, type, nr, size) (((u32)(dir) << 30) | ((u32)(size) << 16) | ((u32)(type) << 8) | (u32)(nr))
#define IO_(t, n) IOC(0, t, n, 0)
#define IOW_(t, n, T) IOC(1, t, n, sizeof(T))
#define IOR_(t, n, T) IOC(2, t, n, sizeof(T))
#define IOWR_(t, n, T) IOC(3, t, n, sizeof(T))

/* ALSA (include/uapi/sound/asound.h) */
struct snd_mask { u32 bits[8]; };
struct snd_interval { u32 min, max; u32 flags; /* openmin:1 openmax:1 integer:1 empty:1 */ };
struct snd_pcm_hw_params {
	u32 flags; struct snd_mask masks[3]; struct snd_mask mres[5];
	struct snd_interval intervals[12]; struct snd_interval ires[9];
	u32 rmask, cmask, info, msbits, rate_num, rate_den; unsigned long fifo_size; u8 reserved[64];
};
struct snd_pcm_info { u8 b[288]; };
#define SNDRV_PCM_IOCTL_INFO IOR_('A', 0x01, struct snd_pcm_info)
#define SNDRV_PCM_IOCTL_HW_PARAMS IOWR_('A', 0x11, struct snd_pcm_hw_params)
#define SNDRV_PCM_IOCTL_HW_FREE IO_('A', 0x12)

/* LSM (5.4 techpack/audio/include/uapi/audio/sound/lsm_params.h == 6.12 AK/include/uapi/sound/lsm_params.h) */
struct snd_lsm_session_data { u32 app_id; };
struct snd_lsm_stage_info { u32 app_type, lpi_enable; };
struct snd_lsm_session_data_v2 { u32 app_id, num_stages; struct snd_lsm_stage_info stage_info[2]; };
struct snd_lsm_module_params { u8 *params; u32 num_params, data_size; };
struct snd_lsm_input_hw_params { u32 sample_rate; u16 bit_width, num_channels; } __attribute__((packed));
struct snd_lsm_sound_model_v2 { u8 *data; u8 *confidence_level; u32 data_size; u32 detection_mode;
	u8 num_confidence_levels; _Bool detect_failure; };
#define SNDRV_LSM_SET_SESSION_DATA IOW_('U', 0x06, struct snd_lsm_session_data)
#define SNDRV_LSM_REG_SND_MODEL_V2 IOW_('U', 0x07, struct snd_lsm_sound_model_v2)
#define SNDRV_LSM_SET_PORT IO_('U', 0x0D)
#define SNDRV_LSM_SET_FWK_MODE_CONFIG IOW_('U', 0x0E, u32)
#define SNDRV_LSM_SET_INPUT_HW_PARAMS IOW_('U', 0x11, struct snd_lsm_input_hw_params)
#define SNDRV_LSM_SET_SESSION_DATA_V2 IOW_('U', 0x12, struct snd_lsm_session_data_v2)
#define SNDRV_LSM_SET_MODULE_PARAMS_V2 IOW_('U', 0x13, struct snd_lsm_module_params)
#define LSM_UNKNOWN IOW_('U', 0x7f, u32)

static int fd, refused, reached;
static long doit(const char *name, u32 cmd, void *arg, int counted) {
	long r = sc(NR_ioctl, fd, (long)cmd, (long)arg, 0);
	ps(name); pc(' '); px(cmd); ps(" ret="); pd(r < 0 ? -1 : r); ps(" errno="); pd(r < 0 ? -r : 0);
	pc('('); ps(ename(r < 0 ? -r : 0)); pc(')');
	if (((cmd >> 8) & 0xff) == 'U') {
		ps(r == -25 ? "  REFUSED BY PCM CORE" : "  REACHED DRIVER");
		if (counted) { if (r == -25) refused++; else reached++; }
	}
	pc('\n');
	return r;
}
static void iset(struct snd_pcm_hw_params *p, int n, u32 v) {
	p->intervals[n - 8].min = p->intervals[n - 8].max = v; p->intervals[n - 8].flags = 4;
}
static long atoi_(const char *s) { long v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0'; return v; }

static char buf[16384];
static int main_(int argc, char **argv) {
	int card = 0, dev = -1, hwp = 1, session = 0, port = 0, model = 0, i;
	const char *want = "Listen 1 Audio Service";
	char path[40]; long r;

	for (i = 1; i < argc; i++) {
		if (seq(argv[i], "-c") && i + 1 < argc) card = atoi_(argv[++i]);
		else if (seq(argv[i], "-d") && i + 1 < argc) dev = atoi_(argv[++i]);
		else if (seq(argv[i], "-n") && i + 1 < argc) want = argv[++i];
		else if (seq(argv[i], "--no-hwparams")) hwp = 0;
		else if (seq(argv[i], "--hwparams")) hwp = 1;
		else if (seq(argv[i], "--session")) session = 1;
		else if (seq(argv[i], "--port")) port = 1;
		else if (seq(argv[i], "--model")) model = 1;
		else if (seq(argv[i], "--list")) {
			static const struct { const char *n; u32 c; } t[] = {
				{ "SNDRV_PCM_IOCTL_INFO", SNDRV_PCM_IOCTL_INFO }, { "SNDRV_PCM_IOCTL_HW_PARAMS", SNDRV_PCM_IOCTL_HW_PARAMS },
				{ "SNDRV_LSM_SET_SESSION_DATA", SNDRV_LSM_SET_SESSION_DATA }, { "SNDRV_LSM_REG_SND_MODEL_V2", SNDRV_LSM_REG_SND_MODEL_V2 },
				{ "SNDRV_LSM_SET_PORT", SNDRV_LSM_SET_PORT }, { "SNDRV_LSM_SET_FWK_MODE_CONFIG", SNDRV_LSM_SET_FWK_MODE_CONFIG },
				{ "SNDRV_LSM_SET_INPUT_HW_PARAMS", SNDRV_LSM_SET_INPUT_HW_PARAMS }, { "SNDRV_LSM_SET_SESSION_DATA_V2", SNDRV_LSM_SET_SESSION_DATA_V2 },
				{ "SNDRV_LSM_SET_MODULE_PARAMS_V2", SNDRV_LSM_SET_MODULE_PARAMS_V2 }, { "unknown 'U' 0x7f", LSM_UNKNOWN } };
			unsigned k;
			ps("ABI " ABI "\n");
			for (k = 0; k < sizeof t / sizeof t[0]; k++) { px(t[k].c); pc(' '); ps(t[k].n); pc('\n'); }
			flush(); return 0;
		}
		else { ps("usage: lsmioctl [-c card] [-d dev | -n name] [--no-hwparams] [--session] [--port] [--model]\n"); flush(); return 2; }
	}
	ps("lsmioctl ABI " ABI ", sizeof(long)="); pu(sizeof(long)); pc('\n');
	if (dev < 0) {
		/* /proc/asound/pcm: "00-16: Listen 1 Audio Service (*) :  : capture 1" */
		long f = sc(NR_openat, -100, (long)"/proc/asound/pcm", 0, 0), n = 0, k;
		char *l, *e;
		if (f < 0) { ps("cannot open /proc/asound/pcm errno="); pd(-f); pc('\n'); flush(); return 2; }
		while (n < (long)sizeof buf - 1 && (k = sc(NR_read, f, (long)(buf + n), sizeof buf - 1 - n, 0)) > 0) n += k;
		sc(NR_close, f, 0, 0, 0); buf[n] = 0;
		for (l = buf; *l; l = e + 1) {
			for (e = l; *e && *e != '\n'; e++) ;
			char s = *e; *e = 0;
			if (sfind(l, want) && sfind(l, "capture") && l[2] == '-' && atoi_(l) == card) {
				dev = atoi_(l + 3); ps("pcm: "); ps(l); pc('\n'); *e = s; break;
			}
			if (!s) break;
			*e = s;
		}
		if (dev < 0) { ps("no capture PCM named \""); ps(want); ps("\" on card "); pd(card); ps(" in /proc/asound/pcm\n"); flush(); return 2; }
	}
	{ char *p = path; const char *a = "/dev/snd/pcmC"; while (*a) *p++ = *a++;
	  if (card >= 10) *p++ = '0' + card / 10; *p++ = '0' + card % 10; *p++ = 'D';
	  if (dev >= 100) *p++ = '0' + dev / 100; if (dev >= 10) *p++ = '0' + dev / 10 % 10; *p++ = '0' + dev % 10;
	  *p++ = 'c'; *p = 0; }
	r = sc(NR_openat, -100, (long)path, 2 /* O_RDWR */ | 04000 /* O_NONBLOCK */, 0);
	ps("open "); ps(path); ps(" O_RDWR|O_NONBLOCK -> "); pd(r < 0 ? -1 : r); if (r < 0) { ps(" errno="); pd(-r); pc('('); ps(ename(-r)); pc(')'); }
	pc('\n');
	if (r < 0) { flush(); return 2; }
	fd = (int)r;

	{ static struct snd_pcm_info info; doit("SNDRV_PCM_IOCTL_INFO", SNDRV_PCM_IOCTL_INFO, &info, 0); }
	{ struct snd_lsm_input_hw_params ip = { 16000, 16, 1 };
	  doit("pre-hw_params SNDRV_LSM_SET_INPUT_HW_PARAMS", SNDRV_LSM_SET_INPUT_HW_PARAMS, &ip, !hwp); }
	if (hwp) {
		static struct snd_pcm_hw_params p; int m;
		memset(&p, 0, sizeof p);
		for (m = 0; m < 3; m++) p.masks[m].bits[0] = p.masks[m].bits[1] = ~0u;
		for (m = 0; m < 12; m++) { p.intervals[m].min = 0; p.intervals[m].max = ~0u; }
		p.rmask = ~0u; p.info = ~0u;
		p.masks[0].bits[0] = 1u << 3; p.masks[0].bits[1] = 0;	/* ACCESS RW_INTERLEAVED */
		p.masks[1].bits[0] = 1u << 2; p.masks[1].bits[1] = 0;	/* FORMAT S16_LE */
		p.masks[2].bits[0] = 1u << 0; p.masks[2].bits[1] = 0;	/* SUBFORMAT STD */
		iset(&p, 8, 16); iset(&p, 9, 16); iset(&p, 10, 1); iset(&p, 11, 16000);
		iset(&p, 13, 320); iset(&p, 15, 8);
		r = doit("SNDRV_PCM_IOCTL_HW_PARAMS(16k/1ch/S16, 320x8)", SNDRV_PCM_IOCTL_HW_PARAMS, &p, 0);
		if (r < 0) ps("note: HW_PARAMS failed; a driver-side fix may not be armed\n");
	}
	{ struct snd_lsm_input_hw_params ip = { 16000, 16, 1 };
	  doit("SNDRV_LSM_SET_INPUT_HW_PARAMS", SNDRV_LSM_SET_INPUT_HW_PARAMS, &ip, 1); }
	{ struct snd_lsm_session_data sd = { 0x7fffffff };
	  doit("SNDRV_LSM_SET_SESSION_DATA(bad app id)", SNDRV_LSM_SET_SESSION_DATA, &sd, 1); }
	{ struct snd_lsm_session_data_v2 sd; memset(&sd, 0, sizeof sd); sd.app_id = 0x7fffffff; sd.num_stages = 1;
	  doit("SNDRV_LSM_SET_SESSION_DATA_V2(bad app id)", SNDRV_LSM_SET_SESSION_DATA_V2, &sd, 1); }
	if (session) {
		struct snd_lsm_session_data_v2 sd; memset(&sd, 0, sizeof sd);
		sd.app_id = 2; sd.num_stages = 1; sd.stage_info[0].app_type = 5; sd.stage_info[0].lpi_enable = 1;
		doit("SNDRV_LSM_SET_SESSION_DATA_V2(app 2, 1 stage: ADSP session open)", SNDRV_LSM_SET_SESSION_DATA_V2, &sd, 1);
	}
	if (port) doit("SNDRV_LSM_SET_PORT", SNDRV_LSM_SET_PORT, 0, 1);
	{ u32 mode = 0; doit("SNDRV_LSM_SET_FWK_MODE_CONFIG(0)", SNDRV_LSM_SET_FWK_MODE_CONFIG, &mode, 1); }
	{ struct snd_lsm_module_params mp; memset(&mp, 0, sizeof mp); mp.num_params = 15; mp.data_size = 1;
	  doit("SNDRV_LSM_SET_MODULE_PARAMS_V2(15 params: invalid)", SNDRV_LSM_SET_MODULE_PARAMS_V2, &mp, 1); }
	if (model) {
		struct snd_lsm_sound_model_v2 sm; memset(&sm, 0, sizeof sm); sm.num_confidence_levels = 255; sm.detection_mode = 1;
		doit("SNDRV_LSM_REG_SND_MODEL_V2(255 conf levels: invalid)", SNDRV_LSM_REG_SND_MODEL_V2, &sm, 1);
	}
	{ u32 x = 0; doit("control: unknown 'U' 0x7f", LSM_UNKNOWN, &x, 1); }
	if (hwp) doit("SNDRV_PCM_IOCTL_HW_FREE", SNDRV_PCM_IOCTL_HW_FREE, 0, 0);
	sc(NR_close, fd, 0, 0, 0);
	ps("VERDICT: "); pd(reached); ps(" 'U' ioctls REACHED DRIVER, "); pd(refused);
	ps(refused ? " REFUSED BY PCM CORE (ENOTTY): voice wake-up cannot work\n" : " refused: the PCM fd accepts the HAL's LSM ioctls\n");
	flush();
	return refused ? 1 : 0;
}

void start_c(long *sp) { sc(NR_exit, main_((int)sp[0], (char **)(sp + 1)), 0, 0, 0); for (;;) ; }
#if defined(__aarch64__)
__asm__(".globl _start\n_start:\n mov x29, #0\n mov x30, #0\n mov x0, sp\n and sp, x0, #-16\n bl start_c\n");
#else
__asm__(".syntax unified\n.arm\n.globl _start\n_start:\n mov fp, #0\n mov lr, #0\n mov r0, sp\n bic sp, sp, #7\n bl start_c\n");
#endif
