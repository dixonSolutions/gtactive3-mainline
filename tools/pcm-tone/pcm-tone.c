// SPDX-License-Identifier: GPL-2.0-only
/*
 * pcm-tone: tiny static ALSA test tool for the bring-up initramfs (nolibc,
 * raw ALSA ioctls, no alsa-lib).
 *
 *   pcm-tone ctls CARD                   list the mixer controls of card CARD
 *   pcm-tone set CARD CTL VAL[,VAL..]    set a control; CTL is a numid from
 *                                        "ctls" or the name with '_' for ' ';
 *                                        enum values by index or item name
 *   pcm-tone play CARD DEV SECS [HZ] [SHIFT]
 *                                        play a sine on /dev/snd/pcmC<CARD>D<DEV>p:
 *                                        48 kHz S16_LE stereo, HZ a multiple of
 *                                        500 (default 1000), amplitude full
 *                                        scale >> SHIFT (default 3, -18 dBFS)
 *
 * Build (static, same flags as initramfs/init.c):
 *   aarch64-linux-gnu-gcc -Os -static -nostdlib -fno-stack-protector \
 *     -I$K/tools/include/nolibc -I$P/build/hdr/usr/include \
 *     -include $K/tools/include/nolibc/nolibc.h -o pcm-tone pcm-tone.c -lgcc
 */

#include <sound/asound.h>

#define RATE		48000
#define CHANNELS	2
#define PERIOD_FRAMES	960	/* 20 ms, 3840 bytes */
#define PERIODS		4

/* one 500 Hz period at 48 kHz, Q15 */
static const short sine96[96] = {
	0, 2143, 4277, 6393, 8481, 10533, 12539, 14492, 16383, 18204, 19947,
	21605, 23170, 24636, 25996, 27245, 28377, 29388, 30273, 31028, 31650,
	32137, 32487, 32697, 32767, 32697, 32487, 32137, 31650, 31028, 30273,
	29388, 28377, 27245, 25996, 24636, 23170, 21605, 19947, 18204, 16383,
	14492, 12539, 10533, 8481, 6393, 4277, 2143, 0, -2143, -4277, -6393,
	-8481, -10533, -12539, -14492, -16383, -18204, -19947, -21605, -23170,
	-24636, -25996, -27245, -28377, -29388, -30273, -31028, -31650, -32137,
	-32487, -32697, -32767, -32697, -32487, -32137, -31650, -31028, -30273,
	-29388, -28377, -27245, -25996, -24636, -23170, -21605, -19947, -18204,
	-16384, -14492, -12539, -10533, -8481, -6393, -4277, -2143,
};

static int ctl_open(const char *card)
{
	char path[32];
	int fd;

	snprintf(path, sizeof(path), "/dev/snd/controlC%s", card);
	fd = open(path, O_RDWR);
	if (fd < 0)
		printf("open %s: errno %d\n", path, errno);
	return fd;
}

static const char *type_name(int t)
{
	switch (t) {
	case SNDRV_CTL_ELEM_TYPE_BOOLEAN: return "bool";
	case SNDRV_CTL_ELEM_TYPE_INTEGER: return "int";
	case SNDRV_CTL_ELEM_TYPE_ENUMERATED: return "enum";
	case SNDRV_CTL_ELEM_TYPE_BYTES: return "bytes";
	case SNDRV_CTL_ELEM_TYPE_INTEGER64: return "int64";
	default: return "?";
	}
}

static int enum_item(int fd, struct snd_ctl_elem_info *info, unsigned int i,
		     char *name, int len)
{
	struct snd_ctl_elem_info e = *info;

	e.value.enumerated.item = i;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &e) < 0)
		return -1;
	snprintf(name, len, "%s", e.value.enumerated.name);
	return 0;
}

static int cmd_ctls(const char *card)
{
	static struct snd_ctl_elem_id ids[512];
	struct snd_ctl_elem_list list;
	int fd = ctl_open(card);
	unsigned int i, j;

	if (fd < 0)
		return 1;
	memset(&list, 0, sizeof(list));
	list.space = 512;
	list.pids = ids;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
		printf("ELEM_LIST: errno %d\n", errno);
		return 1;
	}
	for (i = 0; i < list.used; i++) {
		struct snd_ctl_elem_info info;
		struct snd_ctl_elem_value val;
		char item[64];

		memset(&info, 0, sizeof(info));
		info.id = ids[i];
		if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0)
			continue;
		memset(&val, 0, sizeof(val));
		val.id = ids[i];
		ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &val);
		printf("%u '%s' %s", ids[i].numid, ids[i].name, type_name(info.type));
		if (info.type == SNDRV_CTL_ELEM_TYPE_INTEGER)
			printf(" [%ld..%ld]", info.value.integer.min, info.value.integer.max);
		printf(" =");
		for (j = 0; j < info.count && j < 8; j++) {
			if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
				unsigned int v = val.value.enumerated.item[j];

				if (enum_item(fd, &info, v, item, sizeof(item)))
					item[0] = 0;
				printf(" %u(%s)", v, item);
			} else if (info.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN ||
				   info.type == SNDRV_CTL_ELEM_TYPE_INTEGER) {
				printf(" %ld", val.value.integer.value[j]);
			}
		}
		if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
			printf("  {");
			for (j = 0; j < info.value.enumerated.items && j < 32; j++) {
				if (!enum_item(fd, &info, j, item, sizeof(item)))
					printf("%s%s", j ? "|" : "", item);
			}
			printf("}");
		}
		printf("\n");
	}
	close(fd);
	return 0;
}

static int name_match(const char *ctl, const char *arg)
{
	for (; *ctl && *arg; ctl++, arg++) {
		if (*ctl == *arg || (*arg == '_' && *ctl == ' '))
			continue;
		return 0;
	}
	return !*ctl && !*arg;
}

static int find_ctl(int fd, const char *arg, struct snd_ctl_elem_id *id)
{
	static struct snd_ctl_elem_id ids[512];
	struct snd_ctl_elem_list list;
	unsigned int i, numid = 0;
	const char *p;

	for (p = arg; *p >= '0' && *p <= '9'; p++)
		numid = numid * 10 + (*p - '0');
	memset(&list, 0, sizeof(list));
	list.space = 512;
	list.pids = ids;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0)
		return -1;
	for (i = 0; i < list.used; i++) {
		if ((!*p && ids[i].numid == numid) ||
		    (*p && name_match((const char *)ids[i].name, arg))) {
			*id = ids[i];
			return 0;
		}
	}
	return -1;
}

static int cmd_set(const char *card, const char *ctl, char *vals)
{
	struct snd_ctl_elem_info info;
	struct snd_ctl_elem_value val;
	unsigned int j = 0, k;
	int fd = ctl_open(card);
	char *v = vals, *next;

	if (fd < 0)
		return 1;
	memset(&info, 0, sizeof(info));
	if (find_ctl(fd, ctl, &info.id) ||
	    ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info) < 0) {
		printf("no control '%s'\n", ctl);
		return 1;
	}
	memset(&val, 0, sizeof(val));
	val.id = info.id;
	ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &val);
	while (v && *v && j < info.count) {
		next = strchr(v, ',');
		if (next)
			*next++ = 0;
		if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
			char item[64];
			int found = -1;

			for (k = 0; k < info.value.enumerated.items; k++)
				if (!enum_item(fd, &info, k, item, sizeof(item)) &&
				    name_match(item, v))
					found = k;
			val.value.enumerated.item[j] = found >= 0 ? (unsigned int)found :
						       (unsigned int)strtol(v, 0, 0);
		} else {
			val.value.integer.value[j] = strtol(v, 0, 0);
		}
		j++;
		v = next;
	}
	/* one value given for a stereo control: apply it to all channels */
	for (k = j; j == 1 && k < info.count; k++) {
		if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED)
			val.value.enumerated.item[k] = val.value.enumerated.item[0];
		else
			val.value.integer.value[k] = val.value.integer.value[0];
	}
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val) < 0) {
		printf("ELEM_WRITE '%s': errno %d\n", info.id.name, errno);
		return 1;
	}
	printf("ok %u '%s'\n", info.id.numid, info.id.name);
	close(fd);
	return 0;
}

static struct snd_mask *hw_mask(struct snd_pcm_hw_params *p, int n)
{
	return &p->masks[n - SNDRV_PCM_HW_PARAM_FIRST_MASK];
}

static struct snd_interval *hw_int(struct snd_pcm_hw_params *p, int n)
{
	return &p->intervals[n - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}

static void mask_set(struct snd_pcm_hw_params *p, int n, unsigned int bit)
{
	struct snd_mask *m = hw_mask(p, n);

	memset(m, 0, sizeof(*m));
	m->bits[bit / 32] = 1u << (bit % 32);
}

static void int_set(struct snd_pcm_hw_params *p, int n, unsigned int v)
{
	struct snd_interval *i = hw_int(p, n);

	memset(i, 0, sizeof(*i));
	i->min = i->max = v;
	i->integer = 1;
}

static int cmd_play(const char *card, const char *dev, int secs, int hz,
		    int shift)
{
	static short buf[PERIOD_FRAMES * CHANNELS];
	struct snd_pcm_hw_params hw;
	struct snd_xferi x;
	char path[40];
	unsigned int step, pos = 0;
	int fd, n, i, frames, total;

	if (hz < 500 || hz > 12000 || hz % 500) {
		printf("HZ must be a multiple of 500 in 500..12000\n");
		return 1;
	}
	step = hz / 500;
	snprintf(path, sizeof(path), "/dev/snd/pcmC%sD%sp", card, dev);
	/* non-blocking open: fail with EBUSY instead of waiting for the device */
	fd = open(path, O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		printf("open %s: errno %d\n", path, errno);
		return 1;
	}
	__nolibc_syscall3(__NR_fcntl, fd, 4 /* F_SETFL */, 0);	/* blocking writes */

	memset(&hw, 0, sizeof(hw));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_MASK; n <= SNDRV_PCM_HW_PARAM_LAST_MASK; n++)
		memset(hw_mask(&hw, n), 0xff, sizeof(struct snd_mask));
	for (n = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; n <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; n++)
		hw_int(&hw, n)->max = ~0u;
	hw.rmask = ~0u;
	hw.info = ~0u;
	mask_set(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	mask_set(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	int_set(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, CHANNELS);
	int_set(&hw, SNDRV_PCM_HW_PARAM_RATE, RATE);
	int_set(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, PERIOD_FRAMES);
	int_set(&hw, SNDRV_PCM_HW_PARAM_PERIODS, PERIODS);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw) < 0) {
		printf("HW_PARAMS: errno %d\n", errno);
		close(fd);
		return 1;
	}
	if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0) < 0) {
		printf("PREPARE: errno %d\n", errno);
		close(fd);
		return 1;
	}
	printf("%s: %d Hz S16_LE x%d, period %d frames x %d, %d Hz tone >> %d\n",
	       path, RATE, CHANNELS, PERIOD_FRAMES, PERIODS, hz, shift);

	total = secs * RATE;
	for (frames = 0; frames < total; frames += PERIOD_FRAMES) {
		for (i = 0; i < PERIOD_FRAMES; i++) {
			short s = sine96[pos] >> shift;

			buf[2 * i] = buf[2 * i + 1] = s;
			pos = (pos + step) % 96;
		}
		memset(&x, 0, sizeof(x));
		x.buf = buf;
		x.frames = PERIOD_FRAMES;
		if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &x) < 0) {
			printf("WRITEI at frame %d: errno %d\n", frames, errno);
			if (errno == EPIPE && !ioctl(fd, SNDRV_PCM_IOCTL_PREPARE, 0))
				continue;	/* underrun: recover and go on */
			close(fd);
			return 1;
		}
	}
	if (ioctl(fd, SNDRV_PCM_IOCTL_DRAIN, 0) < 0)
		printf("DRAIN: errno %d\n", errno);
	close(fd);
	printf("done, %d frames\n", frames);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[1], "ctls"))
		return cmd_ctls(argv[2]);
	if (argc >= 5 && !strcmp(argv[1], "set"))
		return cmd_set(argv[2], argv[3], argv[4]);
	if (argc >= 5 && !strcmp(argv[1], "play"))
		return cmd_play(argv[2], argv[3], strtol(argv[4], 0, 0),
				argc > 5 ? strtol(argv[5], 0, 0) : 1000,
				argc > 6 ? strtol(argv[6], 0, 0) : 3);
	printf("usage: pcm-tone ctls CARD | set CARD CTL VAL[,VAL] | play CARD DEV SECS [HZ] [SHIFT]\n");
	return 2;
}
