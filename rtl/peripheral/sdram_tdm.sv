//
// sdram_tdm -- fixed-slot SDRAM controller for 128.86 MHz (sdram128 study)
//
// Same channel ports as sdram.sv (ch1 upload, ch2 CPU + read cache, ch3 flash,
// ch4 PCM), plus one VRAM port served in a fixed slot every 12 clocks (one V9968
// slot at 85.909 MHz).  Design and the reasons for every number below:
// docs/sdram_tdm_design.md; the frame comes from tools/sdram128/tdm_solve.py.
//
//   cycle  0 V  ACT      4 G1 ACT      8 G2 ACT
//          3 V  READ     7 G1 READ    11 G2 READ
//          5 V  WRITE    9 G1 WRITE    1 G2 WRITE (next frame)
//          6 V  word1 mask  10 G1 mask 11   2 G2 mask 11
//
// CL3, BL2, write burst on, auto precharge on every access.  DQM is A[12:11]
// (MiSTer modules tie them), so a general ACT may carry row bits A12:A11 != 00
// only when the access before it is not a read (G1 after a V read, G2 after a
// G1 read are DQM-sensitive).  Two consecutive general accesses must hit
// different banks (tRC); refresh takes a frame per chip (section 5).
//
// The chip samples on SDRAM_CLK rising = clk falling (inverted clock out).  All
// chip-facing signals leave through one output register stage, so the chip sees
// the internal schedule one clock late; read data comes back through two falling
// edge registers and one rising (dq_n, dq_n2, dq_p -- see there for why).  Word0
// of a READ issued internally in cycle t is in dq_p during cycle t+7: V reads land
// at 10/11, G1 at 2, G2 at 6 of the next frame.
//
// This source file is free software under the GNU GPL v3 or later (sdram.sv,
// Sorgelig, 2015-2019, which it is derived from).
//
module sdram_tdm
#(
    parameter CACHE_LINES = 8192,
    parameter CLK_HZ      = 128863620
)
(
    input             init,
    input             clk,
    input             mode128,     // 1: 128 MB board map (two 64 MB chips)
    input             mode64,      // 1: 64 MB board (one chip, 32 MB map): general 24-32 MB moves to 32-40 MB
    input             v_en,        // VRAM port in use: its bank is reserved, V slots run
    //  v_go: the first frame starts on an edge where v_go is high (2026-10-21).  The
    //  VRAM port's client (v9968_link) runs on 85.909 MHz = 2/3 of this clock; it
    //  raises v_go one clk edge after an edge both clocks share, so every frame
    //  boundary lands 7.76 ns after a shared edge and a request launched on that
    //  shared edge has the whole clk period to arrive.  1'b1 = start as before.
    input             v_go,
    //  cpu_paced (clk21m domain, msx.sv): 0 = the stock T80s at 3.58 MHz, no WAIT, a
    //  fixed deadline; 1 = turbo T80s / NextZ80, handshaked.  Only the stock CPU's
    //  T-state grid is learnt and used (S4); a change clears what was learnt.
    input             cpu_paced,
    output     [3:0]  tdm_ph,      // the frame cycle 0..11 (v9968_link: VDP reset phase)
    output            tdm_run,     // frames are running (v9968_link holds the VDP until then)

    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_nCS,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_CKE,
    output            SDRAM_CLK,

    input      [26:0] ch1_addr,
    output      [7:0] ch1_dout,
    input       [7:0] ch1_din,
    input             ch1_req,
    input             ch1_rnw,
    output reg        ch1_ready,

    input      [26:0] ch2_addr,
    output      [7:0] ch2_dout,
    input       [7:0] ch2_din,
    input             ch2_req,
    input             ch2_rnw,
    output reg        ch2_ready,
    output reg        ch2_rdtog,
    output            ch2_hit,
    output            ch2_busy,    // the ch2 queue's second entry is taken: a paced CPU must not send another write

    input      [26:0] ch3_addr,
    output      [7:0] ch3_dout,
    input       [7:0] ch3_din,
    input             ch3_req,
    input             ch3_rnw,
    output reg        ch3_ready,
    output reg        ch3_done,

    input      [26:0] ch4_addr,
    output      [7:0] ch4_dout,
    output     [15:0] ch4_dout16,
    input       [7:0] ch4_din,
    input             ch4_req,
    input             ch4_rnw,
    output reg        ch4_ready,

    // VRAM: one 32-bit access per frame.  Present v_req with the rest before the
    // frame boundary (sampled at the edge that ends cycle 11); v_grant says this
    // frame took it (0 = refresh owned the slot, ask again).  Read data arrives
    // with v_rvalid; word0 (column 2n) is v_rdata[15:0].
    input             v_req,
    input             v_we,
    input      [15:0] v_addr,      // 32-bit word address, 256 KB
    input      [31:0] v_wdata,
    input       [3:0] v_be,        // byte enables, 1 = write that byte
    output reg        v_grant,
    output reg [31:0] v_rdata,
    output reg        v_rvalid
);

//  The board size is static (HPS sdram_sz), but it comes from another clock
//  domain and every slot decision depends on it: take it through one register
//  here so it is not part of those paths (722abff: g1/g2 <- sdram_sz, -2.2 ns).
reg m128 = 1'b0, m64 = 1'b0;
always @(posedge clk) begin m128 <= mode128; m64 <= mode64; end

// ─── timing (CLK_HZ) ───────────────────────────────────────────────────────
localparam int  PERIOD_PS   = 1000000000 / (CLK_HZ / 1000);
localparam int  RFSH_EVERY  = (7800000 / PERIOD_PS) - 60;  // 7.8 us/row; margin for 3 deferred frames + 1
//  The VRAM's chip with the V port in use (2026-10-21, plan S3): due this long after
//  its last REFRESH, then issued in the first frame with no V request (cycle 2, over by
//  the next frame's V ACT).  The rest, up to the 7.8125 us interval, is room to wait
//  for such a frame: (7812.5 - 3900) ns = 504 clocks = 42 frames.
localparam int  RFSH_EVERY_V = (3900000 / PERIOD_PS);
//  From here the wait is urgent: G2 keeps off the chip and G1 does not write it, so the
//  next frame without a V request can take the refresh.  Before it the refresh only
//  takes a frame where those hold anyway (no cost to the CPU): 24 frames before 7.8 us
//  (with a known CPU grid only every third frame can take it: 8 chances).
localparam int  RFSH_URG_V   = (7812500 / PERIOD_PS) - 24 * 12;
//  (the 7.8125 us interval is the model's and the distributed-refresh figure; whether
//  the parts allow postponing is not assumed)
localparam int  INIT_CYCLES = (200000000 / PERIOD_PS);     // 200 us power-up
localparam [12:0] MODE      = 13'b000_0_00_011_0_001;     // write burst, CL3, sequential, BL2
localparam [26:0] VBASE128  = 27'h1C00000;                // 28 MB: chip 1, bank 3
localparam [26:0] VBASE32   = 27'h1800000;                // 24 MB: bank 3

localparam [2:0] CMD_NOP = 3'b111, CMD_ACT = 3'b011, CMD_READ = 3'b101, CMD_WRITE = 3'b100,
                 CMD_PRE = 3'b010, CMD_REF = 3'b001, CMD_MRS = 3'b000;

//  Everything below drives the internal copies (command, chip, a_i, ba_i,
//  dq_out, dq_oe); one register stage takes them to the pins, so the slot logic
//  never routes straight into an IO register (-1.68 ns in d2efe8d).  The whole
//  chip-side schedule is one clock later than the internal one, uniformly.
reg  [2:0] command = CMD_NOP;
reg        chip    = 1'b0;
reg [12:0] a_i     = 13'd0;
reg  [1:0] ba_i    = 2'd0;
reg [15:0] dq_out;
reg        dq_oe   = 1'b0;
reg  [2:0] cmd_o   = CMD_NOP;
reg        cs_o    = 1'b0;
reg [15:0] dq_o_r;
reg        dq_oe_o = 1'b0;
always @(posedge clk) begin
    SDRAM_A <= a_i;   SDRAM_BA <= ba_i;   cmd_o <= command;   cs_o <= chip;
    dq_o_r  <= dq_out; dq_oe_o <= dq_oe;
end
assign SDRAM_nCS  = cs_o;
assign SDRAM_nRAS = cmd_o[2];
assign SDRAM_nCAS = cmd_o[1];
assign SDRAM_nWE  = cmd_o[0];
assign SDRAM_CKE  = 1'b1;
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
assign SDRAM_DQ = dq_oe_o ? dq_o_r : 16'bz;

//  Read data.  STA with tools/sdram128/sdram_io.sdc on a253d77: SDRAM_CLK leaves
//  the pin 3.77 ns after the internal clock (DDIO + output buffer), so the chip
//  edge is ~7.65 ns after an internal rising edge, and a word reaches the input
//  register 8.5-12.6 ns after the chip edge that launches it (tAC 5.4 + board +
//  input 2.4 ns; tOH 2.5 for the end).  Counted from the internal clock that is
//  a window around a FALLING edge (+0.6 .. +4.7 ns after the rising edge two
//  clocks on, falling edge at +3.88), with no rising edge inside: the rising-edge
//  capture of a253d77 was 0.9 ns early.  So: falling-edge IO register (dq_n), a
//  falling-edge fabric register (a full clock from the pad), then rising (dq_p,
//  half a clock fabric to fabric).  The board delays (0.3-0.7 ns) are assumed.
reg [15:0] dq_n, dq_n2, dq_p;
always @(negedge clk) begin dq_n <= SDRAM_DQ; dq_n2 <= dq_n; end
always @(posedge clk) dq_p <= dq_n2;

// ─── address map ───────────────────────────────────────────────────────────
//  32 MB (and 64 MB): bank = a[24:23], row = a[22:10], col = {a[25], a[9:1]},
//  chip = a[26] -- the map sdram.sv uses.  128 MB: row[12:11] = w[25:24] so all of
//  0-32 MB has row bits 00; chip = w[23]; chip 0 interleaves banks every 2 KB,
//  chip 1 keeps 4 MB banks and bank 3 (28-32 MB) is the VRAM's.
typedef struct packed { logic c; logic [1:0] b; logic [12:0] r; logic [9:0] k; } loc_t;
function automatic loc_t map(input [26:0] a, input m);
    loc_t l;
    logic [25:0] w;
    w = a[26:1];
    if (!m) begin
        l.c = a[26]; l.b = a[24:23]; l.r = a[22:10]; l.k = {a[25], a[9:1]};
    end else begin
        l.c = w[23];
        l.r[12:11] = w[25:24];
        l.k = w[9:0];
        if (!w[23]) begin l.b = w[11:10]; l.r[10:0] = w[22:12]; end
        else        begin l.b = w[22:21]; l.r[10:0] = w[20:10]; end
    end
    return l;
endfunction

//  General (non-VRAM) addresses only.  The 32 MB map gives bank 3 (24-32 MB) to the
//  VRAM; on a 64 MB board the column MSB a[25] reaches the other half of every
//  row, so logical 24-32 MB is moved to 32-40 MB (bank 0, upper half, same row
//  bits) and the general area is a contiguous 32 MB there -- a 4 MB machine with
//  MoonSound and two 8 MB carts (24.42 MB) fits.  The V path calls map() directly.
function automatic loc_t gmap(input [26:0] a, input m, input m64);
    logic [26:0] p;
`ifndef TDM_MUT_NO64        // negative control: no move (the VRAM bank refuses 24-32 MB)
    p = (m64 && !m && a[26:23] == 4'b0011) ? {a[26], 3'b100, a[22:0]} : a;
`else
    p = a;
`endif
    return map(p, m);
endfunction

// ─── frame ─────────────────────────────────────────────────────────────────
reg  [3:0] ph = 4'd0;            // the frame cycle (kept for benches)
assign tdm_ph = ph;
assign tdm_run = run;
reg [11:0] ps = 12'd1;           // the same, one-hot: every decode below is one bit
reg        run = 1'b0;           // init sequence done

// ─── requests (as sdram.sv) and the ch2 read cache ─────────────────────────
reg        ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1;
//  ch2_req_s: the CPU request, sampled ONCE (2026-10-19).  Every ch2 decision
//  below -- the edge detector ch2_req_1, the cache lookup ch2_cpend, the queue
//  ch2_rq / ch2_bv, the hit level -- used to read the live ch2_req.  That input
//  comes from the clk21m strobes through msx_slots' sdram_ce, 14-15.5 ns in the
//  slow model, and reaches those registers up to 1.1 ns apart (20261019a fit,
//  docs/evidence_20261019/field_race_601e17d.txt): an edge inside that window
//  gave req_1 the request and cpend not, req & ~req_1 was never true, and the
//  request was lost (the stock T80 then took whatever byte the bus held).  Now
//  only ch2_req_s looks at ch2_req; MSX1.sdc gives the strobe -> ch2_req_s path
//  the second edge (-end 2), so STA proves it is 1 by then.  On the first edge it
//  can still go metastable -- one register instead of four, with a whole
//  clk_sdram cycle to settle before anything reads it.  The fields (addr, rnw,
//  din) are captured one edge after ch2_req_s rose, i.e. on edge 2 at the
//  earliest, which also covers T80 DO (9.5 ns on 20261019a) and ram_rnw.
//  Cost: one clk_sdram (7.76 ns) on every CPU access; fullsys measured 69.8 ns of
//  T80 margin left in the worst frame position with this exact delay (0d7da22).
//  -DSDRAM_NO_REQS (sim only): the live ch2_req, as before (negative control).
reg        ch2_req_s;
`ifndef SDRAM_NO_REQS
wire       ch2_rqv = ch2_req_s;
`else
wire       ch2_rqv = ch2_req;
`endif
reg        ch1_rq, ch2_rq, ch3_rq, ch4_rq;
reg        ch1_rnw_1, ch2_rnw_1, ch3_rnw_1, ch4_rnw_1;
reg [26:0] ch1_addr_1, ch2_addr_1, ch3_addr_1, ch4_addr_1;
reg  [7:0] ch1_din_1, ch2_din_1, ch3_din_1, ch4_din_1;
reg [15:0] ch1_saved_data, ch2_saved_data, ch3_saved_data, ch4_saved_data;
reg        ch1_saved_a0, ch2_saved_a0, ch3_saved_a0, ch4_saved_a0;
initial begin
    {ch1_rq, ch2_rq, ch3_rq, ch4_rq} = '0;
    {ch1_ready, ch2_ready, ch3_ready, ch4_ready, ch3_done, ch2_rdtog} = '0;
    {ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1, ch2_req_s} = '0;
    v_grant = 0; v_rvalid = 0;
end
assign ch1_dout   = ch1_saved_a0 ? ch1_saved_data[15:8] : ch1_saved_data[7:0];
assign ch2_dout   = ch2_saved_a0 ? ch2_saved_data[15:8] : ch2_saved_data[7:0];
assign ch3_dout   = ch3_saved_a0 ? ch3_saved_data[15:8] : ch3_saved_data[7:0];
assign ch4_dout   = ch4_saved_a0 ? ch4_saved_data[15:8] : ch4_saved_data[7:0];
assign ch4_dout16 = ch4_saved_data;

//  The cache is sdram.sv's (see the long note there): direct mapped, one word a
//  line, index registered (ch2_caddr) so the clk21m hop stays inside MSX1.sdc's
//  {*sdram*ch2_*} multicycle, fill at ch2 read capture, drop by index at every
//  write issue, a lookup that overlaps a write to its index misses.
localparam CL = (CACHE_LINES > 1) ? CACHE_LINES : 2;
localparam CW = $clog2(CL);
localparam LW = 1 + (26 - CW) + 16;
reg  [LW-1:0] cmem [0:CL-1];
reg  [LW-1:0] c_rdata;
reg           c_we = 1'b0, c_we_d = 1'b0;
reg  [CW-1:0] c_waddr, c_waddr_d;
reg  [LW-1:0] c_wdata;
reg           c_flush = 1'b1;
reg  [CW-1:0] c_flush_idx = '0;
reg           ch2_cpend = 1'b0, c_pend2 = 1'b0, c_pend3 = 1'b0;
reg           c_hit_q;           // stage 3: the compare, registered
reg  [15:0]   c_word_q;
reg  [26:0]   ch2_caddr;
reg           ch2_hit_r = 1'b0;
assign ch2_hit = ch2_hit_r;
//  Back-pressure for the paced CPU (msx.sv guard): while a request sits in the
//  second entry, the write whose window is open is that one, and holding the
//  window keeps the next request from finding the queue full.  An R800 writing
//  every ~14 clocks outruns one slot per frame in one bank (ch2_ovf in
//  sim/sdram_tdm +r800wr, 2026-10-14).
`ifndef TDM_MUT_NOBUSY
assign ch2_busy = ch2_bv;
`else
assign ch2_busy = 1'b0;
`endif
always @(posedge clk) begin
    if (c_we) cmem[c_waddr] <= c_wdata;
    c_rdata   <= cmem[ch2_caddr[CW:1]];
    c_we_d    <= c_we;
    c_waddr_d <= c_waddr;
end
wire [CW-1:0] c_pidx   = ch2_caddr[CW:1];
wire          c_hazard = (c_we && c_waddr == c_pidx) | (c_we_d && c_waddr_d == c_pidx);
wire          c_match  = c_rdata[LW-1] && c_rdata[LW-2:16] == ch2_caddr[26:CW+1];

// ─── slot state ────────────────────────────────────────────────────────────
//  per general slot: which channel, the access, where it lands
typedef struct packed {
    logic        v;              // slot used
    logic [1:0]  ch;             // 0..3 = ch1..ch4
    logic        rnw;
    logic        a0;
    logic [7:0]  din;
    logic [25:0] word;           // for the ch2 cache fill
    loc_t        l;
} gslot_t;
gslot_t g1, g2;                  // decided at cycle 2 / 6, issued from 4 / 8
loc_t   ch2_hl;                      // the latest CPU request's location (bank reservation)
reg     ch2_bv = 1'b0, ch2_brnw;      // ch2 queue, second entry
reg [26:0] ch2_baddr;
reg  [7:0] ch2_bdin;
reg     ch2_ovf = 1'b0;              // a ch2 write found the queue full (never expected)
logic   enq, enq_rnw, enq_rd;
logic [26:0] enq_addr;
logic  [7:0] enq_din;
reg     ch2_rdwait = 1'b0;       // a ch2 read waits for a queued ch2 write to be picked
wire    c2_hit_now;              // the cache answers the ch2 read on this edge
reg     prev_v;                  // the general slot before this one was used ...
reg     prev_c;                  //   ... on this chip
reg [1:0] prev_b;                //   ... and this bank
//  a hit answers only with no ch2 access queued (ch2_saved_data must not be replaced under it)
//  and not on the edge a picked write is about to drop its line: the drop is issued with
//  the ACT, one edge after the pick (sdram.sv dropped on the pick itself), so on that edge
//  the queue is already empty, c_we not yet up and the line still valid -- an R800
//  LD (HL),A / LD A,(HL) read the old byte (sim/sdram_tdm +r800wr, 2026-10-14).
wire          c_drop_due = (ps[3] && g1.v && !g1.rnw && g1.word[CW-1:0] == c_pidx)
                         | (ps[7] && g2.v && !g2.rnw && g2.word[CW-1:0] == c_pidx);
`ifndef TDM_MUT_DROPGAP     // negative control: the gap open
assign c2_hit_now = c_pend3 && c_hit_q && ~ch2_rq && ~ch2_bv && ~(c_we && c_waddr == c_pidx) && ~c_drop_due;
`else
assign c2_hit_now = c_pend3 && c_hit_q && ~ch2_rq && ~ch2_bv && ~(c_we && c_waddr == c_pidx);
`endif

reg        vs_v, vs_we;          // this frame's V access
loc_t      vs_l;
reg [31:0] vs_wdata;
reg  [3:0] vs_be;

// ─── refresh ───────────────────────────────────────────────────────────────
//  per chip: due every RFSH_EVERY clocks.  A refresh frame n blocks the chip for
//  V, G1, G2 of n and V, G1 of n+1; REFRESH is issued in cycle 10 of n (all banks
//  closed by cycle 7: the last write, G2 of n-1, precharges at ACT+11).
reg [10:0] rf_cnt [0:1];
reg  [1:0] rf_due;
reg  [1:0] rf_now, rf_next;
reg  [1:0] rf_late;              // frames a due refresh has been deferred for the CPU      // chip blocked this frame / blocked for V,G1 next frame
//  The VRAM chip's refresh with v_en (plan S3).  A REFRESH in cycle 10 (above) runs
//  into the next frame and costs two V slots; the V9968 has no stall, so a refused V
//  request is a lost write or a read it waits for for ever.  Instead, with v_en, the
//  VRAM's chip refreshes only in a frame whose boundary saw no V request, in cycle 2:
//  10 clocks (77.6 ns) to the next frame's V ACT, enough for tRFC 70 ns (the model's
//  conservative value; the AS4C32M16SB -7 sheet says 63, other boards' chips may differ).
//  Closed by cycle 2: the previous frame's V (ACT 0: 9/11) and a G1 read (ACT 4: 13 =
//  cycle 1); not a G1 write (15 = cycle 3) or its G2 (ACT 8: 17/19).  So the boundary
//  takes the refresh only if the previous frame's G2 was not on this chip and its G1
//  did not write it, and while the refresh waits, G2 keeps off this chip and G1 does not
//  write it.  The frame's own G1 and G2 are blocked on the chip (rf_now) as before; the
//  next frame is not (rf_next stays 0).
reg        rf_early = 1'b0;      // this frame's rf_now is a cycle-3 VRAM-chip refresh
reg [10:0] rf_vcnt = '0;         // clocks since the VRAM chip's last REFRESH (v_en)
wire       rf_vdue = v_en && (rf_vcnt >= 11'(RFSH_EVERY_V));
wire       rf_vurg = v_en && (rf_vcnt >= 11'(RFSH_URG_V));
//  Plan S4: a stock CPU (no handshake, fixed deadline) asks on a fixed grid: one T-state
//  of 3.58 MHz is exactly 3 frames, so its requests come in the same frame of every
//  three.  An early refresh in that frame costs the request its G slot (the chip is
//  busy cycles 2-11; a request seen in cycles 0-1 cancels it, later ones lose G2, and
//  E0+28 is missed).  cpos counts frames mod 3; cmask[k] = the CPU needed a G slot in a
//  frame at position k: a request first seen in cycles 0-5 is served by that frame's G1
//  or G2, one seen later by the next frame's G1 (cleared every 1024 frames).  Before
//  urgent, no early refresh in a masked position.  All three masked = not a stock grid (turbo,
//  R800, NextZ80 pace themselves with a handshake): the mask is ignored.
reg  [1:0] paced_s = 2'b11;      // cpu_paced through two flops (a level that changes rarely)
reg        stock_d = 1'b0;
`ifndef TDM_MUT_NOPACED         // negative control: learn and use the grid whatever the CPU mode
wire       stock_cpu = ~paced_s[1];
`else
wire       stock_cpu = 1'b1;
`endif
reg  [1:0] cpos = 2'd0;          // this frame's position in the 3-frame T-state grid
reg  [2:0] cmask = 3'b000;
reg  [9:0] cmask_age = '0;
wire [1:0] cpos_next = (cpos == 2'd2) ? 2'd0 : cpos + 2'd1;
//  The grid known (exactly one position p in cmask): the urgent refresh goes in frame
//  p+2 and its G blocking (G2 off the chip, no G1 write to it) in frame p+1 only, so
//  the frame the CPU asks in (p) keeps its G1 and G2.  Unknown: any frame, as before.
wire       grid    = stock_cpu & ((cmask == 3'b001) | (cmask == 3'b010) | (cmask == 3'b100));
wire [1:0] gp      = cmask[0] ? 2'd0 : cmask[1] ? 2'd1 : 2'd2;
wire [1:0] gp1     = (gp == 2'd2) ? 2'd0 : gp + 2'd1;      // p+1
wire [1:0] gp2     = (gp == 2'd0) ? 2'd2 : gp - 2'd1;      // p+2 (= p-1)
wire       urg_blk = rf_vurg && (!grid || cpos == gp1);
wire       v_chip = m128;     // the VRAM's chip: 1 on 128 MB, 0 otherwise
//  A CPU read that arrives inside a refresh frame cancels it, up to the edge that
//  would issue the REFRESH (cycle 10): the frame's G slots open again and the
//  refresh is due again from the next frame boundary.  At stock speed the CPU has
//  a fixed deadline (E0+28 clocks, sim/sdram_tdm +stock) and a refresh frame
//  passes over three of its G decisions (34 clocks, 2026-10-13); the stock CPU
//  asks at most once in three frames, so the refresh goes in the next frame.
//  rf_late bounds deferral and cancellation together (RFSH_EVERY's margin).
wire       cpu_wait;
loc_t      c2_l;
wire       rf_cxl;


// ─── choose a general request for a slot ───────────────────────────────────
//  priority ch2 > ch1 > ch3 > ch4; a candidate is skipped if its bank is the one
//  the previous general access used (tRC), its row bits would hit a DQM-sensitive
//  ACT, its chip is refreshing, or it falls into the VRAM bank (never: the upload
//  map stops below it; the check keeps a bad address from breaking the V slot).
function automatic logic ok(input loc_t l, input logic sens, input logic blk_c0, input logic blk_c1,
                            input logic pv, input logic pc, input [1:0] pb, input logic m);
    logic bad;
`ifndef TDM_MUT_BANK
    bad = (pv && l.c == pc && l.b == pb)
`else           // negative control: no tRC rule between general slots
    bad = 1'b0
`endif
        | (sens && l.r[12:11] != 2'b00)
        | (l.c ? blk_c1 : blk_c0)
        | (v_en && l.b == 2'd3 && l.c == m);          // the VRAM bank, when there is a VRAM
    return !bad;
endfunction

reg  [3:0] cand_ok;
loc_t      cand_l [0:3];         // registered: map() of each channel's held address
reg  [3:0] rq_d;                 // the request was already up last cycle (cand_l is its)
reg        c2_hold;              // registered CPU reservation
//  (ch2_bv / ch2_rdwait are set only while ch2_rq is: not repeated here, they sat
//  on the slot decision path through rf_cxl, 29b9886 -0.110 ns)
assign cpu_wait = ch2_rq | ch2_cpend | c_pend2 | c_pend3;
`ifndef TDM_MUT_RFSLOW      // negative control: no cancellation (the 2026-10-13 controller)
assign rf_cxl = cpu_wait && rf_late != 2'd3 && (c2_l.c ? rf_now[1] : rf_now[0]) && !(ps[10] | ps[11]) && !rf_early;
`else
assign rf_cxl = 1'b0;
`endif
always @(posedge clk) begin
    cand_l[0] <= gmap(ch2_addr_1, m128, m64);
    cand_l[1] <= gmap(ch1_addr_1, m128, m64);
    cand_l[2] <= gmap(ch3_addr_1, m128, m64);
    cand_l[3] <= gmap(ch4_addr_1, m128, m64);
    rq_d      <= {ch4_rq, ch3_rq, ch1_rq, ch2_rq};
    c2_hold   <= ch2_cpend | c_pend2 | c_pend3 | ch2_rq | ch2_rdwait | ch2_bv;
    c2_l      <= gmap(ch2_rq ? ch2_addr_1 : ch2_caddr, m128, m64);
end
always_comb begin
    logic sens, b0, b1, rsv, hold;
    loc_t hl;
    // G1 (decided in cycle 2) is sensitive when V reads this frame; G2 (cycle 6)
    // when G1 reads.  The blocking set differs: G1 also sees rf_next.
`ifndef TDM_MUT_SENS
    sens = ps[2] ? (vs_v && !vs_we) : (g1.v && g1.rnw);
`else           // negative control (sim/sdram_tdm): ignore DQM-sensitive ACTs
    sens = 1'b0;
`endif
    b0   = (rf_now[0] & ~rf_cxl) | (ps[2] & rf_next[0]);
    b1   = (rf_now[1] & ~rf_cxl) | (ps[2] & rf_next[1]);
`ifndef TDM_MUT_VREF_NOG2   // negative control: G2 may take the VRAM chip while its refresh waits
`endif
    cand_ok[0] = ch2_rq & rq_d[0] & ok(cand_l[0], sens, b0, b1, prev_v, prev_c, prev_b, m128);
    //  The CPU's hold and location from the edge after its request, not a clock
    //  later through c2_hold/c2_l: the decision on that edge used to give the CPU's
    //  bank away (sim/sdram_tdm +stock +cpulow=2, "OB-" at 3 of 36 grid phases).
    //  ch2_hl is mapped from the request address on the request edge (a ch2_*
    //  register: MSX1.sdc's CPU-side multicycle covers its input); a comb gmap
    //  here put the map into every slot decision (722abff, -2.2 ns).
`ifndef TDM_MUT_LATEHOLD
    hold = c2_hold | ch2_cpend | ch2_rq;     // c2_hold carries ch2_bv / ch2_rdwait
    hl   = ch2_hl;
`else
    hold = c2_hold;
    hl   = c2_l;
`endif
    //  CPU bank reservation: while a CPU read is being looked up or waits, the
    //  other channels may not take its bank -- the slot after would then be closed
    //  to it by tRC, and at stock speed the CPU has a fixed deadline.  (32 MB banks
    //  are 8 MB, so without this ch2 lost a slot to almost every other access.)
    //  G1 read reservation: a waiting CPU access whose row bits are not 00 cannot
    //  take a DQM-sensitive G1 (after a V read) and can take G2 only if G1 is not a
    //  read.  So while it waits, nobody else gets G1 for a READ (writes still may):
    //  G2 stays open to it.  Without this, row bits 01 missed the stock deadline at
    //  every grid phase (sim/sdram_tdm +stock +cpulow=2, 1030 LATE of ~31k).
`ifndef TDM_MUT_NORSV
    rsv  = ps[2] & hold & ~cand_ok[0] & (hl.r[12:11] != 2'b00);
`else
    rsv  = 1'b0;
`endif
    cand_ok[1] = ch1_rq & rq_d[1] & ok(cand_l[1], sens, b0, b1, prev_v, prev_c, prev_b, m128) & ~(hold & ~cand_ok[0] & cand_l[1].c == hl.c & cand_l[1].b == hl.b) & ~(rsv & ch1_rnw_1);
    cand_ok[2] = ch3_rq & rq_d[2] & ok(cand_l[2], sens, b0, b1, prev_v, prev_c, prev_b, m128) & ~(hold & ~cand_ok[0] & cand_l[2].c == hl.c & cand_l[2].b == hl.b) & ~(rsv & ch3_rnw_1);
    cand_ok[3] = ch4_rq & rq_d[3] & ok(cand_l[3], sens, b0, b1, prev_v, prev_c, prev_b, m128) & ~(hold & ~cand_ok[0] & cand_l[3].c == hl.c & cand_l[3].b == hl.b) & ~(rsv & ch4_rnw_1);
`ifndef TDM_MUT_VREF_NOG1W
    //  the VRAM chip's refresh is urgent: in the frame before the one it is meant for,
    //  G2 keeps off that chip and G1 does not write it -- except for the CPU, whose
    //  stock deadline outranks the refresh's next chance three frames on (see rf_early)
    if (ps[2] && urg_blk) begin
        if (cand_l[1].c == v_chip && !ch1_rnw_1) cand_ok[1] = 1'b0;
        if (cand_l[2].c == v_chip && !ch3_rnw_1) cand_ok[2] = 1'b0;
        if (cand_l[3].c == v_chip && !ch4_rnw_1) cand_ok[3] = 1'b0;
    end
    if (ps[6] && urg_blk) begin
        if (cand_l[1].c == v_chip) cand_ok[1] = 1'b0;
        if (cand_l[2].c == v_chip) cand_ok[2] = 1'b0;
        if (cand_l[3].c == v_chip) cand_ok[3] = 1'b0;
    end
`endif
end

// ─── init ──────────────────────────────────────────────────────────────────
reg [15:0] init_cnt = INIT_CYCLES[15:0] + 16'd200;

always @(posedge clk) begin
    gslot_t pick;
    logic   took;
    loc_t   vl;
    logic [1:0] due_old;
    logic   vgo;

    ch2_req_s <= ch2_req;
    ch1_req_1 <= ch1_req; ch2_req_1 <= ch2_rqv; ch3_req_1 <= ch3_req; ch4_req_1 <= ch4_req;
    c_we     <= 1'b0;
    v_rvalid <= 1'b0;
    command  <= CMD_NOP;

    // requests (sdram.sv semantics), except that ready falls AT the request edge.
    //  memory_upload and the flash bridge issue a one-clk21m request and take
    //  ready high two clk21m later (12 clocks here) as "done, send the next"
    //  (memory_upload.sv:542).  sdram.sv drops ready when it picks the request,
    //  1-2 clocks in; here the pick waits for a G slot (up to ~14 clocks), so the
    //  uploader saw the previous ready, sent the next byte over the pending one
    //  and the first was lost: BIOS word 04E6h read 00 in fullsys (2026-10-13).
    if (ch1_req & ~ch1_req_1) begin
        ch1_rq <= 1; ch1_rnw_1 <= ch1_rnw; ch1_addr_1 <= ch1_addr; ch1_din_1 <= ch1_din;
`ifndef TDM_MUT_RDY     // negative control: ready falls only at the pick
        ch1_ready <= 0;
`endif
    end
    if (~ch2_rqv) ch2_hit_r <= 0;
    //  ch2 queue: the head is ch2_rq / ch2_*_1 (what the slots pick), behind it one
    //  more entry, ch2_b*.  A paced CPU writes with no completion handshake (msx.sv
    //  GUARD_WR, 2 clk21m) and its next request follows 12-18 clocks later; a TDM
    //  slot can take longer than that, and the second request used to overwrite the
    //  queued one (a lost write; sdram.sv picked within a clock or two).  At most
    //  one request enters per edge: a write, a cache miss, or a read that waited.
    enq = 1'b0; enq_rnw = 1'b1; enq_addr = ch2_caddr; enq_din = ch2_din_1; enq_rd = 1'b0;
`ifndef TDM_MUT_NOGRID          // negative control: no T-state grid avoidance
    if (ch2_rqv & ~ch2_req_1 & stock_cpu) begin
        if (ph <= 4'd5) cmask[cpos] <= 1'b1; else cmask[cpos_next] <= 1'b1;
    end
`endif
    if (ch2_rqv & ~ch2_req_1) begin
        ch2_hl <= gmap(ch2_addr, m128, m64);
        if (CACHE_LINES != 0 && ch2_rnw) begin
            ch2_cpend <= 1;
            ch2_caddr <= ch2_addr;
            //  (Issuing the read in parallel with this lookup was tried, with a drop
            //  flag for hits: no change at any of 36 grid phases, rows 00 or 01 --
            //  the first decision is lost to the slot rules, not to these 3 clocks.)
        end else begin
            enq = 1'b1; enq_rnw = ch2_rnw; enq_addr = ch2_addr; enq_din = ch2_din;
        end
    end
    //  A write whose rnw came late.  The request and ram_rnw start from the same
    //  strobe, and on the 128.86 MHz fit rnw reaches the controller after the first
    //  edge the request can be seen on (T80 WR_n 13.5 ns, NextZ80 12.8 ns, slow
    //  model, against 7.76; docs/evidence_20261018/field_race_ae02602.txt), so that
    //  edge can take a write for a cache read and the write is lost (fullsys
    //  INJ_RNW).  STA puts rnw in by the second edge: look again there, and if the
    //  request turned out to be a write, drop the lookup and queue the write.  Reads
    //  keep their first-edge start -- the stock T80 takes its byte at a fixed time
    //  (sim/sdram_tdm +stock) and one edge later misses a slot at 3 of 36 phases.
    //  (2026-10-19: with ch2_req_s every request starts one edge later anyway, and
    //  this recheck reads ram_rnw yet one edge after that -- kept, it is harmless.)
    //  rnw only goes 1 -> 0 inside a request (a read's rnw does not move), so only
    //  this direction exists.  ch2_cpend is high on exactly the second edge, so
    //  ch2_req is not looked at, and the check sits INSIDE the ch2_cpend branch:
    //  091ba37 had it in front of the whole chain, which put the live CPU
    //  address -> sdram_ce cone on c_hit_q's enable (-22.6 ns slow).  Live
    //  ch2_rnw now reaches c_pend2 and the queue (ch2_*); MSX1.sdc gives c_pend2
    //  the second edge (-end 2), which is what this check assumes.
    if (ch2_cpend) begin
        ch2_cpend <= 0;
`ifndef SDRAM_NO_RNW2       // sim only: the first edge decides, as before
        if (~ch2_rnw) begin
            enq = 1'b1; enq_rnw = 1'b0; enq_addr = ch2_addr; enq_din = ch2_din;
        end else
`endif
        c_pend2   <= 1;
    end else if (c_pend2) begin
        //  compare registered (RAM out -> tag compare -> ch2_saved_data was -1.2 ns);
        //  a write to the index on this edge or the next still makes it a miss
        c_pend2  <= 0;
        c_pend3  <= 1;
        c_hit_q  <= ~c_flush && c_match && ~c_hazard;
        c_word_q <= c_rdata[15:0];
    end else if (c_pend3) begin
        c_pend3 <= 0;
        if (c2_hit_now) begin
            ch2_saved_data <= c_word_q;
            ch2_saved_a0   <= ch2_caddr[0];
            ch2_ready      <= 1;
            ch2_hit_r      <= 1;
        end else begin
            enq = 1'b1; enq_rd = 1'b1;            // a miss: queued behind any write
        end
    end
    if (ch2_rdwait) begin enq = 1'b1; enq_rd = 1'b1; end
    begin
        logic promo;
        promo = !ch2_rq && ch2_bv;
        if (promo) begin
            ch2_rq <= 1; ch2_rnw_1 <= ch2_brnw; ch2_addr_1 <= ch2_baddr; ch2_din_1 <= ch2_bdin;
            ch2_bv <= 0;
        end
        if (enq) begin
`ifndef TDM_MUT_RDOVER      // negative control: no second entry, a request replaces the queued one
            if (!ch2_rq && !ch2_bv) begin
                ch2_rq <= 1; ch2_rnw_1 <= enq_rnw; ch2_addr_1 <= enq_addr; ch2_din_1 <= enq_din;
                ch2_rdwait <= 0;
            end else if (!ch2_bv || promo) begin
                ch2_bv <= 1; ch2_brnw <= enq_rnw; ch2_baddr <= enq_addr; ch2_bdin <= enq_din;
                ch2_rdwait <= 0;
            end else if (enq_rd)
                ch2_rdwait <= 1;                   // full: the read tries again next edge
            else
                ch2_ovf <= 1;                      // full: a write is lost (sticky, benches fail on it)
`else
            ch2_rq <= 1; ch2_rnw_1 <= enq_rnw; ch2_addr_1 <= enq_addr; ch2_din_1 <= enq_din;
            ch2_rdwait <= 0;
`endif
        end
    end
    if (ch3_req & ~ch3_req_1) begin
        ch3_rq <= 1; ch3_rnw_1 <= ch3_rnw; ch3_addr_1 <= ch3_addr; ch3_din_1 <= ch3_din;
`ifndef TDM_MUT_RDY
        ch3_ready <= 0;
`endif
    end
    if (ch4_req & ~ch4_req_1) begin
        ch4_rq <= 1; ch4_rnw_1 <= ch4_rnw; ch4_addr_1 <= ch4_addr; ch4_din_1 <= ch4_din;
`ifndef TDM_MUT_RDY
        ch4_ready <= 0;
`endif
    end
    if (~ch3_req) ch3_done <= 0;

    if (!run) begin
        // ── power-up: wait, precharge all, 8 refreshes, mode, per chip ─────
        a_i <= 13'd0; ba_i <= 2'd0;
        if (init_cnt != 0) init_cnt <= init_cnt - 16'd1;
        //  per chip (chip 0 in 199..100, chip 1 in 99..0): precharge all, eight
        //  refreshes 11 clocks apart (tRFC), load mode, tMRD before the first frame
        case (init_cnt)
            16'd199, 16'd99: begin command <= CMD_PRE; a_i[10] <= 1'b1; end
            16'd195, 16'd184, 16'd173, 16'd162, 16'd151, 16'd140, 16'd129, 16'd118,
            16'd95,  16'd84,  16'd73,  16'd62,  16'd51,  16'd40,  16'd29,  16'd18:
                             command <= CMD_REF;
            16'd106, 16'd6:  begin command <= CMD_MRS; a_i <= MODE; end
            default: ;
        endcase
        chip <= (init_cnt < 16'd100);
        if (init_cnt == 0 && v_go) begin
            run <= 1'b1; ph <= 4'd0; ps <= 12'd1;
            ch1_ready <= 1; ch2_ready <= 1; ch3_ready <= 1; ch4_ready <= 1;
            g1.v <= 0; g2.v <= 0; prev_v <= 0; vs_v <= 0; v_grant <= 0;
            //  rf_vcnt starts a little in: the model (and the chip) count from the mode
            //  register, ~100 clocks before the first frame (as rf_cnt[0] does)
            rf_due <= 0; rf_now <= 0; rf_next <= 0; rf_late <= 0; rf_early <= 0; rf_vcnt <= 11'd200;
            //  first refresh soon after the mode register (the chip counts from its
            //  init refreshes: chip 0's are ~200 clocks back), the chips staggered
            rf_cnt[0] <= RFSH_EVERY[10:0] - 11'd100; rf_cnt[1] <= RFSH_EVERY[10:0] - 11'd600;
        end
    end else begin
        ph <= (ph == 4'd11) ? 4'd0 : ph + 4'd1;
        if (ps[11]) begin
            cpos <= cpos_next;
            cmask_age <= cmask_age + 10'd1;
            if (cmask_age == '1) cmask <= 3'b000;      // relearn (a mode change moves the grid)
        end
        paced_s <= {paced_s[0], cpu_paced};
        stock_d <= stock_cpu;
`ifndef TDM_MUT_NOPACED
        if (stock_cpu != stock_d) begin cmask <= 3'b000; cmask_age <= '0; end   // the CPU changed mode
`endif
        ps <= {ps[10:0], ps[11]};

        // refresh timers
        for (int c = 0; c < 2; c++) begin
            if (rf_cnt[c] >= RFSH_EVERY[10:0]) rf_cnt[c] <= 0;
            else                               rf_cnt[c] <= rf_cnt[c] + 11'd1;
        end

        // default address bus: the DQM a NOP cycle owes (00 unless set below)
        a_i[12:11] <= 2'b00;
        dq_oe <= 1'b0;

        case (1'b1)
        // cycle 11 -> frame boundary: V decision, refresh frame start
        ps[11]: begin
            //  one chip per refresh frame; the other stays due (a frame later
            //  is inside RFSH_EVERY's margin)
            //  A CPU read waiting (or being looked up) defers the refresh frame:
            //  the CPU has a fixed deadline at stock speed and a refresh frame costs
            //  it up to two slots.  rf_late bounds the deferral to three frames,
            //  inside RFSH_EVERY's 48-clock margin.
            rf_next <= rf_early ? 2'b00 : rf_now;
            //  (chip 1 exists only on 128 MB: its timer still runs on 32 MB, and an
            //  unmasked rf_due[1] kept every boundary "deferring", rf_late pinned at 3)
            //  With v_en the VRAM's chip is not in rf_due: it takes the early path below.
            due_old = rf_due & {m128, 1'b1} & ~(v_en ? (v_chip ? 2'b10 : 2'b01) : 2'b00);
`ifndef TDM_MUT_VREF_NOG2
            vgo = rf_vdue && !v_req && !(g2.v && g2.l.c == v_chip)
`ifndef TDM_MUT_NOGRID
                  && (rf_vurg ? (!grid || cpos_next == gp2) : (!stock_cpu || cmask == 3'b111 || !cmask[cpos_next]))
`endif
`ifndef TDM_MUT_VREF_NOG1W  // negative control: a G1 write on the chip may still be open
                  && !(g1.v && g1.l.c == v_chip && !g1.rnw)
`endif
                  ;
`else
            vgo = rf_vdue && !v_req;
`endif
            //  The VRAM chip's early refresh is deferred for a waiting CPU only before it is
            //  urgent: after that the CPU waits on the G blocking anyway, and deferring
            //  would only spend the frames the refresh can use (they are scarce).
            if ((due_old != 2'b00 || (vgo && !rf_vurg)) && cpu_wait && rf_late != 2'd3) begin
                rf_now  <= 2'b00; rf_early <= 1'b0;
                rf_late <= rf_late + 2'd1;
            end
            //  rf_late is cleared when the REFRESH is issued, not here: a frame
            //  started at the bound and then cancelled would restart the count
            //  and postpone the refresh without limit (7.822 us, sim/sdram_tdm)
            //  the other chip first: its cycle-10 refresh has 48 clocks of margin, the
            //  VRAM chip's early one 25 frames
            else if (due_old[0])           begin rf_now <= 2'b01; rf_due[0] <= 1'b0; rf_early <= 1'b0; end
            else if (due_old[1])           begin rf_now <= 2'b10; rf_due[1] <= 1'b0; rf_early <= 1'b0; end
            else if (vgo)                  begin rf_now <= v_chip ? 2'b10 : 2'b01; rf_early <= 1'b1; end
            //  (the deferral branch above may hold a frame where vgo was true: only for
            //  the other chip's cycle-10 refresh; rf_late stays bounded by it)
            else                           begin rf_now <= 2'b00; rf_early <= 1'b0; end
            vl = map((m128 ? VBASE128 : VBASE32) + {9'd0, v_addr, 2'b00}, m128);
            //  with v_en the VRAM's chip has no cycle-10 refresh: a V request is always taken
            took = v_en && v_req;
            vs_v <= took; vs_we <= v_we; vs_l <= vl; vs_wdata <= v_wdata; vs_be <= v_be;
            v_grant <= took;
            //  chip / bank / row are loaded whether or not V asks this frame: nothing else
            //  uses them on this edge, the row's A12:A11 are 0 for every V address (VBASE +
            //  18-bit word address), so the cycle-0 DQM stays 00, and a NOP ignores them.
            //  Only the command depends on v_req: the V9968's request (clk_vdp, 7.76 ns
            //  away) no longer enables 20-odd address flops (MSX1_V9968 f8fb45d: a_i <-
            //  ff_vram_address -0.162 ns at SEED 10, a_i <- ff_vram_valid -0.135 at SEED 11).
            chip <= vl.c; ba_i <= vl.b; a_i <= vl.r;
            if (took) command <= CMD_ACT;
        end
        ps[2]: begin         // V READ (cycle 3) / G1 decision
            if (vs_v && !vs_we) begin
                command <= CMD_READ; chip <= vs_l.c; ba_i <= vs_l.b;
                a_i <= {2'b00, 1'b1, vs_l.k};
            end
        end
        ps[4]: begin         // V WRITE (cycle 5): word0 with its byte mask
            if (vs_v && vs_we) begin
                command <= CMD_WRITE; chip <= vs_l.c; ba_i <= vs_l.b;
                a_i <= {~vs_be[1], ~vs_be[0], 1'b1, vs_l.k};
                dq_out <= vs_wdata[15:0]; dq_oe <= 1'b1;
            end
        end
        ps[5]: begin         // cycle 6: V word1 (mask on A12:A11), or 00 for a V read's DQM
            if (vs_v && vs_we) begin
                a_i[12:11] <= {~vs_be[3], ~vs_be[2]};
                dq_out <= vs_wdata[31:16]; dq_oe <= 1'b1;
            end
        end
        ps[10]: if (vs_v && !vs_we) v_rdata[15:0] <= dq_p;   // V word0
        default: ;
        endcase
        //  V word1 at the edge ending cycle 11 -- the one that also makes the next
        //  V decision, so it reads this frame's vs_* (they change on this edge)
        if (ps[11] && vs_v && !vs_we) begin v_rdata[31:16] <= dq_p; v_rvalid <= 1'b1; end

        // ── G1: decide in cycle 2, ACT 4, READ 7 / WRITE 9, mask 10 ───────────
        // ── G2: decide in cycle 6, ACT 8, READ 11 / WRITE 1, mask 2 ───────────
        if (ps[2] || ps[6]) begin
            pick = '0;
            if      (cand_ok[0]) begin pick.v = 1; pick.ch = 2'd1; pick.rnw = ch2_rnw_1; pick.a0 = ch2_addr_1[0];
                                       pick.din = ch2_din_1; pick.word = ch2_addr_1[26:1]; pick.l = cand_l[0]; end
            else if (cand_ok[1]) begin pick.v = 1; pick.ch = 2'd0; pick.rnw = ch1_rnw_1; pick.a0 = ch1_addr_1[0];
                                       pick.din = ch1_din_1; pick.word = ch1_addr_1[26:1]; pick.l = cand_l[1]; end
            else if (cand_ok[2]) begin pick.v = 1; pick.ch = 2'd2; pick.rnw = ch3_rnw_1; pick.a0 = ch3_addr_1[0];
                                       pick.din = ch3_din_1; pick.word = ch3_addr_1[26:1]; pick.l = cand_l[2]; end
            else if (cand_ok[3]) begin pick.v = 1; pick.ch = 2'd3; pick.rnw = ch4_rnw_1; pick.a0 = ch4_addr_1[0];
                                       pick.din = ch4_din_1; pick.word = ch4_addr_1[26:1]; pick.l = cand_l[3]; end
            //  chN_saved_a0 is taken with the data (read capture below), not here: on
            //  this edge it hung off the whole cand_ok cone (ch2_saved_a0 <- ps -0.130 ns
            //  on the 13e72cd fit, 2026-10-20), and a0 and data now change together
            if (pick.v) begin
                case (pick.ch)
                    2'd0: begin ch1_rq <= 0; ch1_ready <= 0; end
                    2'd1: begin ch2_rq <= 0; ch2_ready <= 0; end
                    2'd2: begin ch3_rq <= 0; ch3_ready <= 0; end
                    2'd3: begin ch4_rq <= 0; ch4_ready <= 0; end
                endcase
            end
            if (ps[2]) g1 <= pick; else g2 <= pick;
            prev_v <= pick.v;
            if (pick.v) begin prev_c <= pick.l.c; prev_b <= pick.l.b; end
        end

        // ACT (cycles 4, 8) and the cache drop for a write (by index, as sdram.sv)
        //  ACT; a write drops its cache line here (by index, as sdram.sv) -- the
        //  read fills come in cycles 2 and 6, so the port is free in 3 and 7
        if (ps[3] && g1.v) begin
            command <= CMD_ACT; chip <= g1.l.c; ba_i <= g1.l.b; a_i <= g1.l.r;
            if (!g1.rnw) begin c_we <= 1; c_waddr <= g1.word[CW-1:0]; c_wdata <= '0; end
        end
        if (ps[7] && g2.v) begin
            command <= CMD_ACT; chip <= g2.l.c; ba_i <= g2.l.b; a_i <= g2.l.r;
            if (!g2.rnw) begin c_we <= 1; c_waddr <= g2.word[CW-1:0]; c_wdata <= '0; end
        end
        // READ (cycles 7, 11)
        if (ps[6] && g1.v && g1.rnw) begin
            command <= CMD_READ; chip <= g1.l.c; ba_i <= g1.l.b; a_i <= {2'b00, 1'b1, g1.l.k};
        end
        if (ps[10] && g2.v && g2.rnw) begin
            command <= CMD_READ; chip <= g2.l.c; ba_i <= g2.l.b; a_i <= {2'b00, 1'b1, g2.l.k};
        end
        // WRITE (cycles 9, 1): one byte, the other byte and word1 masked
        if ((ps[8] && g1.v && !g1.rnw) || (ps[0] && g2.v && !g2.rnw)) begin
            gslot_t g;
            g = ps[8] ? g1 : g2;
            command <= CMD_WRITE; chip <= g.l.c; ba_i <= g.l.b;
            a_i <= {~g.a0, g.a0, 1'b1, g.l.k};
            dq_out <= {g.din, g.din}; dq_oe <= 1'b1;
            case (g.ch)
                2'd0: ch1_ready <= 1;
                2'd1: ch2_ready <= 1;
                2'd2: begin ch3_ready <= 1; ch3_done <= 1; end
                2'd3: ch4_ready <= 1;
            endcase
        end
        // word1 mask (cycles 10, 2)
        if ((ps[9] && g1.v && !g1.rnw) || (ps[1] && g2.v && !g2.rnw))
            a_i[12:11] <= 2'b11;

        // read capture from dq_p: G1 word0 at the edge ending cycle 2 (next frame),
        // G2 at cycle 6 -- the same edges that decide the next G1/G2, so g1/g2
        // read here are still this access's
`ifdef TDM_MUT_CAP          // negative control: one clock late
        if ((ps[3] && g1.v && g1.rnw) || (ps[7] && g2.v && g2.rnw)) begin
`elsif TDM_MUT_CAPE         // negative control: one clock early
        if ((ps[1] && g1.v && g1.rnw) || (ps[5] && g2.v && g2.rnw)) begin
`else
        if ((ps[2] && g1.v && g1.rnw) || (ps[6] && g2.v && g2.rnw)) begin
`endif
            gslot_t g;
            g = (ps[1] | ps[2] | ps[3]) ? g1 : g2;
            case (g.ch)
                2'd0: begin ch1_saved_data <= dq_p; ch1_saved_a0 <= g.a0; ch1_ready <= 1; end
                2'd1: begin
`ifndef TDM_MUT_A0          // negative control: ch2's byte select left from the access before
                    ch2_saved_a0 <= g.a0;
`endif
                    ch2_saved_data <= dq_p; ch2_ready <= 1; ch2_rdtog <= ~ch2_rdtog;
                    c_we <= 1; c_waddr <= g.word[CW-1:0]; c_wdata <= {1'b1, g.word[25:CW], dq_p};
                end
                2'd2: begin ch3_saved_data <= dq_p; ch3_saved_a0 <= g.a0; ch3_ready <= 1; end
                2'd3: begin ch4_saved_data <= dq_p; ch4_saved_a0 <= g.a0; ch4_ready <= 1; end
            endcase
        end

        if (rf_cxl) begin                // see rf_cxl: back to due, not done
            rf_due  <= rf_due | rf_now;
            rf_now  <= 2'b00;
            rf_late <= rf_late + 2'd1;
        end
        for (int c = 0; c < 2; c++)
            if (rf_cnt[c] >= RFSH_EVERY[10:0] && !(v_en && c == int'(v_chip))) rf_due[c] <= 1'b1;
        if (rf_vcnt != '1) rf_vcnt <= rf_vcnt + 11'd1;

        //  the VRAM chip's REFRESH, cycle 2 of a frame with no V request (see rf_early)
`ifdef TDM_MUT_VREF_LATE       // negative control: a clock late (cycle 3: 70 ns tRFC overruns the next V ACT)
        if (ps[2] && rf_early && rf_now != 2'b00) begin
`else
        if (ps[1] && rf_early && rf_now != 2'b00) begin
`endif
`ifndef TDM_MUT_VREF_NOCXL     // negative control: a CPU arriving in cycles 0-1 does not cancel it
            if (cpu_wait && !rf_vurg) begin
                //  a CPU request came in before the REFRESH went out and the refresh is not
                //  urgent: give the frame's G slots back (G1 is decided on the next edge)
                rf_now <= 2'b00; rf_early <= 1'b0;
            end else
`endif
            begin
`ifndef TDM_SIM_NO_VCHIP_REFRESH
                command <= CMD_REF;
                chip    <= rf_now[1];
`endif
                rf_late <= 2'd0;
                rf_vcnt <= '0;
            end
        end

        // REFRESH in cycle 10 of a refresh frame, on the chip it is for.  Cycle 10
        // may owe G1's word1 mask (11): the REFRESH carries it on A12:A11.
`ifndef TDM_MUT_NOREF
        if (ps[9] && rf_now != 2'b00 && !rf_cxl && !rf_early) begin
            rf_late <= 2'd0;
`else           // negative control: refresh frames are kept but nothing is refreshed
        if (1'b0) begin
`endif
            command <= CMD_REF;
            chip    <= rf_now[1];
        end
    end

    // valid-bit sweep (sdram.sv): wins the write port while it runs
    if (c_flush && ~init) begin
        c_we <= 1; c_waddr <= c_flush_idx; c_wdata <= '0;
        c_flush_idx <= c_flush_idx + 1'b1;
        if (&c_flush_idx) c_flush <= 0;
    end

    if (init) begin
        run <= 1'b0;
        init_cnt <= INIT_CYCLES[15:0] + 16'd200;
        c_flush <= 1; c_flush_idx <= '0;
        ch2_cpend <= 0; c_pend2 <= 0; c_pend3 <= 0; ch2_hit_r <= 0;
        ch2_rdwait <= 0; ch2_bv <= 0;
        dq_oe <= 1'b0;
    end
end

altddio_out
#(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
)
sdramclk_ddr
(
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

endmodule
