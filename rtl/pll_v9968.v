// pll_v9968 -- rtl/pll.v with a third output for the V9968 build (MSX_V9968), 2026-10-21.
// outclk_0 128.863620 MHz (clk_sdram), outclk_1 21.477270 MHz (clk21m), outclk_2 85.909080
// MHz (clk_vdp = 2/3 of clk_sdram, 4 x clk21m), outclk_3 42.954540 MHz (clk_geo = clk_vdp / 2,
// the Geo3D engine clock, 2026-10-22).  All three at phase 0: one VCO (515.45 MHz)
// divided by 4 / 24 / 6 / 12, so clk_sdram and clk_vdp share a rising edge every 23.28 ns, which
// rtl/video/v9968_link.sv relies on.  The core of it is rtl/pll/pll_v9968_0002.v, a copy
// of the (hand-set 128.86 MHz) pll_0002.v with number_of_clocks 3; not wizard-generated.
`timescale 1 ps / 1 ps
module pll_v9968 (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  outclk_1,
		output wire  outclk_2,
		output wire  outclk_3,
		output wire  locked
	);
	pll_v9968_0002 pll_inst (       // same instance name as rtl/pll.v: MSX1.sdc names emu|pll|pll_inst|...
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.outclk_3 (outclk_3),
		.locked   (locked)
	);
endmodule
