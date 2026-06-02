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

# OPL4 CPU register write path (opl4latch → pcm_engine decode registers).
# CPU writes the OPL4 latch on ce_3m58_p ticks; address decode goes through
# a deep chain (Add + Divider op_5..op_8 + Decoder + reg_upd + hf_upd) before
# reaching the CPU-config registers (ram_regs[slot].fn, reg_upd.tl, etc.).
# Same multi-cycle reasoning as ch2.
#
# IMPORTANT: -from is restricted to opl4latch.  Every register reachable
# from opl4latch inside the PCM engine is CPU-config data (wave/fn/oct/tl/
# pan/ar/...) that only changes at ce_3m58 cadence, so relaxing the whole
# pcm_engine -to set is safe — the engine's own per-cycle state updates
# (EG, dyn, accum) have different launch registers and stay single-cycle.
# Broad -to avoids the worst path hopping between ram_regs → reg_upd → ...
set_multicycle_path -setup -end 6 \
    -from [get_registers {*ymf278b_regs*opl4latch*}] \
    -to   [get_registers {*pcm_engine*}]
set_multicycle_path -hold  -end 5 \
    -from [get_registers {*ymf278b_regs*opl4latch*}] \
    -to   [get_registers {*pcm_engine*}]

# OPL4 PCM position/step datapath (stage_a_reg -> next_pos_r / next_stepPtr_r /
# next_pos_for_b_r).  stage_a_reg latches a slot's regs ONCE per 64-cycle slot
# window (at dispatch, slot_phase==0) and holds; next_*_r feed next_addrs which
# is only consumed at the next stage_advance (slot_phase==63), ~63 cycles later.
# So the whole window is available and the single-cycle setup is pessimistic.
# These are the chronic oct/fn -> next_pos setup violators on this clock.
set_multicycle_path -setup -end 4 \
    -from [get_registers {*u_pcm|stage_a_reg*}] \
    -to   [get_registers {*u_pcm|next_pos_r* *u_pcm|next_stepPtr_r* *u_pcm|next_pos_for_b_r*}]
set_multicycle_path -hold  -end 3 \
    -from [get_registers {*u_pcm|stage_a_reg*}] \
    -to   [get_registers {*u_pcm|next_pos_r* *u_pcm|next_stepPtr_r* *u_pcm|next_pos_for_b_r*}]
# next_pos_for_b_r is chained off the (window-stable) next_pos_r.
set_multicycle_path -setup -end 4 \
    -from [get_registers {*u_pcm|next_pos_r*}] \
    -to   [get_registers {*u_pcm|next_pos_for_b_r*}]
set_multicycle_path -hold  -end 3 \
    -from [get_registers {*u_pcm|next_pos_r*}] \
    -to   [get_registers {*u_pcm|next_pos_for_b_r*}]
# OPL4 PCM LFO vibrato ([14]).  vib_off_r = compute_vib(stage_a_reg.dyn.lfo_cnt):
# triangle fold + multiply + signed /12 — a deep combinational cloud (~45 ns,
# single-cycle slack -33.9 ns).  lfo_cnt is part of stage_a_reg, latched once
# per 64-cycle slot window and held; vib_off_r is only consumed (via calc_step ->
# next_pos_r) at the next stage_advance.  Window is free → multicycle (6 covers
# the /12 with margin).
set_multicycle_path -setup -end 6 \
    -from [get_registers {*u_pcm|stage_a_reg*}] \
    -to   [get_registers {*u_pcm|vib_off_r*}]
set_multicycle_path -hold  -end 5 \
    -from [get_registers {*u_pcm|stage_a_reg*}] \
    -to   [get_registers {*u_pcm|vib_off_r*}]
# vib_off_r feeds calc_step -> next_pos_r / next_stepPtr_r (same window-stable
# datapath as the oct/fn paths above).
set_multicycle_path -setup -end 4 \
    -from [get_registers {*u_pcm|vib_off_r*}] \
    -to   [get_registers {*u_pcm|next_pos_r* *u_pcm|next_stepPtr_r*}]
set_multicycle_path -hold  -end 3 \
    -from [get_registers {*u_pcm|vib_off_r*}] \
    -to   [get_registers {*u_pcm|next_pos_r* *u_pcm|next_stepPtr_r*}]

# OPL4 PCM Stage B -> Stage C sample decode/interpolation.  stage_b_reg, sb_split
# and sb_b_idx all latch at stage_advance (slot_phase==63) and hold for the whole
# 64-cycle window; stage_c_reg samples the decode result at the NEXT stage_advance,
# ~64 cycles later.  The 12-bit loop-seam fix added an sb_split branch to this
# combinational decode, pushing stage_b_reg/sb_split -> stage_c_reg.interp to
# -0.418ns under single-cycle analysis — pessimistic, since the window is free.
set_multicycle_path -setup -end 4 \
    -from [get_registers {*u_pcm|stage_b_reg* *u_pcm|sb_split* *u_pcm|sb_b_idx*}] \
    -to   [get_registers {*u_pcm|stage_c_reg*}]
set_multicycle_path -hold  -end 3 \
    -from [get_registers {*u_pcm|stage_b_reg* *u_pcm|sb_split* *u_pcm|sb_b_idx*}] \
    -to   [get_registers {*u_pcm|stage_c_reg*}]
