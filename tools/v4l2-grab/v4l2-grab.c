// SPDX-License-Identifier: GPL-2.0-only
/*
 * v4l2-grab: tiny static V4L2 capture tool for the bring-up initramfs
 * (nolibc, raw ioctls, no libv4l2), to bring up a camera without
 * v4l2-ctl or libcamera.
 *
 *   v4l2-grab info VIDEO               capabilities, formats, current format
 *   v4l2-grab ctrl DEV ID [VAL]        read (and set) control ID (hex, e.g.
 *                                      0x009f0903 test pattern) on a video
 *                                      or v4l-subdev node
 *   v4l2-grab grab VIDEO SUBDEV WxH OUT [FRAMES] [SKIP]
 *                                      set the sensor subdev to the mode
 *                                      nearest WxH and the video node to
 *                                      match, stream, drop SKIP (default 4)
 *                                      frames, write FRAMES (default 1) to
 *                                      OUT back to back, print per-frame
 *                                      sequence/size/interval
 *
 * A frame that does not arrive within 2 s ends the stream with an error
 * (the CSIS driver then logs its frame and error counters).
 *
 * The buffers are twice the size the driver asks for and filled with 0x5a
 * before every use, so a DMA that writes a different layout than the
 * driver assumes (unpacked pixels, other line padding) lands in that
 * margin instead of other memory, and is reported: "written up to N"
 * should be within the last line of sizeimage.
 *
 * Build (static, same flags as initramfs/init.c):
 *   aarch64-linux-gnu-gcc -Os -static -nostdlib -fno-stack-protector \
 *     -I$K/tools/include/nolibc -I$P/build/hdr/usr/include \
 *     -include $K/tools/include/nolibc/nolibc.h -o v4l2-grab v4l2-grab.c -lgcc
 */

#include <linux/videodev2.h>
#include <linux/v4l2-subdev.h>
#include <linux/media-bus-format.h>

#define NBUF		4
#define TIMEOUT_MS	2000
#define FILL		0x5a

static const struct {
	unsigned int code;
	unsigned int fourcc;
} raw10[] = {
	{ MEDIA_BUS_FMT_SBGGR10_1X10, V4L2_PIX_FMT_SBGGR10P },
	{ MEDIA_BUS_FMT_SGBRG10_1X10, V4L2_PIX_FMT_SGBRG10P },
	{ MEDIA_BUS_FMT_SGRBG10_1X10, V4L2_PIX_FMT_SGRBG10P },
	{ MEDIA_BUS_FMT_SRGGB10_1X10, V4L2_PIX_FMT_SRGGB10P },
};

static void fourcc_str(unsigned int f, char *s)
{
	s[0] = f & 0xff;
	s[1] = (f >> 8) & 0xff;
	s[2] = (f >> 16) & 0xff;
	s[3] = f >> 24;
	s[4] = 0;
}

static int xopen(const char *path)
{
	int fd = open(path, O_RDWR);

	if (fd < 0)
		printf("%s: open failed: %d\n", path, errno);
	return fd;
}

static int xioctl(int fd, unsigned long req, void *arg, const char *what)
{
	int ret = ioctl(fd, req, arg);

	if (ret < 0)
		printf("%s failed: %d\n", what, errno);
	return ret;
}

static long long ts_us(const struct v4l2_buffer *b)
{
	return (long long)b->timestamp.tv_sec * 1000000 + b->timestamp.tv_usec;
}

static int cmd_info(const char *dev)
{
	struct v4l2_capability cap = { 0 };
	struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_fmtdesc fd = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	char s[5];
	int f = xopen(dev);

	if (f < 0)
		return 1;
	if (xioctl(f, VIDIOC_QUERYCAP, &cap, "VIDIOC_QUERYCAP") < 0)
		return 1;
	printf("driver %s, card %s, bus %s, caps %08x device %08x\n",
	       cap.driver, cap.card, cap.bus_info, cap.capabilities,
	       cap.device_caps);
	while (ioctl(f, VIDIOC_ENUM_FMT, &fd) == 0) {
		fourcc_str(fd.pixelformat, s);
		printf("format %u: %s (%s)\n", fd.index, s, fd.description);
		fd.index++;
	}
	if (xioctl(f, VIDIOC_G_FMT, &fmt, "VIDIOC_G_FMT") < 0)
		return 1;
	fourcc_str(fmt.fmt.pix.pixelformat, s);
	printf("current %ux%u %s, %u bytes/line, %u bytes\n",
	       fmt.fmt.pix.width, fmt.fmt.pix.height, s,
	       fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);
	close(f);
	return 0;
}

static int cmd_ctrl(const char *dev, const char *id, const char *val)
{
	struct v4l2_control c = { .id = strtoul(id, NULL, 0) };
	int f = xopen(dev);

	if (f < 0)
		return 1;
	if (val) {
		c.value = strtoul(val, NULL, 0);
		if (xioctl(f, VIDIOC_S_CTRL, &c, "VIDIOC_S_CTRL") < 0)
			return 1;
	}
	if (xioctl(f, VIDIOC_G_CTRL, &c, "VIDIOC_G_CTRL") < 0)
		return 1;
	printf("control %08x = %d\n", c.id, c.value);
	close(f);
	return 0;
}

static int cmd_grab(const char *vdev, const char *sdev, unsigned int w,
		    unsigned int h, const char *out, unsigned int frames,
		    unsigned int skip)
{
	struct v4l2_subdev_format sf = {
		.which = V4L2_SUBDEV_FORMAT_ACTIVE,
		.pad = 0,
	};
	struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_create_buffers cb = {
		.count = NBUF,
		.memory = V4L2_MEMORY_MMAP,
	};
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	unsigned char *map[NBUF];
	unsigned int len[NBUF];
	unsigned int i, end, got = 0, written = 0;
	long long last = 0;
	int vf, sfd, of, ret = 1;
	char s[5];

	sfd = xopen(sdev);
	vf = xopen(vdev);
	if (sfd < 0 || vf < 0)
		return 1;

	/* the sensor picks its nearest mode and keeps its own Bayer order */
	if (xioctl(sfd, VIDIOC_SUBDEV_G_FMT, &sf, "VIDIOC_SUBDEV_G_FMT") < 0)
		return 1;
	sf.format.width = w;
	sf.format.height = h;
	if (xioctl(sfd, VIDIOC_SUBDEV_S_FMT, &sf, "VIDIOC_SUBDEV_S_FMT") < 0)
		return 1;
	printf("sensor %ux%u code %04x\n", sf.format.width, sf.format.height,
	       sf.format.code);

	for (i = 0; i < sizeof(raw10) / sizeof(raw10[0]); i++)
		if (raw10[i].code == sf.format.code)
			break;
	if (i == sizeof(raw10) / sizeof(raw10[0])) {
		printf("sensor code %04x is not RAW10\n", sf.format.code);
		return 1;
	}
	fmt.fmt.pix.width = sf.format.width;
	fmt.fmt.pix.height = sf.format.height;
	fmt.fmt.pix.pixelformat = raw10[i].fourcc;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(vf, VIDIOC_S_FMT, &fmt, "VIDIOC_S_FMT") < 0)
		return 1;
	fourcc_str(fmt.fmt.pix.pixelformat, s);
	printf("video %ux%u %s, %u bytes/line, %u bytes\n", fmt.fmt.pix.width,
	       fmt.fmt.pix.height, s, fmt.fmt.pix.bytesperline,
	       fmt.fmt.pix.sizeimage);

	cb.format = fmt;
	cb.format.fmt.pix.sizeimage *= 2;
	if (xioctl(vf, VIDIOC_CREATE_BUFS, &cb, "VIDIOC_CREATE_BUFS") < 0)
		return 1;
	if (cb.count > NBUF)
		cb.count = NBUF;
	for (i = 0; i < cb.count; i++) {
		struct v4l2_buffer b = {
			.index = cb.index + i,
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.memory = V4L2_MEMORY_MMAP,
		};

		if (xioctl(vf, VIDIOC_QUERYBUF, &b, "VIDIOC_QUERYBUF") < 0)
			return 1;
		len[i] = b.length;
		map[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
			      MAP_SHARED, vf, b.m.offset);
		if (map[i] == MAP_FAILED) {
			printf("mmap failed: %d\n", errno);
			return 1;
		}
		memset(map[i], FILL, len[i]);
		if (xioctl(vf, VIDIOC_QBUF, &b, "VIDIOC_QBUF") < 0)
			return 1;
	}
	printf("%u buffers of %u bytes\n", cb.count, len[0]);

	of = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (of < 0) {
		printf("%s: open failed: %d\n", out, errno);
		return 1;
	}

	if (xioctl(vf, VIDIOC_STREAMON, &type, "VIDIOC_STREAMON") < 0)
		return 1;

	while (written < frames) {
		struct pollfd p = { .fd = vf, .events = POLLIN };
		struct v4l2_buffer b = {
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.memory = V4L2_MEMORY_MMAP,
		};

		if (poll(&p, 1, TIMEOUT_MS) <= 0) {
			printf("no frame within %u ms after %u frames\n",
			       TIMEOUT_MS, got);
			goto stop;
		}
		if (xioctl(vf, VIDIOC_DQBUF, &b, "VIDIOC_DQBUF") < 0)
			goto stop;
		i = b.index - cb.index;
		end = len[i];
		while (end && map[i][end - 1] == FILL)
			end--;
		printf("frame %u: seq %u, %u bytes%s, written up to %u%s, +%lld us\n",
		       got, b.sequence, b.bytesused,
		       b.flags & V4L2_BUF_FLAG_ERROR ? ", ERROR" : "", end,
		       end > fmt.fmt.pix.sizeimage ? " (DMA OVERRUN)" : "",
		       got ? ts_us(&b) - last : 0LL);
		last = ts_us(&b);
		if (got++ >= skip) {
			if (write(of, map[i], fmt.fmt.pix.sizeimage) !=
			    (ssize_t)fmt.fmt.pix.sizeimage) {
				printf("write failed: %d\n", errno);
				goto stop;
			}
			written++;
		}
		memset(map[i], FILL, len[i]);
		if (xioctl(vf, VIDIOC_QBUF, &b, "VIDIOC_QBUF") < 0)
			goto stop;
	}
	ret = 0;
	printf("wrote %u frame(s) of %u bytes to %s\n", written,
	       fmt.fmt.pix.sizeimage, out);
stop:
	ioctl(vf, VIDIOC_STREAMOFF, &type);
	close(of);
	close(vf);
	close(sfd);
	return ret;
}

int main(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[1], "info"))
		return cmd_info(argv[2]);
	if (argc >= 4 && !strcmp(argv[1], "ctrl"))
		return cmd_ctrl(argv[2], argv[3], argc > 4 ? argv[4] : NULL);
	/* the console's "run" passes at most 7 arguments: WxH is one */
	if (argc >= 6 && !strcmp(argv[1], "grab")) {
		char *x;
		unsigned int w = strtoul(argv[4], &x, 0);
		unsigned int h = *x == 'x' ? strtoul(x + 1, NULL, 0) : 0;

		if (w && h)
			return cmd_grab(argv[2], argv[3], w, h, argv[5],
					argc > 6 ? strtoul(argv[6], NULL, 0) : 1,
					argc > 7 ? strtoul(argv[7], NULL, 0) : 4);
	}

	printf("usage: v4l2-grab info VIDEO | ctrl DEV ID [VAL] |\n"
	       "       grab VIDEO SUBDEV WxH OUT [FRAMES] [SKIP]\n");
	return 2;
}
