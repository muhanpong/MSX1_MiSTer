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
# CORRECTION (2026-10-17, sdram128-study): two statements above are not what the
# code does.  (1) "ch2_addr_1 captures ~2 clk_sdram after the req edge": sdram.sv
# and sdram_tdm both capture ch2_addr on the FIRST clk_sdram edge that sees the
# request (sdram.sv:254-257, sdram_tdm request-edge block).  (2) "ch2_req_1 ...
# stays single-cycle": the {*sdram*ch2_*} pattern below matches ch2_req_1 too, and
# the comment further down says so.  So the premise is only that the captured
# fields are on the bus BEFORE the strobe that makes the request.  That holds for
# a memory cycle's A bus.  It did not hold for the kanji port read, where IORQ_n
# both raises the request and switches ram_addr (board: 0-8/4096 bytes at 128.86
# MHz); kanji.sv now raises that request one clk21m after the select, which makes
# the premise true for that path as well.  tools/buildgate/strobe_race.tcl prints
# the strobe -> request / capture arrivals the 6-cycle exception hides.
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

# ...but only for sources OUTSIDE the sdram module.  The pattern above is by name,
# so it also swallowed sdram-internal clk_sdram -> clk_sdram paths into ch2_*:
# the read cache's stage 2 (cmem/c_rdata/ch2_caddr/c_pend2 -> ch2_saved_data,
# _saved_a0, _ready, _hit_r, _rq, _rnw_1, _addr_1; sdram.sv:171-174 says these
# must stay single-cycle) and the FSM's own ch2_rq/ch2_rdtog bookkeeping.  With
# those relaxed to 6 the fitter never tried to close them: 20260928a_opll1 had
# cmem -> ch2_saved_data at -4.2 ns single-cycle, signoff PASS, and read wrong
# bytes on the board.  -from and -to both given outranks -to alone, so this
# restores one cycle for internal sources and leaves the T80/NextZ80 hop at 6.
#  sdram128 study: the controller is sdram_tdm, instance `sdram`.  This pattern
#  must name it -- with the old {*sdram:sdram|*} it matched nothing and every
#  internal path into ch2_* would have been relaxed to 6 (the 20260928a failure).
set_multicycle_path -setup -end 1 -from [get_registers {*sdram_tdm:sdram|*}] -to [get_registers {*sdram*ch2_*}]
set_multicycle_path -hold  -end 0 -from [get_registers {*sdram_tdm:sdram|*}] -to [get_registers {*sdram*ch2_*}]

# rnw looked at again on the second edge of a ch2 cache lookup (sdram_tdm.sv,
# "A write whose rnw came late", 2026-10-18).  c_pend2 is the one register outside
# ch2_* that reads ch2_rnw live, and only while ch2_cpend is high -- the edge after
# the one that saw the request.  The request is seen at the earliest one edge after
# the clk21m edge that launched it, so -end 2 is that check's own deadline: if rnw
# misses it, this fails here instead of being taken for a read.  Only clk21m
# sources: the sdram-internal paths into c_pend2 stay single-cycle.
#
# The second-edge deadline belongs to the STROBES only (T80s MREQ_n/WR_n/RD_n/
# IORQ_n, nz_bus ph): they launch on the clk21m edge whose request ch2_cpend saw.
# ram_rnw also depends on the address (slot/mapper decode -> sram_cs, ram_ro),
# and the address is out one clk21m before the strobe (fullsys LEAD, 2026-10-18:
# NextZ80 6 clk_sdram, T80 >= 12), so those sources have 6 + 2 = 8 edges.  With
# one -end 2 for every clk21m source, 732de12 failed at -7.82 ns slow on exactly
# such a path (NextZ80 FETCH -> slot/mapper mux -> sram_cs -> ram_rnw -> c_pend2);
# with the split the same fit signs off (+0.095 ns worst, strobes +4.99 at edge 2).
# Node -from outranks clock -from: the strobe pair below wins for those registers.
set_multicycle_path -setup -end 8 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_registers {*sdram_tdm:sdram|c_pend2}]
set_multicycle_path -hold  -end 7 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_registers {*sdram_tdm:sdram|c_pend2}]
set_multicycle_path -setup -end 2 \
    -from [get_registers {*T80s:T80|MREQ_n *T80s:T80|WR_n *T80s:T80|RD_n *T80s:T80|IORQ_n *nz_bus:NZB|ph*}] \
    -to   [get_registers {*sdram_tdm:sdram|c_pend2}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*T80s:T80|MREQ_n *T80s:T80|WR_n *T80s:T80|RD_n *T80s:T80|IORQ_n *nz_bus:NZB|ph*}] \
    -to   [get_registers {*sdram_tdm:sdram|c_pend2}]

# The MSX reset (MSX1.sv rst_meta / rst_hold, clk21m) is a level held for 63
# clk21m (~3 us).  sd_card's SPI half runs on clk_spi = clk_sdram and reads it
# unsynchronised; its state machines only idle while reset is high, so a register
# that sees the release one clk_sdram late changes nothing.  20261019a: rst_hold[4]
# -> sd_buf was the worst internal path at +0.095 ns; two cycles for sd_card only.
# NOT for the other clk_sdram consumers (the PCM engine's MLAB sweep counts reset
# clocks and must see one release edge; sdram_tdm): those stay single-cycle --
# a first version used -to the clk_sdram clock and covered them too (core_builder).
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|rst_hold[*] emu|rst_meta[*]}] \
    -to   [get_registers {*sd_card:sd_card|*}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {emu|rst_hold[*] emu|rst_meta[*]}] \
    -to   [get_registers {*sd_card:sd_card|*}]

# ch2_req_s (sdram_tdm.sv, 2026-10-19): the one register that samples the CPU
# request.  The request starts from the strobes and arrives 14-15.5 ns slow, so
# its deadline is the second edge (-end 2); STA then proves ch2_req_s is 1 there.
# On the first edge it is inside the transition window and may go metastable --
# it is read only on the next edge (ch2_req_s -> req_1/cpend/rq/bv is internal and
# single-cycle by the rule above), so the settle time is that path's slack.
set ch2_strobes [get_registers {*T80s:T80|MREQ_n *T80s:T80|WR_n *T80s:T80|RD_n *T80s:T80|IORQ_n *nz_bus:NZB|ph*}]
set_multicycle_path -setup -end 2 -from $ch2_strobes -to [get_registers {*sdram_tdm:sdram|ch2_req_s}]
set_multicycle_path -hold  -end 1 -from $ch2_strobes -to [get_registers {*sdram_tdm:sdram|ch2_req_s}]
# The fields are taken one edge after ch2_req_s rose, i.e. on edge 2 at the
# earliest.  The parts that start with the strobe -- ram_rnw (cpu_wr & cpu_mreq),
# and the T80's write data (DO changes on the WR_n edge, fullsys LEAD 0) -- get
# that second edge; the address side leads by a clk21m and keeps the generic 6
# (with kanji fix B the D9h select also leads its request by a clk21m).
set_multicycle_path -setup -end 2 -from $ch2_strobes -through [get_nets {*msx_slots|ram_rnw*}] -to [get_registers {*sdram_tdm:sdram|ch2_*}]
set_multicycle_path -hold  -end 1 -from $ch2_strobes -through [get_nets {*msx_slots|ram_rnw*}] -to [get_registers {*sdram_tdm:sdram|ch2_*}]
set_multicycle_path -setup -end 2 -from [get_registers {*T80s:T80|T80:u0|DO[*]}] -to [get_registers {*sdram_tdm:sdram|ch2_din_1[*] *sdram_tdm:sdram|ch2_bdin[*]}]
set_multicycle_path -hold  -end 1 -from [get_registers {*T80s:T80|T80:u0|DO[*]}] -to [get_registers {*sdram_tdm:sdram|ch2_din_1[*] *sdram_tdm:sdram|ch2_bdin[*]}]

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

# The v2 PCM engine's window multicycles (stage_a_reg / stage_b_reg / stage_c_reg /
# vib_off_r / next_pos_r / d1a_pkt) were removed 2026-10-13: engine2 has none of
# those registers, TimeQuest ignored all nine pairs as empty collections (332049),
# and engine2 closes 128.86 MHz single-cycle (sdram128-study efddce8, +0.180 ns).
# A relaxed path inside engine2 would hide exactly the kind of chain PIPE splits.

# ─── clk21m -> clk_sdram at 6:1 ──────────────────────────────────────────────
#  With clk_sdram at 128.86 MHz the two clocks are an exact 6:1 and every
#  single-cycle crossing gets one clk_sdram (7.76 ns, was 11.64).  The two
#  multicycles above still hold: the ch2 head window is 1 clk21m + 2 clk_sdram =
#  8 clk_sdram at 6:1 (4+2 = 6 at 4:1), so -end 6 keeps its margin; the OPL4
#  latch is written an OUT instruction before the data write it qualifies.
#  OSD audio trims (pcm_vol/fm_vol/mutes, hps_io status bits) into MoonSound's
#  gain stage: set from the menu, read every sample; a change landing a sample
#  late is inaudible and was the worst clk21m -> clk_sdram path (status[112] ->
#  pc_l_mul, -0.35 ns in 4cd2115).
set_false_path -from [get_registers {*hps_io|status[*]}] -to [get_registers {*u_moonsound|*}]

# ─── CPU select ─────────────────────────────────────────────────────────────
#  OSD speed bits: quasi-static, registered through clock.sv's bus-idle latch.
set_false_path -from [get_registers {*hps_io|status[56] *hps_io|status[57] *hps_io|status[58]}]

# ─── NextZ80 (rtl/cpu/cpuswap) ──────────────────────────────────────────────
#  Every register in NextZ80 is written only on an edge where its WAIT input is
#  low (nz_bus `adv`) or by LOAD.  `adv` needs nz_bus's phase flop set, and that
#  flop is cleared by every advance and by LOAD, so two NextZ80 writes are always
#  at least two clk21m edges apart (LOAD is additionally followed by FLIP and
#  SETTLE before the first advance).  NextZ80 -> NextZ80 is therefore a two-cycle
#  path.  Everything INTO NextZ80 from outside (WAIT, DI, INT, LDIR from T80s REG)
#  and NextZ80 XREG -> T80s DIR stays single-cycle.
#
#  NextZ80 -> everything on clk21m (both edges): two-cycle.  NextZ80's address, data
#  and strobes change only on an advance, and nz_bus masks every strobe for the
#  clock after it, so nothing qualified by a strobe (writes, `req`, the pacers and
#  guard, wait_n, I/O decodes, the SCC wave RAM write) can act on the first edge;
#  reads are sampled no earlier than the second.  NextZ80's address is combinational
#  out of its stage state (post-map ~9 ns deeper than T80s' into the same fabric),
#  so single-cycle would not close.  Core to core is two-cycle anyway: T80s
#  registers change only on CEN (withheld while NextZ80 owns the bus) or DIRSet,
#  which captures two edges after NextZ80's swap-point edge.
#  Audit of registers that sample the bare address every clock (grep `<= a`,
#  `[a]`): debug/forensics (fadr_p1, addr_d, dbg_*) and strobe-gated latches, except
#  the two single-cycle exceptions below.
set_multicycle_path -setup -end 2 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
#  Exceptions (node-to-node, so they outrank the clock-based rule above):
#   - the cheat lookup registers the bare address (a_q, the cheat RAMs' address
#     registers) and its result reaches d_to_cpu on a fast SDRAM read, which the
#     guard may release on the first visible clock (cache hit);
#   - NextZ80 SWAPPT -> cpuswap_ctl state: a late capture could tear the state.
set_multicycle_path -setup -end 1 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_registers {*msx:MSX|a_q[*] *cheat_ram* *msx:MSX|cpuswap_ctl:CPUSWAP|*}]
set_multicycle_path -hold  -end 0 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_registers {*msx:MSX|a_q[*] *cheat_ram* *msx:MSX|cpuswap_ctl:CPUSWAP|*}]
#  T80s -> NextZ80 and nz_bus's phase flop: NextZ80 captures only on an advance
#  (T80s frozen) or on LOAD, two edges after T80s' swap-point edge; ph only moves
#  while NextZ80 owns the bus (T80s' terms reach it through wait_n).
set_multicycle_path -setup -end 2 \
    -from [get_registers {*msx:MSX|T80s:T80|*}] \
    -to   [get_registers {*msx:MSX|NextZ80:NZ|* *msx:MSX|nz_bus:NZB|ph}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*msx:MSX|T80s:T80|*}] \
    -to   [get_registers {*msx:MSX|NextZ80:NZ|* *msx:MSX|nz_bus:NZB|ph}]
#  NextZ80 -> SDRAM ch2 needs nothing of its own: the generic -end 6 above is the
#  T80-at-10.74 head window (address one clk21m ahead of the strobe, + 2
#  clk_sdram), and nz_bus gives exactly that lead.
set_multicycle_path -setup -end 2 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_registers {*msx:MSX|NextZ80:NZ|*}]
set_multicycle_path -hold  -end 1 \
    -from [get_registers {*msx:MSX|NextZ80:NZ|*}] \
    -to   [get_registers {*msx:MSX|NextZ80:NZ|*}]

# ─── Debug overlay CDC ──────────────────────────────────────────────────────
#  rtl/debug_overlay.sv brings slow debug values into CLK_VIDEO through 2-FF
#  synchronisers named *_s1 -> *_s2.  The *_s1 input is asynchronous by design;
#  timing it only produces placement-luck hold misses (20260920e: -0.102 ns on
#  u_pcm ram_regs[6].keyon -> u_overlay keyon_s1[6], general[0] -> general[1]).
set_false_path -to [get_registers {*u_overlay|*_s1[*]}]

#  debug_overlay's CDC: the first stage of each two-flop synchroniser (and lvl_sync1)
#  takes signals from other clock domains on CLK_VIDEO.  In the V9968 build CLK_VIDEO is
#  clk_vdp, from the same PLL as clk_sdram, so TimeQuest times these as ordinary paths
#  (pcm_sync <- pcm_valid failed by 0.01 ns in MSX1_V9968 75c48e2).  They are
#  synchronisers by design: not timed.
set_false_path -to [get_registers {*debug_overlay:u_overlay|*_sync[0] *debug_overlay:u_overlay|lvl_sync1[*]}]

# V9968 build: the V9968's VRAM request (clk_vdp) into sdram_tdm (clk_sdram).  v9968_link
# locks the TDM so that every frame boundary (ps[11], the only state that reads v_req /
# v_addr / v_we / v_wdata / v_be) is the clk_sdram edge 7.76 ns after a shared rising
# edge, and the V9968 launches its request on shared edges.  TimeQuest takes the closer
# edge pair of the 2:3 ratio (3.88 ns), which these paths never use.  Measured
# (sim/v9968_vram/edge_probe.sv, RELEASE_PH 5, CPU / display / LRMM runs, 100k
# requests): every source change is 7.76 ns (bench 5.82 + its 1.94 ns clock offset)
# before the boundary that reads it, never 3.88.  Not a multicycle: -end 2 would allow
# 11.64 ns; the real budget is one clk_sdram period.  The reverse path (v_rvalid ->
# V9968) is a true 3.88 ns pair and stays default.
set v99_req [get_registers -nowarn {*u_vram_interface|ff_vram_valid* *u_vram_interface|ff_vram_address[*]* *u_vram_interface|ff_vram_write* *u_vram_interface|ff_vram_wdata[*]* *u_vram_interface|ff_vram_wdata_mask[*]*}]
if {[get_collection_size $v99_req] > 0} {
    set_max_delay -from $v99_req -to [get_registers {*sdram_tdm:sdram|*}] 7.760
}
