// SPDX-License-Identifier: GPL-2.0-only
/*
 * tabtool: hands-free input testing for the SM-T570 (static, aarch64).
 *
 *   tabtool tap X Y [MS]               touch down at X,Y for MS (100) ms
 *   tabtool swipe X1 Y1 X2 Y2 [MS]     one-finger drag over MS (400) ms
 *   tabtool pinch CX CY R1 R2 [MS]     two fingers from radius R1 to R2
 *   tabtool rumble EVDEV [MS] [STRONG] play an FF_RUMBLE effect on EVDEV
 *   tabtool events EVDEV [SECS]        print events from EVDEV
 *   tabtool find NAME                  print /dev/input/eventN whose name
 *                                      contains NAME
 *
 * Touches come from a uinput multitouch device ("tabtool touchscreen",
 * INPUT_PROP_DIRECT, 1200 x 1920 like the panel) so the compositor maps
 * them to the panel the same way as the real Himax touchscreen. The real
 * driver path is tested separately (raw frames, checksum counters).
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define W 1200
#define H 1920

static int ufd = -1;

static void emit(int type, int code, int val)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = val;
	if (write(ufd, &ev, sizeof(ev)) != sizeof(ev))
		perror("write");
}

static void msleep(int ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };

	nanosleep(&ts, NULL);
}

static int touch_open(void)
{
	struct uinput_setup us;
	struct uinput_abs_setup a;
	int codes[][3] = {
		{ ABS_X, W - 1 }, { ABS_Y, H - 1 },
		{ ABS_MT_SLOT, 9 }, { ABS_MT_TRACKING_ID, 65535 },
		{ ABS_MT_POSITION_X, W - 1 }, { ABS_MT_POSITION_Y, H - 1 },
		{ ABS_MT_TOUCH_MAJOR, 255 },
	};
	unsigned int i;

	ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (ufd < 0) {
		perror("/dev/uinput");
		return -1;
	}
	ioctl(ufd, UI_SET_EVBIT, EV_KEY);
	ioctl(ufd, UI_SET_KEYBIT, BTN_TOUCH);
	ioctl(ufd, UI_SET_EVBIT, EV_ABS);
	ioctl(ufd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
	for (i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
		memset(&a, 0, sizeof(a));
		ioctl(ufd, UI_SET_ABSBIT, codes[i][0]);
		a.code = codes[i][0];
		a.absinfo.maximum = codes[i][1];
		if (a.code == ABS_X || a.code == ABS_MT_POSITION_X)
			a.absinfo.resolution = 7;	/* ~172 mm / 1200 */
		if (a.code == ABS_Y || a.code == ABS_MT_POSITION_Y)
			a.absinfo.resolution = 11;	/* ~172 mm wide panel, 16:10 */
		ioctl(ufd, UI_ABS_SETUP, &a);
	}
	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_VIRTUAL;
	us.id.vendor = 0x1d6b;
	us.id.product = 0x5457;
	strcpy(us.name, "tabtool touchscreen");
	if (ioctl(ufd, UI_DEV_SETUP, &us) || ioctl(ufd, UI_DEV_CREATE)) {
		perror("UI_DEV_CREATE");
		return -1;
	}
	/* let udev/libinput/the compositor pick the device up */
	sleep(2);
	return 0;
}

static void touch_close(void)
{
	msleep(300);
	ioctl(ufd, UI_DEV_DESTROY);
	close(ufd);
}

/* fingers: n points, down/move/up per slot */
static void frame(int n, const int *x, const int *y, int down)
{
	int i;

	for (i = 0; i < n; i++) {
		emit(EV_ABS, ABS_MT_SLOT, i);
		if (down) {
			emit(EV_ABS, ABS_MT_TRACKING_ID, 100 + i);
			emit(EV_ABS, ABS_MT_POSITION_X, x[i]);
			emit(EV_ABS, ABS_MT_POSITION_Y, y[i]);
			emit(EV_ABS, ABS_MT_TOUCH_MAJOR, 30);
		} else {
			emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
		}
	}
	emit(EV_KEY, BTN_TOUCH, down);
	if (down) {
		emit(EV_ABS, ABS_X, x[0]);
		emit(EV_ABS, ABS_Y, y[0]);
	}
	emit(EV_SYN, SYN_REPORT, 0);
}

static int cmd_tap(int argc, char **argv)
{
	int x = atoi(argv[0]), y = atoi(argv[1]);
	int ms = argc > 2 ? atoi(argv[2]) : 100;

	if (touch_open())
		return 1;
	frame(1, &x, &y, 1);
	msleep(ms);
	frame(1, &x, &y, 0);
	touch_close();
	printf("tap %d,%d %d ms\n", x, y, ms);
	return 0;
}

static int cmd_swipe(int argc, char **argv)
{
	int x1 = atoi(argv[0]), y1 = atoi(argv[1]);
	int x2 = atoi(argv[2]), y2 = atoi(argv[3]);
	int ms = argc > 4 ? atoi(argv[4]) : 400, steps = ms / 10, i, x, y;

	if (steps < 2)
		steps = 2;
	if (touch_open())
		return 1;
	for (i = 0; i <= steps; i++) {
		x = x1 + (x2 - x1) * i / steps;
		y = y1 + (y2 - y1) * i / steps;
		frame(1, &x, &y, 1);
		msleep(10);
	}
	frame(1, &x, &y, 0);
	touch_close();
	printf("swipe %d,%d -> %d,%d %d ms\n", x1, y1, x2, y2, ms);
	return 0;
}

static int cmd_pinch(int argc, char **argv)
{
	int cx = atoi(argv[0]), cy = atoi(argv[1]);
	int r1 = atoi(argv[2]), r2 = atoi(argv[3]);
	int ms = argc > 4 ? atoi(argv[4]) : 500, steps = ms / 10, i, r;
	int x[2], y[2];

	if (touch_open())
		return 1;
	for (i = 0; i <= steps; i++) {
		r = r1 + (r2 - r1) * i / steps;
		x[0] = cx - r; y[0] = cy;
		x[1] = cx + r; y[1] = cy;
		frame(2, x, y, 1);
		msleep(10);
	}
	frame(2, x, y, 0);
	touch_close();
	printf("pinch at %d,%d radius %d -> %d\n", cx, cy, r1, r2);
	return 0;
}

static int cmd_rumble(int argc, char **argv)
{
	struct ff_effect e;
	struct input_event play;
	int ms = argc > 1 ? atoi(argv[1]) : 300;
	int strong = argc > 2 ? atoi(argv[2]) : 0xc000;
	int fd = open(argv[0], O_RDWR);

	if (fd < 0) {
		perror(argv[0]);
		return 1;
	}
	memset(&e, 0, sizeof(e));
	e.type = FF_RUMBLE;
	e.id = -1;
	e.u.rumble.strong_magnitude = strong;
	e.u.rumble.weak_magnitude = strong;
	e.replay.length = ms;
	if (ioctl(fd, EVIOCSFF, &e) < 0) {
		perror("EVIOCSFF");
		return 1;
	}
	memset(&play, 0, sizeof(play));
	play.type = EV_FF;
	play.code = e.id;
	play.value = 1;
	if (write(fd, &play, sizeof(play)) != sizeof(play)) {
		perror("play");
		return 1;
	}
	printf("rumble effect %d playing for %d ms\n", e.id, ms);
	fflush(stdout);
	msleep(ms + 200);
	ioctl(fd, EVIOCRMFF, e.id);
	close(fd);
	return 0;
}

static int cmd_events(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 10;
	int fd = open(argv[0], O_RDONLY | O_NONBLOCK);
	time_t end = time(NULL) + secs;
	struct input_event ev;
	struct pollfd p;
	long n = 0;

	if (fd < 0) {
		perror(argv[0]);
		return 1;
	}
	p.fd = fd;
	p.events = POLLIN;
	while (time(NULL) < end) {
		if (poll(&p, 1, 200) <= 0)
			continue;
		while (read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
			n++;
			if (ev.type == EV_SYN)
				continue;
			printf("%ld.%06ld type %d code %d value %d\n",
			       (long)ev.input_event_sec, (long)ev.input_event_usec,
			       ev.type, ev.code, ev.value);
		}
	}
	printf("%ld events\n", n);
	return 0;
}

static int cmd_find(char *name)
{
	char path[64], nm[256];
	int i, fd;

	for (i = 0; i < 32; i++) {
		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		fd = open(path, O_RDONLY);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(nm)), nm) > 0 && strstr(nm, name))
			printf("%s %s\n", path, nm);
		close(fd);
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 4 && !strcmp(argv[1], "tap"))
		return cmd_tap(argc - 2, argv + 2);
	if (argc >= 6 && !strcmp(argv[1], "swipe"))
		return cmd_swipe(argc - 2, argv + 2);
	if (argc >= 6 && !strcmp(argv[1], "pinch"))
		return cmd_pinch(argc - 2, argv + 2);
	if (argc >= 3 && !strcmp(argv[1], "rumble"))
		return cmd_rumble(argc - 2, argv + 2);
	if (argc >= 3 && !strcmp(argv[1], "events"))
		return cmd_events(argc - 2, argv + 2);
	if (argc >= 3 && !strcmp(argv[1], "find"))
		return cmd_find(argv[2]);
	fprintf(stderr, "usage: tabtool tap X Y [MS] | swipe X1 Y1 X2 Y2 [MS] | "
		"pinch CX CY R1 R2 [MS] | rumble EVDEV [MS] [STRONG] | "
		"events EVDEV [SECS] | find NAME\n");
	return 2;
}
