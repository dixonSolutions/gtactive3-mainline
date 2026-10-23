/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Board files registration framework
 * Copyright (c) 2024, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 */
#ifndef BOARD_H_
#define BOARD_H_

#include <stddef.h>
#include <drivers/framework.h>

struct chain_info;

struct board_ops {
	int (*early_init)(void);
	int (*late_init)(void);
	/*
	 * Dual payload (CONFIG_CHAINLOAD), all optional:
	 * chain_select: fill in reset status/keys, return 0 to boot the
	 *               fallback Linux at once. Runs unguarded: keep it to
	 *               register reads.
	 * chain_arm:    arm a recovery mechanism (e.g. a watchdog); called
	 *               once as a guard before anything that could hang, and
	 *               again right before jumping to the chained bootloader.
	 * fallback_arm: last call before booting the fallback Linux.
	 * wdt_test:     CHAINLOAD_DEFAULT=2: arm the recovery mechanism and
	 *               wait for it to reset the SoC; returns only if it
	 *               did not.
	 */
	int (*chain_select)(struct chain_info *ci);
	void (*chain_arm)(struct chain_info *ci);
	void (*fallback_arm)(struct chain_info *ci);
	void (*wdt_test)(struct chain_info *ci);
};

struct board_data {
	const char *name;
	struct board_ops ops;
	const struct device *devices;
	size_t num_devices;
	unsigned int quirks;
};

#endif /* BOARD_H_ */
