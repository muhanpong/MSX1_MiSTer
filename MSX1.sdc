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
#  it runs from a real clock that az80_clkgen divides out of clk_sdram.  That
#  clock has to be DECLARED or the analyser has no idea what it is: the first
#  build with A-Z80 in it reported -6.903 ns worst setup and -1412 ns TNS on the
#  clk21m domain purely because the flops az80_clk drives were being related to
#  clk21m instead of to their own clock.
#
#  The divisor is variable (24/16/12/8 for 3.58 .. 10.74 MHz) and SDC cannot
#  express that, so it is declared at its FASTEST -- /8, one toggle every four
#  clk_sdram, giving a 10.74 MHz clock.  Constraining the fast case constrains
#  every slower one.  /4 is RETIRED: 21.5 MHz is T80s on clk21m (see msx.sv) --
#  seven full fits put A-Z80's /4 half-cycle paths at 18.6-21.0 MHz against the
#  21.477 required, and az80_clkgen clamps the divisor so nothing can ever
#  clock the core past what is analysed here.  At /8 the half-period is
#  46.57 ns and the same paths close with ~20 ns of margin, seed-independent.
create_generated_clock -name az80_clk \
    -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 8 \
    [get_registers {*az80_clkgen*|az80_clk}]

#  clk21m and az80_clk are integer divides of the same PLL output, so they are
#  synchronous -- but the CPU's strobes still cross between them, and at /4 a
#  transfer window is exactly one clk21m period.  Leave those paths timed; do
#  NOT false-path them.  The existing PLL-to-PLL false path above covers the
#  unrelated domains only.

#  The reset crossing into az80_clk.  reset_req lives in FPGA_CLK2_50 and the
#  two clocks are unrelated, so the analyser pairs their worst edges and asks
#  for a negative setup time -- unsatisfiable by construction.  The synchroniser
#  in msx.sv (async assert, sync deassert) is what makes the crossing safe; the
#  path into its first stage is what must not be timed.
#  Both stages share the async assert (reset | use_t80), so both async pins
#  are recovery-timed against FPGA_CLK2_50 / the HPS reset -- unsatisfiable by
#  construction (-13.1 ns on az_rst_sync[1], build 3194311).  The assert is
#  asynchronous on purpose (az80_clk may be stopped); only the deassert is
#  timed, and that is the synchronous shift between the two stages, which
#  stays a normal az80_clk -> az80_clk path.
set_false_path -to [get_registers {*msx:MSX|az_rst_sync[*]}]

#  SDRAM read data into A-Z80's input register (data_pins' dout).  ch2_saved_*
#  are the read-cache registers on clk_sdram; dout is the CPU's one and only
#  data entry point, clocked on ~az80_clk.  The two clocks divide the same PLL
#  output, so the analyser finds a 0.001 ns edge pairing and asks the whole
#  cpu_din mux cloud to settle in nothing (-4.5 ns, build 6697e64) -- but the
#  transfer is not single-cycle by construction:
#    settle -> pacer/guard sees ready (>= 1 registered clk21m edge)
#           -> wait_n released (registered)
#           -> the CPU, having sampled nWAIT high at a falling edge, consumes
#              the byte at the NEXT falling edge, one full T-state later.
#  At /4 (21.477 MHz, the fastest and the declared rate) one T-state is
#  46.6 ns, so the true budget from last data change to consumption is at
#  least one az80_clk period.  Setup 2 moves the capture to exactly that edge;
#  hold 1 keeps the coincident edge's hold check, trivially met.
#  Scoped to the ch2 read-return only -- every other cpu_din source is on
#  clk21m and meets its pairing as-is; do not widen this.
#  GENERALISED after the 5b6b9fd build's cross-domain survey (docs/
#  az80_migration_20260913.md): every clk_sdram source that can reach dout is a
#  paced read (SDRAM ch2 via the pacer, MoonSound via its WAIT/status hold), and
#  every clk21m source is an I/O or memory device whose read data is consumed at
#  the T3 falling edge -- at /4 that is >= 1.5 T-states (69.9 ns) after the T2
#  clk21m edge that could last have launched it, and the -end 2 budget is 69.85.
#  Devices that update later than T2 do so under WAIT (VDP DBI, MoonSound), which
#  only adds whole T-states of margin.  Hold stays on the coincident edge and is
#  met by any positive route delay.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_registers {*data_pins:data_pins_|dout*}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_registers {*data_pins:data_pins_|dout*}]
#  clk21m -> az80_clk, the whole pair (supersedes the earlier clk21m -> dout
#  line).  Build b9g9xx16g showed the last class: PPI port A -- the 0xA8
#  primary-slot register -- and mapper state (map_valid) feeding the slot
#  decode -> sdram_ce -> bus_guard_n -> A-Z80's nWAIT sampler, -12.2 ns on the
#  23.28 ns pairing.  Every clk21m register that reaches the CPU is one of:
#    read data      consumed at T3 falling (the dout argument above);
#    wait_n         slot/mapper/guard state is written by the CPU's OWN previous
#                   bus cycle and sampled at the NEXT cycle's T2 falling edge,
#                   >= 1.5 T-states (139.7 ns at /8) after it can last change;
#    int_n          level held for many cycles, sampled at T_last; one cycle
#                   of lateness is one clk21m of interrupt latency;
#    reset          the synchroniser, false-pathed separately.
#  -end 2 asks for 46.57 ns of each.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_clocks {az80_clk}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_clocks {az80_clk}]

#  (The arithmetic below was derived at /4.  The clock is now declared /8 --
#  T-states double, every contract lead doubles, the -end 2 budgets stay the
#  same 46.57 ns -- so each relation only gains margin.  Left in /4 terms
#  because that is the tightest case that was ever argued.)
#
#  az80_clk -> clk21m, the WHOLE domain pair: every clk21m consumer of a CPU
#  output is strobe-qualified, because that is what a Z80 bus is.  The contract
#  arithmetic on the /4 grid (T-state = 46.566 ns, tightest edge pairing
#  23.283 ns, so -end 2 = 69.849 ns):
#    WRITES  address valid at T1 rise, nWR falls at T2 fall = 1.5 T = 69.849 ns
#            later.  A write-enable-qualified capture therefore cannot fire
#            before the very edge the MCP budget delivers the address to.
#            Equality is by construction -- both are 1.5 grid periods -- so
#            this is deterministic, not lucky.
#    READS   nRD falls 0.5 T after the address; a torn first-cycle view of a
#            read address produces one clk21m cycle of garbage dout, which
#            self-corrects long before the CPU consumes at the T3 falling edge.
#            Consumers that ACT on a read address (sdram ch2 capture) are
#            already behind their own -end 6 exception above.
#    STROBES themselves stay effectively single-cycle -- they are the
#            qualifiers; the MCP merely also covers them, and a uniformly
#            1-cycle-late strobe view shifts guard windows without shrinking
#            them (the guard counts in its own clk21m time base).
#  First measured on the a8r_val debug shadow (-12.6 ns x hundreds of paths,
#  build 5b6b9fd), then the next tier (systemRAM write ports, -5.98) made it
#  clear the class is the domain pair, not any single endpoint.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {az80_clk}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {az80_clk}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

#  az80_clkgen's divisor latch samples CPU bus-idle to pick a glitch-free moment
#  to change the division.  The inputs (mreq/m1/wait state from the core) are
#  level-stable whenever bus-idle is actually true, and the divisor itself only
#  changes on an OSD speed change -- single-cycle analysis of the sampling cone
#  is pessimism.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {az80_clk}] \
    -to   [get_registers {*az80_clkgen*|speed_q*}]
set_multicycle_path -hold  -end 1 \
    -from [get_clocks {az80_clk}] \
    -to   [get_registers {*az80_clkgen*|speed_q*}]

#  Inside A-Z80 itself: every remaining az80_clk violation ends at data_pins'
#  dout, through the RESOLVED internal tri-state bus `db` (Quartus flattens its
#  ~30 drivers into 10-12 logic levels; on the die this was a wired bus with
#  zero levels -- this is A-Z80's FPGA tax).  The launch registers split into
#  two kinds:
#    ir|opcode, decode_state flags (instED/instCB/inst4/instIY*/in_halt):
#      stable PER INSTRUCTION.  dout's we-load (write-data staging) happens
#      only in a write M-cycle, at least one full M-cycle -- >= 4 half-periods
#      -- after IR/prefix flags last changed.  The enable cone is the same
#      argument: the IR-launched component of ctl_bus_db_we settles M-cycles
#      before any staging edge that depends on it.  -end 2 asks for 2 half-
#      periods of the >= 4 available.
#    sequencer T/M state bits: change EVERY half-period -- genuinely single-
#      cycle, deliberately NOT relaxed here.  If they cannot close physically,
#      that is the real ceiling of this core on this device.
set_multicycle_path -setup -end 2 \
    -from [get_registers {*z80_top_direct_n:cpu|ir:ir_|opcode* *z80_top_direct_n:cpu|decode_state:decode_state_|*}] \
    -to   [get_registers {*data_pins:data_pins_|dout*}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*z80_top_direct_n:cpu|ir:ir_|opcode* *z80_top_direct_n:cpu|decode_state:decode_state_|*}] \
    -to   [get_registers {*data_pins:data_pins_|dout*}]

#  Core-to-core paths in the dual-CPU arrangement are false BY CONSTRUCTION:
#  exactly one of T80s / A-Z80 is ever out of reset (use_t80 changes only
#  inside the stretched core-switch machine reset, MSX1.sv), and a core held
#  in reset neither launches transitions nor acts on captures.  Without this,
#  T80s' combinational wait cone (IR and friends -> guard -> wait_n) reaches
#  A-Z80's nWAIT sampler as a -16.5 ns clk21m -> az80_clk path that no real
#  execution can ever traverse.  A-Z80's own wait loop (its strobes -> guard ->
#  wait_n -> its nWAIT) is NOT covered by these two lines and stays timed.
set_false_path -from [get_registers {*msx:MSX|T80s:T80|*}] \
               -to   [get_registers {*msx:MSX|az80_wrapper:CPU|*}]
set_false_path -from [get_registers {*msx:MSX|az80_wrapper:CPU|*}] \
               -to   [get_registers {*msx:MSX|T80s:T80|*}]

#  The core-select flop.  It changes only at a speed-4 boundary crossing, and
#  that crossing raises core_switch_rst for ~12 ms -- both CPUs, the guard and
#  every bus consumer are in machine reset for thousands of cycles around the
#  transition, so no path launched by this register is ever consumed near its
#  transition.  Quasi-static by construction.
set_false_path -from [get_registers {*|use_t80}]

#  status[58:56] are the OSD "CPU Speed" bits.  Registering use_t80 in MSX1.sv
#  did not take the raw bits out of the address-mux select cone in the fitted
#  netlist (build btvhccwyg: hps_io|status[58]|q -> MSX|a[14]~16 -> slot decode
#  -> neo16 -> wait cone -> A-Z80 nWAIT, -13.0 ns), so constrain the source.
#  These three bits are quasi-static by construction: they change only on an
#  OSD interaction, every consumer latches them at a bus-idle point (clock.sv,
#  az80_clkgen) or triggers the 12 ms core-switch reset (MSX1.sv), and a torn
#  multi-bit capture can at worst select a neighbouring valid speed until the
#  next idle re-latch, or extend that reset.  Nothing samples them under
#  single-cycle timing on purpose.
set_false_path -from [get_registers {*hps_io|status[56] *hps_io|status[57] *hps_io|status[58]}]
