
struct exynos9810_cmu {
	const struct samsung_cmu_info *info;
	bool leaf;		/* may switch its gates to manual mode */
	bool writable;		/* registered with exynos_arm64_register_cmu() */
};

/*
 * Switch the gates of one CMU to manual mode without stopping anything:
 * every gate that is still in HWACG mode is set to MANUAL | CG_VAL, so a
 * clock that was running keeps running and the framework owns it from now on.
 */
static void __init exynos9810_cmu_manual_gates(void __iomem *base,
					       const struct samsung_cmu_info *info)
{
	unsigned int i, n = 0;

	for (i = 0; i < info->nr_gate_clks; i++) {
		void __iomem *reg = base + info->gate_clks[i].offset;
		u32 val = readl(reg);

		if (val & GATE_MANUAL)
			continue;
		val |= GATE_MANUAL | GATE_CG_VAL;
		val &= ~GATE_ENABLE_HWACG;
		writel(val, reg);
		n++;
	}

	pr_info("exynos9810-cmu: %u of %u gates switched to manual mode\n",
		n, info->nr_gate_clks);
}

static int __init exynos9810_cmu_probe(struct platform_device *pdev)
{
	const struct exynos9810_cmu *cmu;
	struct samsung_clk_provider *ctx;
	struct device *dev = &pdev->dev;
	void __iomem *base;

	cmu = of_device_get_match_data(dev);

	if (cmu->writable) {
		exynos_arm64_register_cmu(dev, dev->of_node, cmu->info);
		return 0;
	}

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	if (manual_gates && cmu->leaf)
		exynos9810_cmu_manual_gates(base, cmu->info);

	ctx = samsung_clk_init(dev, base, cmu->info->nr_clk_ids);
	samsung_cmu_register_clocks(ctx, cmu->info, dev->of_node);
	samsung_clk_of_add_provider(dev->of_node, ctx);

	return 0;
}

static const struct exynos9810_cmu exynos9810_cmu_top __initconst = {
	.info = &top_cmu_info,
	.leaf = false,
};

static const struct exynos9810_cmu exynos9810_cmu_apm __initconst = {
	.info = &apm_cmu_info,
	.leaf = false,
};

static const struct exynos9810_cmu exynos9810_cmu_chub __initconst = {
	.info = &chub_cmu_info,
	.writable = true,
};

static const struct exynos9810_cmu exynos9810_cmu_cmgp __initconst = {
	.info = &cmgp_cmu_info,
	.leaf = true,
};

static const struct exynos9810_cmu exynos9810_cmu_peric0 __initconst = {
	.info = &peric0_cmu_info,
	.leaf = true,
};

static const struct exynos9810_cmu exynos9810_cmu_peric1 __initconst = {
	.info = &peric1_cmu_info,
	.leaf = true,
};

static const struct exynos9810_cmu exynos9810_cmu_peris __initconst = {
	.info = &peris_cmu_info,
	.leaf = true,
};

static const struct exynos9810_cmu exynos9810_cmu_fsys0 __initconst = {
	.info = &fsys0_cmu_info,
	.leaf = true,
};

static const struct exynos9810_cmu exynos9810_cmu_dpu __initconst = {
	.info = &dpu_cmu_info,
	.leaf = true,
};

/* The G3D gates follow the GPU power domain, leave them to the hardware */
static const struct exynos9810_cmu exynos9810_cmu_g3d __initconst = {
	.info = &g3d_cmu_info,
	.leaf = false,
};

static const struct of_device_id exynos9810_cmu_of_match[] = {
	{
		.compatible = "samsung,exynos9810-cmu-top",
		.data = &exynos9810_cmu_top,
	}, {
		.compatible = "samsung,exynos9810-cmu-apm",
		.data = &exynos9810_cmu_apm,
	}, {
		.compatible = "samsung,exynos9810-cmu-chub",
		.data = &exynos9810_cmu_chub,
	}, {
		.compatible = "samsung,exynos9810-cmu-cmgp",
		.data = &exynos9810_cmu_cmgp,
	}, {
		.compatible = "samsung,exynos9810-cmu-peric0",
		.data = &exynos9810_cmu_peric0,
	}, {
		.compatible = "samsung,exynos9810-cmu-peric1",
		.data = &exynos9810_cmu_peric1,
	}, {
		.compatible = "samsung,exynos9810-cmu-peris",
		.data = &exynos9810_cmu_peris,
	}, {
		.compatible = "samsung,exynos9810-cmu-fsys0",
		.data = &exynos9810_cmu_fsys0,
	}, {
		.compatible = "samsung,exynos9810-cmu-dpu",
		.data = &exynos9810_cmu_dpu,
	}, {
		.compatible = "samsung,exynos9810-cmu-g3d",
		.data = &exynos9810_cmu_g3d,
	},
	{ }
};

static struct platform_driver exynos9810_cmu_driver __refdata = {
	.driver = {
		.name = "exynos9810-cmu",
		.of_match_table = exynos9810_cmu_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = exynos9810_cmu_probe,
};

static int __init exynos9810_cmu_init(void)
{
	return platform_driver_register(&exynos9810_cmu_driver);
}
core_initcall(exynos9810_cmu_init);
