// SPDX-License-Identifier: GPL-2.0-only
/*
 * gtactive3wifi-usb-prep: make USB device mode work on the SM-T570 while the
 * mainline kernel has no Exynos 9810 clock driver and no MAX77705 USB-C/MUIC
 * driver.
 *
 *  1. Force the USB 3.0 DRD gates on (CMU_TOP GATE_CLKCMU_FSYS0_USB30DRD,
 *     CMU_FSYS0 GOUT_USB30DRD_REF_CLK): the dwc3/PHY registers are not
 *     clocked otherwise. Same writes as the bring-up init
 *     (gtactive3-mainline initramfs/init.c, force_gate()).
 *  2. Route the MAX77705 USB-C data switch to the AP: COMMAND_CONTROL1_WRITE
 *     = COM_USB, i.e. write {0x21, 0x06, 0x09} then {0x41, 0x00} to address
 *     0x25 on i2c-0 (HSI2C_40, DT alias i2c0), through i2c-dev. Without it
 *     the host never sees the gadget when the cable was plugged in at boot.
 *     The HSI2C driver needs exynos-usi and i2c-exynos5 loaded first
 *     (gtactive3wifi-usb-prep.service does that), and the same CMGP gates
 *     the bring-up init enables before it loads them.
 *
 * Exit status: 0 = switch acknowledged, 1 = error (gates may still be on),
 * 2 = no /dev/i2c-0 (gates on, switch not attempted).
 *
 * Remove once the clk-exynos9810 and MAX77705 USB-C drivers land.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#define CMU_TOP_BASE	0x1a240000UL
#define CMU_FSYS0_BASE	0x11000000UL
#define CMU_CMGP_BASE	0x14200000UL
#define GATE_CG_VAL	(1u << 21)
#define GATE_MANUAL	(1u << 20)

#define I2C_DEV		"/dev/i2c-0"
/* HSI2C_40, the bus with the MAX77705 (exynos9810.dtsi hsi2c_40) */
#define I2C_OF_NODE	"i2c@14360000"
#define MAX77705_USBC	0x25

static int devmem = -1;

static int rmw_or(unsigned long phys, unsigned int set, const char *name)
{
	volatile unsigned int *p;
	unsigned int v, w;

	p = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, devmem, phys & ~0xfffUL);
	if (p == MAP_FAILED) {
		fprintf(stderr, "%s: cannot map %#lx: %s\n", name, phys, strerror(errno));
		return -1;
	}
	v = p[(phys & 0xfff) / 4];
	p[(phys & 0xfff) / 4] = v | set;
	w = p[(phys & 0xfff) / 4];
	printf("%s: %#010x -> %#010x\n", name, v, w);
	munmap((void *)p, 0x1000);
	return 0;
}

static void msleep(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };

	nanosleep(&ts, NULL);
}

/* Is i2c-0 really HSI2C_40? (an unexpected bus must never be written) */
static int is_hsi2c40(void)
{
	char buf[PATH_MAX];
	ssize_t n = readlink("/sys/bus/i2c/devices/i2c-0/of_node", buf, sizeof(buf) - 1);
	const char *base;

	if (n < 0)
		return 0;
	buf[n] = 0;
	base = strrchr(buf, '/');
	return base && !strcmp(base + 1, I2C_OF_NODE);
}

static int i2c_write(int fd, unsigned char *b, int n)
{
	struct i2c_msg msg = { .addr = MAX77705_USBC, .flags = 0, .len = n, .buf = b };
	struct i2c_rdwr_ioctl_data d = { .msgs = &msg, .nmsgs = 1 };

	return ioctl(fd, I2C_RDWR, &d) == 1 ? 0 : -1;
}

static int max77705_com_usb(void)
{
	unsigned char sw[3] = { 0x21, 0x06, 0x09 }, end[2] = { 0x41, 0x00 };
	int fd = -1, i;

	for (i = 0; i < 100 && fd < 0; i++) {	/* 10 s: deferred probe */
		fd = open(I2C_DEV, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			msleep(100);
	}
	if (fd < 0) {
		fprintf(stderr, "MAX77705: no %s, data switch not set\n", I2C_DEV);
		return 2;
	}
	if (!is_hsi2c40()) {
		fprintf(stderr, "MAX77705: i2c-0 is not %s, not touching it\n", I2C_OF_NODE);
		close(fd);
		return 1;
	}
	/* I2C_RDWR, not I2C_SLAVE: works even if a driver ever binds 0x25 */
	for (i = 0; i < 3; i++) {
		if (!i2c_write(fd, sw, sizeof(sw)) && !i2c_write(fd, end, sizeof(end))) {
			printf("MAX77705: data switch -> USB\n");
			close(fd);
			return 0;
		}
		fprintf(stderr, "MAX77705: write to 0x25 failed (%s), retrying\n", strerror(errno));
		msleep(50);
	}
	close(fd);
	return 1;
}

int main(int argc, char **argv)
{
	int gates_only = argc > 1 && !strcmp(argv[1], "--gates-only");
	int switch_only = argc > 1 && !strcmp(argv[1], "--switch-only");

	if (!switch_only) {
		devmem = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
		if (devmem < 0) {
			perror("/dev/mem");
			return 1;
		}
		rmw_or(CMU_TOP_BASE + 0x2064, GATE_CG_VAL | GATE_MANUAL,
		       "CMU_TOP GATE_CLKCMU_FSYS0_USB30DRD");
		rmw_or(CMU_FSYS0_BASE + 0x206c, GATE_CG_VAL | GATE_MANUAL,
		       "FSYS0 GOUT_USB30DRD_REF_CLK");
		/* USI_CMGP03 (HSI2C_40) gates, as the bring-up init sets them */
		rmw_or(CMU_CMGP_BASE + 0x2014, GATE_CG_VAL | GATE_MANUAL, "CMGP GATE_CLK_USI_CMGP03");
		rmw_or(CMU_CMGP_BASE + 0x20a8, GATE_CG_VAL | GATE_MANUAL, "CMGP USI_CMGP03 IPCLK");
		rmw_or(CMU_CMGP_BASE + 0x20ac, GATE_CG_VAL | GATE_MANUAL, "CMGP USI_CMGP03 PCLK");
		rmw_or(CMU_CMGP_BASE + 0x2074, GATE_CG_VAL | GATE_MANUAL, "CMGP RSTNSYNC USI_CMGP03");
		close(devmem);
	}
	if (gates_only)
		return 0;
	return max77705_com_usb();
}
