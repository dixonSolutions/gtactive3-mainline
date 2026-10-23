// SPDX-License-Identifier: GPL-2.0-only
/*
 * Dual payload: a chained bootloader with the embedded Linux as fallback.
 */

#ifndef CHAINLOAD_H_
#define CHAINLOAD_H_

#include <stdint.h>

#define CHAIN_INFO_MAGIC	0x48434c55	/* "ULCH" */
#define CHAIN_INFO_VERSION	1

/* chain_info.decision */
#define CHAIN_BOOT_CHAINED	0
#define CHAIN_BOOT_FALLBACK	1

/* chain_info.stage */
#define CHAIN_STAGE_START	1	/* watchdog armed, record started */
#define CHAIN_STAGE_CHECKED	2	/* FDT and payload checked */
#define CHAIN_STAGE_FALLBACK	3	/* forced fallback Linux */
#define CHAIN_STAGE_JUMP	4	/* jumping to the chained bootloader */
#define CHAIN_STAGE_WDT_TEST	5	/* CHAINLOAD_DEFAULT=2: waiting for the reset */
#define CHAIN_STAGE_WDT_PASSED	6	/* ... and it came, with RST_STAT bit set */
#define CHAIN_STAGE_OS		7	/* set by the chained bootloader at OS handover */

/* chain_info.reason: bits below 8 select the fallback, the others are notes */
#define CHAIN_R_WDT_RESET	(1 << 0)	/* last reset was the watchdog */
#define CHAIN_R_KEY		(1 << 1)	/* fallback key held */
#define CHAIN_R_FORCED		(1 << 2)	/* CONFIG_CHAINLOAD_DEFAULT != 0 */
#define CHAIN_R_BAD_PAYLOAD	(1 << 3)	/* no arm64 Image header, or too big */
#define CHAIN_R_WDT_FAIL	(1 << 4)	/* watchdog not armed / did not reset */
#define CHAIN_R_CHAIN_DIED	(1 << 5)	/* last chained boot never reached the OS */
#define CHAIN_R_FALLBACK_MASK	0xff
#define CHAIN_N_PREV_FDT_BAD	(1 << 8)	/* x0 was not a usable FDT */
#define CHAIN_N_NO_BOOTLOADER	(1 << 9)	/* no androidboot.bootloader= */
#define CHAIN_N_WDT_ARMED	(1 << 10)	/* watchdog left armed */

/*
 * Boot decision record, written at CONFIG_CHAINLOAD_HANDOFF_ADDR. All
 * fields are 32 bit so it reads back with a plain register dump. When the
 * board picks the fallback at once (watchdog reset, key) only the fb_*
 * fields are updated, so after a watchdog reset the rest still describes
 * the boot that failed.
 */
struct chain_info {
	uint32_t magic;
	uint32_t version;
	uint32_t boot_count;	/* uniLoader runs since the record was cleared */
	uint32_t decision;
	uint32_t reason;
	uint32_t rst_stat;	/* board: raw reset status */
	uint32_t keys;		/* board: raw key GPIO data */
	uint32_t hw_rev;	/* androidboot.revision / hw_rev, or ~0 */
	uint32_t prev_fdt_lo;	/* previous bootloader's x0 */
	uint32_t prev_fdt_hi;
	uint32_t prev_fdt_size;
	uint32_t load_addr_lo;	/* where the previous bootloader loaded us */
	uint32_t load_addr_hi;
	uint32_t chain_entry_lo;
	uint32_t chain_entry_hi;
	uint32_t chain_size;
	uint32_t fdt_passed_lo;	/* FDT handed to the chained bootloader */
	uint32_t fdt_passed_hi;
	uint32_t wdt_ctrl;	/* board: watchdog control after arming */
	uint32_t stage;		/* CHAIN_STAGE_*: how far the last run got */
	uint32_t fb_count;	/* fallbacks picked at once (kept over runs) */
	uint32_t fb_reason;	/* reason of the last of them */
	uint32_t fb_rst_stat;	/* reset status then */
	uint32_t reserved;
	char bootloader[32];	/* androidboot.bootloader= value */
};

#ifdef CONFIG_CHAINLOAD
/* Returns only when the fallback Linux has to be booted. */
void chainload(void *dt, void *prev_fdt, void *load_addr);
#endif

#endif // CHAINLOAD_H_
