// SPDX-License-Identifier: GPL-2.0-only
/*
 * Dual payload: boot a chained bootloader (an arm64 Image such as U-Boot),
 * or fall back to the embedded Linux when the board says so (for example
 * after a watchdog reset). The decision is recorded in RAM for the next OS.
 */

#include <board.h>
#include <lib/debug.h>
#include <lib/libfdt/libfdt.h>
#include <main/boot.h>
#include <main/chainload.h>
#include <string.h>

extern struct board_data board_ops;
extern unsigned long chain_size;
extern char chain[];

/* arm64 Image header: "ARM\x64" at offset 0x38 (Documentation/arch/arm64/booting.rst) */
#define ARM64_IMAGE_MAGIC_OFF	0x38
#define ARM64_IMAGE_MAGIC	0x644d5241

#define CACHE_LINE		64

static void dcache_clean_range(unsigned long start, unsigned long size)
{
	unsigned long p, end = start + size;

	for (p = start & ~(CACHE_LINE - 1UL); p < end; p += CACHE_LINE)
		asm volatile("dc civac, %0" : : "r"(p) : "memory");
	asm volatile("dsb sy" : : : "memory");
}

/* Find "key=" in a kernel command line; returns the value or NULL. */
static const char *cmdline_find(const char *s, int len, const char *key)
{
	int kl = strlen(key), i;

	for (i = 0; i + kl <= len && s[i]; i++) {
		if ((i == 0 || s[i - 1] == ' ') && !strncmp(s + i, key, kl))
			return s + i + kl;
	}
	return NULL;
}

static void copy_word(char *dst, int size, const char *src, const char *end)
{
	int i;

	for (i = 0; i < size - 1 && src + i < end && src[i] && src[i] != ' '; i++)
		dst[i] = src[i];
	dst[i] = 0;
}

static unsigned long parse_dec(const char *s, const char *end)
{
	unsigned long v = 0;

	while (s < end && *s >= '0' && *s <= '9')
		v = v * 10 + (*s++ - '0');
	return v;
}

/*
 * Check the previous bootloader's FDT and note what the chained bootloader
 * will find in it (board match strings). Never records the serial number.
 */
static int prev_fdt_usable(struct chain_info *ci, void *fdt)
{
	unsigned long a = (unsigned long)fdt;
	const char *args, *v, *end;
	int off, len;

	if (a < CONFIG_CHAINLOAD_PREV_FDT_LO || a >= CONFIG_CHAINLOAD_PREV_FDT_HI || (a & 7))
		return 0;
	if (fdt_check_header(fdt) || fdt_totalsize(fdt) > CONFIG_CHAINLOAD_FDT_MAX)
		return 0;
	ci->prev_fdt_size = fdt_totalsize(fdt);

	off = fdt_path_offset(fdt, "/chosen");
	args = off < 0 ? NULL : fdt_getprop(fdt, off, "bootargs", &len);
	if (!args || len <= 0)
		return 1;
	end = args + len;

	v = cmdline_find(args, len, "androidboot.bootloader=");
	if (v)
		copy_word(ci->bootloader, sizeof(ci->bootloader), v, end);

	v = cmdline_find(args, len, "androidboot.revision=");
	if (!v)
		v = cmdline_find(args, len, "androidboot.hw_rev=");
	if (v)
		ci->hw_rev = parse_dec(v, end);

	return 1;
}

/* Publish the record (one aligned copy, then cleaned to memory) */
static void record_commit(struct chain_info *ci, uint32_t stage)
{
	struct chain_info *rec = (struct chain_info *)CONFIG_CHAINLOAD_HANDOFF_ADDR;

	ci->stage = stage;
	if (!CONFIG_CHAINLOAD_HANDOFF_ADDR)
		return;
	memcpy(rec, ci, sizeof(*ci));
	dcache_clean_range((unsigned long)rec, sizeof(*rec));
}

void chainload(void *dt, void *prev_fdt, void *load_addr)
{
	struct chain_info ci;
	struct chain_info *rec = (struct chain_info *)CONFIG_CHAINLOAD_HANDOFF_ADDR;
	unsigned long entry = CONFIG_CHAINLOAD_ENTRY;
	unsigned long fdt_dst = CONFIG_CHAINLOAD_FDT_ADDR;
	unsigned long size = (unsigned long)&chain_size;
	void *fdt_src = dt;
	unsigned long fdt_len;
	uint32_t prev_stage = 0;

	memset(&ci, 0, sizeof(ci));

	/*
	 * 1. Reset status and keys: register reads only. After a watchdog
	 * reset or with the key held, boot the fallback straight away and
	 * leave the record of the failed boot alone.
	 */
	if (board_ops.ops.chain_select && !board_ops.ops.chain_select(&ci)) {
		/* Only note it in the record of the failed boot */
		if (CONFIG_CHAINLOAD_HANDOFF_ADDR && rec->magic == CHAIN_INFO_MAGIC &&
		    rec->version == CHAIN_INFO_VERSION) {
			rec->fb_count++;
			rec->fb_reason = ci.reason;
			rec->fb_rst_stat = ci.rst_stat;
			if (rec->stage == CHAIN_STAGE_WDT_TEST && (ci.reason & CHAIN_R_WDT_RESET))
				rec->stage = CHAIN_STAGE_WDT_PASSED;
			dcache_clean_range((unsigned long)rec, sizeof(*rec));
		}
		if (board_ops.ops.fallback_arm)
			board_ops.ops.fallback_arm(&ci);
		printk(KERN_INFO, "chainload: fallback Linux (reason 0x%x, reset 0x%x)\n",
		       ci.reason, ci.rst_stat);
		return;
	}

	/* 2. From here on a hang or crash ends in a watchdog reset (board) */
	if (board_ops.ops.chain_arm)
		board_ops.ops.chain_arm(&ci);

	/* 3. Record, checks */
	ci.magic = CHAIN_INFO_MAGIC;
	ci.version = CHAIN_INFO_VERSION;
	ci.boot_count = 1;
	/* DRAM keeps its contents over a warm reset: count the runs */
	if (CONFIG_CHAINLOAD_HANDOFF_ADDR && rec->magic == CHAIN_INFO_MAGIC &&
	    rec->version == CHAIN_INFO_VERSION) {
		ci.boot_count = rec->boot_count + 1;
		ci.fb_count = rec->fb_count;
		prev_stage = rec->stage;
	}
	ci.hw_rev = ~0U;
	ci.prev_fdt_lo = (unsigned long)prev_fdt;
	ci.prev_fdt_hi = (unsigned long)prev_fdt >> 32;
	ci.load_addr_lo = (unsigned long)load_addr;
	ci.load_addr_hi = (unsigned long)load_addr >> 32;
	ci.chain_entry_lo = entry;
	ci.chain_entry_hi = entry >> 32;
	ci.chain_size = size;
	record_commit(&ci, CHAIN_STAGE_START);

	printk(KERN_INFO, "chainload: loaded at 0x%lx, previous FDT 0x%lx, run %u\n",
	       (unsigned long)load_addr, (unsigned long)prev_fdt, ci.boot_count);

	if (prev_fdt_usable(&ci, prev_fdt)) {
		fdt_src = prev_fdt;
		if (!ci.bootloader[0])
			ci.reason |= CHAIN_N_NO_BOOTLOADER;
	} else {
		ci.reason |= CHAIN_N_PREV_FDT_BAD;
	}

	/*
	 * The last run jumped to the chained bootloader and it never marked
	 * the OS handover (CHAIN_STAGE_OS): it crashed or reset on the way.
	 * Boot the fallback once; the record then says FALLBACK, so the run
	 * after that chains again.
	 */
	if (prev_stage == CHAIN_STAGE_JUMP) {
		ci.reason |= CHAIN_R_CHAIN_DIED;
		printk(KERN_INFO, "chainload: the last chained boot did not reach the OS\n");
	}
	if (CONFIG_CHAINLOAD_DEFAULT != 0)
		ci.reason |= CHAIN_R_FORCED;
	if (size < 0x40 ||
	    *(uint32_t *)(chain + ARM64_IMAGE_MAGIC_OFF) != ARM64_IMAGE_MAGIC ||
	    entry + size > fdt_dst)
		ci.reason |= CHAIN_R_BAD_PAYLOAD;
	record_commit(&ci, CHAIN_STAGE_CHECKED);

	/*
	 * Watchdog test: the reset brings us back with RST_STAT set. If the
	 * previous run was still waiting, the reset came without RST_STAT (or
	 * was not ours): do not test again, or we would loop.
	 */
	if (CONFIG_CHAINLOAD_DEFAULT == 2 && prev_stage == CHAIN_STAGE_WDT_TEST) {
		ci.reason |= CHAIN_R_WDT_FAIL;
		printk(KERN_INFO, "chainload: reset during the watchdog test without RST_STAT bit\n");
	}
	if (CONFIG_CHAINLOAD_DEFAULT == 2 && board_ops.ops.wdt_test &&
	    !(ci.reason & CHAIN_R_WDT_FAIL)) {
		record_commit(&ci, CHAIN_STAGE_WDT_TEST);
		printk(KERN_INFO, "chainload: watchdog test, waiting for the reset (~82 s)\n");
		board_ops.ops.wdt_test(&ci);
		ci.reason |= CHAIN_R_WDT_FAIL;
		printk(KERN_INFO, "chainload: the watchdog did NOT reset the SoC\n");
	}

	if (ci.reason & CHAIN_R_FALLBACK_MASK) {
		ci.decision = CHAIN_BOOT_FALLBACK;
		if (board_ops.ops.fallback_arm)
			board_ops.ops.fallback_arm(&ci);
		record_commit(&ci, CHAIN_STAGE_FALLBACK);
		printk(KERN_INFO, "chainload: fallback Linux (reason 0x%x, reset 0x%x)\n",
		       ci.reason, ci.rst_stat);
		return;
	}

	/*
	 * 4. The FDT first: it may sit where the chained image goes. Lengths
	 * are rounded up to 16 bytes so that the copy never makes an unaligned
	 * access, which faults if the MMU is off. Both sources are followed by
	 * readable memory (FDT padding, the rest of our image).
	 */
	fdt_len = (fdt_totalsize(fdt_src) + 15) & ~15UL;
	size = (size + 15) & ~15UL;
	memmove((void *)fdt_dst, fdt_src, fdt_len);
	memmove((void *)entry, chain, size);
	dcache_clean_range(fdt_dst, fdt_len);
	dcache_clean_range(entry, size);
	asm volatile("ic iallu\n\tdsb sy\n\tisb" : : : "memory");

	ci.decision = CHAIN_BOOT_CHAINED;
	ci.fdt_passed_lo = fdt_dst;
	ci.fdt_passed_hi = fdt_dst >> 32;

	printk(KERN_INFO, "chainload: %s FDT, %s, jumping to 0x%lx (%lu bytes)\n",
	       fdt_src == prev_fdt ? "previous bootloader" : "embedded",
	       ci.bootloader[0] ? ci.bootloader : "no bootloader version",
	       entry, size);

	/* 5. Full watchdog timeout for the chained bootloader */
	if (board_ops.ops.chain_arm)
		board_ops.ops.chain_arm(&ci);
	if (ci.reason & CHAIN_R_FALLBACK_MASK) {
		ci.decision = CHAIN_BOOT_FALLBACK;
		if (board_ops.ops.fallback_arm)
			board_ops.ops.fallback_arm(&ci);
		record_commit(&ci, CHAIN_STAGE_FALLBACK);
		printk(KERN_INFO, "chainload: fallback Linux (reason 0x%x)\n", ci.reason);
		return;
	}
	record_commit(&ci, CHAIN_STAGE_JUMP);

	load_kernel_and_jump((void *)fdt_dst, 0, 0, 0, (void *)entry);
}
