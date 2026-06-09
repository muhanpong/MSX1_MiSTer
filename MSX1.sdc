derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# audio_out|IIR_filter coefficients are written by the HPS on clk_sys and consumed
# on clk_audio; these rarely-changing coefficients tolerate the cross-domain sample.
# sys/sys_top.sdc tries to exclude emu|pll <-> pll_audio but the glob doesn't always
# match in Quartus 17.1 (TimeQuest still reports ~-23 ns paths).  Explicit false_path.
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|*|divclk}] \
               -to   [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}]
set_false_path -from [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|*|divclk}]

# T80 (clk21m, ce_3m58_p enable ~3.58 MHz) -> SDRAM ch2 multi-cycle path.
# T80 instruction-bound signals update only on ce_3m58_p ticks (every 24 clk_sdram
# cycles), so the mapper chain ending at sdram|ch2_* has 24+ cycles to settle, not 1.
# Single-cycle analysis falsely flags this ~-9 ns.  Conservative 6/5 multi-cycle.
set_multicycle_path -setup -end 6 -to [get_registers {*sdram*ch2_*}]
set_multicycle_path -hold  -end 5 -to [get_registers {*sdram*ch2_*}]
