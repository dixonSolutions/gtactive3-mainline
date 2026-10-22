/* ---- CMU_CHUB (hand-written, writable: SPI21 needs its USI divider) ----- */

/* NOTE: Must be equal to the last clock ID increased by one */
#define CLKS_NR_CHUB	(CLK_GOUT_CHUB_RSTNSYNC_USI01 + 1)

/* Register Offset definitions for CMU_CHUB (0x13a00000) */
#define PLL_CON0_MUX_CLKCMU_CHUB_BUS_USER				0x0100
#define PLL_CON2_MUX_CLKCMU_CHUB_BUS_USER				0x0108
#define PLL_CON0_MUX_CLKCMU_CHUB_DLL_BUS_USER				0x0120
#define PLL_CON2_MUX_CLKCMU_CHUB_DLL_BUS_USER				0x0128
#define CLK_CON_MUX_MUX_CLK_CHUB_BUS					0x1004
#define CLK_CON_MUX_MUX_CLK_CHUB_I2C					0x1008
#define CLK_CON_MUX_MUX_CLK_CHUB_USI00					0x100c
#define CLK_CON_MUX_MUX_CLK_CHUB_USI01					0x1010
#define CLK_CON_DIV_DIV_CLK_CHUB_BUS					0x1800
#define CLK_CON_DIV_DIV_CLK_CHUB_I2C					0x1804
#define CLK_CON_DIV_DIV_CLK_CHUB_USI00					0x1808
#define CLK_CON_DIV_DIV_CLK_CHUB_USI01					0x180c
#define CLK_CON_GAT_GATE_CLK_CHUB_I2C					0x200c
#define CLK_CON_GAT_GATE_CLK_CHUB_USI00					0x2010
#define CLK_CON_GAT_GATE_CLK_CHUB_USI01					0x2014
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB00_IPCLKPORT_IPCLK	0x2058
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB01_IPCLKPORT_IPCLK	0x2060
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_I2C_IPCLKPORT_CLK	0x208c
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI00_IPCLKPORT_CLK	0x2090
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI01_IPCLKPORT_CLK	0x2094
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB00_IPCLKPORT_IPCLK	0x20a8
#define CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB01_IPCLKPORT_IPCLK	0x20b0

static const unsigned long chub_clk_regs[] __initconst = {
	PLL_CON0_MUX_CLKCMU_CHUB_BUS_USER,
	PLL_CON2_MUX_CLKCMU_CHUB_BUS_USER,
	PLL_CON0_MUX_CLKCMU_CHUB_DLL_BUS_USER,
	PLL_CON2_MUX_CLKCMU_CHUB_DLL_BUS_USER,
	CLK_CON_MUX_MUX_CLK_CHUB_BUS,
	CLK_CON_MUX_MUX_CLK_CHUB_I2C,
	CLK_CON_MUX_MUX_CLK_CHUB_USI00,
	CLK_CON_MUX_MUX_CLK_CHUB_USI01,
	CLK_CON_DIV_DIV_CLK_CHUB_BUS,
	CLK_CON_DIV_DIV_CLK_CHUB_I2C,
	CLK_CON_DIV_DIV_CLK_CHUB_USI00,
	CLK_CON_DIV_DIV_CLK_CHUB_USI01,
	CLK_CON_GAT_GATE_CLK_CHUB_I2C,
	CLK_CON_GAT_GATE_CLK_CHUB_USI00,
	CLK_CON_GAT_GATE_CLK_CHUB_USI01,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB00_IPCLKPORT_IPCLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB01_IPCLKPORT_IPCLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_I2C_IPCLKPORT_CLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI00_IPCLKPORT_CLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI01_IPCLKPORT_CLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB00_IPCLKPORT_IPCLK,
	CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB01_IPCLKPORT_IPCLK,
};

/* List of parent clocks for Muxes in CMU_CHUB */
PNAME(mout_chub_bus_user_p)	= { "clk_rco_chub", "dout_cmu_chub_bus" };
PNAME(mout_chub_dll_bus_user_p)	= { "clk_rco_chub", "gout_cmu_apm_dll_chub" };
PNAME(mout_chub_bus_p)		= { "mout_chub_bus_user",
				    "mout_chub_dll_bus_user" };
PNAME(mout_chub_i2c_p)		= { "clk_rco_chub", "mout_chub_bus" };
PNAME(mout_chub_usi00_p)	= { "clk_rco_chub", "mout_chub_bus" };
PNAME(mout_chub_usi01_p)	= { "clk_rco_chub", "mout_chub_bus" };

/* CHUB internal RC oscillator, 26 MHz nominal according to CMUCAL */
static const struct samsung_fixed_rate_clock chub_fixed_clks[] __initconst = {
	FRATE(CLK_RCO_CHUB, "clk_rco_chub", NULL, 0, 26000000),
};

static const struct samsung_mux_clock chub_mux_clks[] __initconst = {
	MUX(CLK_MOUT_CHUB_BUS_USER, "mout_chub_bus_user", mout_chub_bus_user_p,
	    PLL_CON0_MUX_CLKCMU_CHUB_BUS_USER, 4, 1),
	MUX(CLK_MOUT_CHUB_DLL_BUS_USER, "mout_chub_dll_bus_user",
	    mout_chub_dll_bus_user_p,
	    PLL_CON0_MUX_CLKCMU_CHUB_DLL_BUS_USER, 4, 1),
	MUX(CLK_MOUT_CHUB_BUS, "mout_chub_bus", mout_chub_bus_p,
	    CLK_CON_MUX_MUX_CLK_CHUB_BUS, 0, 1),
	MUX(CLK_MOUT_CHUB_I2C, "mout_chub_i2c", mout_chub_i2c_p,
	    CLK_CON_MUX_MUX_CLK_CHUB_I2C, 0, 1),
	MUX(CLK_MOUT_CHUB_USI00, "mout_chub_usi00", mout_chub_usi00_p,
	    CLK_CON_MUX_MUX_CLK_CHUB_USI00, 0, 1),
	MUX(CLK_MOUT_CHUB_USI01, "mout_chub_usi01", mout_chub_usi01_p,
	    CLK_CON_MUX_MUX_CLK_CHUB_USI01, 0, 1),
};

static const struct samsung_div_clock chub_div_clks[] __initconst = {
	DIV(CLK_DOUT_CHUB_BUS, "dout_chub_bus", "mout_chub_bus",
	    CLK_CON_DIV_DIV_CLK_CHUB_BUS, 0, 4),
	DIV(CLK_DOUT_CHUB_I2C, "dout_chub_i2c", "gout_chub_i2c",
	    CLK_CON_DIV_DIV_CLK_CHUB_I2C, 0, 4),
	DIV(CLK_DOUT_CHUB_USI00, "dout_chub_usi00", "gout_chub_usi00",
	    CLK_CON_DIV_DIV_CLK_CHUB_USI00, 0, 4),
	DIV(CLK_DOUT_CHUB_USI01, "dout_chub_usi01", "gout_chub_usi01",
	    CLK_CON_DIV_DIV_CLK_CHUB_USI01, 0, 4),
};

static const struct samsung_gate_clock chub_gate_clks[] __initconst = {
	GATE(CLK_GOUT_CHUB_I2C, "gout_chub_i2c", "mout_chub_i2c",
	     CLK_CON_GAT_GATE_CLK_CHUB_I2C, 21, 0, 0),
	GATE(CLK_GOUT_CHUB_USI00, "gout_chub_usi00", "mout_chub_usi00",
	     CLK_CON_GAT_GATE_CLK_CHUB_USI00, 21, 0, 0),
	GATE(CLK_GOUT_CHUB_USI01, "gout_chub_usi01", "mout_chub_usi01",
	     CLK_CON_GAT_GATE_CLK_CHUB_USI01, 21, 0, 0),
	GATE(CLK_GOUT_CHUB_I2C_CHUB00_IPCLK, "gout_chub_i2c_chub00_ipclk",
	     "dout_chub_i2c",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB00_IPCLKPORT_IPCLK,
	     21, CLK_SET_RATE_PARENT, 0),
	GATE(CLK_GOUT_CHUB_I2C_CHUB01_IPCLK, "gout_chub_i2c_chub01_ipclk",
	     "dout_chub_i2c",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_I2C_CHUB01_IPCLKPORT_IPCLK,
	     21, CLK_SET_RATE_PARENT, 0),
	GATE(CLK_GOUT_CHUB_USI_CHUB00_IPCLK, "gout_chub_usi_chub00_ipclk",
	     "dout_chub_usi00",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB00_IPCLKPORT_IPCLK,
	     21, CLK_SET_RATE_PARENT, 0),
	GATE(CLK_GOUT_CHUB_USI_CHUB01_IPCLK, "gout_chub_usi_chub01_ipclk",
	     "dout_chub_usi01",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_USI_CHUB01_IPCLKPORT_IPCLK,
	     21, CLK_SET_RATE_PARENT, 0),
	/*
	 * The reset synchronizers of the USI/I2C blocks have no consumer in
	 * the device tree, but the IPs do not work without them.
	 */
	GATE(CLK_GOUT_CHUB_RSTNSYNC_I2C, "gout_chub_rstnsync_i2c",
	     "dout_chub_i2c",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_I2C_IPCLKPORT_CLK,
	     21, CLK_IGNORE_UNUSED, 0),
	GATE(CLK_GOUT_CHUB_RSTNSYNC_USI00, "gout_chub_rstnsync_usi00",
	     "dout_chub_usi00",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI00_IPCLKPORT_CLK,
	     21, CLK_IGNORE_UNUSED, 0),
	GATE(CLK_GOUT_CHUB_RSTNSYNC_USI01, "gout_chub_rstnsync_usi01",
	     "dout_chub_usi01",
	     CLK_CON_GAT_GOUT_BLK_CHUB_UID_RSTNSYNC_CLK_CHUB_USI01_IPCLKPORT_CLK,
	     21, CLK_IGNORE_UNUSED, 0),
};

static const struct samsung_cmu_info chub_cmu_info __initconst = {
	.mux_clks		= chub_mux_clks,
	.nr_mux_clks		= ARRAY_SIZE(chub_mux_clks),
	.div_clks		= chub_div_clks,
	.nr_div_clks		= ARRAY_SIZE(chub_div_clks),
	.gate_clks		= chub_gate_clks,
	.nr_gate_clks		= ARRAY_SIZE(chub_gate_clks),
	.fixed_clks		= chub_fixed_clks,
	.nr_fixed_clks		= ARRAY_SIZE(chub_fixed_clks),
	.nr_clk_ids		= CLKS_NR_CHUB,
	.clk_regs		= chub_clk_regs,
	.nr_clk_regs		= ARRAY_SIZE(chub_clk_regs),
	.clk_name		= "bus",
};
