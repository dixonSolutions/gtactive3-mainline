// SPDX-License-Identifier: GPL-2.0+
/*
 * Samsung Exynos watchdog (S3C2410 type) with the PMU reset control of
 * Exynos 9810: one DISABLE_WDT / MASK_WDT_RESET bit per CPU cluster.
 *
 * Register layout and PMU offsets as in Linux s3c2410_wdt.c (WTCON, WTDAT,
 * WTCNT, WTCLRINT; PMU 0x408 auto-disable, 0x40c reset mask, 0x404 reset
 * status) and Samsung's Exynos 9810 kernel (bit 24 = cluster 0).
 */

#include <clk.h>
#include <dm.h>
#include <dm/device_compat.h>
#include <regmap.h>
#include <syscon.h>
#include <wdt.h>
#include <asm/io.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/err.h>

#define WTCON			0x00
#define WTDAT			0x04
#define WTCNT			0x08
#define WTCLRINT		0x0c

#define WTCON_RSTEN		BIT(0)
#define WTCON_INTEN		BIT(2)
#define WTCON_DIV128		(3 << 3)
#define WTCON_ENABLE		BIT(5)
#define WTCON_PRESCALE(x)	((x) << 8)
#define WTCON_PRESCALE_MAX	0xff
#define WTCNT_MAX		0xffff

#define PMU_WDT_DISABLE		0x0408
#define PMU_WDT_MASK_RESET	0x040c

#define DEFAULT_RATE		26000000UL

struct exynos_wdt_priv {
	void __iomem *base;
	struct regmap *pmu;
	u32 pmu_bit;
	ulong rate;
};

/* Let (or stop) the counter reset the SoC */
static void exynos_wdt_pmu_reset(struct exynos_wdt_priv *priv, bool enable)
{
	u32 val = enable ? 0 : priv->pmu_bit;

	if (!priv->pmu)
		return;
	regmap_update_bits(priv->pmu, PMU_WDT_DISABLE, priv->pmu_bit, val);
	regmap_update_bits(priv->pmu, PMU_WDT_MASK_RESET, priv->pmu_bit, val);
}

static int exynos_wdt_reset(struct udevice *dev)
{
	struct exynos_wdt_priv *priv = dev_get_priv(dev);

	writel(readl(priv->base + WTDAT), priv->base + WTCNT);

	return 0;
}

static int exynos_wdt_start(struct udevice *dev, u64 timeout_ms, ulong flags)
{
	struct exynos_wdt_priv *priv = dev_get_priv(dev);
	u64 count;

	/* one tick = 256 (prescaler) * 128 (divider) input clocks */
	count = timeout_ms * priv->rate / (1000ULL * 256 * 128);
	if (count < 1)
		count = 1;
	if (count > WTCNT_MAX)
		count = WTCNT_MAX;

	writel(0, priv->base + WTCON);
	writel(count, priv->base + WTDAT);
	writel(count, priv->base + WTCNT);
	writel(1, priv->base + WTCLRINT);
	writel(WTCON_PRESCALE(WTCON_PRESCALE_MAX) | WTCON_DIV128 |
	       WTCON_ENABLE | WTCON_RSTEN, priv->base + WTCON);
	exynos_wdt_pmu_reset(priv, true);

	return 0;
}

static int exynos_wdt_stop(struct udevice *dev)
{
	struct exynos_wdt_priv *priv = dev_get_priv(dev);

	exynos_wdt_pmu_reset(priv, false);
	writel(readl(priv->base + WTCON) & ~(WTCON_ENABLE | WTCON_RSTEN),
	       priv->base + WTCON);

	return 0;
}

static int exynos_wdt_expire_now(struct udevice *dev, ulong flags)
{
	struct exynos_wdt_priv *priv = dev_get_priv(dev);

	writel(0, priv->base + WTCON);
	writel(1, priv->base + WTDAT);
	writel(1, priv->base + WTCNT);
	exynos_wdt_pmu_reset(priv, true);
	writel(WTCON_ENABLE | WTCON_RSTEN, priv->base + WTCON);

	mdelay(500);

	return -ETIMEDOUT;
}

static int exynos_wdt_probe(struct udevice *dev)
{
	struct exynos_wdt_priv *priv = dev_get_priv(dev);
	struct clk clk;
	u32 cluster;

	priv->base = dev_read_addr_ptr(dev);
	if (!priv->base)
		return -EINVAL;

	priv->rate = DEFAULT_RATE;
	if (!clk_get_by_index(dev, 0, &clk)) {
		clk_enable(&clk);
		if (clk_get_rate(&clk) > 0)
			priv->rate = clk_get_rate(&clk);
	}

	priv->pmu = syscon_regmap_lookup_by_phandle(dev, "samsung,syscon-phandle");
	if (IS_ERR(priv->pmu)) {
		dev_warn(dev, "no PMU, cannot change the reset mask\n");
		priv->pmu = NULL;
	}

	cluster = dev_read_u32_default(dev, "samsung,cluster-index", 0);
	priv->pmu_bit = BIT(24 - cluster);	/* 24: cluster 0, 23: cluster 1 */

	return 0;
}

static const struct wdt_ops exynos_wdt_ops = {
	.start = exynos_wdt_start,
	.stop = exynos_wdt_stop,
	.reset = exynos_wdt_reset,
	.expire_now = exynos_wdt_expire_now,
};

static const struct udevice_id exynos_wdt_ids[] = {
	{ .compatible = "samsung,exynos9810-wdt" },
	{ }
};

U_BOOT_DRIVER(exynos_wdt) = {
	.name = "exynos_wdt",
	.id = UCLASS_WDT,
	.of_match = exynos_wdt_ids,
	.priv_auto = sizeof(struct exynos_wdt_priv),
	.probe = exynos_wdt_probe,
	.ops = &exynos_wdt_ops,
};
