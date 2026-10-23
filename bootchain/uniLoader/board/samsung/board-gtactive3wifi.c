/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung Galaxy Tab Active3 (SM-T570) board, based on board-starlte.c
 */
#include <board.h>
#include <util.h>
#include <drivers/framework.h>
#include <lib/simplefb.h>
#include <stdint.h>

#define DECON_F_BASE		0x16030000
#define HW_SW_TRIG_CONTROL	0x70

// Early initialization
int gtactive3wifi_init(void)
{
	/* Allow framebuffer to be written to */
	*(int*) (DECON_F_BASE + HW_SW_TRIG_CONTROL) = 0x1281;
	return 0;
}

#ifdef CONFIG_CHAINLOAD
#include <main/chainload.h>

/*
 * Exynos 9810 PMU (stock DT system-controller@14060000). The watchdog
 * registers follow Samsung's s3c2410_wdt.c drv_data_exynos8 (RST_STAT 0x404,
 * DISABLE_WDT 0x408, MASK_WDT_RESET 0x40c, bit 24 = cluster 0 WDTRESET); the
 * reboot reason is INFORM2/INFORM3 as in Samsung's sec_reboot.c.
 */
#define PMU_BASE		0x14060000
#define PMU_RST_STAT		(PMU_BASE + 0x0404)
#define PMU_WDT_DISABLE		(PMU_BASE + 0x0408)
#define PMU_WDT_MASK_RESET	(PMU_BASE + 0x040c)
#define PMU_INFORM2		(PMU_BASE + 0x0808)
#define PMU_INFORM3		(PMU_BASE + 0x080c)
#define CL0_WDTRESET		(1U << 24)
#define SEC_POWER_RESET		0x12345678
#define SEC_RESET_DOWNLOAD	0x12345671

/* Cluster 0 (A55) watchdog, stock DT watchdog_cl0@10050000 */
#define WDT_BASE		0x10050000
#define WTCON			(WDT_BASE + 0x00)
#define WTDAT			(WDT_BASE + 0x04)
#define WTCNT			(WDT_BASE + 0x08)
/* prescaler 255 + 1, divider 128, enable, reset: 26 MHz -> ~82 s for 0xffff */
#define WTCON_ARMED		((0xff << 8) | (3 << 3) | (1 << 5) | (1 << 0))

/* Volume Down: gpa0-4, active low; gpa0 is the bank at +0x20 of pinctrl@14050000 */
#define GPA0_DAT		(0x14050000 + 0x20 + 0x04)
#define KEY_VOLDOWN		(1U << 4)

static inline uint32_t rd(unsigned long a) { return *(volatile uint32_t *)a; }
static inline void wr(unsigned long a, uint32_t v) { *(volatile uint32_t *)a = v; }

static void reboot_reason_download(void)
{
	wr(PMU_INFORM2, SEC_POWER_RESET);
	wr(PMU_INFORM3, SEC_RESET_DOWNLOAD);
}

/*
 * S-Boot leaves this watchdog running with its reset masked. Reload it,
 * then let it reset the SoC: S-Boot boots BOOT again and we see RST_STAT
 * bit 24. Then check that it really is armed: both PMU gates open and the
 * counter moving (one tick is 256 * 128 / 26 MHz, ~1.3 ms). If not, ask
 * for the fallback Linux: nothing would catch a hang of the chained
 * bootloader.
 */
static void wdt_arm(struct chain_info *ci)
{
	uint32_t c0;
	int i, moved = 0;

	wr(WTCON, 0);
	wr(WTDAT, 0xffff);
	wr(WTCNT, 0xffff);
	wr(WTCON, WTCON_ARMED);
	wr(PMU_WDT_DISABLE, rd(PMU_WDT_DISABLE) & ~CL0_WDTRESET);
	wr(PMU_WDT_MASK_RESET, rd(PMU_WDT_MASK_RESET) & ~CL0_WDTRESET);
	ci->wdt_ctrl = rd(WTCON);
	ci->reason |= CHAIN_N_WDT_ARMED;

	c0 = rd(WTCNT);
	for (i = 0; i < 2000000 && !moved; i++)
		moved = rd(WTCNT) != c0;
	if (!moved || ci->wdt_ctrl != WTCON_ARMED ||
	    (rd(PMU_WDT_DISABLE) & CL0_WDTRESET) ||
	    (rd(PMU_WDT_MASK_RESET) & CL0_WDTRESET))
		ci->reason |= CHAIN_R_WDT_FAIL;
}

/* Back to the state S-Boot leaves: running, reset masked and auto-disabled */
static void wdt_disarm(struct chain_info *ci)
{
	wr(PMU_WDT_MASK_RESET, rd(PMU_WDT_MASK_RESET) | CL0_WDTRESET);
	wr(PMU_WDT_DISABLE, rd(PMU_WDT_DISABLE) | CL0_WDTRESET);
	ci->wdt_ctrl = rd(WTCON);
	ci->reason &= ~CHAIN_N_WDT_ARMED;
}

/* Register reads only: this runs before the watchdog guards anything */
static int gtactive3wifi_chain_select(struct chain_info *ci)
{
	int i, held = 1;

	ci->rst_stat = rd(PMU_RST_STAT);
	ci->keys = rd(GPA0_DAT);
	/* "held" only if every sample reads low */
	for (i = 0; i < 2000; i++)
		if (rd(GPA0_DAT) & KEY_VOLDOWN)
			held = 0;

	if (ci->rst_stat & CL0_WDTRESET)
		ci->reason |= CHAIN_R_WDT_RESET;
	if (held)
		ci->reason |= CHAIN_R_KEY;

	return !(ci->reason & (CHAIN_R_WDT_RESET | CHAIN_R_KEY));
}

/* Called once as a guard right after chain_select, and again before the jump */
static void gtactive3wifi_chain_arm(struct chain_info *ci)
{
	reboot_reason_download();
	wdt_arm(ci);
}

static void gtactive3wifi_fallback_arm(struct chain_info *ci)
{
	reboot_reason_download();
	wdt_disarm(ci);
}

/*
 * CONFIG_CHAINLOAD_DEFAULT=2: arm as for the chained bootloader and wait
 * for the reset. Returns only if the counter ran out (or stopped) without
 * resetting the SoC, so that the test itself can never leave us hanging.
 */
static void gtactive3wifi_wdt_test(struct chain_info *ci)
{
	uint32_t c, last, low = 0xffff;
	unsigned long same = 0;

	gtactive3wifi_chain_arm(ci);
	if (ci->reason & CHAIN_R_WDT_FAIL)
		return;

	last = rd(WTCNT);
	for (;;) {
		c = rd(WTCNT);
		if (c < low)
			low = c;
		/* reloaded from WTDAT after reaching 0: no reset happened */
		if (low < 0x100 && c > 0x8000)
			return;
		if (c == last) {
			/* about 10 s of reads without a tick: stopped */
			if (++same > 100000000UL)
				return;
		} else {
			same = 0;
			last = c;
		}
	}
}
#endif

/* Bootloader framebuffer (stock DTBO "exynos,fb_handover" at 0xca000000) */
static struct video_info gtactive3wifi_fb = {
	.format = FB_FORMAT_ARGB8888,
	.width = 1200,
	.height = 1920,
	.stride = 4,
	.scale = 2,
	.address = (void *)0xca000000
};

static const struct device gtactive3wifi_devices[] = {
	{ "simplefb", &gtactive3wifi_fb, "fb" },
};

struct board_data board_ops = {
	.name = "samsung-gtactive3wifi",
	.ops = {
		.early_init = gtactive3wifi_init,
#ifdef CONFIG_CHAINLOAD
		.chain_select = gtactive3wifi_chain_select,
		.chain_arm = gtactive3wifi_chain_arm,
		.fallback_arm = gtactive3wifi_fallback_arm,
		.wdt_test = gtactive3wifi_wdt_test,
#endif
	},
	.devices = gtactive3wifi_devices,
	.num_devices = ARRAY_SIZE(gtactive3wifi_devices),
	.quirks = 0
};
