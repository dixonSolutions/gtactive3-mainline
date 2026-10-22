// SPDX-License-Identifier: GPL-2.0-only
/*
 * Common Clock Framework support for the Exynos9810 SoC.
 *
 * The clock tree is taken from Samsung's CMUCAL tables for S5E9810
 * (drivers/soc/samsung/cal-if/exynos9810/cmucal-{sfr,node}.c in the
 * downstream kernel).
 *
 * The driver is read-only on purpose: the PLLs are owned by the bootloader
 * and the APM/ACPM firmware, so they have no rate tables, and all muxes and
 * dividers are registered with CLK_MUX_READ_ONLY / CLK_DIVIDER_READ_ONLY.
 * The reported rates are therefore exactly what the bootloader programmed.
 *
 * Gates come up in hardware auto clock gating (HWACG) mode, where the CG_VAL
 * bit that the clock framework toggles has no effect. Booting with
 * clk_exynos9810.manual_gates=1 switches the gates of the leaf CMUs to
 * manual mode, forcing them on first, so that consumers really control
 * them. CMU_TOP and CMU_APM are never touched, ACPM relies on them.
 *
 * CMU_CHUB is the exception: SPI21 (touchscreen) needs to set its USI
 * divider, so it is a hand-written, writable CMU registered through the
 * common exynos_arm64_register_cmu() path.
 */

#include <linux/bits.h>
#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include <dt-bindings/clock/samsung,exynos9810.h>

#include "clk.h"
#include "clk-exynos-arm64.h"

#define GATE_MANUAL		BIT(20)
#define GATE_CG_VAL		BIT(21)
#define GATE_ENABLE_HWACG	BIT(28)

static bool manual_gates;
module_param(manual_gates, bool, 0444);
MODULE_PARM_DESC(manual_gates,
		 "Switch leaf CMU gates from HWACG to manual mode (forced on)");

