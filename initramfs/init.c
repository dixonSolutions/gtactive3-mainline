/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Bring-up init for the SM-T570 mainline port. Built with the kernel's nolibc.
 *
 *  1. Arms "reboot into Download mode" in the PMU, so any reset (panic, bus
 *     error, watchdog) lands where the host can flash the next build.
 *  2. Prints what the kernel found to the framebuffer console.
 *  3. Forces the USB clock gates on, loads the USB PHY/DWC3 modules and
 *     creates a USB NCM network gadget.
 *  4. Serves a tiny line-based debug console on TCP port 23 over IPv6
 *     link-local: dmesg, peek/poke of physical registers, reboot.
 *  5. If no USB host configures the gadget within the timeout, reboots into
 *     Download mode so the host can flash the next attempt.
 *  6. When it runs because the watchdog reset a Duranium that U-Boot had
 *     already handed over to, restarts Duranium after 15 s, at most twice
 *     in a row (see os_hang_check()).
 */
#include <linux/input.h>
#include <linux/reboot.h>
#include <linux/in6.h>
#include <linux/socket.h>
#include <linux/sockios.h>
#include <linux/if.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <linux/watchdog.h>
#include <linux/fs.h>

#define PMU_BASE	0x14060000UL
#define PMU_INFORM2	0x0808
#define PMU_INFORM3	0x080c
#define PMU_RST_STAT	0x0404
#define RST_CL0_WDTRESET	(1u << 24)
#define SEC_POWER_RESET		0x12345678
#define SEC_REASON_NORMAL	0x12345670
#define SEC_REASON_DOWNLOAD	0x12345671

#define CMU_TOP_BASE	0x1a240000UL
#define CMU_FSYS0_BASE	0x11000000UL
#define GATE_CG_VAL	(1u << 21)
#define GATE_MANUAL	(1u << 20)

#define USB_TIMEOUT_S	60

static int con = 1;
/* status for the timing side channel: see main() */
static int st_max, st_gadget;
static int kmsg = -1;
static int devmem = -1;
static int wdt = -1;
static char logbuf[1 << 17];

/* ---------- output helpers ---------- */

static void wr(int fd, const char *s) { write(fd, s, strlen(s)); }
static void out(const char *s)
{
	static char line[256];
	static int len;

	wr(con, s);
	/* mirror complete lines into the kernel log (and so into pstore) */
	for (; *s; s++) {
		if (*s != '\n' && len < (int)sizeof(line) - 8) { line[len++] = *s; continue; }
		if (kmsg >= 0 && len) {
			char rec[272] = "<6>init: ";
			memcpy(rec + 9, line, len);
			write(kmsg, rec, 9 + len);
		}
		len = 0;
	}
}

static void hex32(char *b, unsigned long v)
{
	static const char d[] = "0123456789abcdef";
	int i;

	b[0] = '0'; b[1] = 'x';
	for (i = 0; i < 8; i++)
		b[2 + i] = d[(v >> (28 - 4 * i)) & 0xf];
	b[10] = 0;
}

static void outhex(const char *label, unsigned long v)
{
	char b[12];

	hex32(b, v);
	out(label); out(b); out("\n");
}

static void cat(const char *label, const char *path, int max)
{
	char buf[512];
	int fd = open(path, O_RDONLY), n;

	out(label);
	if (fd < 0) { out("(unavailable)\n"); return; }
	n = read(fd, buf, max < (int)sizeof(buf) - 1 ? max : (int)sizeof(buf) - 1);
	close(fd);
	if (n < 0) n = 0;
	buf[n] = 0;
	out(buf);
	if (n && buf[n - 1] != '\n') out("\n");
}

static int readfile(const char *path, char *buf, int len)
{
	int fd = open(path, O_RDONLY), n;

	if (fd < 0) return -1;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0) n = 0;
	buf[n] = 0;
	return n;
}

static int writefile(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY), r;

	if (fd < 0) return -1;
	r = write(fd, s, strlen(s));
	close(fd);
	return r < 0 ? -1 : 0;
}

/* ---------- physical register access through /dev/mem ---------- */

static volatile unsigned int *map_reg(unsigned long phys)
{
	unsigned long page = phys & ~0xfffUL;
	void *p;

	if (devmem < 0)
		devmem = open("/dev/mem", O_RDWR | O_SYNC);
	if (devmem < 0)
		return 0;
	p = mmap(0, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, devmem, page);
	if (p == MAP_FAILED)
		return 0;
	return (volatile unsigned int *)((char *)p + (phys & 0xfff));
}

static int peek(unsigned long phys, unsigned int *val)
{
	volatile unsigned int *r = map_reg(phys);

	if (!r) return -1;
	*val = *r;
	munmap((void *)((unsigned long)r & ~0xfffUL), 0x1000);
	return 0;
}

static int poke(unsigned long phys, unsigned int val)
{
	volatile unsigned int *r = map_reg(phys);

	if (!r) return -1;
	*r = val;
	munmap((void *)((unsigned long)r & ~0xfffUL), 0x1000);
	return 0;
}

/* U-Boot's RAM console log (CONFIG_EXYNOS_MOBILE_RAMLOG): { "ULOG", len, text } */
#define ULOG_BASE	0x8ff100000UL
#define ULOG_SIZE	0x100000UL

static void ulog_print(int c)
{
	volatile unsigned int *hdr;
	unsigned int len;
	char *p;

	if (devmem < 0)
		devmem = open("/dev/mem", O_RDWR | O_SYNC);
	p = devmem < 0 ? MAP_FAILED :
		mmap(0, ULOG_SIZE, PROT_READ, MAP_SHARED, devmem, ULOG_BASE);
	if (p == MAP_FAILED) {
		wr(c, "ulog: cannot map\n");
		return;
	}
	hdr = (volatile unsigned int *)p;
	len = hdr[1];
	if (hdr[0] != 0x474f4c55 || len > ULOG_SIZE - 8) {
		char b[64];

		snprintf(b, sizeof(b), "ulog: no log (magic %x len %x)\n", hdr[0], len);
		wr(c, b);
	} else {
		write(c, p + 8, len);
		wr(c, "\n");
	}
	munmap(p, ULOG_SIZE);
}

static void arm_download_on_reset(void)
{
	if (poke(PMU_BASE + PMU_INFORM2, SEC_POWER_RESET) ||
	    poke(PMU_BASE + PMU_INFORM3, SEC_REASON_DOWNLOAD))
		out("WARNING: could not arm Download mode on reset (/dev/mem)\n");
	else
		out("Any reset now goes to Download mode.\n");
}

static void force_gate(const char *name, unsigned long phys)
{
	unsigned int v = 0, w = 0;
	char b[12];

	if (peek(phys, &v)) { out(name); out(": unreadable\n"); return; }
	poke(phys, v | GATE_CG_VAL | GATE_MANUAL);
	peek(phys, &w);
	out("  "); out(name); out(": "); hex32(b, v); out(b);
	out(" -> "); hex32(b, w); out(b); out("\n");
}

/* ---------- kernel log ---------- */

static int klog_read(void)
{
	int n = __nolibc_syscall3(__NR_syslog, 3 /* READ_ALL */, logbuf, sizeof(logbuf) - 1);

	if (n < 0) n = 0;
	logbuf[n] = 0;
	return n;
}

static void klog_summary(void)
{
	char *line = logbuf, *end;
	int shown = 0;

	if (klog_read() <= 0) { out("(kernel log unavailable)\n"); return; }
	out("Kernel log (CPU / USB / errors):\n");
	while (line && *line && shown < 14) {
		end = strchr(line, '\n');
		if (end) *end = 0;
		if (strstr(line, "CPU") || strstr(line, "psci") || strstr(line, "fail") ||
		    strstr(line, "error") || strstr(line, "usb") || strstr(line, "dwc3") ||
		    strstr(line, "phy")) {
			char *msg = strchr(line, ']');
			out("  ");
			out(msg ? msg + 2 : line);
			out("\n");
			shown++;
		}
		line = end ? end + 1 : 0;
	}
}

static void reboot_to(const char *mode)
{
	out("\nRestarting to ");
	out(mode);
	out(" mode...\n");
	__nolibc_syscall0(__NR_sync);
	__nolibc_syscall4(__NR_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
			  LINUX_REBOOT_CMD_RESTART2, mode);
}

/* ---------- restarting a hung Duranium (bring-up init only) ---------- */

#ifndef CONSOLE_STDIO
/*
 * uniLoader's boot record, the 4 KiB page after U-Boot's RAM log, as U-Boot
 * reads it (exynos_show_uniloader_record()): word 0 "ULCH", word 5 RST_STAT
 * of this boot, word 19 the stage. U-Boot sets stage 7 when it hands over
 * to the OS; stage 3 makes uniLoader's next regular boot chain U-Boot again
 * (scripts/duranium-boot writes the same).
 */
#define UL_RECORD	0x8ff1ff000UL
#define UL_MAGIC	0x48434c55
#define UL_RST_STAT	(UL_RECORD + 4 * 5)
#define UL_STAGE	(UL_RECORD + 4 * 19)
#define UL_STAGE_CHAIN	3
#define UL_STAGE_OS	7

/*
 * Our restart record, the last 16 bytes of that page: "HRTY", restarts in
 * a row, and a flag set while a restart is on its way. U-Boot clears the
 * flag, and the count on any boot that is not such a restart, so only
 * hangs in a row count (exynos_account_hang_retry()). DRAM keeps it over
 * resets and Download mode, not over a power-off.
 */
#define HR_BASE		(UL_RECORD + 0xff0)
#define HR_MAGIC	0x59545248
#define HR_COUNT	(HR_BASE + 4)
#define HR_PENDING	(HR_BASE + 8)
#define HR_MAX		2
#define HR_DELAY_S	15
/* the "stay" console command leaves this behind */
#define HR_STAY_FILE	"/stay"

static unsigned int hang_restarts(void)
{
	unsigned int magic = 0, n = 0;

	if (peek(HR_BASE, &magic) || magic != HR_MAGIC || peek(HR_COUNT, &n))
		return 0;
	return n;
}

/*
 * Did the watchdog reset an OS that U-Boot had already started (stage 7)?
 * Then a kernel hung, not this chain: say so and return 1 if Duranium may
 * be restarted once more. The stage goes back to 3 either way, so that a
 * later reset of this Linux is not taken for another OS hang. A watchdog
 * reset before the handover (U-Boot's "Bring-up Linux" menu entry, which
 * fires it on purpose) leaves the stage at 4 and is not touched.
 */
static int os_hang_check(void)
{
	unsigned int magic = 0, rst = 0, now = 0, stage = 0, n;
	char b[96];

	if (peek(UL_RECORD, &magic) || magic != UL_MAGIC ||
	    peek(UL_STAGE, &stage) || peek(UL_RST_STAT, &rst))
		return 0;
	peek(PMU_BASE + PMU_RST_STAT, &now);
	if (stage != UL_STAGE_OS || !((rst | now) & RST_CL0_WDTRESET))
		return 0;

	poke(UL_STAGE, UL_STAGE_CHAIN);
	n = hang_restarts();
	if (n >= HR_MAX) {
		snprintf(b, sizeof(b), "\nDuranium stopped responding, %u restarts in a row did not help:\n", n);
		out(b);
		out("staying in the recovery console.\n");
		return 0;
	}
	snprintf(b, sizeof(b), "\nDuranium stopped responding; restarting it in %d s\n", HR_DELAY_S);
	out(b);
	out("(Volume Up: stay in the recovery console; console command \"stay\" too)\n");
	return 1;
}

static void os_restart(void)
{
	poke(HR_COUNT, hang_restarts() + 1);
	poke(HR_PENDING, 1);
	poke(HR_BASE, HR_MAGIC);
	/* undo arm_download_on_reset(): back through uniLoader to U-Boot */
	poke(PMU_BASE + PMU_INFORM2, SEC_POWER_RESET);
	poke(PMU_BASE + PMU_INFORM3, SEC_REASON_NORMAL);
	reboot_to("normal");
}
#endif /* !CONSOLE_STDIO */

/* ---------- MAX77705: route USB D+/D- to the AP ---------- */

#define MAX77705_USBC_ADDR	0x25	/* USB-C / MUIC block */
#define MAX77705_OPCODE_WRITE	0x21
#define MAX77705_OPCODE_END	0x41
#define MAX77705_CMD_CTRL1_W	0x06	/* COMMAND_CONTROL1_WRITE */
#define MAX77705_COM_USB	0x09	/* COMP2SW = COMN1SW = USB */

/*
 * The bootloader leaves the MAX77705 data switch open after a warm boot with
 * the cable already attached; Samsung's MUIC driver writes COM_USB at boot.
 */
static void max77705_com_to_usb(void)
{
	unsigned char cmd[3] = { MAX77705_OPCODE_WRITE, MAX77705_CMD_CTRL1_W, MAX77705_COM_USB };
	unsigned char end[2] = { MAX77705_OPCODE_END, 0x00 };
	int fd, i;

	for (i = 0; i < 30; i++) {
		fd = open("/dev/i2c-0", O_RDWR);
		if (fd >= 0) break;
		usleep(100000);
	}
	if (fd < 0) { out("  MAX77705: no /dev/i2c-0\n"); st_max = 0; return; }
	if (ioctl(fd, I2C_SLAVE, MAX77705_USBC_ADDR) < 0) {
		out("  MAX77705: I2C_SLAVE failed\n");
	} else if (write(fd, cmd, sizeof(cmd)) != sizeof(cmd) ||
		   write(fd, end, sizeof(end)) != sizeof(end)) {
		out("  MAX77705: switch write FAILED (no ACK)\n");
		st_max = 1;
	} else {
		out("  MAX77705: data switch -> USB\n");
		st_max = 2;
	}
	close(fd);
}

/* ---------- bit-banged I2C on the HSI2C_40 pins (gpm14-0 / gpm15-0) ----------
 *
 * The HSI2C_40 controller times out after the bootloader (USI/clock state not
 * fully known yet), but the MAX77705 only needs a few bytes. Drive the two bus
 * pins as open-drain GPIOs through the CMGP pin controller: "0" = output low,
 * "1" = input (released, pulled up by the board). Never drives a line high.
 */
#define PINCTRL_CMGP	0x14220000UL
#define GPM14_OFF	0x180
#define GPM15_OFF	0x1a0

static volatile unsigned int *cmgp;
static unsigned int bb_sda, bb_scl;

#define CON(o)	cmgp[(o) / 4]
#define DAT(o)	cmgp[((o) + 4) / 4]

static void bb_delay(void) { for (int i = 0; i < 80; i++) (void)CON(GPM14_OFF); }
static void bb_rel(unsigned int o) { CON(o) = CON(o) & ~0xfu; }
static void bb_low(unsigned int o) { DAT(o) = DAT(o) & ~1u; CON(o) = (CON(o) & ~0xfu) | 1u; }
static int bb_get(unsigned int o) { return DAT(o) & 1; }

static void bb_scl_rel(void)
{
	bb_rel(bb_scl);
	for (int i = 0; i < 2000 && !bb_get(bb_scl); i++)	/* clock stretching */
		bb_delay();
}

static void bb_start(void) { bb_rel(bb_sda); bb_scl_rel(); bb_delay(); bb_low(bb_sda); bb_delay(); bb_low(bb_scl); bb_delay(); }
static void bb_stop(void) { bb_low(bb_sda); bb_delay(); bb_scl_rel(); bb_delay(); bb_rel(bb_sda); bb_delay(); }

static int bb_bit(int b)	/* write bit b, return the line as sampled */
{
	if (b) bb_rel(bb_sda); else bb_low(bb_sda);
	bb_delay();
	bb_scl_rel();
	bb_delay();
	b = bb_get(bb_sda);
	bb_low(bb_scl);
	bb_delay();
	return b;
}

static int bb_byte(int v)	/* returns 1 on ACK */
{
	for (int i = 7; i >= 0; i--) bb_bit((v >> i) & 1);
	return !bb_bit(1);
}

static int bb_rbyte(int ack)
{
	int v = 0;

	for (int i = 0; i < 8; i++) v = (v << 1) | bb_bit(1);
	bb_bit(!ack);
	return v;
}

static int bb_write(int addr, const unsigned char *b, int n)
{
	int ok;

	bb_start();
	ok = bb_byte(addr << 1);
	for (int i = 0; ok && i < n; i++) ok = bb_byte(b[i]);
	bb_stop();
	return ok;
}

static int bb_read(int addr, int reg, unsigned char *b, int n)
{
	int ok;

	bb_start();
	ok = bb_byte(addr << 1) && bb_byte(reg);
	if (ok) {
		bb_start();	/* repeated start */
		ok = bb_byte((addr << 1) | 1);
		for (int i = 0; ok && i < n; i++) b[i] = bb_rbyte(i + 1 < n);
	}
	bb_stop();
	return ok;
}

/* MAX77705 USB-C block: route D+/D- to the AP (Samsung COMMAND_CONTROL1_WRITE) */
static void max77705_bitbang(void)
{
	static const unsigned char sw[3] = { 0x21, 0x06, 0x09 }, end[2] = { 0x41, 0x00 };
	static const unsigned char rq[2] = { 0x21, 0x05 };
	unsigned int con14, con15, pud14, pud15;
	unsigned char rb[4] = { 0 };
	volatile unsigned int *base;
	char b[12];
	int map;

	base = map_reg(PINCTRL_CMGP);
	if (!base) { out("  bitbang: cannot map pin controller\n"); return; }
	cmgp = base;
	con14 = CON(GPM14_OFF); con15 = CON(GPM15_OFF);
	pud14 = cmgp[(GPM14_OFF + 8) / 4]; pud15 = cmgp[(GPM15_OFF + 8) / 4];
	cmgp[(GPM14_OFF + 8) / 4] = pud14 & ~0xfu;	/* board pull-ups only */
	cmgp[(GPM15_OFF + 8) / 4] = pud15 & ~0xfu;
	bb_rel(GPM14_OFF); bb_rel(GPM15_OFF);
	bb_delay(); bb_delay();
	out("  bitbang: idle lines gpm14="); out(bb_get(GPM14_OFF) ? "1" : "0");
	out(" gpm15="); out(bb_get(GPM15_OFF) ? "1\n" : "0\n");

	/* find which pin is SDA by probing the MAX77705 PMIC block at 0x66 */
	for (map = 0; map < 2; map++) {
		bb_sda = map ? GPM15_OFF : GPM14_OFF;
		bb_scl = map ? GPM14_OFF : GPM15_OFF;
		if (bb_write(0x66, 0, 0)) break;
	}
	if (map == 2) {
		out("  bitbang: no ACK from 0x66 on either pin order\n");
		st_max = 0;
	} else {
		out(map ? "  bitbang: SDA=gpm15 SCL=gpm14, 0x66 ACK\n" : "  bitbang: SDA=gpm14 SCL=gpm15, 0x66 ACK\n");
		if (bb_write(0x25, sw, 3) && bb_write(0x25, end, 2)) {
			out("  MAX77705: data switch -> USB (bit-banged)\n");
			st_max = 2;
		} else {
			out("  MAX77705: USB-C block 0x25 NACK\n");
			st_max = 1;
		}
		/* read CONTROL1 back for the log */
		if (bb_write(0x25, rq, 2) && bb_write(0x25, end, 2)) {
			usleep(20000);
			if (bb_read(0x25, 0x51, rb, 3)) {
				out("  MAX77705 CONTROL1 read:");
				for (int i = 0; i < 3; i++) { hex32(b, rb[i]); out(" "); out(b + 8); }
				out("\n");
			}
		}
	}
	/* hand the pins back to the HSI2C function */
	CON(GPM14_OFF) = con14; CON(GPM15_OFF) = con15;
	cmgp[(GPM14_OFF + 8) / 4] = pud14; cmgp[(GPM15_OFF + 8) / 4] = pud15;
	munmap((void *)((unsigned long)base & ~0xfffUL), 0x1000);
}

/* ---------- USB gadget ---------- */

static int load_module(const char *path)
{
	int fd = open(path, O_RDONLY), r;

	if (fd < 0) { out("  missing "); out(path); out("\n"); return -1; }
	r = __nolibc_syscall3(__NR_finit_module, fd, "", 0);
	close(fd);
	out("  insmod "); out(path); out(r == 0 || r == -17 ? ": ok\n" : ": FAILED\n");
	return r;
}

static int find_udc(char *name, int len)
{
	char buf[4096];
	int fd = open("/sys/class/udc", O_RDONLY | O_DIRECTORY), n;
	struct linux_dirent64 *d;

	if (fd < 0) return -1;
	n = __nolibc_syscall3(__NR_getdents64, fd, buf, sizeof(buf));
	close(fd);
	for (int off = 0; off < n; off += d->d_reclen) {
		d = (struct linux_dirent64 *)(buf + off);
		if (d->d_name[0] == '.') continue;
		strncpy(name, d->d_name, len - 1);
		name[len - 1] = 0;
		return 0;
	}
	return -1;
}

#define G "/sys/kernel/config/usb_gadget/g1"

static int setup_gadget(char *udc, int udclen)
{
	int i;

	for (i = 0; i < 50 && find_udc(udc, udclen); i++)
		usleep(100000);
	if (i == 50) { out("  no USB device controller appeared\n"); return -1; }
	out("  UDC: "); out(udc); out("\n");

	mkdir("/sys/kernel/config", 0755);
	mount("configfs", "/sys/kernel/config", "configfs", 0, 0);
	mkdir(G, 0755);
	writefile(G "/idVendor", "0x1d6b");	/* Linux Foundation */
	writefile(G "/idProduct", "0x0104");	/* Multifunction composite gadget */
	writefile(G "/bcdDevice", "0x0001");
	mkdir(G "/strings/0x409", 0755);
	writefile(G "/strings/0x409/manufacturer", "Samsung");
	writefile(G "/strings/0x409/product", "Galaxy Tab Active3 (mainline bring-up)");
	writefile(G "/strings/0x409/serialnumber", "gtactive3-bringup");
	mkdir(G "/configs/c.1", 0755);
	mkdir(G "/configs/c.1/strings/0x409", 0755);
	writefile(G "/configs/c.1/strings/0x409/configuration", "NCM");
	mkdir(G "/functions/ncm.usb0", 0755);
	/* fixed MACs so the IPv6 link-local addresses never change */
	writefile(G "/functions/ncm.usb0/dev_addr", "02:57:0a:00:00:01");
	writefile(G "/functions/ncm.usb0/host_addr", "02:57:0a:00:00:02");
	symlink(G "/functions/ncm.usb0", G "/configs/c.1/ncm.usb0");
	if (writefile(G "/UDC", udc)) { out("  binding gadget to UDC failed\n"); return -1; }
	out("  gadget bound\n");
	return 0;
}

static void ifup(const char *ifname)
{
	struct ifreq ifr;
	int s = __nolibc_syscall3(__NR_socket, AF_INET6, 2 /* SOCK_DGRAM */, 0);

	if (s < 0) { out("  no socket for ifup\n"); return; }
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ioctl(s, SIOCGIFFLAGS, &ifr);
	ifr.ifr_flags |= IFF_UP;
	out(ioctl(s, SIOCSIFFLAGS, &ifr) ? "  ifup failed\n" : "  usb0 up (fe80::57:aff:fe00:1)\n");
	close(s);
}

/* ---------- debug console on TCP/23 ---------- */

static unsigned long parse_num(const char *s, const char **end)
{
	unsigned long v = 0;

	while (*s == ' ') s++;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		for (;; s++) {
			int c = *s;
			if (c >= '0' && c <= '9') v = v * 16 + c - '0';
			else if (c >= 'a' && c <= 'f') v = v * 16 + c - 'a' + 10;
			else if (c >= 'A' && c <= 'F') v = v * 16 + c - 'A' + 10;
			else break;
		}
	} else {
		while (*s >= '0' && *s <= '9') v = v * 10 + *s++ - '0';
	}
	if (end) *end = s;
	return v;
}

/* i2c-dev helpers for the console: raw write, and write-then-read */
static int i2c_xfer(int addr, unsigned char *wbuf, int wlen, unsigned char *rbuf, int rlen)
{
	struct i2c_msg msgs[2];
	struct i2c_rdwr_ioctl_data d;
	int fd = open("/dev/i2c-0", O_RDWR), n = 0, r;

	if (fd < 0) return -1;
	if (wlen) { msgs[n].addr = addr; msgs[n].flags = 0; msgs[n].len = wlen; msgs[n].buf = wbuf; n++; }
	if (rlen) { msgs[n].addr = addr; msgs[n].flags = I2C_M_RD; msgs[n].len = rlen; msgs[n].buf = rbuf; n++; }
	d.msgs = msgs;
	d.nmsgs = n;
	r = ioctl(fd, I2C_RDWR, &d);
	close(fd);
	return r < 0 ? -1 : 0;
}

static void serve(int c)
{
	static char fbuf[64];
	char line[256], b[12];
	int n = 0, r;
	unsigned int v;

	wr(c, "SM-T570 mainline bring-up console. Commands: dmesg, peek ADDR, dump ADDR N, "
	      "poke ADDR VAL, cat PATH, write PATH VALUE, put PATH LEN, run PATH [ARGS], insmod PATH [ARGS], rmmod NAME, ls DIR, i2cw ADDR B.., i2cr ADDR REG N, evread PATH [N] [SECS], ulog, reboot [download|recovery|normal]\n> ");
	for (;;) {
		r = read(c, line + n, 1);
		if (r <= 0) return;
		if (line[n] == '\r') continue;
		if (line[n] != '\n' && n < (int)sizeof(line) - 2) { n++; continue; }
		line[n] = 0;
		n = 0;
		if (!strcmp(line, "dmesg")) {
			r = klog_read();
			write(c, logbuf, r);
		} else if (!strncmp(line, "peek ", 5)) {
			unsigned long a = parse_num(line + 5, 0);
			if (peek(a, &v)) wr(c, "error\n");
			else { hex32(b, v); wr(c, b); wr(c, "\n"); }
		} else if (!strncmp(line, "discard ", 8)) {
			/*
			 * discard DEV: UFS unmap of a whole partition. Only the
			 * Android partitions the user approved wiping (metadata,
			 * super, cache, userdata); never EFS/param/persistent/
			 * bootloaders.
			 */
			static const char *const ok_devs[] = {
				"/dev/sda24", "/dev/sda25", "/dev/sda28", "/dev/sda31",
			};
			unsigned long long range[2] = { 0, 0 };
			char ob[96];
			int k, allowed = 0, fd;

			for (k = 0; k < 4; k++)
				if (!strcmp(line + 8, ok_devs[k]))
					allowed = 1;
			if (!allowed) {
				wr(c, "discard: not an approved partition\n");
			} else if ((fd = open(line + 8, O_RDWR)) < 0) {
				wr(c, "error\n");
			} else {
				if (ioctl(fd, BLKGETSIZE64, &range[1]) < 0 ||
				    ioctl(fd, BLKDISCARD, range) < 0) {
					wr(c, "discard failed\n");
				} else {
					snprintf(ob, sizeof(ob), "discarded %llu bytes\n", range[1]);
					wr(c, ob);
				}
				close(fd);
			}
		} else if (!strcmp(line, "ulog")) {
			ulog_print(c);
#ifndef CONSOLE_STDIO
		} else if (!strcmp(line, "stay")) {
			/* cancel a pending restart of a hung Duranium (main loop) */
			int fd = open(HR_STAY_FILE, O_WRONLY | O_CREAT, 0644);

			if (fd >= 0) close(fd);
			wr(c, fd < 0 ? "error\n" : "ok\n");
#endif
		} else if (!strncmp(line, "dump ", 5)) {
			/* dump ADDR COUNT: COUNT 32-bit registers */
			const char *e;
			unsigned long a = parse_num(line + 5, &e);
			unsigned long nn = parse_num(e, 0), k;
			char ob[48];

			for (k = 0; k < nn && k < 1024; k++) {
				if (peek(a + 4 * k, &v)) { wr(c, "error\n"); break; }
				hex32(b, v);
				snprintf(ob, sizeof(ob), "%08lx %s\n", a + 4 * k, b);
				wr(c, ob);
			}
		} else if (!strncmp(line, "memcat ", 7)) {
			/*
			 * memcat ADDR LEN: LEN raw bytes of physical memory (e.g. the
			 * framebuffer). mmap, not read(): arm64 /dev/mem read() only
			 * covers mapped RAM. The mapping is device memory, so copy
			 * with aligned 32-bit loads.
			 */
			static unsigned int mb[16384];
			const char *e;
			unsigned long a = parse_num(line + 7, &e);
			unsigned long nn = parse_num(e, 0);
			unsigned long base = a & ~4095UL, off = a - base;
			int fd = open("/dev/mem", O_RDONLY | O_SYNC);
			void *m = fd < 0 ? MAP_FAILED :
				mmap(0, off + nn, PROT_READ, MAP_SHARED, fd, base);

			if (m == MAP_FAILED || (a & 3)) {
				wr(c, "error\n");
			} else {
				volatile unsigned int *src = (volatile unsigned int *)((char *)m + off);
				unsigned long k, done = 0;

				while (done < nn) {
					unsigned long chunk = nn - done < sizeof(mb) ? nn - done : sizeof(mb);

					for (k = 0; k < (chunk + 3) / 4; k++)
						mb[k] = src[done / 4 + k];
					if (write(c, mb, chunk) != (ssize_t)chunk)
						break;
					done += chunk;
				}
				munmap(m, off + nn);
			}
			if (fd >= 0)
				close(fd);
		} else if (!strncmp(line, "poke ", 5)) {
			const char *e;
			unsigned long a = parse_num(line + 5, &e);
			unsigned long val = parse_num(e, 0);
			wr(c, poke(a, val) ? "error\n" : "ok\n");
		} else if (!strncmp(line, "cat ", 4)) {
			static char fb[8192];
			int fd = open(line + 4, O_RDONLY);
			if (fd < 0) wr(c, "error\n");
			else {
				while ((r = read(fd, fb, sizeof(fb))) > 0)
					write(c, fb, r);
				close(fd);
			}
		} else if (!strncmp(line, "i2cw ", 5) || !strncmp(line, "i2cr ", 5)) {
			/* i2cw ADDR B0 B1 ...  |  i2cr ADDR REG N */
			unsigned char wb[40], rb[64];
			const char *e = line + 5;
			int addr = parse_num(e, &e), nw = 0, nr = 0, k;

			if (line[3] == 'w') {
				while (*e && nw < 40) { while (*e == ' ') e++; if (!*e) break; wb[nw++] = parse_num(e, &e); }
			} else {
				wb[nw++] = parse_num(e, &e);
				nr = parse_num(e, &e);
				if (nr > 64) nr = 64;
			}
			if (i2c_xfer(addr, wb, nw, rb, nr)) wr(c, "i2c error (no ACK?)\n");
			else if (!nr) wr(c, "ok\n");
			else {
				for (k = 0; k < nr; k++) { hex32(b, rb[k]); wr(c, b + 8); wr(c, k + 1 < nr ? " " : "\n"); }
			}
		} else if (!strncmp(line, "put ", 4)) {
			/* put PATH LEN, then LEN raw bytes: upload a file into the initramfs */
			static char pb[16384];
			char *sp = strchr(line + 4, ' ');
			long len, got = 0;
			int fd;

			if (!sp) { wr(c, "usage: put PATH LEN\n"); goto prompt; }
			*sp++ = 0;
			len = parse_num(sp, 0);
			fd = open(line + 4, O_WRONLY | O_CREAT | O_TRUNC, 0644);
			while (got < len) {
				int want = len - got > (long)sizeof(pb) ? (int)sizeof(pb) : (int)(len - got);
				int k = read(c, pb, want);
				if (k <= 0) break;
				if (fd >= 0) write(fd, pb, k);
				got += k;
			}
			if (fd >= 0) close(fd);
			snprintf(fbuf, sizeof(fbuf), fd < 0 ? "error\n" : "ok %ld\n", got);
			wr(c, fbuf);
		} else if (!strncmp(line, "insmod ", 7)) {
			/* insmod PATH [module parameters] */
			char *args = strchr(line + 7, ' ');
			int fd, rr;

			if (args) *args++ = 0;
			fd = open(line + 7, O_RDONLY);
			rr = fd < 0 ? -2 : __nolibc_syscall3(__NR_finit_module, fd, args ? args : "", 0);
			if (fd >= 0) close(fd);
			snprintf(fbuf, sizeof(fbuf), "%s\n", rr == 0 ? "ok" : rr == -17 ? "already loaded" : "FAILED");
			wr(c, fbuf);
			if (rr && rr != -17) { snprintf(fbuf, sizeof(fbuf), "errno %d\n", -rr); wr(c, fbuf); }
		} else if (!strncmp(line, "evread ", 7)) {
			/*
			 * evread PATH [N] [SECS]: print up to N (default 64) input
			 * events from an evdev node, giving up after SECS (default 5)
			 * seconds without an event, so the console never blocks.
			 */
			char *sp = strchr(line + 7, ' ');
			struct input_event ie;
			struct pollfd pfd;
			long n = 64, secs = 5, k;
			const char *e;

			if (sp) {
				*sp++ = 0;
				n = parse_num(sp, &e);
				while (*e == ' ') e++;
				if (*e) secs = parse_num(e, 0);
			}
			pfd.fd = open(line + 7, O_RDONLY | O_NONBLOCK);
			pfd.events = POLLIN;
			if (pfd.fd < 0) { wr(c, "error\n"); goto prompt; }
			if (ioctl(pfd.fd, EVIOCGNAME(sizeof(fbuf)), fbuf) > 0) {
				fbuf[sizeof(fbuf) - 1] = 0;
				wr(c, "name: "); wr(c, fbuf); wr(c, "\n");
			}
			for (k = 0; k < n; ) {
				if (poll(&pfd, 1, secs * 1000) <= 0) { wr(c, "timeout\n"); break; }
				while (k < n && read(pfd.fd, &ie, sizeof(ie)) == sizeof(ie)) {
					char eb[64];

					snprintf(eb, sizeof(eb), "%ld.%06ld %x %x %d\n",
						 (long)ie.input_event_sec, (long)ie.input_event_usec,
						 ie.type, ie.code, ie.value);
					wr(c, eb);
					k++;
				}
			}
			close(pfd.fd);
		} else if (!strncmp(line, "rmmod ", 6)) {
			int rr = __nolibc_syscall2(__NR_delete_module, line + 6, 0x800 /* O_NONBLOCK */);
			snprintf(fbuf, sizeof(fbuf), rr ? "FAILED errno %d\n" : "ok\n", -rr);
			wr(c, fbuf);
		} else if (!strncmp(line, "ls ", 3)) {
			char db[4096];
			int fd = open(line + 3, O_RDONLY | O_DIRECTORY), nn;
			if (fd < 0) { wr(c, "error\n"); }
			else {
				while ((nn = __nolibc_syscall3(__NR_getdents64, fd, db, sizeof(db))) > 0) {
					for (int off = 0; off < nn;) {
						struct linux_dirent64 *d = (struct linux_dirent64 *)(db + off);
						if (d->d_name[0] != '.') { wr(c, d->d_name); wr(c, "\n"); }
						off += d->d_reclen;
					}
				}
				close(fd);
			}
		} else if (!strncmp(line, "write ", 6)) {
			char *val = strchr(line + 6, ' ');
			if (!val) { wr(c, "usage: write PATH VALUE\n"); }
			else { *val++ = 0; wr(c, writefile(line + 6, val) ? "error\n" : "ok\n"); }
		} else if (!strncmp(line, "run ", 4)) {
			/*
			 * run PATH [ARGS]: start a test program (uploaded with put),
			 * output to this connection, killed after 60 s.
			 */
			char *av[9], *p = line + 4;
			int na = 0, st = 0, pid, w = 0, t;

			while (*p && na < 8) {
				while (*p == ' ') *p++ = 0;
				if (!*p) break;
				av[na++] = p;
				while (*p && *p != ' ') p++;
			}
			av[na] = 0;
			if (!na) { wr(c, "usage: run PATH [ARGS]\n"); goto prompt; }
			chmod(av[0], 0755);
			pid = fork();
			if (pid == 0) {
				char *envp[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", 0 };

				dup2(c, 1);
				dup2(c, 2);
				execve(av[0], av, envp);
				_exit(127);
			}
			for (t = 0; pid > 0 && t < 600; t++) {
				w = waitpid(pid, &st, WNOHANG);
				if (w) break;
				usleep(100000);
			}
			if (pid > 0 && !w) {
				kill(pid, 9);
				waitpid(pid, &st, 0);
				wr(c, "run: killed after 60 s\n");
			}
			snprintf(fbuf, sizeof(fbuf), pid < 0 ? "run: fork failed\n" :
				 "run: exit %d signal %d\n", (st >> 8) & 0xff, st & 0x7f);
			wr(c, fbuf);
		} else if (!strncmp(line, "reboot", 6)) {
			const char *m = line[6] == ' ' ? line + 7 : "normal";
			wr(c, "rebooting\n");
			close(c);
			reboot_to(m);
		} else if (line[0]) {
			wr(c, "unknown command\n");
		}
prompt:
		wr(c, "> ");
	}
}

static int listen23(void)
{
	struct sockaddr_in6 a;
	int one = 1;
	int s = __nolibc_syscall3(__NR_socket, AF_INET6, 1 /* SOCK_STREAM */, 0);

	if (s < 0) return -1;
	__nolibc_syscall5(__NR_setsockopt, s, 1 /* SOL_SOCKET */, 2 /* SO_REUSEADDR */, &one, sizeof(one));
	memset(&a, 0, sizeof(a));
	a.sin6_family = AF_INET6;
	a.sin6_port = (23 >> 8) | ((23 & 0xff) << 8);
	if (__nolibc_syscall3(__NR_bind, s, &a, sizeof(a)) ||
	    __nolibc_syscall2(__NR_listen, s, 2)) {
		close(s);
		return -1;
	}
	return s;
}

/* ---------- keys ---------- */

static const char *keyname(int code)
{
	switch (code) {
	case KEY_POWER: return "POWER";
	case KEY_VOLUMEUP: return "VOLUME UP";
	case KEY_VOLUMEDOWN: return "VOLUME DOWN";
	case KEY_HOMEPAGE: return "HOME";
	case KEY_BACK: return "BACK";
	case KEY_APPSELECT: return "RECENT APPS";
	case KEY_PROG1: return "ACTIVE KEY";
	default: return "other";
	}
}

#ifndef CONSOLE_STDIO
int main(void)
{
	char udc[64] = "", path[128];
	int host_seen = 0;
	struct input_event ev;
	int keys, lsock, i, restart;

	mkdir("/proc", 0755); mkdir("/sys", 0755); mkdir("/dev", 0755);
	mount("proc", "/proc", "proc", 0, 0);
	mount("sysfs", "/sys", "sysfs", 0, 0);
	mount("devtmpfs", "/dev", "devtmpfs", 0, 0);

	i = open("/dev/tty0", O_WRONLY);
	if (i >= 0) con = i;
	kmsg = open("/dev/kmsg", O_WRONLY);
	mkdir("/sys/fs/pstore", 0755);
	mount("pstore", "/sys/fs/pstore", "pstore", 0, 0);
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, 0);

	out("\n\n==============================================\n");
	out("  Galaxy Tab Active3 - mainline Linux is alive\n");
	out("==============================================\n\n");
	arm_download_on_reset();
	cat("Kernel:   ", "/proc/version", 200);
	cat("CPUs:     ", "/sys/devices/system/cpu/online", 32);
	cat("Board:    ", "/sys/firmware/devicetree/base/model", 64);
	cat("Memory:   ", "/proc/meminfo", 28);
	klog_summary();

	out("\nUSB bring-up:\n");
	force_gate("CMU_TOP GATE_CLKCMU_FSYS0_USB30DRD", CMU_TOP_BASE + 0x2064);
	force_gate("FSYS0 GOUT_USB30DRD_REF_CLK", CMU_FSYS0_BASE + 0x206c);
	/*
	 * HSI2C_40 sits in a USI block whose USI_CON[0] reset stays asserted
	 * after the bootloader; Samsung's driver clears it before any transfer.
	 * TODO: describe the USI wrapper in DT instead (exynos-usi).
	 */
	{
		unsigned int mux = 0, div = 0;
		char b[12];

		/* USI_03_CMGP (hsi2c@14360000) into I2C mode: SYSREG_CMGP SW_CONF */
		poke(0x14212030UL, 0x4);
		/* CMU_CMGP gates for USI_CMGP03 */
		force_gate("CMGP GATE_CLK_USI_CMGP03", 0x14200000UL + 0x2014);
		force_gate("CMGP USI_CMGP03 IPCLK", 0x14200000UL + 0x20a8);
		force_gate("CMGP USI_CMGP03 PCLK", 0x14200000UL + 0x20ac);
		force_gate("CMGP RSTNSYNC USI_CMGP03", 0x14200000UL + 0x2074);
		peek(0x14200000UL + 0x1018, &mux);
		peek(0x14200000UL + 0x1814, &div);
		hex32(b, mux); out("  USI_CMGP03 mux "); out(b);
		hex32(b, div); out(" div "); out(b); out("\n");
		/* release the USI reset */
		poke(0x14360000UL + 0xc4, 0);
	}
	max77705_bitbang();
	load_module("/lib/modules/phy-exynos5-usbdrd.ko");
	load_module("/lib/modules/dwc3.ko");
	load_module("/lib/modules/dwc3-exynos.ko");
	if (!setup_gadget(udc, sizeof(udc))) {
		st_gadget = 1;
		ifup("usb0");
	}

	lsock = listen23();
	out(lsock < 0 ? "  debug console: FAILED\n" : "  debug console on port 23\n");
	out("\nVOLUME UP = restart into Download mode.\n");

	/* storage, so the partitions are there without a manual insmod */
	load_module("/lib/modules/phy-exynos-ufs.ko");
	load_module("/lib/modules/ufshcd-core.ko");
	load_module("/lib/modules/ufshcd-pltfrm.ko");
	load_module("/lib/modules/ufs-exynos.ko");

	/* bundle 1 (tested 2026-10-21): hardware I2C behind its USI wrapper, DCS backlight */
	load_module("/lib/modules/exynos-usi.ko");
	load_module("/lib/modules/i2c-exynos5.ko");
	load_module("/lib/modules/exynos9810-dsim-bl.ko");

	/* bundle 2 (tested 2026-10-21): TMU, ACPM + read-only S2MPS18, MAX77705 */
	load_module("/lib/modules/exynos9810_tmu.ko");
	load_module("/lib/modules/exynos-mailbox.ko");
	load_module("/lib/modules/acpm-protocol.ko");
	load_module("/lib/modules/sec-core.ko");
	load_module("/lib/modules/sec-acpm.ko");
	load_module("/lib/modules/s2mps11.ko");
	/* ACPM DVFS clocks + cpufreq-dt (CPU frequency scaling) */
	load_module("/lib/modules/clk-acpm.ko");
	load_module("/lib/modules/cpufreq-dt.ko");
	load_module("/lib/modules/max77705.ko");
	/* USB-C/BC1.2 input detection: the charger's input supplier */
	load_module("/lib/modules/max77705_usbc_psy.ko");
	load_module("/lib/modules/max77705_charger.ko");
	load_module("/lib/modules/simple-mfd-i2c.ko");
	load_module("/lib/modules/max77705-hwmon.ko");
	load_module("/lib/modules/max17042_battery.ko");
	/*
	 * Safety: no battery temperature input yet (the NTC is on an ADC we
	 * have no driver for), so never charge faster than 1.5 A.
	 */
	writefile("/sys/class/power_supply/max77705-charger/constant_charge_current", "1500000");

	/* bundle 3 (tested 2026-10-21): panfrost on the Mali-G72, G3D left on by S-Boot */
	load_module("/lib/modules/gpu-sched.ko");
	load_module("/lib/modules/panfrost.ko");

	/*
	 * Hardware watchdog (cluster 0, 30 s), kicked from the main loop below:
	 * if the kernel or init wedges, the SoC resets and S-Boot boots BOOT.
	 */
	wdt = open("/dev/watchdog0", O_WRONLY);
	if (wdt >= 0) {
		int t = 30;

		ioctl(wdt, WDIOC_SETTIMEOUT, &t);
		out("  watchdog armed (30 s)\n");
	} else {
		out("  watchdog: not available\n");
	}

	keys = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
	if (lsock >= 0)
		__nolibc_syscall3(__NR_fcntl, lsock, 4 /* F_SETFL */, O_NONBLOCK);

	/* countdown in main-loop ticks (100 ms) to restarting Duranium, 0 = none */
	restart = os_hang_check() ? HR_DELAY_S * 10 : 0;

	for (i = 0;; i++) {
		int c;

		if (keys >= 0 && read(keys, &ev, sizeof(ev)) == sizeof(ev) &&
		    ev.type == EV_KEY && ev.value == 1) {
			out("Key: "); out(keyname(ev.code)); out("\n");
			if (ev.code == KEY_VOLUMEUP && restart) {
				restart = 0;
				out("Staying in the recovery console. VOLUME UP again = Download mode.\n");
			} else if (ev.code == KEY_VOLUMEUP) {
				reboot_to("download");
			}
		}
		if (restart) {
			int fd = open(HR_STAY_FILE, O_RDONLY);

			if (fd >= 0) {
				close(fd);
				restart = 0;
				out("Staying in the recovery console (\"stay\" from the host).\n");
			} else if (--restart == 0) {
				out("Restarting Duranium.\n");
				os_restart();
			} else if (restart % 50 == 0) {
				char b[32];

				snprintf(b, sizeof(b), "  restarting in %d s\n", restart / 10);
				out(b);
			}
		}
		if (lsock >= 0) {
			c = __nolibc_syscall4(__NR_accept4, lsock, 0, 0, 0);
			if (c >= 0) {
				int pid;

				out("Host connected to debug console.\n");
				host_seen = 1;
				/*
				 * Serve each connection in a child: a peek/dump of a
				 * register that faults (unclocked or secure block)
				 * then only kills that child, not init.
				 */
				pid = fork();
				if (pid == 0) {
					close(lsock);
					serve(c);
					_exit(0);
				}
				if (pid < 0)
					serve(c);
				close(c);
			}
			while (waitpid(-1, 0, WNOHANG) > 0)
				;
		}
		/* not enumerated yet: drop and re-assert the D+ pull-up every 8 s */
		if (!host_seen && udc[0] && i && i % 80 == 0) {
			char st[32] = "";

			snprintf(path, sizeof(path), "/sys/class/udc/%s/state", udc);
			readfile(path, st, sizeof(st));
			if (!strstr(st, "configured")) {
				snprintf(path, sizeof(path), "/sys/class/udc/%s/soft_connect", udc);
				writefile(path, "disconnect");
				usleep(500000);
				writefile(path, "connect");
				out("  USB not enumerated, re-asserted pull-up\n");
			}
		}
		/* no host after the timeout: hand back to the flashing loop */
		/*
		 * Timing side channel for the host loop: with no host, reboot into
		 * Download mode after 30 + 10 * code seconds,
		 * code = st_max (0 no i2c, 1 NACK, 2 ACK) + 3 * st_gadget (0/1).
		 */
		if (i == (30 + 10 * (st_max + 3 * st_gadget)) * 10 && !host_seen) {
			char st[32] = "";

			snprintf(path, sizeof(path), "/sys/class/udc/%s/state", udc);
			readfile(path, st, sizeof(st));
			if (!strstr(st, "configured")) {
				out("No USB host after timeout (UDC state: ");
				out(st[0] ? st : "unknown\n");
				out(").\n");
				reboot_to("download");
			}
			out("USB host present, staying up.\n");
		}
		if (wdt >= 0 && i % 10 == 0)
			ioctl(wdt, WDIOC_KEEPALIVE, 0);
		usleep(100000);
	}
	return 0;
}
#else
/*
 * The same debug console as a standalone program for the booted system
 * (Duranium): systemd accepts the TCP connection (Accept=yes) and hands it
 * over on stdin/stdout, so the host tools (scripts/tab, tab-get, tab-put)
 * work unchanged.
 */
int main(void)
{
	serve(0);
	return 0;
}
#endif /* CONSOLE_STDIO */
