// SPDX-License-Identifier: GPL-2.0-only
/*
 * UFS PHY driver data for the Samsung Exynos9810 SoC
 *
 * Values are taken from Samsung's ufs-cal-9810.c calibration tables, whose
 * PMA register addresses are byte offsets with a 0x140 byte lane stride.
 * Same tables as the Linux driver (drivers/phy/samsung/phy-exynos9810-ufs.c).
 */

#include <linux/delay.h>
#include <linux/io.h>
#include <dm/device_compat.h>

#include "phy-samsung-ufs.h"

#define EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL	0x724
#define EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL_MASK	0x1
#define EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL_EN	BIT(0)

/* PMA registers are 32-bit wide: offsets below are in units of registers */
#define EXYNOS9810_TRSV_LANE_OFFSET		0x50	/* 0x140 bytes */
#define E9810_COMN(o, v)	PHY_COMN_REG_CFG((o) >> 2, v, PWR_MODE_ANY)
#define E9810_TRSV(o, v, d)	\
	PHY_TRSV_REG_CFG_OFFSET((o) >> 2, v, d, EXYNOS9810_TRSV_LANE_OFFSET)

#define EXYNOS9810_TRSV_CDR_AFC		0x1fc
#define EXYNOS9810_TRSV_CDR_AFC_DONE	BIT(6)
#define EXYNOS9810_TRSV_LANE_CTRL	0x0f0

static const struct samsung_ufs_phy_cfg exynos9810_pre_init_cfg[] = {
	E9810_COMN(0x08c, 0x80),
	E9810_COMN(0x074, 0x10),
	E9810_TRSV(0x110, 0xb5, PWR_MODE_ANY),
	E9810_TRSV(0x134, 0x43, PWR_MODE_ANY),
	E9810_TRSV(0x16c, 0x20, PWR_MODE_ANY),
	E9810_TRSV(0x178, 0xc0, PWR_MODE_ANY),
	E9810_TRSV(0x0e0, 0x12, PWR_MODE_ANY),
	E9810_TRSV(0x164, 0x58, PWR_MODE_ANY),
	E9810_TRSV(0x1b0, 0x18, PWR_MODE_ANY),
	E9810_COMN(0x08c, 0xc0),
	E9810_COMN(0x08c, 0x00),
	END_UFS_PHY_CFG
};

/* HS series A/B tuning, HS-G3 x2 (the only mode the board runs in) */
static const struct samsung_ufs_phy_cfg exynos9810_pre_pwr_hs_cfg[] = {
	E9810_TRSV(0x0c8, 0xbc, PWR_MODE_HS_ANY),
	E9810_TRSV(0x0f0, 0x7f, PWR_MODE_HS_ANY),
	E9810_TRSV(0x120, 0xc0, PWR_MODE_HS_ANY),
	E9810_TRSV(0x128, 0x00, PWR_MODE_HS_G3_ANY),
	E9810_TRSV(0x134, 0x63, PWR_MODE_HS_G3_ANY),
	END_UFS_PHY_CFG
};

static const struct samsung_ufs_phy_cfg exynos9810_post_pwr_hs_cfg[] = {
	END_UFS_PHY_CFG
};

static const struct samsung_ufs_phy_cfg *exynos9810_ufs_phy_cfgs[CFG_TAG_MAX] = {
	[CFG_PRE_INIT]		= exynos9810_pre_init_cfg,
	[CFG_PRE_PWR_HS]	= exynos9810_pre_pwr_hs_cfg,
	[CFG_POST_PWR_HS]	= exynos9810_post_pwr_hs_cfg,
};

static const char * const exynos9810_ufs_phy_clks[] = {
	"ref_clk",
};

/* Samsung CAL: 200 us settle after the PMA init sequence */
static int exynos9810_ufs_phy_wait_for_cal(struct phy *phy, u8 lane)
{
	if (!lane)
		udelay(200);
	return 0;
}

/*
 * Samsung CAL PHY_CDR_AFC_WAIT: poll the AFC done bit, kicking the lane
 * control register between polls.
 */
static int exynos9810_ufs_phy_wait_for_cdr(struct phy *phy, u8 lane)
{
	struct samsung_ufs_phy *ufs_phy = get_samsung_ufs_phy(phy);
	void __iomem *trsv = ufs_phy->reg_pma + lane * (EXYNOS9810_TRSV_LANE_OFFSET << 2);
	int i;

	for (i = 0; i < 100; i++) {
		udelay(40);
		if (readl(trsv + EXYNOS9810_TRSV_CDR_AFC) & EXYNOS9810_TRSV_CDR_AFC_DONE)
			return 0;
		udelay(1);
		writel(0x7f, trsv + EXYNOS9810_TRSV_LANE_CTRL);
		writel(0xff, trsv + EXYNOS9810_TRSV_LANE_CTRL);
	}

	dev_err(ufs_phy->dev, "failed to get CDR AFC lock on lane %u\n", lane);
	return -ETIMEDOUT;
}

const struct samsung_ufs_phy_drvdata exynos9810_ufs_phy = {
	.cfgs = exynos9810_ufs_phy_cfgs,
	.isol = {
		.offset = EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL,
		.mask = EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL_MASK,
		.en = EXYNOS9810_EMBEDDED_COMBO_PHY_CTRL_EN,
	},
	.clk_list = exynos9810_ufs_phy_clks,
	.num_clks = ARRAY_SIZE(exynos9810_ufs_phy_clks),
	.wait_for_cal = exynos9810_ufs_phy_wait_for_cal,
	.wait_for_cdr = exynos9810_ufs_phy_wait_for_cdr,
};
