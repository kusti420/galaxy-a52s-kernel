/*
 * voippcm: drive the msm-pcm-voip-v2 front end (ALSA PCM 0-3 "VoIP") directly with raw ioctls, silent
 * (zero frames out, captured frames discarded), to test the kernel copy callbacks without the audio HAL.
 *   voippcm run <secs> [rate=8000] [play_periods=2] [cap_periods=2]   both directions, 1 period per step
 *   voippcm early                 playback only, write 4 periods before capture is prepared (empty-queue case)
 *   voippcm hw2 <secs>            hw_params twice on both directions, then run
 * Prints per-direction counts of ok / errno results. Root (audio device nodes). Build: tools/voippcm/build.sh
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

static struct snd_mask *pmask(struct snd_pcm_hw_params *p, int n)
{ return &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK]; }
static struct snd_interval *pint(struct snd_pcm_hw_params *p, int n)
{ return &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL]; }
static void setmask(struct snd_pcm_hw_params *p, int n, unsigned v)
{ struct snd_mask *m = pmask(p, n); memset(m, 0, sizeof(*m)); m->bits[v >> 5] |= 1u << (v & 31); }
static void setint(struct snd_pcm_hw_params *p, int n, unsigned v)
{ struct snd_interval *i = pint(p, n); i->min = i->max = v; i->integer = 1; i->openmin = i->openmax = 0; }

static void init_params(struct snd_pcm_hw_params *p)
{
	int n;

	memset(p, 0, sizeof(*p));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_MASK; n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++)
		memset(pmask(p, n), 0xff, sizeof(struct snd_mask));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++) {
		pint(p, n)->min = 0; pint(p, n)->max = ~0u;
	}
	p->rmask = ~0u; p->cmask = 0; p->info = ~0u;
}

static int pcm_setup(int fd, unsigned rate, unsigned periods, unsigned period_frames, const char *what)
{
	struct snd_pcm_hw_params p;
	struct snd_pcm_sw_params sw;

	init_params(&p);
	setmask(&p, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	setmask(&p, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	setmask(&p, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	setint(&p, SNDRV_PCM_HW_PARAM_CHANNELS, 1);
	setint(&p, SNDRV_PCM_HW_PARAM_RATE, rate);
	setint(&p, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period_frames);
	setint(&p, SNDRV_PCM_HW_PARAM_PERIODS, periods);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &p)) {
		printf("%s: HW_PARAMS failed: %s\n", what, strerror(errno));
		return -1;
	}
	memset(&sw, 0, sizeof(sw));
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw.period_step = 1; sw.avail_min = 1;
	sw.start_threshold = 1; sw.stop_threshold = periods * period_frames;
	sw.boundary = periods * period_frames;
	while (sw.boundary * 2 <= 0x7fffffffUL - periods * period_frames)
		sw.boundary *= 2;
	if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw))
		printf("%s: SW_PARAMS failed: %s (ignored)\n", what, strerror(errno));
	return 0;
}

struct cnt { long ok, err[140]; };
static void tally(struct cnt *c, int r) { if (r == 0) c->ok++; else if (errno > 0 && errno < 140) c->err[errno]++; }
static void show(const char *w, struct cnt *c)
{
	int e;

	printf("%s: ok %ld", w, c->ok);
	for (e = 1; e < 140; e++)
		if (c->err[e])
			printf(", %s x%ld", strerror(e), c->err[e]);
	printf("\n");
}

static int xfer(int fd, short *buf, unsigned frames, int write)
{
	struct snd_xferi x = { .buf = buf, .frames = frames };
	int r = ioctl(fd, write ? SNDRV_PCM_IOCTL_WRITEI_FRAMES : SNDRV_PCM_IOCTL_READI_FRAMES, &x);

	if (r && (errno == EPIPE || errno == ESTRPIPE || errno == EBADFD))
		ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
	return r;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "run";
	int secs = argc > 2 ? atoi(argv[2]) : 5;
	unsigned rate = argc > 3 ? atoi(argv[3]) : 8000;
	unsigned pp = argc > 4 ? atoi(argv[4]) : 2, cp = argc > 5 ? atoi(argv[5]) : 2;
	unsigned pf = rate / 50;	/* 20 ms */
	static short buf[4096];
	struct cnt pc = { 0 }, cc = { 0 };
	int p, c, i;
	time_t end;

	p = open("/dev/snd/pcmC0D3p", O_RDWR);
	if (p < 0) { printf("open playback: %s\n", strerror(errno)); return 1; }
	if (!strcmp(mode, "early")) {
		if (pcm_setup(p, rate, pp, pf, "playback") || ioctl(p, SNDRV_PCM_IOCTL_PREPARE))
			printf("playback prepare: %s\n", strerror(errno));
		for (i = 0; i < 4; i++) {
			int r = xfer(p, buf, pf, 1);

			printf("early write %d: %s\n", i + 1, r ? strerror(errno) : "ok");
		}
		close(p);
		return 0;
	}
	c = open("/dev/snd/pcmC0D3c", O_RDWR);
	if (c < 0) { printf("open capture: %s\n", strerror(errno)); return 1; }
	if (!strcmp(mode, "hw2")) {
		pcm_setup(p, rate, 2, pf, "playback(1)"); pcm_setup(c, rate, 2, pf, "capture(1)");
	}
	if (pcm_setup(p, rate, pp, pf, "playback") || pcm_setup(c, rate, cp, pf, "capture"))
		return 1;
	if (ioctl(p, SNDRV_PCM_IOCTL_PREPARE)) printf("playback prepare: %s\n", strerror(errno));
	if (ioctl(c, SNDRV_PCM_IOCTL_PREPARE)) printf("capture prepare: %s\n", strerror(errno));
	printf("voippcm %s: rate %u, periods %u/%u, period %u frames, %d s\n", mode, rate, pp, cp, pf, secs);
	fflush(stdout);
	end = time(NULL) + secs;
	while (time(NULL) < end) {
		tally(&pc, xfer(p, buf, pf, 1));
		tally(&cc, xfer(c, buf, pf, 0));
	}
	show("playback", &pc); show("capture", &cc);
	close(c); close(p);
	printf("closed\n");
	return 0;
}
