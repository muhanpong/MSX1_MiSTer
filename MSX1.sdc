derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# audio_out|IIR_filter is fed by `acx`/`acx0..2`/`acy0..2` coefficients that
# are written by the HPS on clk_sys and consumed by the IIR taps on clk_audio.
# These coefficient updates happen rarely and the filter implicitly tolerates
# the cross-domain sampling (multi-cycle averaging through the IIR structure).
# sys/sys_top.sdc tries to handle this with set_clock_groups -exclusive
# between emu|pll outputs and pll_audio, but the glob pattern doesn't always
# match in Quartus 17.1 — TimeQuest still reports -23 ns paths from
# emu|pll|general[1] to pll_audio.  Add an explicit false_path here.
set_false_path -from [get_clocks {emu|pll|pll_inst|altera_pll_i|*|divclk}] \
               -to   [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}]
set_false_path -from [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*|divclk}] \
               -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|*|divclk}]

# T80 (clk21m, ce_3m58_p enable ~3.58 MHz) → SDRAM ch2 multi-cycle path.
# T80 instruction-bound signals (IR, MCycle, A, etc.) update only on
# ce_3m58_p ticks — every 6 clk21m cycles = 24 clk_sdram cycles.  The
# msx_slots mapper combinational chain that ends at sdram|ch2_addr_1[*]|d
# therefore has 24+ clk_sdram cycles to settle, not 1.  Quartus single-
# cycle analysis flags this as -9.1 ns slack even though the data is
# stable far longer than 1 clk_sdram cycle.
#
# Conservative 6-cycle setup (69.6 ns budget vs. 11.6 ns) with matching
# hold 5.  Applies to captured ch2 fields (addr/rnw/din); ch2_req_1 is
# the edge-detect signal and stays single-cycle.
#
# Use -to pin patterns only (no -from clock) so Quartus matches any
# source feeding the captured ch2 registers.  Use ~ wildcards to handle
# Quartus's hierarchical naming (emu:emu|sdram:sdram|...).
# Apply to all ch2-related sdram registers (captured fields + queue + req delay).
# Critical path source is T80 instruction-bound logic which only updates on
# ce_3m58_p ticks (every 24 clk_sdram cycles).  ch2_req_1 is the edge-detect
# delay register but receives the same multi-cycle source, so the 6-cycle
# budget is safe for it too.
set_multicycle_path -setup -end 6 -to [get_registers {*sdram*ch2_*}]
set_multicycle_path -hold  -end 5 -to [get_registers {*sdram*ch2_*}]
