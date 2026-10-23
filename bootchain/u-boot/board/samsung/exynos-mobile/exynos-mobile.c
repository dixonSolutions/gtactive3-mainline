// SPDX-License-Identifier: GPL-2.0
/*
 * Samsung Exynos Generic Board Source (for mobile devices)
 *
 * Copyright (c) 2025 Kaustabh Chakraborty <kauschluss@disroot.org>
 */

#include <asm/armv8/mmu.h>
#include <asm/io.h>
#include <blk.h>
#include <bootm.h>
#include <bootflow.h>
#include <cpu_func.h>
#include <ctype.h>
#include <dm/ofnode.h>
#include <dm/uclass.h>
#include <efi_loader.h>
#include <env.h>
#include <errno.h>
#include <init.h>
#include <limits.h>
#include <linux/delay.h>
#include <log.h>
#include <linux/sizes.h>
#include <lmb.h>
#include <part.h>
#include <stdbool.h>
#include <wdt.h>

DECLARE_GLOBAL_DATA_PTR;

#define lmb_alloc(size, addr) \
	lmb_alloc_mem(LMB_MEM_ALLOC_ANY, SZ_2M, addr, size, LMB_NONE)

struct exynos_board_info {
	const char *name;
	const char *chip;
	const u64 *const dram_bank_bases;

	char serial[64];

	int (*const match)(struct exynos_board_info *);
	const char *match_model;
	const u8 match_max_rev;
};

/*
 * The memory mapping includes all DRAM banks, along with the
 * peripheral block, and a sentinel at the end. This is filled in
 * dynamically.
 */
static struct mm_region exynos_mem_map[CONFIG_NR_DRAM_BANKS + 2] = {
	{
		/* Peripheral MMIO block */
		.virt = 0x10000000UL,
		.phys = 0x10000000UL,
		.size = 0x10000000UL,
		.attrs = PTE_BLOCK_MEMTYPE(MT_DEVICE_NGNRNE) |
			 PTE_BLOCK_NON_SHARE | PTE_BLOCK_PXN | PTE_BLOCK_UXN,
	},
};

struct mm_region *mem_map = exynos_mem_map;

static const u64 exynos7870_common_dram_bank_bases[CONFIG_NR_DRAM_BANKS] = {
	0x40000000, 0x80000000, 0x100000000,
};

static const u64 exynos9810_common_dram_bank_bases[CONFIG_NR_DRAM_BANKS] = {
	0x80000000, 0xc0000000, 0xe1900000, 0x880000000,
};

static const u64 exynos9820_common_dram_bank_bases[CONFIG_NR_DRAM_BANKS] = {
	0x80000000,  0xc0000000, 0xe1900000, 0x880000000, 0x900000000, 0x980000000
};

static const char *exynos_prev_bl_get_bootargs(void)
{
	void *prev_bl_fdt_base = (void *)get_prev_bl_fdt_addr();
	int chosen_node_offset, ret;
	const struct fdt_property *bootargs_prop;

	ret = fdt_check_header(prev_bl_fdt_base);
	if (ret < 0) {
		log_err("%s: FDT is invalid (FDT_ERR %d)\n", __func__, ret);
		return NULL;
	}

	ret = fdt_path_offset(prev_bl_fdt_base, "/chosen");
	chosen_node_offset = ret;
	if (ret < 0) {
		log_err("%s: /chosen node not found (FDT_ERR %d)\n", __func__,
			ret);
		return NULL;
	}

	bootargs_prop = fdt_get_property(prev_bl_fdt_base, chosen_node_offset,
					 "bootargs", &ret);
	if (!bootargs_prop) {
		log_err("%s: /chosen/bootargs property not found (FDT_ERR %d)\n",
			__func__, ret);
		return NULL;
	}

	return bootargs_prop->data;
}

static int exynos7870_fdt_match(struct exynos_board_info *board_info)
{
	const char *prev_bl_bootargs;
	int val, ret;

	prev_bl_bootargs = exynos_prev_bl_get_bootargs();
	if (!prev_bl_bootargs)
		return -1;

	/*
	 * Read the cmdline property which stores the
	 * bootloader/firmware version. An example value of the option
	 * can be: "J600GDXU3ARH5". This can be used to verify the model
	 * of the device.
	 */
	ret = cmdline_get_arg(prev_bl_bootargs, "androidboot.bootloader", &val);
	if (ret < 0) {
		log_err("%s: unable to find property for bootloader version (%d)\n",
			__func__, ret);
		return -1;
	}

	if (strncmp(prev_bl_bootargs + val, board_info->match_model,
		    strlen(board_info->match_model)))
		return -1;

	/*
	 * Read the cmdline property which stores the hardware revision.
	 * This is required to allow selecting one of multiple dtbs
	 * available of a single device, varying in hardware changes in
	 * different revisions.
	 */
	ret = cmdline_get_arg(prev_bl_bootargs, "androidboot.revision", &val);
	if (ret < 0)
		ret = cmdline_get_arg(prev_bl_bootargs, "androidboot.hw_rev", &val);
	if (ret < 0) {
		log_err("%s: unable to find property for bootloader revision (%d)\n",
			__func__, ret);
		return -1;
	}

	if (strtoul(prev_bl_bootargs + val, NULL, 10) > board_info->match_max_rev)
		return -1;

	/*
	 * Read the cmdline property which stores the serial number.
	 * Store this in the board info struct.
	 */
	ret = cmdline_get_arg(prev_bl_bootargs, "androidboot.serialno", &val);
	if (ret > 0)
		strlcpy(board_info->serial, prev_bl_bootargs + val, ret);

	return 0;
}

/*
 * Galaxy Tab Active3: match like the other boards, but when chain-loaded by
 * uniLoader without a usable S-Boot FDT (it then passes its own DTB, which
 * has no Samsung command line), still take the device tree if this image
 * is built for this board alone.
 */
static int exynos9810_gtactive3_match(struct exynos_board_info *board_info)
{
	if (!exynos7870_fdt_match(board_info))
		return 0;

	if (strcmp(CONFIG_OF_LIST, CONFIG_DEFAULT_DEVICE_TREE))
		return -1;

	log_warning("%s: previous bootloader did not identify the board, using %s\n",
		    __func__, CONFIG_DEFAULT_DEVICE_TREE);
	return 0;
}

/*
 * This array is used for matching the models and revisions with the
 * devicetree used by U-Boot. This allows a single U-Boot to work on
 * multiple devices.
 *
 * Entries are kept in lexicographical order of board SoCs, followed by
 * board names.
 */
static struct exynos_board_info exynos_board_info_match[] = {
	{
		/* Samsung Galaxy A2 Core */
		.name = "a2corelte",
		.chip = "exynos7870",
		.dram_bank_bases = exynos7870_common_dram_bank_bases,
		.match = exynos7870_fdt_match,
		.match_model = "A260",
		.match_max_rev = U8_MAX,
	}, {
		/* Samsung Galaxy J6 */
		.name = "j6lte",
		.chip = "exynos7870",
		.dram_bank_bases = exynos7870_common_dram_bank_bases,
		.match = exynos7870_fdt_match,
		.match_model = "J600",
		.match_max_rev = U8_MAX,
	}, {
		/* Samsung Galaxy J7 Prime */
		.name = "on7xelte",
		.chip = "exynos7870",
		.dram_bank_bases = exynos7870_common_dram_bank_bases,
		.match = exynos7870_fdt_match,
		.match_model = "G610",
		.match_max_rev = U8_MAX,
	}, {
		/* Samsung Galaxy Tab Active3 (Wi-Fi) */
		.name = "gtactive3wifi",
		.chip = "exynos9810",
		.dram_bank_bases = exynos9810_common_dram_bank_bases,
		.match = exynos9810_gtactive3_match,
		.match_model = "T570",
		.match_max_rev = U8_MAX,
	}, {
		/* Samsung Galaxy S10 */
		.name = "beyond1lte",
		.chip = "exynos9820",
		.dram_bank_bases = exynos9820_common_dram_bank_bases,
		.match = exynos7870_fdt_match,
		.match_model = "G973",
		.match_max_rev = U8_MAX,
	}, {
		/* Samsung Galaxy S10+ */
		.name = "beyond2lte",
		.chip = "exynos9820",
		.dram_bank_bases = exynos9820_common_dram_bank_bases,
		.match = exynos7870_fdt_match,
		.match_model = "G975",
		.match_max_rev = U8_MAX,
	},
};

static void exynos_parse_dram_banks(const struct exynos_board_info *board_info,
				    const void *fdt_base)
{
	u64 mem_addr, mem_size = 0;
	u32 na, ns, i, j;
	int offset;

	if (fdt_check_header(fdt_base) < 0)
		return;

	/* #address-cells and #size-cells as defined in the fdt root. */
	na = fdt_address_cells(fdt_base, 0);
	ns = fdt_size_cells(fdt_base, 0);
log_debug("%s: %d, na = %u, ns = %u\n", __func__, __LINE__, na, ns);
	fdt_for_each_subnode(offset, fdt_base, 0) {
		if (strncmp(fdt_get_name(fdt_base, offset, NULL), "memory", 6))
			continue;

		for (i = 0; ; i++) {
			mem_addr = fdtdec_get_addr_size_fixed(fdt_base, offset,
							      "reg", i, na, ns,
							      &mem_size, false);
			if (mem_addr == FDT_ADDR_T_NONE)
				break;

			if (!mem_size)
				continue;

			for (j = 0; j < CONFIG_NR_DRAM_BANKS; j++) {
				if (board_info->dram_bank_bases[j] != mem_addr)
					continue;

				mem_map[j + 1].phys = mem_addr;
				mem_map[j + 1].virt = mem_addr;
				mem_map[j + 1].size = mem_size;
				mem_map[j + 1].attrs = PTE_BLOCK_MEMTYPE(MT_NORMAL) |
						       PTE_BLOCK_INNER_SHARE;
				break;
			}
		}
	}
}

#if IS_ENABLED(CONFIG_FASTBOOT_FLASH_MMC)
static int exynos_fastboot_setup(void)
{
	struct blk_desc *blk_dev;
	struct disk_partition info = {0};
	char buf[128];
	phys_addr_t addr;
	int offset, i, j;

	/* Allocate and define buffer address for fastboot interface. */
	if (lmb_alloc(CONFIG_FASTBOOT_BUF_SIZE, &addr)) {
		log_err("%s: failed to allocate fastboot buffer\n", __func__);
		return -ENOMEM;
	}
	env_set_hex("fastboot_addr_r", addr);

	blk_dev = blk_get_dev("mmc", CONFIG_FASTBOOT_FLASH_MMC_DEV);
	if (!blk_dev) {
		log_err("%s: required mmc device not available\n", __func__);
		return -ENODEV;
	}

	strcpy(buf, "fastboot_partition_alias_");
	offset = strlen(buf);

	for (i = 1; i < CONFIG_EFI_PARTITION_ENTRIES_NUMBERS; i++) {
		if (part_get_info(blk_dev, i, &info))
			continue;

		/*
		 * The partition name must be lowercase (stored in buf[]),
		 * as is expected in all fastboot partitions ...
		 */
		strlcpy(buf + offset, info.name, sizeof(buf) - offset);
		for (j = offset; buf[j]; j++)
			buf[j] = tolower(buf[j]);
		if (!strcmp(buf + offset, info.name))
			continue;
		/*
		 * ... However, if that isn't the case, a fastboot
		 * partition alias must be defined to establish it.
		 */
		env_set(buf, info.name);
	}

	return 0;
}
#endif

int board_fit_config_name_match(const char *name)
{
	struct exynos_board_info *board_info;
	char buf[128];
	unsigned int i;
	int ret;

	/*
	 * Iterate over exynos_board_info_match[] to select the
	 * appropriate board info struct. If not found, exit.
	 */
	for (i = 0; i < ARRAY_SIZE(exynos_board_info_match); i++) {
		board_info = exynos_board_info_match + i;
		snprintf(buf, sizeof(buf), "%s-%s", board_info->chip,
			 board_info->name);

		if (!strcmp(name, buf))
			break;
	}
	if (i == ARRAY_SIZE(exynos_board_info_match))
		return -1;

	/*
	 * Execute match logic for the target board. This is separated
	 * as the process may be different for multiple boards.
	 */
	ret = board_info->match(board_info);
	if (ret)
		return ret;

	/*
	 * Store the correct board info struct in gd->board_type to
	 * allow other functions to access it.
	 */
	gd->board_type = (ulong)board_info;
	log_debug("%s: device detected: %s\n", __func__, name);

	return 0;
}

int timer_init(void)
{
	ofnode timer_node;

	/*
	 * In a lot of Exynos devices, the previous bootloader does not
	 * set CNTFRQ_EL0 properly. However, the timer node in
	 * devicetree has the correct frequency, use that instead.
	 */
	timer_node = ofnode_by_compatible(ofnode_null(), "arm,armv8-timer");
	gd->arch.timer_rate_hz = ofnode_read_u32_default(timer_node,
							 "clock-frequency", 0);

	return 0;
}

int board_early_init_f(void)
{
	const struct exynos_board_info *board_info;

	if (!gd->board_type)
		return -ENODATA;
	board_info = (const struct exynos_board_info *)gd->board_type;

	exynos_parse_dram_banks(board_info, gd->fdt_blob);
	/*
	 * Some devices have multiple variants based on the amount of
	 * memory and internal storage. The lowest bank base has been
	 * observed to have the same memory range in all board variants.
	 * For variants with more memory, the previous bootloader should
	 * overlay the devicetree with the required extra memory ranges.
	 */
	exynos_parse_dram_banks(board_info, (const void *)get_prev_bl_fdt_addr());

	return 0;
}

int dram_init(void)
{
	unsigned int i;

	/* Select the lowest RAM bank for U-Boot. */
	for (i = 0; i < 1; i++) {
		if (gd->ram_size < mem_map[i + 1].size) {
			gd->ram_base = mem_map[i + 1].phys;
			gd->ram_size = mem_map[i + 1].size;
		}
	}

	return 0;
}

int dram_init_banksize(void)
{
	unsigned int i;

	for (i = 0; i < CONFIG_NR_DRAM_BANKS; i++) {
		gd->bd->bi_dram[i].start = mem_map[i + 1].phys;
		gd->bd->bi_dram[i].size = mem_map[i + 1].size;
	}

	return 0;
}

void efi_add_known_memory(void)
{
	unsigned int i;

	/* Make sure kernel is placed in the lowest memory bank */
	for (i = 3; i < CONFIG_NR_DRAM_BANKS; i++) {
		efi_add_memory_map(mem_map[i + 1].phys, mem_map[i + 1].size,
				   EFI_BOOT_SERVICES_DATA);
	}
}

int board_init(void)
{
	return 0;
}

#if IS_ENABLED(CONFIG_EXYNOS_MOBILE_RAMLOG)
/*
 * RAM console log: { magic, length, text... } at CONFIG_EXYNOS_MOBILE_RAMLOG_ADDR.
 * Each byte is cleaned to the point of coherency, so the log survives a
 * watchdog reset whether or not the data cache is on yet.
 */
#define RAMLOG_MAGIC	0x474f4c55	/* "ULOG" */
/* 1 MiB reserved; the last 4 KiB hold uniLoader's boot decision record */
#define RAMLOG_SIZE	0xff000

static int ramlog_started __section(".data");

static void ramlog_clean(volatile void *p)
{
	asm volatile("dc civac, %0" : : "r"(p) : "memory");
}

void board_console_tap(const char c)
{
	volatile u32 *hdr = (volatile u32 *)CONFIG_EXYNOS_MOBILE_RAMLOG_ADDR;
	volatile char *buf = (volatile char *)(hdr + 2);
	u32 len;

	if (!ramlog_started) {
		ramlog_started = 1;
		hdr[0] = RAMLOG_MAGIC;
		hdr[1] = 0;
		ramlog_clean(hdr);
	}
	len = hdr[1];
	if (len >= RAMLOG_SIZE - 8)
		return;
	buf[len] = c;
	ramlog_clean(&buf[len]);
	hdr[1] = len + 1;
	ramlog_clean(hdr);
	asm volatile("dsb sy" : : : "memory");
}
#endif


/*
 * Galaxy Tab Active3: the MAX77705 USB-C controller leaves its D+/D- switch
 * open after the bootloader when the cable stays attached. Route it to the
 * AP with Samsung's COMMAND_CONTROL1_WRITE(COM_USB) opcode, sent by bit-
 * banging the HSI2C_40 pins (gpm15-0 = SDA, gpm14-0 = SCL; the controller
 * itself is not usable here). Open drain: 0 = output low, 1 = input.
 */
#define GTA3_PINCTRL_CMGP	0x14220000UL
#define GTA3_SDA		(GTA3_PINCTRL_CMGP + 0x1a0)	/* gpm15-0 */
#define GTA3_SCL		(GTA3_PINCTRL_CMGP + 0x180)	/* gpm14-0 */

static void gta3_rel(ulong b) { writel(readl(b) & ~0xfu, b); }
static void gta3_low(ulong b) { writel(readl(b + 4) & ~1u, b + 4); writel((readl(b) & ~0xfu) | 1u, b); }
static int gta3_get(ulong b) { return readl(b + 4) & 1; }
static void gta3_scl_rel(void)
{
	int i;

	gta3_rel(GTA3_SCL);
	for (i = 0; i < 1000 && !gta3_get(GTA3_SCL); i++)
		udelay(2);
}

static int gta3_bit(int b)
{
	if (b) gta3_rel(GTA3_SDA); else gta3_low(GTA3_SDA);
	udelay(5);
	gta3_scl_rel();
	udelay(5);
	b = gta3_get(GTA3_SDA);
	gta3_low(GTA3_SCL);
	udelay(5);
	return b;
}

static int gta3_i2c_write(int addr, const u8 *buf, int len)
{
	int i, j, ok = 1;

	gta3_rel(GTA3_SDA); gta3_scl_rel(); udelay(5);
	gta3_low(GTA3_SDA); udelay(5); gta3_low(GTA3_SCL); udelay(5);
	for (i = -1; ok && i < len; i++) {
		int v = i < 0 ? addr << 1 : buf[i];

		for (j = 7; j >= 0; j--)
			gta3_bit((v >> j) & 1);
		ok = !gta3_bit(1);
	}
	gta3_low(GTA3_SDA); udelay(5); gta3_scl_rel(); udelay(5); gta3_rel(GTA3_SDA); udelay(5);
	return ok ? 0 : -EIO;
}

static void gtactive3_max77705_com_usb(void)
{
	static const u8 sw[] = { 0x21, 0x06, 0x09 }, end[] = { 0x41, 0x00 };
	u32 con_sda = readl(GTA3_SDA), con_scl = readl(GTA3_SCL);

	if (gta3_i2c_write(0x25, sw, sizeof(sw)) || gta3_i2c_write(0x25, end, sizeof(end)))
		log_err("MAX77705: USB switch command not acknowledged\n");
	else
		log_info("MAX77705: USB data switch routed to AP\n");
	writel(con_sda, GTA3_SDA);
	writel(con_scl, GTA3_SCL);
}

/*
 * uniLoader arms the cluster 0 watchdog (~82 s) and the Download-mode
 * reboot reason before it jumps here. Undo both: stop the counter, mask its
 * PMU reset again as S-Boot leaves it, and make a reset boot normally
 * (syscon-reboot-mode "normal" in the kernel DT). A hang now stays on
 * screen instead of resetting; the bring-up Linux is in the boot menu.
 */
#define GTA3_PMU		0x14060000UL
#define GTA3_WDT_CL0		0x10050000UL

static void gtactive3_watchdog_off(void)
{
	writel(0, GTA3_WDT_CL0);
	writel(readl(GTA3_PMU + 0x40c) | BIT(24), GTA3_PMU + 0x40c);
	writel(readl(GTA3_PMU + 0x408) | BIT(24), GTA3_PMU + 0x408);
	writel(0x12345678, GTA3_PMU + 0x808);
	writel(0x12345670, GTA3_PMU + 0x80c);
	log_info("watchdog stopped, reboot reason normal\n");
}

#if IS_ENABLED(CONFIG_EXYNOS_MOBILE_RAMLOG)
/*
 * uniLoader's boot decision record (struct chain_info, main/chainload.h in
 * uniLoader), in the last 4 KiB of the RAM log area. 32-bit words: 0 magic,
 * 2 run, 3 decision, 4 reason, 5 RST_STAT, 8 previous FDT, 16 FDT passed,
 * 18 WTCON, 19 stage, 20-22 fallbacks picked at once (count, reason,
 * RST_STAT), 24.. androidboot.bootloader.
 */
static void exynos_show_uniloader_record(void)
{
	const u32 *ci = (const u32 *)(CONFIG_EXYNOS_MOBILE_RAMLOG_ADDR + RAMLOG_SIZE);

	if (ci[0] != 0x48434c55)	/* "ULCH" */
		return;
	log_info("uniLoader: run %u, %s, stage %u, reason 0x%x, RST_STAT 0x%08x, WTCON 0x%x\n",
		 ci[2], ci[3] ? "fallback" : "chained", ci[19], ci[4], ci[5], ci[18]);
	log_info("uniLoader: FDT 0x%x -> 0x%x, bootloader %.32s, %u earlier fallbacks\n",
		 ci[8], ci[16], (const char *)&ci[24], ci[20]);
}
#else
static void exynos_show_uniloader_record(void) {}
#endif

/*
 * Tell uniLoader that this chained boot got as far as handing over to the
 * OS: stage 7 (CHAIN_STAGE_OS). A record still at stage 4 (jumped to us)
 * on the next run means U-Boot died on the way, and uniLoader then boots
 * its fallback Linux instead of chaining into the same crash again.
 */
static void exynos_mark_uniloader_os(void)
{
#if IS_ENABLED(CONFIG_EXYNOS_MOBILE_RAMLOG)
	u32 *ci = (u32 *)(CONFIG_EXYNOS_MOBILE_RAMLOG_ADDR + RAMLOG_SIZE);

	if (ci[0] != 0x48434c55)
		return;
	ci[19] = 7;
	flush_dcache_range((ulong)ci, (ulong)ci + 128);
#endif
}

/*
 * Hand the watchdog to the OS (EFI ExitBootServices and booti both end up
 * here). wdt_handover=keep: leave it running with a full timeout, so a
 * kernel that hangs before its watchdog driver takes over resets into
 * uniLoader's fallback Linux. wdt_handover=stop (gtactive3wifi): stop it.
 */
void board_quiesce_devices(void)
{
	struct udevice *dev;
	const char *mode = env_get("wdt_handover");

	exynos_mark_uniloader_os();
	if (!IS_ENABLED(CONFIG_WDT) || uclass_first_device_err(UCLASS_WDT, &dev))
		return;

	if (mode && !strcmp(mode, "stop")) {
		wdt_stop(dev);
		log_info("watchdog stopped for the OS\n");
	} else {
		wdt_start(dev, env_get_ulong("wdt_handover_ms", 10, 80000), 0);
		log_info("watchdog left running for the OS\n");
	}
}

int misc_init_r(void)
{
	const struct exynos_board_info *board_info;
	char buf[128];

	if (!gd->board_type)
		return -ENODATA;
	board_info = (const struct exynos_board_info *)gd->board_type;

	env_set("platform", board_info->chip);
	env_set("board", board_info->name);

	if (!strcmp(board_info->name, "gtactive3wifi")) {
		gtactive3_watchdog_off();
		exynos_show_uniloader_record();
		gtactive3_max77705_com_usb();
	}

	if (strlen(board_info->serial))
		env_set("serial#", board_info->serial);

	/* EFI booting requires the path to correct dtb, specify it here. */
	snprintf(buf, sizeof(buf), "exynos/%s-%s.dtb", board_info->chip,
		 board_info->name);
	env_set("fdtfile", buf);
return 0;
	// return exynos_fastboot_setup();
}
