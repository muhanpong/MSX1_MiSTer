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

# T80 (clk21m, ce_cpu_p enable, 3.58-10.74 MHz) → SDRAM ch2 multi-cycle path.
# T80 instruction-bound signals (IR, MCycle, A, etc.) update only on CEN
# ticks.  Re-derived for turbo (20260825): the bound is set by the WINDOW
# HEAD, which the guard/scoping never shortens — the address goes out on the
# T1 CEN_p and the strobe falls on the T1 CEN_n, half a T-state later, and
# ch2_addr_1 captures ~2 clk_sdram after the req edge (ch2_req is decoded
# from the strobe).  At the fastest CE (/2, 10.74MHz) half a T-state =
# 1 clk21m = 4 clk_sdram, so launch-to-capture is >= 4+2 = 6 clk_sdram —
# meets the 6-cycle budget below exactly (and has shipped that way at 10.74
# since the turbo commit; stock has 4x that margin).  If the budget is ever
# raised above 6, this head window is the number it must be checked against.
# The msx_slots mapper combinational chain that ends at sdram|ch2_addr_1[*]|d
# therefore has the full head window to settle, not 1 cycle.  Quartus single-
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

# OPL4 PCM EG-rate datapath: stage_c_reg latches at stage_advance and HOLDS for
# the whole 64-cycle window; d1a_pkt is latched at the NEXT stage_advance from it.
# So the deep calc_eg_rate/calc_decay_rate -> eg_rate_shift_rom -> eg_inc_rom chain
# (stage_c_reg.regs.rc/oct/fn -> d1a_pkt.inc_v) has the full window, not 1 cycle.
# Same window-stable pattern as the stage_a/stage_b paths above; without it this
# path swings to ~-1 ns on placement churn.
set_multicycle_path -setup -end 4 \
    -from [get_registers {*u_pcm|stage_c_reg*}] \
    -to   [get_registers {*u_pcm|d1a_pkt*}]
set_multicycle_path -hold  -end 3 \
    -from [get_registers {*u_pcm|stage_c_reg*}] \
    -to   [get_registers {*u_pcm|d1a_pkt*}]

# ─── A-Z80's clock ──────────────────────────────────────────────────────────
#  A-Z80 has no clock enable -- parts of it latch on ~clk by construction -- so
#  it runs from a real clock that az80_clkgen makes out of clk_sdram.  It must
#  be DECLARED or the flops it drives get related to clk21m (first A-Z80 build:
#  -6.9 ns / -1412 ns TNS of pure mis-analysis).
#
#  REWRITTEN 20260914 after the first hardware boot failed.  az80_clkgen now
#  places every az80_clk edge on a clk_sdram edge that coincides with a clk21m
#  rise (PLL outputs are 0 ps).  Declared /8 (1+1 clk21m periods, the fastest
#  phase of every speed; 3.58/5.37/7.16 are 3+3, 2+2, 2+1), the default /8
#  waveform -- rise on source edge 0, fall on edge 4 -- is exactly that grid.
#  Consequence: every CPU <-> clk21m path is a genuine single-cycle 46.57 ns
#  relationship, so NONE of the earlier boundary multicycles are needed.  They
#  are removed, and they were not merely unneeded: with the old free-running
#  divider an az80_clk edge could land half a clk21m before a fabric edge, and
#  "-end 2" told the analyser to look one edge later than the flops actually
#  capture -- the violations were real.  The history is in
#  docs/az80_migration_20260913.md; do not reintroduce them.
create_generated_clock -name az80_clk \
    -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 8 \
    [get_registers {*az80_clkgen*|az80_clk}]

#  Reset synchroniser into az80_clk: both stages carry the asynchronous assert
#  (reset | use_t80).  Assert is async on purpose (the clock is stopped in
#  reset); only the synchronous deassert shift is a timed path.
set_false_path -to [get_registers {*msx:MSX|az_rst_sync[*]}]

#  SDRAM read data into A-Z80's data latch.  The one remaining clk_sdram ->
#  az80_clk class: ch2_saved_* (and MoonSound's ms_io_dout_lat) change on
#  clk_sdram edges, which can precede an az80_clk edge by a single 11.6 ns
#  clk_sdram period.  They are not single-cycle by protocol: A-Z80 only ever
#  consumes a ch2 read after msx.sv's az_rd_pace_n releases WAIT, and that
#  release is REGISTERED on clk21m from a completion (rdtog / sdram_hit) that
#  was set on or after the edge the data became valid.  Data valid >= 1
#  clk_sdram before the clk21m release edge, WAIT reaches the CPU a full clk21m
#  later -> >= 58 ns of stable data at consumption.  set_max_delay 40 checks
#  the real requirement with margin instead of an edge-count guess.
#  MoonSound reads are held by exwait_n (ms_io_pending) the same way.
set_max_delay -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
              -to   [get_registers {*data_pins:data_pins_|dout*}] 40.000

#  The divisor latch samples cpu_bus_idle (combinational from CPU strobes) on a
#  clk_sdram edge right after an az80_clk edge.  It only matters on the edge
#  that STARTS a period, where the bus has been idle for a whole T-state, and a
#  one-period-late speed change is harmless.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {az80_clk}] \
    -to   [get_registers {*az80_clkgen*|speed_q* *az80_clkgen*|cnt*}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {az80_clk}] \
    -to   [get_registers {*az80_clkgen*|speed_q* *az80_clkgen*|cnt*}]

#  Dual core: exactly one of T80s / A-Z80 is out of reset (use_t80 changes only
#  inside the 12 ms core-switch machine reset, MSX1.sv), so core-to-core paths
#  never carry a live transition.
set_false_path -from [get_registers {*msx:MSX|T80s:T80|*}] \
               -to   [get_registers {*msx:MSX|az80_wrapper:CPU|*}]
set_false_path -from [get_registers {*msx:MSX|az80_wrapper:CPU|*}] \
               -to   [get_registers {*msx:MSX|T80s:T80|*}]

#  sdram_hit reaches bus_guard_n combinationally for T80s.  For A-Z80 that term
#  is irrelevant -- az_rd_pace_n holds WAIT until its own REGISTERED copy of the
#  hit -- but the analyser cannot see the use_t80 masking.
set_false_path -from [get_registers {*sdram:sdram|ch2_hit_r}] \
               -to   [get_registers {*msx:MSX|az80_wrapper:CPU|*}]

#  Core select and its OSD source bits: quasi-static, and every change is
#  wrapped in the 12 ms core-switch reset.
set_false_path -from [get_registers {*|use_t80}]
set_false_path -from [get_registers {*hps_io|status[56] *hps_io|status[57] *hps_io|status[58]}]

#  clk21m -> az80_clk: the requirement is exactly one clk21m period.
#  The emu PLL makes clk_sdram with C counter 5 and clk21m with C counter 20
#  off the same VCO at 0 degrees (fit.rpt PLL summary), so their edges coincide
#  exactly, and az80_clkgen puts every az80_clk edge on one of those edges.
#  TimeQuest rounds each period to the picosecond on its own -- clk_sdram 11.641,
#  clk21m 46.566, 4 x 11.641 = 46.564 -- sees a coincident capture edge as a
#  hair after the launch, and reports a 0.000 ns setup relationship (build
#  2f5ff24: -14.8 ns on all 2000 paths).  Physically that edge is the HOLD edge.
#  The tightest real capture is one clk21m period later (launch on an az80_clk
#  rise, capture at the next fall -- at every speed, 7.16's 2+1 included).
#  An edge-count multicycle is WRONG here: "-end 2" was tried and measured a
#  93.133 ns relationship, a full extra CPU period for the falling-edge flops.
#  A fixed max delay states the real requirement for every flop polarity.
#  Hold stays on the default (coincident) edge.
set_max_delay -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
              -to   [get_clocks {az80_clk}] 46.566

#  CPU address -> SCC wavetable RAM.  IKASCC's wave RAMs register their address
#  on the clk21m FALLING edge, a genuine half-period (23.28 ns) after an az80_clk
#  edge.  A write lands only when the write strobe is active, and A-Z80 drives
#  the address at T1 rise and WR at T2 fall -- 1.5 T-states, >= 1.5 clk21m
#  periods, later -- so the falling edge that commits a write has seen that
#  address stable for at least one full clk21m period.  Address bits only.
set_multicycle_path -setup -end 2 \
    -from [get_registers {*az80_wrapper:CPU|*address_pins:address_pins_|*}] \
    -to   [get_registers {*IKASCC_player_memory_s*}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*az80_wrapper:CPU|*address_pins:address_pins_|*}] \
    -to   [get_registers {*IKASCC_player_memory_s*}]
