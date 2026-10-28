`default_nettype none
// ═══════════════════════════════════════════════════════════════════════════
// YMF278B PCM engine v4 -- from-scratch rebuild (docs/opl4_scratch/PLAN.md, DESIGN.md)
// ═══════════════════════════════════════════════════════════════════════════
// P3: the datapath on top of the P2 CPU side.  Slot processing is split in two
// passes (DESIGN sections 1-6):
//   * pass A (control) runs the 24 slots of frame N bunched from T_K of frame
//     N-1: it reads the registers and the slot state, steps pitch, position,
//     envelope, LFO and TL, puts the slot's memory pairs into the request FIFO
//     and leaves a two-word plan for pass B.  It never waits for memory;
//   * pass B (data) takes slot s at the fixed cycle C_s of frame N, picks the
//     two samples out of the pairs that came back, interpolates, applies the
//     gains and accumulates.  A slot whose data is not in by C_s is late: it
//     plays its previous sample (or 0 right after a restart) and counts in
//     dbg_late_cnt (SPEC F-LATE).
// One memory sequencer owns the port: CPU memory op first, then the earlier
// deadline of the header fetch and the FIFO head.  A read returns an aligned
// 4-byte pair: word0 on mem_rd_data16, word1 on mem_rd_data16b.
//
// CPU-visible semantics as the P2 skeleton (SPEC sections B-C):
//   * the wave-memory port follows openMSX (DESIGN decision 1, 2026-10-26): reg 2
//     bit 0 gates reg 6 (D3), only a reg 5 write moves the address (D4), and a
//     reg 6 write refreshes the prefetched byte (D7);
//   * the slot registers live in ONE memory (RAM-R, 240 x 8, simple dual-port:
//     one M10K), not in 30 MLABs;
//   * a reg 6 write keeps cpu_mem_busy up until the write has left the ch4
//     bridge (PLAN goal 5), not only until it was issued -- the top then needs
//     no 1024-clk MEM_WRITE_DELAY to keep an R800 OTIR from outrunning SDRAM;
//   * a wave-number write that lands while that slot's header is being fetched
//     makes the fetch run again (engine2 stored the header of the old number);
//   * after reset the registers read as openMSX's reset leaves them (field 4 = 0,
//     fields 5-9 = wave 0's header), not engine2's 20h / 0 (cpuvis D10, D11).
`default_nettype none

import ymf278_pcm_alu_pkg::*;
import ymf278_pcm_eg_pkg::*;

module ymf278_pcm_engine3 #(
    parameter int CLK_HZ       = 85909090,
    parameter int SDRAM_RD_LAT = 6,       // unused (engine2 port compatibility)
    parameter int PIPE_FORCE   = -1       // unused (engine2 port compatibility)
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU register interface (ymf278b_regs -> top)
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_data,
    input  wire        reg_wr,
    input  wire        reg_rd,
    output logic [7:0] cpu_mem_rd_data,
    output logic       cpu_mem_busy,
    output logic [7:0] reg02_readback,
    //  Readback of the wave register at reg_addr (openMSX peekReg: the stored byte,
    //  header-loaded values included).  Registered: valid 3 clk after reg_addr.
    output logic [7:0] reg_rd_data,

    // SDRAM port (msx.sv ch4 bridge: edge-detected request, one at a time)
    output logic [21:0] mem_addr,
    output logic        mem_rd_en,
    input  wire  [7:0]  mem_rd_data,
    input  wire  [15:0] mem_rd_data16,   // [7:0] = even byte, [15:8] = odd byte
    input  wire  [15:0] mem_rd_data16b,  // the other word of the aligned pair (byte addr ^ 2)
    input  wire         mem_rd_valid,
    output logic        mem_wr_en,
    output logic [7:0]  mem_wr_data,
    input  wire         mem_busy,

    input  wire  [1:0]         pcm_vol,

    // Audio output
    output logic signed [15:0] pcm_left,
    output logic signed [15:0] pcm_right,
    output logic               pcm_valid,

    // Debug ports (engine2's set; the ones engine3 has no source for are 0)
    output logic [2:0]  dbg_wavetblhdr,
    output logic [23:0] dbg_hf_pending,
    output logic [8:0]  dbg_slot0_wave,
    output logic [9:0]  dbg_slot0_fn,
    output logic signed [3:0] dbg_slot0_oct,
    output logic        dbg_slot0_prvb,
    output logic        dbg_slot0_keyon,
    output logic        dbg_slot0_damp,
    output logic [3:0]  dbg_slot0_pan,
    output logic [3:0]  dbg_slot0_ar,
    output logic [3:0]  dbg_slot0_d1r,
    output logic [8:0]  dbg_slot5_wave,
    output logic [8:0]  dbg_slot23_wave,
    output logic [21:0] dbg_slot0_hdr_start,
    output logic [15:0] dbg_slot0_hdr_loop,
    output logic [15:0] dbg_slot0_hdr_end,
    output logic [2:0]  fm_mix_l_o,
    output logic [2:0]  fm_mix_r_o,
    output logic [1:0]  dbg_slot0_hdr_bits,
    output logic [15:0] dbg_slot0_dyn_pos,
    output logic [15:0] dbg_slot0_dyn_stepPtr,
    output logic [9:0]  dbg_slot0_dyn_env_vol,
    output logic [2:0]  dbg_slot0_dyn_env_state,
    output logic        dbg_stage_b_bytes_done,
    output logic        dbg_stage_advance,
    output logic        dbg_stage_b_valid,
    output logic [23:0] dbg_slot_keyon,
    output logic [23:0] dbg_slot_active,
    output logic [23:0] dbg_slot_envlive,
    //  slot-frames played without their data (SPEC F-LATE), saturating
    output logic [15:0] dbg_late_cnt
);

// ═══════════════════════════════════════════════════════════════════════════
// Frame and timeline (DESIGN section 3).  At 128.86 MHz: T_K = 2850, C_s = 190 +
// 116 s (C_23 = 2858), pass A's deadline for slot s = C_s - 128.
// ═══════════════════════════════════════════════════════════════════════════
localparam int CYCLES_PER_FRAME = CLK_HZ / 44100;
localparam int CPF              = CYCLES_PER_FRAME;
localparam int FRAME_W          = $clog2(CYCLES_PER_FRAME);
localparam int T_K              = CPF - 72;           // pass A start (previous frame)
localparam int T_C0             = 190;                // pass B, slot 0
localparam int T_CSTEP          = (CPF - 254) / 23;   // pass B slot spacing
localparam int T_AMARGIN        = 128;                // A must start a slot this long before C_s


logic [FRAME_W-1:0] frame_cycle;
logic [1:0]         bfr;              // frame index mod 4 (the frame pass B is in)
wire sample_start = (frame_cycle == FRAME_W'(CYCLES_PER_FRAME - 1));

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_cycle <= '0;
        bfr         <= '0;
    end else begin
        frame_cycle <= sample_start ? '0 : frame_cycle + 1'd1;
        if (sample_start) bfr <= bfr + 2'd1;
    end
end

function automatic logic [31:0][FRAME_W-1:0] mk_cs();
    for (int s = 0; s < 32; s++) mk_cs[s] = FRAME_W'(T_C0 + T_CSTEP * s);
endfunction
localparam logic [31:0][FRAME_W-1:0] CS_TAB = mk_cs();
function automatic logic [FRAME_W-1:0] cs_of(input logic [4:0] s);
    return CS_TAB[s];
endfunction

// ═══════════════════════════════════════════════════════════════════════════
// Register address decode: slot registers 08h-F7h are field f of slot s at
// 08h + 24f + s.  A compare ladder, not a divider.
// ═══════════════════════════════════════════════════════════════════════════
function automatic logic [8:0] slot_field(input logic [7:0] a);   // {field[3:0], slot[4:0]}
    logic [7:0] o;
    o = a - 8'h08;
    for (int f = 9; f >= 0; f--)
        if (o >= 8'(24 * f)) return {4'(f), 5'(o - 8'(24 * f))};
    return '0;
endfunction
wire [8:0] wr_sf       = slot_field(reg_addr);
wire [3:0] wr_field    = wr_sf[8:5];
wire [4:0] wr_snum     = wr_sf[4:0];
wire       is_slot_reg = (reg_addr >= 8'h08) && (reg_addr <= 8'hF7);
wire       wr_slot_reg = reg_wr && is_slot_reg;
wire [7:0] reg_word    = reg_addr - 8'h08;     // RAM-R word of a slot register

// Fields are stored as written.  (engine2 stores field 4 with bit 5 inverted, so its
// all-zero reset image reads back 20h; openMSX's reset writes 0 to every register,
// reads back 0 and leaves the LFO running: cpuvis D10.)

// ═══════════════════════════════════════════════════════════════════════════
// RAM-R: one byte per slot register, word = register - 08h (field f of slot s
// at 24f + s).  One write port, one read port: simple dual-port, one M10K.  (A
// 48 x 40 word with byte enables took 2 M10K as simple dual-port and 4 as true
// dual-port: Quartus 17.0 fit of the memory alone, 2026-10-25.)  Write port:
// the reset sweep, the header backfill, the CPU.  Read port: pass A (a field
// every other clk), the header fetch (the wave number) and, in every other
// cycle, the CPU readback.
// ═══════════════════════════════════════════════════════════════════════════
logic       rw_we;
logic [7:0] rw_addr, rw_d;
logic [7:0] rr_addr, rr_q;
pcm_regram u_regram (.clk, .we(rw_we), .waddr(rw_addr), .wd(rw_d), .raddr(rr_addr), .rd(rr_q));

// Reset: the memories have no reset, so the sweep below writes them while rst_n
// is low, counted from the fall of rst_n: RAM-R fields 5-9 first (words 120-239),
// then fields 0-4; RAM-S words 0-127 in the same count.  LOAD-BEARING: rst_n
// must stay low >= 240 clk (engine2: 24).  The MSX reset (MSX1.sv rst_hold, 63
// clk21m = 378 clk at 128.86 MHz) and upload_hold are longer.  A shorter reset
// misses the last words, field 4 of the top slots, which the reset header
// backfill does not rewrite: the harness `reset` gate runs the cpuvis warm reset
// at 240 (pass) and 239 (must fail).
wire        clr_run = ~rst_n;
logic [7:0] clr_cnt = '0;
always_ff @(posedge clk) clr_cnt <= rst_n ? 8'd0 : (clr_cnt == 8'd239) ? 8'd239 : clr_cnt + 8'd1;
wire  [7:0] clr_word = (clr_cnt < 8'd120) ? clr_cnt + 8'd120 : clr_cnt - 8'd120;

// header backfill (from the header FSM below): one field per cycle
logic        bf_now, bf_step;
logic [7:0]  bf_word;
logic [7:0]  bf_d;

// CPU slot-register write, queued one entry deep: it waits only for the reset
// sweep.  The header backfill takes the write port in the clks the queue leaves
// free, so back-to-back writes (the golden bench writes every 3 clk) never wait
// behind it.  A CPU write still wins over the header as openMSX's synchronous
// backfill does: the write marks its field dirty at reg_wr, and the backfill
// skips a dirty field.
logic        wq_v;
logic [7:0]  wq_word;
logic [7:0]  wq_d;
wire         wq_go = wq_v && !clr_run;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wq_v <= 1'b0;
    else begin
        if (wq_go) wq_v <= 1'b0;
        if (wr_slot_reg) begin
            wq_v    <= 1'b1;
            wq_word <= reg_word;
            wq_d    <= reg_data;
        end
    end
end
`ifndef SYNTHESIS
//  a lost register write: the cpuvis and memwr gates FAIL on this message
always @(posedge clk) if (rst_n && wr_slot_reg && wq_v && !wq_go)
    $error("ymf278_pcm_engine3: CPU write queue overflow (a slot-register write is lost)");
`endif

always_comb begin
    rw_we   = 1'b0;
    rw_addr = wq_word;
    rw_d    = wq_d;
    if (clr_run) begin
        rw_we = 1'b1; rw_addr = clr_word; rw_d = 8'h00;
    end else if (wq_v)
        rw_we = 1'b1;
    else if (bf_now) begin
        rw_we = 1'b1; rw_addr = bf_word; rw_d = bf_d;
    end
end

// Readback pipeline: address (q1), read port (q2), byte (reg_rd_data).  The read
// port is the engine's in the cycles it reads (eng_rd); the readback skips those
// and is taken again in the next cycle (reg_addr stays put for the whole I/O
// access).  A CPU write is passed straight to reg_rd_data in the next clk (the
// write goes to the latched register, the one being read): it reads back as early
// as on engine2, not 2 clk later through the write queue and the memory.
logic       a_rr_en, hf_rr_en;
logic [7:0] a_rr_addr, hf_rr_addr;
wire        eng_rd = a_rr_en | hf_rr_en;
logic [7:0] rd_word_q1;
logic       rd_ns_q1, rd_ns_q2, rd_upd_q2, rd_byp;
logic [7:0] rd_bypd;
logic [3:0] rd_nsidx_q1, rd_nsidx_q2;
wire        ns_hit = (reg_addr <= 8'h07) || (reg_addr >= 8'hF8);
wire [3:0]  ns_idx = {reg_addr[7], reg_addr[2:0]};
assign rr_addr = a_rr_en ? a_rr_addr : hf_rr_en ? hf_rr_addr : rd_word_q1;

logic [7:0] ns_reg [0:15];    // 00h-07h -> 0..7, F8h-FFh -> 8..15
always_ff @(posedge clk) begin
    rd_word_q1  <= reg_word;
    rd_ns_q1    <= ns_hit;
    rd_nsidx_q1 <= ns_idx;
    rd_ns_q2    <= rd_ns_q1;
    rd_nsidx_q2 <= rd_nsidx_q1;
    rd_upd_q2   <= !eng_rd && !(rw_we && rw_addr == rd_word_q1);
    rd_byp      <= wr_slot_reg;
    rd_bypd     <= reg_data;
    if (rd_byp)         reg_rd_data <= rd_bypd;
    else if (rd_ns_q2)  reg_rd_data <= ns_reg[rd_nsidx_q2];
    else if (rd_upd_q2) reg_rd_data <= rr_q;
end

// ═══════════════════════════════════════════════════════════════════════════
// Non-slot registers 00h-07h, F8h-FFh (plain shadow; reg 3 keeps 6 bits)
// ═══════════════════════════════════════════════════════════════════════════
logic [2:0] wavetblhdr;
logic       reg02_mem_access_mode, reg02_mem_type;
logic [2:0] fm_mix_l, fm_mix_r, pcm_mix_l, pcm_mix_r;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) ns_reg[i] <= 8'h00;
        wavetblhdr <= '0;
        reg02_mem_access_mode <= 1'b0;
        reg02_mem_type        <= 1'b0;
        fm_mix_l <= '0; fm_mix_r <= '0; pcm_mix_l <= '0; pcm_mix_r <= '0;
    end else if (reg_wr && ns_hit) begin
        ns_reg[ns_idx] <= (reg_addr == 8'h03) ? {2'b00, reg_data[5:0]} : reg_data;
        if (reg_addr == 8'h02) begin
            wavetblhdr            <= reg_data[4:2];
            reg02_mem_type        <= reg_data[1];   // stored for readback only (SPEC I8)
            reg02_mem_access_mode <= reg_data[0];   // gates reg 6 (D3)
        end
        if (reg_addr == 8'hF8) begin fm_mix_l  <= reg_data[2:0]; fm_mix_r  <= reg_data[5:3]; end
        if (reg_addr == 8'hF9) begin pcm_mix_l <= reg_data[2:0]; pcm_mix_r <= reg_data[5:3]; end
    end
end
assign reg02_readback = {3'b001, wavetblhdr, reg02_mem_type, reg02_mem_access_mode};

// ═══════════════════════════════════════════════════════════════════════════
// Per-slot flags set by CPU writes.  The write-time events of openMSX
// (YMF278.cc writeRegDirect) are latched here and consumed by pass A at the
// slot's next visit:
//   key_retrig  key-on edge, or a wave-number write while keyed on (keyOnHelper)
//   pos_clr     a wave-number write while keyed off (position reset only)
//   tl_load     a field 3 write with bit 0 (TL jumps to TLdest)
// One 4-bit word per slot {keyon, tl_load, pos_clr, key_retrig} in two MLAB
// copies (the CPU's read-modify-write reads at wr_snum, pass A at a_slot), one
// write port.  A CPU write takes the port; pass A's consumption (clear the flags
// it read as set) waits for a clk without one, and pass A stays on the slot until
// it is done.  A flag the CPU sets on the same slot in that clk is kept: an event after A's read is kept for the next
// frame, as a set winning over a clear in one clk.  (tl_load uses TLdest as pass
// A reads it: two field 3 writes to one slot inside one frame, the first with
// bit 0, load the second's level, not the first's.  SPEC F-REG.)
// ═══════════════════════════════════════════════════════════════════════════
logic [23:0] hf_pending;      // header fetch wanted (set by a wave-number write)
logic        hf_busy;         // the header FSM is fetching hf_slot's header
logic [4:0]  hf_slot;
logic        hf_again;        // hf_slot's wave number was written during its fetch
wire         wr_wave = wr_slot_reg && (wr_field == 4'd0);
logic        bf_done;         // the last backfill cycle: the fetch is over
logic        a_take;          // pass A has flags of a_slot to clear (mask a_take_m)
logic [2:0]  a_take_m;        // {tl_load, pos_clr, key_retrig}
logic [4:0]  a_slot;

logic [3:0] ev_a [0:31] /* synthesis ramstyle = "MLAB, no_rw_check" */;
logic [3:0] ev_b [0:31] /* synthesis ramstyle = "MLAB, no_rw_check" */;
wire  [3:0] ev_cpu = ev_a[wr_snum];
wire  [3:0] ev_rd  = ev_b[a_slot];            // pass A's view
wire        keyon_cur   = ev_cpu[3];
wire        key_retrig_a = ev_rd[0];
wire        pos_clr_a    = ev_rd[1];
wire        tl_load_a    = ev_rd[2];
wire        a_flags_rd;               // pass A reads a_slot's flags this clk (tb_flagrace)
//  the CPU write's new word, and the flags it sets (ev_cs)
logic [3:0] ev_cw;
logic [2:0] ev_cs;
logic       ev_cwe;
always_comb begin
    ev_cs  = '0;
    ev_cwe = 1'b0;
    if (wr_slot_reg)
        case (wr_field)
            4'd0: begin ev_cwe = 1'b1; ev_cs = keyon_cur ? 3'b001 : 3'b010; end
            4'd3: begin ev_cwe = reg_data[0]; ev_cs = 3'b100; end
            4'd4: begin ev_cwe = 1'b1; ev_cs = {2'b00, reg_data[7] && !keyon_cur}; end
            default: ;
        endcase
    ev_cw = {(wr_field == 4'd4) ? reg_data[7] : ev_cpu[3], ev_cpu[2:0] | ev_cs};
end
wire        ev_we = clr_run ? (clr_cnt < 8'd32) : (ev_cwe || a_take);
wire  [4:0] ev_wa = clr_run ? clr_cnt[4:0] : ev_cwe ? wr_snum : a_slot;
wire  [3:0] ev_wd = clr_run ? 4'd0 : ev_cwe ? ev_cw : ev_rd & ~{1'b0, a_take_m};
always_ff @(posedge clk) if (ev_we) begin
    ev_a[ev_wa] <= ev_wd;
    ev_b[ev_wa] <= ev_wd;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        //  openMSX's reset writes 0 to every register, so the last writes, wave
        //  number 0 on each slot, load wave 0's header and backfill fields 5-9 from
        //  it (YMF278.cc reset -> writeRegDirect case 0).  engine2 leaves them 0
        //  (cpuvis D11).  All 24 fetches are queued here.  The slots are silent, so
        //  pass A does not wait for them.
        hf_pending <= '1;
        hf_again   <= 1'b0;
    end else begin
        if (bf_done) begin
            if (!hf_again) hf_pending[hf_slot] <= 1'b0;
            hf_again <= 1'b0;
        end
        if (wr_wave) begin
            hf_pending[wr_snum] <= 1'b1;
            //  (in the bf_done cycle the pending bit above stays set: no refetch flag)
            if (hf_busy && wr_snum == hf_slot && !bf_done) hf_again <= 1'b1;
        end
    end
end

// Fields 5..9 written since the slot's wave-number write: the backfill skips them.
// One 5-bit word per slot, in two MLAB copies (the write's own read-modify-write
// reads at wr_snum, the backfill at hf_slot); the reset sweep clears them.
logic [4:0] dirty_a [0:31] /* synthesis ramstyle = "MLAB, no_rw_check" */;
logic [4:0] dirty_b [0:31] /* synthesis ramstyle = "MLAB, no_rw_check" */;
wire        dirty_we = clr_run ? (clr_cnt < 8'd32)
                     : wr_slot_reg && (wr_field == 4'd0 || wr_field >= 4'd5);
wire  [4:0] dirty_wa = clr_run ? clr_cnt[4:0] : wr_snum;
wire  [4:0] dirty_wd = (clr_run || wr_field == 4'd0) ? 5'd0
                     : dirty_a[wr_snum] | (5'd1 << (wr_field - 4'd5));
always_ff @(posedge clk) if (dirty_we) begin
    dirty_a[dirty_wa] <= dirty_wd;
    dirty_b[dirty_wa] <= dirty_wd;
end

// ═══════════════════════════════════════════════════════════════════════════
// CPU wave-memory port (regs 3-6), openMSX semantics (YMF278.cc:716-748, 759-786,
// "Verified on real YMF278"):
//   * reg 3/4 are only stored (ns_reg); a reg 5 write loads all three bytes (D4);
//   * with reg 2 bit 0 = 0 a reg 6 write is ignored and a reg 6 read returns FFh,
//     neither moves the address (D3);
//   * a reg 6 read returns a byte prefetched at the last reg 5 write, reg 6 read or
//     (new) reg 6 write, so the SDRAM latency stays hidden; after a write the
//     prefetch is taken again at the advanced address once the write has left the
//     port, so a read never returns a byte from before the write (D7).  Left: the
//     prefetch is the memory at prefetch time, not at read time; only CPU writes
//     change the memory and each one refreshes it, so the two differ only if a read
//     comes before the prefetch is in (SPEC H13).
// ═══════════════════════════════════════════════════════════════════════════
logic [23:0] cpu_mem_adr;
logic [7:0]  cpu_wr_data;
logic        cpu_rd_pend, cpu_wr_pend, cpu_rd_out, cpu_wr_out, cpu_rd_after_wr;
logic        cpu_rd_issue, cpu_wr_issue, cpu_wr_done;
logic [7:0]  cpu_mem_rd_buf;
wire cpu_adr_set_l = reg_wr && (reg_addr == 8'h05);
wire mem_on        = reg02_mem_access_mode;           // reg 2 bit 0 (D3)
wire cpu_rd_06     = reg_rd && (reg_addr == 8'h06) && mem_on;
wire cpu_wr_06     = reg_wr && (reg_addr == 8'h06) && mem_on;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_mem_adr <= '0;
        cpu_wr_data <= '0;
        cpu_rd_pend <= 1'b0;
        cpu_wr_pend <= 1'b0;
        cpu_rd_out  <= 1'b0;
        cpu_wr_out  <= 1'b0;
        cpu_rd_after_wr <= 1'b0;
        cpu_mem_rd_buf <= '0;
    end else begin
        if (cpu_adr_set_l) cpu_mem_adr <= {ns_reg[3], ns_reg[4], reg_data};
        if ((cpu_rd_06 || cpu_wr_issue) && !cpu_adr_set_l) cpu_mem_adr <= cpu_mem_adr + 24'd1;
        if (cpu_wr_06) cpu_wr_data <= reg_data;

        if (cpu_rd_issue) cpu_rd_pend <= 1'b0;
        if (cpu_adr_set_l || cpu_rd_06) cpu_rd_pend <= 1'b1;
        if (cpu_wr_issue) cpu_wr_pend <= 1'b0;
        if (cpu_wr_06)    cpu_wr_pend <= 1'b1;
        //  D7: the prefetch again after the last queued write has left the port
        if (cpu_wr_06) cpu_rd_after_wr <= 1'b1;
        else if (cpu_rd_after_wr && cpu_wr_done && !cpu_wr_pend) begin
            cpu_rd_after_wr <= 1'b0;
            cpu_rd_pend     <= 1'b1;
        end

        if (cpu_rd_issue) cpu_rd_out <= 1'b1;
        else if (mem_rd_valid && cpu_rd_out) begin
            cpu_rd_out     <= 1'b0;
            cpu_mem_rd_buf <= mem_rd_data;
        end
        if (cpu_wr_issue)     cpu_wr_out <= 1'b1;
        else if (cpu_wr_done) cpu_wr_out <= 1'b0;
    end
end
assign cpu_mem_rd_data = mem_on ? cpu_mem_rd_buf : 8'hFF;
//  a write counts until it has left the bridge (cpu_wr_out), not until it is issued
assign cpu_mem_busy    = cpu_rd_pend | cpu_wr_pend | cpu_rd_out | cpu_wr_out | cpu_rd_after_wr;

// ═══════════════════════════════════════════════════════════════════════════
// Slot memories (DESIGN section 2).  Simple dual-port, registered read.
//   RAM-S  {slot, w}: w0 {pos, stepPtr, TL}, w1 {lfo_cnt, env_vol, env_state},
//          w2 {startAddr, bits, loopAddr}, w3 {endAddr}
//   RAM-PD {slot, w}: w0-w1 pass A's plan for pass B, w2-w5 the pairs k0-k3
//          ({valid, pair}: pass A writes 0 when it queues the pair, the response 1)
// ═══════════════════════════════════════════════════════════════════════════
localparam logic [39:0] S_W1_INIT = {9'd0, 18'd0, MAX_ATT_INDEX, EG_OFF};

logic        s_we;
logic [6:0]  s_waddr, s_raddr;
logic [39:0] s_wd, s_q;
pcm_sdp #(.W(40), .AW(7)) u_rams (.clk, .we(s_we), .waddr(s_waddr), .wd(s_wd), .raddr(s_raddr), .rd(s_q));

logic        pd_we;
logic [7:0]  pd_waddr, pd_raddr;
logic [39:0] pd_wd, pd_q;
pcm_sdp #(.W(40), .AW(8)) u_rampd (.clk, .we(pd_we), .waddr(pd_waddr), .wd(pd_wd), .raddr(pd_raddr), .rd(pd_q));

// What pass A left for pass B, in RAM-PD w7 {frame mod 4, status}.  Nothing else
// per slot is shared: a request or a response is stale once its frame's C_s has
// passed (pass B has taken the slot), and pass A starts a slot only after pass B
// has finished with the slot's previous frame (C_s + T_BDONE).
localparam logic [1:0] ST_NONE = 2'd0, ST_QUIET = 2'd1, ST_PLAN = 2'd2;
localparam int T_BDONE = 40;          // pass B has read all of a slot's RAM-PD words

// the slot's C_s of frame f (mod 4) has passed
function automatic logic c_past(input logic [1:0] f, input logic [1:0] bf,
                                input logic [FRAME_W-1:0] fc, input logic [4:0] slot);
    logic [1:0] d;
    d = f - bf;
    return (d == 2'd3) || (d == 2'd0 && fc >= cs_of(slot));
endfunction

// ═══════════════════════════════════════════════════════════════════════════
// Request FIFO (MLAB, 16 x 29): {pair address, slot, k, frame mod 4}
// ═══════════════════════════════════════════════════════════════════════════
logic [28:0] fq_m [0:15] /* synthesis ramstyle = "MLAB, no_rw_check" */;
logic [3:0]  fq_wp, fq_rp;
logic [4:0]  fq_n;
logic        fq_push, fq_pop;
logic [28:0] fq_wd;
always_ff @(posedge clk) if (fq_push) fq_m[fq_wp] <= fq_wd;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fq_wp <= '0; fq_rp <= '0; fq_n <= '0;
    end else begin
        if (fq_push) fq_wp <= fq_wp + 4'd1;
        if (fq_pop)  fq_rp <= fq_rp + 4'd1;
        fq_n <= fq_n + 5'(fq_push) - 5'(fq_pop);
    end
end
wire fq_full = (fq_n >= 5'd15);    // one spare: a push and the full flag are a clk apart
`ifndef SYNTHESIS
always @(posedge clk) if (rst_n && fq_push && fq_n == 5'd16)
    $error("ymf278_pcm_engine3: request FIFO overflow");
`endif

// ═══════════════════════════════════════════════════════════════════════════
// Header FSM: a wave-number write -> the wave number from RAM-R -> 3 pairs
// (12 bytes at wave x 12, always 4-aligned) through the sequencer -> RAM-S w2/w3
// and the backfill of fields 5-9.  The fetch of a slot pass A is waiting for is
// ordered against the sample reads by deadline (sequencer).
// ═══════════════════════════════════════════════════════════════════════════
typedef enum logic [2:0] { Q_IDLE, Q_RD_WAIT, Q_WR_SETTLE, Q_WR_COMMIT, Q_P_WAIT } q_state_t;
q_state_t    q_state;
wire         q_take_h;            // the sequencer issues the header pair this clk
typedef enum logic [3:0] {
    H_IDLE, H_W0, H_W0C, H_W1, H_W1C, H_BASE, H_REQ, H_WAIT, H_ST0, H_ST1, H_BF
} h_state_t;
h_state_t    h_state;
logic [2:0]  sv_cnt;               // backfill field 0..4
logic [1:0]  hf_widx;              // pair 0..2
logic [31:0] hf_b0, hf_b1;         // pair 0 (then pair 2), pair 1
logic [21:0] hf_base;
logic [8:0]  hf_wave;
logic        hf_resp;              // the sequencer stored pair hf_widx this clk
logic        a_s_we;               // pass A writes RAM-S this clk (the header store waits)

// lowest pending slot
logic       hf_found;
logic [4:0] hf_pick;
always_comb begin
    hf_found = 1'b0;
    hf_pick  = '0;
    for (int i = 23; i >= 0; i--)
        if (hf_pending[i]) begin hf_found = 1'b1; hf_pick = 5'(i); end
end

//  the header FSM's reads of RAM-R (fields 0 and 1 of the slot), in clks pass A leaves free
assign hf_rr_en   = !a_rr_en && ((h_state == H_W0) || (h_state == H_W1));
assign hf_rr_addr = (h_state == H_W0) ? {3'd0, hf_slot} : 8'd24 + {3'd0, hf_slot};
assign hf_busy    = (h_state != H_IDLE);

wire [21:0] hf_base_c = (hf_wave < 9'd384 || wavetblhdr == 3'd0)
    ? 22'({13'd0, hf_wave} * 22'd12)
    : 22'({wavetblhdr, 19'd0} + ({13'd0, hf_wave - 9'd384} * 22'd12));

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_state <= H_IDLE;
        sv_cnt  <= '0;
        hf_slot <= '0;
        hf_widx <= '0;
        hf_base <= '0;
        hf_wave <= '0;
    end else begin
        case (h_state)
            //  not while a CPU slot-register write is still queued (the wave
            //  number read below must see it)
            H_IDLE: if (hf_found && !wq_v) begin
                hf_slot <= hf_pick;
                h_state <= H_W0;
            end
            H_W0:  if (!a_rr_en) h_state <= H_W0C;    // field 0 address -> read port
            H_W0C: begin hf_wave[7:0] <= rr_q;   h_state <= H_W1; end
            H_W1:  if (!a_rr_en) h_state <= H_W1C;
            H_W1C: begin hf_wave[8]   <= rr_q[0]; h_state <= H_BASE; end
            H_BASE: begin
                hf_base <= hf_base_c;
                hf_widx <= '0;
                h_state <= H_REQ;
            end
            H_REQ: if (q_take_h) h_state <= H_WAIT;
            //  pairs 0 and 1, RAM-S w2/w3, pair 2 (bytes 8-11), the backfill
            H_WAIT: if (hf_resp) begin
                hf_widx <= hf_widx + 2'd1;
                case (hf_widx)
                    2'd1:    h_state <= H_ST0;
                    2'd2:    begin sv_cnt <= '0; h_state <= H_BF; end
                    default: h_state <= H_REQ;
                endcase
            end
            H_ST0: if (!a_s_we && !clr_run) h_state <= H_ST1;
            H_ST1: if (!a_s_we && !clr_run) h_state <= H_REQ;
            H_BF: if (bf_step) begin                   // fields 5..9, one per free clk
                sv_cnt <= sv_cnt + 3'd1;
                if (sv_cnt == 3'd4) h_state <= H_IDLE;
            end
            default: h_state <= H_IDLE;
        endcase
    end
end

// header bytes 0..7 = {hf_b1, hf_b0} little-endian (byte i = hbv[8i +: 8]); bytes 8-11
// are hf_b0 again once pair 2 is in
wire [63:0] hbv = {hf_b1, hf_b0};
// RAM-S w2 {startAddr, bits, loopAddr}, w3 {endAddr (stored 2's complement form)}
wire [39:0] hf_w2 = {hbv[5:0], hbv[15:8], hbv[23:16], hbv[7:6], hbv[31:24], hbv[39:32]};
wire [39:0] hf_w3 = {24'd0, hbv[47:40], hbv[55:48]};
wire        hf_s_we = (h_state == H_ST0 || h_state == H_ST1) && !a_s_we && !clr_run;

// backfill: header bytes 7..11 -> fields 5..9, except the ones the CPU wrote (the
// dirty bit is read in the field's own cycle, so a write that lands during the
// backfill is kept too)
assign bf_step = (h_state == H_BF) && !wq_v && !clr_run;   // the write port is free
wire   [4:0] bf_dirty = dirty_b[hf_slot];
assign bf_now  = bf_step && !bf_dirty[sv_cnt];
assign bf_word = 8'd120 + 8'd24 * {5'd0, sv_cnt} + {3'd0, hf_slot};
assign bf_d    = (sv_cnt == 3'd0) ? hf_b1[31:24] : hf_b0[{sv_cnt[1:0] - 2'd1, 3'd0} +: 8];
assign bf_done = bf_step && (sv_cnt == 3'd4);

// ═══════════════════════════════════════════════════════════════════════════
// Memory sequencer: owns the port, one request at a time.  CPU memory op first
// (BUSY bound, S-BOUND), then the earlier deadline of the header pair and the
// FIFO head: a sample pair is due at its slot's C_s, a header pair at the A
// deadline (C_s - T_AMARGIN) of the frame pass A will next visit the slot for.
// A FIFO entry whose slot pass B has already taken (or pass A has restarted) is
// dropped unissued; a response for one is dropped too.
// ═══════════════════════════════════════════════════════════════════════════
logic [2:0]  q_cnt;                 // write settle count
logic        q_hdr;                 // the pair in flight is the header's
logic [4:0]  q_slot;
logic [1:0]  q_k;
logic [1:0]  q_r;

wire mem_free = !mem_busy && !mem_rd_en && !mem_wr_en;
wire cpu_op   = (cpu_rd_pend || cpu_wr_pend) && !cpu_rd_issue && !cpu_wr_issue;

// FIFO head register (stage 1) and its staleness / deadline (stage 2)
logic        hq_v, hq_ok;
logic [19:0] hq_pair;
logic [4:0]  hq_slot;
logic [1:0]  hq_k;
logic [1:0]  hq_r;
logic        hq_stale;
logic        hf_first;              // the header's deadline is not after the head's

// pass A's position, for the header deadline
logic        a_busy, a_rev;
logic [23:0] a_def;
logic [15:0] a_fcnt;
wire  [1:0]  a_fr = a_fcnt[1:0];
wire  hf_inpass = a_busy && ((!a_rev && hf_slot >= a_slot) || a_def[hf_slot]);
wire  [1:0] hf_tgt = (a_busy && !hf_inpass) ? a_fr + 2'd1 : a_fr;
wire  [1:0] hf_rel = hf_tgt - bfr;               // 3 = overdue: due now
wire  [1:0] hq_rel = (hq_r - bfr == 2'd3) ? 2'd0 : hq_r - bfr;
//  header deadline rel x CPF + C_s - 128 against sample deadline rel x CPF + C_s,
//  C_s = 190 + 116 s: in one frame the header is first iff s_h <= s_q + 1; an
//  earlier frame is always first and a later one never (|s_h - s_q| <= 23 and
//  CPF - 128 > 23 x 116).  Exact, no times.
wire        hf_first_c = (hf_rel == 2'd3) || (hf_rel < hq_rel) ||
                         (hf_rel == hq_rel && {1'b0, hf_slot} <= {1'b0, hq_slot} + 6'd1);

assign fq_pop = !hq_v && (fq_n != 5'd0);

wire hdr_c    = (h_state == H_REQ);
wire smp_c    = hq_ok && !hq_stale;
wire q_drop   = (q_state == Q_IDLE) && hq_ok && hq_stale;
wire q_pick_h = hdr_c && (!smp_c || hf_first);
wire q_go     = (q_state == Q_IDLE) && mem_free && !cpu_op;
assign q_take_h = q_go && q_pick_h;
wire q_take_s = q_go && !q_pick_h && smp_c;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hq_v <= 1'b0; hq_ok <= 1'b0; hq_stale <= 1'b0;
        hq_pair <= '0; hq_slot <= '0; hq_k <= '0; hq_r <= '0;
        hf_first <= 1'b0;
    end else begin
        hq_ok    <= hq_v;               // stage 2 is one clk behind a load
        hq_stale <= c_past(hq_r, bfr, frame_cycle, hq_slot);
        hf_first <= hf_first_c;
        if (fq_pop) begin
            {hq_pair, hq_slot, hq_k, hq_r} <= fq_m[fq_rp];
            hq_v  <= 1'b1;
            hq_ok <= 1'b0;
        end
        if (q_take_s || q_drop) begin
            hq_v  <= 1'b0;
            hq_ok <= 1'b0;
        end
    end
end


// the response of a sample pair is written to RAM-PD in its own clk (pd_rv: pass A's
// writes wait), with its valid bit, if its slot still wants it
wire         q_resp   = (q_state == Q_P_WAIT) && mem_rd_valid;
wire         pd_rv    = q_resp && !q_hdr;
wire         q_accept = pd_rv && !c_past(q_r, bfr, frame_cycle, q_slot);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        q_state      <= Q_IDLE;
        q_cnt        <= '0;
        q_hdr        <= 1'b0;
        q_slot       <= '0;
        q_k          <= '0;
        q_r          <= '0;
        mem_addr     <= '0;
        mem_rd_en    <= 1'b0;
        mem_wr_en    <= 1'b0;
        mem_wr_data  <= '0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        cpu_wr_done  <= 1'b0;
        hf_resp      <= 1'b0;
        hf_b0 <= '0;
        hf_b1 <= '0;
    end else begin
        mem_rd_en    <= 1'b0;
        mem_wr_en    <= 1'b0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        cpu_wr_done  <= 1'b0;
        hf_resp      <= 1'b0;
        case (q_state)
            Q_IDLE:
                if (cpu_op) begin
                    if (mem_free) begin
                        mem_addr <= cpu_mem_adr[21:0];
                        if (cpu_rd_pend) begin
                            mem_rd_en    <= 1'b1;
                            cpu_rd_issue <= 1'b1;
                            q_state      <= Q_RD_WAIT;
                        end else begin
                            mem_wr_data  <= cpu_wr_data;
                            mem_wr_en    <= 1'b1;
                            cpu_wr_issue <= 1'b1;
                            q_cnt        <= '0;
                            q_state      <= Q_WR_SETTLE;
                        end
                    end
                end else if (q_take_h) begin
                    mem_addr  <= {hf_base[21:2] + 20'(hf_widx), 2'b00};
                    mem_rd_en <= 1'b1;
                    q_hdr     <= 1'b1;
                    q_state   <= Q_P_WAIT;
                end else if (q_take_s) begin
                    mem_addr  <= {hq_pair, 2'b00};
                    mem_rd_en <= 1'b1;
                    q_hdr     <= 1'b0;
                    q_slot    <= hq_slot;
                    q_k       <= hq_k;
                    q_r       <= hq_r;
                    q_state   <= Q_P_WAIT;
                end
            Q_RD_WAIT:
                if (mem_rd_valid) q_state <= Q_IDLE;
            //  A write is done when the bridge is idle again.  Wait 3 clk first so it
            //  has left IDLE (a memory that never raises mem_busy for a write, the
            //  benches' model, is done after those 3 clk).
            Q_WR_SETTLE: begin
                q_cnt <= q_cnt + 3'd1;
                if (q_cnt == 3'd2) q_state <= Q_WR_COMMIT;
            end
            Q_WR_COMMIT:
                if (!mem_busy) begin
                    cpu_wr_done <= 1'b1;
                    q_state     <= Q_IDLE;
                end
            Q_P_WAIT:
                if (mem_rd_valid) begin
                    if (q_hdr) begin
                        if (hf_widx == 2'd1) hf_b1 <= {mem_rd_data16b, mem_rd_data16};
                        else                 hf_b0 <= {mem_rd_data16b, mem_rd_data16};
                        hf_resp         <= 1'b1;
                    end
                    q_state <= Q_IDLE;
                end
            default: q_state <= Q_IDLE;
        endcase
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Pass A (control).  One slot at a time, every field from RAM-R (one read every
// other clk, so the CPU readback gets the port in between), the state from
// RAM-S, the golden model's per-slot order (golden_pcm.py gen_frame):
//   TL ramp; if the slot runs (EG not off, or a key-on edge): vib -> step ->
//   position (restart on an edge or a wave write) -> sample addresses -> EG ->
//   AM -> gains -> LFO.
// A slot that runs but whose header is still being fetched is put aside and
// taken again after slot 23; if its header is not in by its A deadline it is
// stalled for the frame (state frozen, silent, counted late: S-STALL).
// A slot first reached after its A deadline (pass A behind) still steps its
// state but issues no reads and leaves no plan: pass B plays it late.
// Interlock: pass A starts slot s for frame F only after pass B has finished with
// slot s of frame F-1 (C_s + T_BDONE), so a plan or a pair is never overwritten
// before use.
// ═══════════════════════════════════════════════════════════════════════════
typedef enum logic [5:0] {
    A_IDLE, A_SEL, A_LD, A_SKIP, A_SKIPWB,
    A_VIB, A_STEP1, A_STEP2, A_ADV1, A_ADV2, A_NP1, A_NP2, A_NP3,
    A_OFF, A_PAIR1, A_PAIR2, A_ENQ,
    A_EG0, A_EG1, A_EG2, A_EG3, A_EG4, A_EG5,
    A_AM, A_ENV, A_TL, A_GAIN, A_GAIN2, A_LFO,
    A_PLAN0, A_WB0, A_WB1, A_NEXT, A_SCAN
} a_state_t;
a_state_t a_state;

logic        a_go;                 // a pass is due (T_K, or the one after reset)
logic [3:0]  a_tl9;                // eg_cnt % 9 of the pass
logic [1:0]  a_tl3;                // (eg_cnt / 9) % 3 of the pass
logic [FRAME_W-1:0] a_cs;          // A deadline of a_slot (C_s - T_AMARGIN)
logic [4:0]  a_lcnt;
logic        a_dead, a_stall;
logic        a_edge, a_pclr, a_tll;   // key_retrig / pos_clr / tl_load as consumed

// register fields
logic [9:0]  f_fn;
logic [3:0]  f_oct;
logic        f_prvb, f_keyon, f_damp, f_lfoact;
logic [7:0]  f_tld;
logic [3:0]  f_pan;
logic [2:0]  f_lfo, f_vib, f_am;
logic [3:0]  f_ar, f_d1r, f_dl, f_d2r, f_rc, f_rr;
// slot state and header
logic [15:0] d_pos, d_sp;
logic [7:0]  d_tl;
logic [17:0] d_lfo;
logic [9:0]  d_env;
logic [2:0]  d_est;
logic [21:0] h_start;
logic [1:0]  h_bits;
logic [15:0] h_loop, h_end;
// temporaries
logic signed [6:0]  t_vib;
logic [12:0] t_x;
logic [16:0] t_sum;
logic [8:0]  t_inc;
logic        a_np_b;               // next_pos unit: 0 = advance by t_inc, 1 = posB
logic        a_ab;                 // address unit: 0 = sample A, 1 = sample B
logic [15:0] t_p, t_posb;
logic [16:0] t_w;
logic [21:0] t_ma, t_mb;
logic        t_eq0, t_eq1, t_eqm;  // B's pair = A's, A's + 1, A's - 1
logic [1:0]  t_ka1, t_kb0, t_kb1;
logic [3:0]  t_need, t_left;
logic [1:0]  t_mode;               // EG: 0 normal, 1 key-on edge, 2 to release
logic [3:0]  t_val;
logic [5:0]  t_rate;
logic [3:0]  t_shift;
logic [6:0]  t_sel;
logic        t_upd;
logic [2:0]  t_ph;
logic [3:0]  t_einc;
logic [11:0] t_att;
logic [10:0] t_esum;
logic [9:0]  t_envt;

// the deadline of a_slot in pass frame a_fr has passed
wire [1:0] a_dfr  = bfr - a_fr;
wire       a_past = (a_dfr == 2'd1) || (a_dfr == 2'd2) || (a_dfr == 2'd0 && frame_cycle >= a_cs);
//  pass B is done with a_slot of frame a_fr - 1
wire       a_free = (a_dfr != 2'd3) || (frame_cycle >= a_cs + FRAME_W'(T_AMARGIN + T_BDONE));

// RAM-R reads: field order 3, 4, 1, 2, 5, 6, 7, 8, 9 at a_lcnt 0, 2, .., 16
function automatic logic [7:0] a_fbase(input logic [3:0] i);
    case (i)
        4'd0: return 8'd72;   4'd1: return 8'd96;   4'd2: return 8'd24;
        4'd3: return 8'd48;   4'd4: return 8'd120;  4'd5: return 8'd144;
        4'd6: return 8'd168;  4'd7: return 8'd192;  default: return 8'd216;
    endcase
endfunction
assign a_rr_en   = (a_state == A_LD) && !a_lcnt[0] && (a_lcnt <= 5'd16);
assign a_rr_addr = a_fbase(a_lcnt[4:1]) + {3'd0, a_slot};

// vibrato F-Num offset magnitude: floor(|lfo_fm| x vib_depth / 12), a 128-entry table
function automatic logic [127:0][5:0] mk_vibq();
    int d;
    for (int v = 0; v < 8; v++)
        for (int m = 0; m < 16; m++) begin
            d = (v == 0) ? 0 : (v == 1) ? 2 : (v == 2) ? 3 : (v == 3) ? 4 :
                (v == 4) ? 6 : (v == 5) ? 12 : (v == 6) ? 24 : 48;
            mk_vibq[v * 16 + m] = 6'((m * d) / 12);
        end
endfunction
localparam logic [127:0][5:0] VIBQ = mk_vibq();

// Pass A's multiplier (one DSP, product registered in the clk it is enabled):
//   A_STEP2  step = (fn + 1024 + vib) << (8 + oct) >> 3 = (t_x x 2^sh)[26:3]
//   A_AM     AM   = (triangle(lfo) x am_depth) >> 7 (compute_am)
//   A_TL / leaving A_GAIN: openMSX vol_factor's multiplier for the env / TL
//            attenuation, (0x8000 x (0x80 - (att & 0x3F))) >> (7 + att >> 6)
//            = ((0x80 - att[5:0]) x 2^(9 - att[9:6])) >> 1 (att[9:6] = 9 is
//            floor(m / 2) too); 0 from MAX_ATT_INDEX = 0x280 (att[9:6] >= 10)
logic [12:0] a_mx;
logic [15:0] a_my;
logic [28:0] a_mp;
logic        a_mp_en;
wire  [9:0]  a_att = (a_state == A_TL) ? t_envt : {d_tl, 2'b00};
always_comb begin
    logic [3:0] sh;
    logic [7:0] lam;
    sh  = {~f_oct[3], f_oct[2:0]};
    lam = d_lfo[17] ? ~d_lfo[17:10] : d_lfo[17:10];
    a_mx = {5'd0, 8'h80 - {2'b00, a_att[5:0]}};
    a_my = (a_att[9:6] <= 4'd9) ? 16'(10'd1 << (4'd9 - a_att[9:6])) : 16'd0;
    if (a_state == A_STEP2) begin
        a_mx = t_x;
        a_my = (sh == 4'd0) ? 16'd0 : 16'd1 << sh;
    end else if (a_state == A_AM) begin
        a_mx = {5'd0, lam};
        a_my = {8'd0, am_depth_rom(f_am)};
    end
end
always_ff @(posedge clk) if (a_mp_en) a_mp <= 29'(a_mx * a_my);
wire [23:0] t_step = a_mp[26:3];
wire [8:0]  t_am   = (f_lfoact && f_am != 3'd0) ? a_mp[15:7] : 9'd0;
wire [15:0] a_vs   = a_mp[16:1];

assign a_mp_en = (a_state == A_STEP2) || (a_state == A_AM) || (a_state == A_TL) ||
                 (a_state == A_GAIN && (!pd_rv || a_dead));

// the plan for pass B
wire [39:0] a_plan0 = {3'd0, a_edge | a_pclr, t_need, h_bits, t_kb1, t_mb[1:0], t_kb0,
                       t_ka1, t_ma[1:0], t_posb[0], d_pos[0], d_sp};

always_comb begin
    a_s_we  = 1'b0;
    s_waddr = {a_slot, 2'd0};
    s_wd    = {d_pos, d_sp, d_tl};
    if (a_state == A_WB0 || a_state == A_SKIPWB) a_s_we = 1'b1;
    if (a_state == A_WB1) begin
        a_s_we  = 1'b1;
        s_waddr = {a_slot, 2'd1};
        s_wd    = {9'd0, d_lfo, d_env, d_est};
    end
    s_we = a_s_we;
    if (clr_run) begin
        s_we    = (clr_cnt < 8'd128);
        s_waddr = clr_cnt[6:0];
        s_wd    = (clr_cnt[1:0] == 2'd1) ? S_W1_INIT : 40'd0;
    end else if (hf_s_we) begin
        s_we    = 1'b1;
        s_waddr = {hf_slot, (h_state == H_ST0) ? 2'd2 : 2'd3};
        s_wd    = (h_state == H_ST0) ? hf_w2 : hf_w3;
    end
end
//  RAM-S reads: w1, w0, w2, w3 at a_lcnt 0-3
assign s_raddr = {a_slot, (a_lcnt == 5'd0) ? 2'd1 : (a_lcnt == 5'd1) ? 2'd0 : a_lcnt[1:0]};

//  RAM-PD writes: a response first; pass A's plan and the invalidation of a pair it
//  queues wait for a clk without one
//  (plan0 at w0; the env gain with pan at w1 and the TL gain at w6 as A computes them)
//  and the slot's status at w7 (its first visit, and when it is done)
logic        a_pd_req;
logic [2:0]  a_pd_w;
logic [39:0] a_pd_d;
always_comb begin
    a_pd_req = 1'b0;
    a_pd_w   = 3'd7;
    a_pd_d   = {36'd0, a_fr, ST_NONE};
    case (a_state)
        A_SEL:    a_pd_req = !a_rev && (a_past || a_free);
        A_ENQ:    begin a_pd_req = fq_push; a_pd_w = {1'b0, a_qk} + 3'd2; a_pd_d = '0; end
        A_GAIN:   begin a_pd_req = !a_dead; a_pd_w = 3'd1; a_pd_d = {20'd0, f_pan, a_vs}; end
        A_GAIN2:  begin a_pd_req = !a_dead; a_pd_w = 3'd6; a_pd_d = {24'd0, a_vs}; end
        A_PLAN0:  begin a_pd_req = !a_dead; a_pd_w = 3'd0; a_pd_d = a_plan0; end
        A_SKIPWB: begin a_pd_req = 1'b1; a_pd_d = {36'd0, a_fr, a_stall ? ST_NONE : ST_QUIET}; end
        A_WB1:    begin a_pd_req = 1'b1; a_pd_d = {36'd0, a_fr, a_dead ? ST_NONE : ST_PLAN}; end
        default: ;
    endcase
    pd_we    = q_accept | (a_pd_req && !pd_rv);
    pd_waddr = pd_rv ? {q_slot, 1'b0, q_k} + 8'd2 : {a_slot, a_pd_w};
    pd_wd    = pd_rv ? {7'd0, 1'b1, mem_rd_data16b, mem_rd_data16} : a_pd_d;
end

assign a_flags_rd = (a_state == A_LD) && (a_lcnt == 5'd2);

// FIFO push from A_ENQ: the lowest pair still to send
wire [1:0]  a_qk   = t_left[0] ? 2'd0 : t_left[1] ? 2'd1 : t_left[2] ? 2'd2 : 2'd3;
wire [19:0] a_qpr  = (a_qk[1] ? t_mb[21:2] : t_ma[21:2]) + {19'd0, a_qk[0]};
assign fq_push = (a_state == A_ENQ) && !a_dead && (t_left != 4'd0) && !fq_full && !pd_rv;
assign fq_wd   = {a_qpr, a_slot, a_qk, a_fr};

logic       b_busy;
logic [4:0] b_cur;
typedef enum logic [4:0] {
    B_IDLE, B_ST, B_P0, B_D0, B_D1, B_D2, B_D3, B_DEC,
    B_I1, B_I2, B_SAVE, B_E1, B_E2, B_T1, B_T2, B_L1, B_L2, B_R2
} b_state_t;
b_state_t    b_state;
logic [4:0]  b_slot;               // next slot to take (24 = done for the frame)
logic [FRAME_W-1:0] b_c;           // its C_s
wire         b_take = (b_state == B_IDLE) && (b_slot != 5'd24) && (frame_cycle == b_c);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a_state <= A_IDLE;
        a_go    <= 1'b1;               // frame 0 runs right after reset
        a_busy  <= 1'b0;
        a_rev   <= 1'b0;
        a_def   <= '0;
        a_fcnt  <= '0;
        a_tl9   <= '0;
        a_tl3   <= '0;
        a_slot  <= '0;
        a_cs    <= '0;
        a_lcnt  <= '0;
        a_dead  <= 1'b0;
        a_stall <= 1'b0;
        a_edge  <= 1'b0;
        a_pclr  <= 1'b0;
        a_tll   <= 1'b0;
        a_take  <= 1'b0;
        a_take_m <= '0;
        a_np_b  <= 1'b0;
        a_ab    <= 1'b0;
    end else begin
        //  the clear is done in a clk without a CPU flag write; one on the same
        //  slot keeps the flags it sets
        if (a_take) begin
            if (!ev_cwe) a_take <= 1'b0;
            else if (wr_snum == a_slot) a_take_m <= a_take_m & ~ev_cs;
        end
        if (frame_cycle == FRAME_W'(T_K)) a_go <= 1'b1;


        case (a_state)
            A_IDLE: if (a_go) begin
                a_go    <= 1'b0;
                a_busy  <= 1'b1;
                a_rev   <= 1'b0;
                a_slot  <= '0;
                a_cs    <= FRAME_W'(T_C0 - T_AMARGIN);
                a_state <= A_SEL;
            end

            //  interlock and deadline; a revisit has done both at its first visit
            //  (a first visit marks the slot {a_fr, NONE} in w7)
            A_SEL: begin
                a_lcnt <= '0;
                if (a_rev) begin
                    a_dead  <= a_past;
                    a_state <= A_LD;
                end else if ((a_past || a_free) && !pd_rv) begin
                    a_dead  <= a_past;
                    a_state <= A_LD;
                end
            end

            A_LD: begin
                a_lcnt <= a_lcnt + 5'd1;
                case (a_lcnt)
                    5'd1: begin
                        f_tld <= (rr_q[7:1] == 7'h7F) ? 8'hFF : {1'b0, rr_q[7:1]};
                        {d_lfo, d_env, d_est} <= s_q[30:0];
                    end
                    5'd2: begin
                        logic run;
                        {d_pos, d_sp, d_tl} <= s_q;
                        run = (d_est != EG_OFF) || key_retrig_a;
                        a_stall <= 1'b0;
                        if (!run) begin
                            //  silent slot: TL ramp only (S-SKIP)
                            a_tll    <= tl_load_a;
                            a_take   <= 1'b1;
                            a_take_m <= {tl_load_a, 2'b00};
                            a_state  <= A_SKIP;
                        end else if (hf_pending[a_slot]) begin
                            if (a_dead) begin
                                //  its header is not in by its deadline: S-STALL
                                a_stall  <= 1'b1;
                                a_tll    <= tl_load_a;
                                a_take   <= 1'b1;
                                a_take_m <= {tl_load_a, 2'b00};
                                a_state  <= A_SKIP;
                            end else begin
                                a_def[a_slot] <= 1'b1;
                                a_state       <= A_NEXT;
                            end
                        end else begin
                            a_edge   <= key_retrig_a;
                            a_pclr   <= pos_clr_a;
                            a_tll    <= tl_load_a;
                            a_take   <= 1'b1;
                            a_take_m <= {tl_load_a, pos_clr_a, key_retrig_a};
                        end
                    end
                    5'd3: begin
                        f_keyon  <= rr_q[7];
                        f_damp   <= rr_q[6];
                        f_lfoact <= !rr_q[5];
                        f_pan    <= rr_q[4] ? 4'd8 : rr_q[3:0];
                        {h_start, h_bits, h_loop} <= s_q;
                    end
                    5'd4:  h_end <= s_q[15:0];
                    5'd5:  f_fn[6:0] <= rr_q[7:1];
                    5'd7:  begin f_fn[9:7] <= rr_q[2:0]; f_prvb <= rr_q[3]; f_oct <= rr_q[7:4]; end
                    5'd9:  begin f_lfo <= rr_q[5:3]; f_vib <= rr_q[2:0]; end
                    5'd11: begin f_ar  <= rr_q[7:4]; f_d1r <= rr_q[3:0]; end
                    5'd13: begin f_dl  <= rr_q[7:4]; f_d2r <= rr_q[3:0]; end
                    5'd15: begin f_rc  <= rr_q[7:4]; f_rr  <= rr_q[3:0]; end
                    5'd17: begin f_am  <= rr_q[2:0]; a_state <= A_VIB; end
                    default: ;
                endcase
            end

            //  TL: load, else one ramp step on the frames eg_cnt % 9 == 0 (all slots)
            A_SKIP, A_TL: begin
                if (a_tll)
                    d_tl <= f_tld;
                else if (a_tl9 == 4'd0) begin
                    if (a_tl3 == 2'd0) begin if (d_tl < f_tld) d_tl <= d_tl + 8'd1; end
                    else               begin if (d_tl > f_tld) d_tl <= d_tl - 8'd1; end
                end
                a_state <= (a_state == A_SKIP) ? A_SKIPWB : A_GAIN;
            end
            A_SKIPWB: if (!pd_rv) a_state <= A_NEXT;          // w0 and w7

            // ── pitch and position ──
            A_VIB: begin
                logic [5:0] fm6;
                logic [5:0] q;
                fm6 = d_lfo[17:12];
                if (fm6[4]) fm6 = fm6 ^ 6'h1F;
                q = VIBQ[{f_vib, fm6[3:0]}];
                t_vib <= (f_lfoact && f_vib != 3'd0) ? (fm6[5] ? -$signed({1'b0, q}) : $signed({1'b0, q}))
                                                      : 7'sd0;
                a_state <= A_STEP1;
            end
            A_STEP1: begin
                t_x     <= 13'({3'd0, f_fn} + 13'd1024 + {{6{t_vib[6]}}, t_vib});
                a_state <= A_STEP2;
            end
            //  (fn + 1024 + vib) << (8 + oct) >> 3 on the multiplier; oct = -8 is 0
            A_STEP2: a_state <= A_ADV1;
            A_ADV1: begin
                if (a_edge || a_pclr) begin
                    d_pos   <= '0;
                    d_sp    <= '0;
                    a_np_b  <= 1'b1;
                    a_state <= A_NP1;
                end else begin
                    t_sum   <= {1'b0, d_sp} + {1'b0, t_step[15:0]};
                    a_state <= A_ADV2;
                end
            end
            A_ADV2: begin
                t_inc   <= {1'b0, t_step[23:16]} + {8'd0, t_sum[16]};
                d_sp    <= t_sum[15:0];
                a_np_b  <= (t_step[23:16] == 8'd0) && !t_sum[16];
                a_state <= A_NP1;
            end
            //  next_pos: (p + inc) & 0xFFFF, past the end -> + endAddr + loopAddr
            A_NP1: begin
                t_p     <= d_pos + (a_np_b ? 16'd1 : {7'd0, t_inc});
                a_state <= A_NP2;
            end
            A_NP2: begin
                t_w     <= {1'b0, t_p} + {1'b0, h_end};
                a_state <= A_NP3;
            end
            A_NP3: begin
                logic [15:0] r;
                r = t_w[16] ? t_w[15:0] + h_loop : t_p;
                if (!a_np_b) begin
                    d_pos   <= r;
                    a_np_b  <= 1'b1;
                    a_state <= A_NP1;
                end else begin
                    t_posb  <= r;
                    a_ab    <= 1'b0;
                    a_state <= A_OFF;
                end
            end

            // ── sample addresses and pairs ──
            //  the sample's first byte: 8-bit start + p, 12-bit start + 3(p >> 1) + (p & 1)
            //  (odd: low nibble byte, then the high byte), 16-bit start + 2p
            //  (12-bit: 3(p >> 1) + (p & 1) = p + (p >> 1); one three-input add)
            A_OFF: begin
                logic [15:0] p;
                logic [21:0] m;
                p = a_ab ? t_posb : d_pos;
                m = h_start + (h_bits[1] ? {5'd0, p, 1'b0} : {6'd0, p})
                            + ((h_bits == 2'd1) ? {7'd0, p[15:1]} : 22'd0);
                if (!a_ab) begin
                    t_ma <= m;
                    a_ab <= 1'b1;
                end else begin
                    t_mb    <= m;
                    a_state <= A_PAIR1;
                end
            end
            A_PAIR1: begin
                logic [19:0] d;
                d = t_mb[21:2] - t_ma[21:2];
                t_eq0   <= (d == 20'd0);
                t_eq1   <= (d == 20'd1);
                t_eqm   <= (d == 20'hFFFFF);
                a_state <= A_PAIR2;
            end
            //  pairs: k0 = A's, k1 = the one after it, k2 = B's, k3 = the one after
            //  B's; a byte goes to the first k holding its pair
            A_PAIR2: begin
                logic two, xa, xb, eq0, eq1, eqm;
                logic [1:0] ka1, kb0, kb1;
                two = (h_bits != 2'd0);
                xa  = two && (t_ma[1:0] == 2'd3);
                xb  = two && (t_mb[1:0] == 2'd3);
                eq0 = t_eq0;
                eq1 = t_eq1;
                eqm = t_eqm;
                ka1 = xa ? 2'd1 : 2'd0;
                kb0 = eq0 ? 2'd0 : eq1 ? 2'd1 : 2'd2;
                kb1 = !xb ? kb0 : eqm ? 2'd0 : eq0 ? 2'd1 : 2'd3;
                t_ka1  <= ka1;
                t_kb0  <= kb0;
                t_kb1  <= kb1;
                t_need <= {kb1 == 2'd3, kb0 == 2'd2, ka1 == 2'd1 || kb0 == 2'd1 || kb1 == 2'd1, 1'b1};
                t_left <= {kb1 == 2'd3, kb0 == 2'd2, ka1 == 2'd1 || kb0 == 2'd1 || kb1 == 2'd1, 1'b1};
                a_state <= A_ENQ;
            end
            A_ENQ: begin
                if (fq_push) t_left[a_qk] <= 1'b0;
                if (a_dead || t_left == 4'd0) a_state <= A_EG0;
            end

            // ── envelope (golden_pcm.py: rate on the pre-update env_vol) ──
            A_EG0: begin
                t_val <= f_ar;
                if (a_edge) t_mode <= 2'd1;
                else if (!f_keyon && d_est != EG_OFF && d_est != EG_REL) t_mode <= 2'd2;
                else begin
                    t_mode <= 2'd0;
                    case (d_est)
                        EG_DEC:  t_val <= f_d1r;
                        EG_SUS:  t_val <= f_d2r;
                        EG_REL:  t_val <= f_rr;
                        default: t_val <= f_ar;
                    endcase
                end
                a_state <= A_EG1;
            end
            A_EG1: begin
                if (t_mode == 2'd1 || d_est == EG_ATT)
                    t_rate <= calc_eg_rate(t_val, f_rc, $signed(f_oct), f_fn);
                else
                    t_rate <= calc_decay_rate(t_val, f_rc, f_damp, f_prvb, d_env, $signed(f_oct), f_fn);
                a_state <= A_EG2;
            end
            A_EG2: begin
                logic [3:0] sh;
                sh = 4'(eg_rate_shift_rom(t_rate));
                t_shift <= sh;
                t_sel   <= 7'(eg_rate_select_rom(t_rate));
                t_upd   <= (a_fcnt & ((16'd1 << sh) - 16'd1)) == 16'd0;
                t_ph    <= 3'(a_fcnt >> sh);
                a_state <= A_EG3;
            end
            A_EG3: begin
                t_einc  <= 4'(eg_inc_rom(t_sel + {4'd0, t_ph}));
                a_state <= A_EG4;
            end
            A_EG4: begin
                logic signed [15:0] inv;
                logic signed [15:0] prod;
                inv    = 16'($signed(~{1'b0, d_env}));         // -env - 1
                case (t_einc)                                 // inv x inc
                    4'd1:    prod = inv;
                    4'd2:    prod = inv <<< 1;
                    4'd4:    prod = inv <<< 2;
                    4'd8:    prod = inv <<< 3;
                    default: prod = '0;
                endcase
                t_att  <= 12'($signed({2'b00, d_env}) + (prod >>> 4));
                t_esum <= {1'b0, d_env} + {7'd0, t_einc};
                a_state <= A_EG5;
            end
            A_EG5: begin
                case (t_mode)
                    2'd1: if (t_rate < 6'd63) begin
                              d_env <= MAX_ATT_INDEX; d_est <= EG_ATT;
                          end else begin
                              d_env <= MIN_ATT_INDEX; d_est <= (f_dl != 4'd0) ? EG_DEC : EG_SUS;
                          end
                    2'd2: d_est <= EG_REL;
                    default:
                        case (d_est)
                            EG_ATT: if (t_rate < 6'd63 && t_upd) begin
                                        //  golden: env += (~env * inc) >> 4; env &= 0x3FF; <= 0 -> 0
                                        if (t_att[9:0] == 10'd0) begin
                                            d_env <= MIN_ATT_INDEX;
                                            d_est <= (f_dl != 4'd0) ? EG_DEC : EG_SUS;
                                        end else d_env <= t_att[9:0];
                                    end
                            EG_DEC: if (t_upd) begin
                                        logic [9:0] e;
                                        e = (t_esum > 11'h3FF) ? 10'h3FF : t_esum[9:0];
                                        d_env <= e;
                                        if (e >= dl_tab_rom(f_dl))
                                            d_est <= (e < MAX_ATT_INDEX) ? EG_SUS : EG_OFF;
                                    end
                            EG_SUS, EG_REL: if (t_upd) begin
                                        if (t_esum >= {1'b0, MAX_ATT_INDEX}) begin
                                            d_env <= MAX_ATT_INDEX; d_est <= EG_OFF;
                                        end else d_env <= t_esum[9:0];
                                    end
                            default: ;
                        endcase
                endcase
                a_state <= A_AM;
            end

            // ── AM, gains, LFO ──
            A_AM: a_state <= A_ENV;                          // AM on the multiplier
            A_ENV: begin
                logic [10:0] e;
                e = {1'b0, d_env} + {2'd0, t_am};
                t_envt  <= (e >= {1'b0, MAX_ATT_INDEX}) ? MAX_ATT_INDEX : e[9:0];
                a_state <= A_TL;
            end
            //  the gains go straight to RAM-PD (a response there first)
            A_GAIN:  if (!pd_rv || a_dead) a_state <= A_GAIN2;
            A_GAIN2: if (!pd_rv || a_dead) a_state <= A_LFO;
            A_LFO: begin
                d_lfo   <= f_lfoact ? d_lfo + {12'd0, lfo_period_rom(f_lfo)} : 18'd0;
                a_state <= A_PLAN0;
            end
            A_PLAN0: if (!pd_rv || a_dead) a_state <= A_WB0;
            A_WB0: a_state <= A_WB1;
            A_WB1: if (!pd_rv) a_state <= A_NEXT;             // w1 and w7

            // ── the pass ──
            A_NEXT:
                if (a_take) ;                           // the flag clear first
                else if (a_rev) a_state <= A_SCAN;
                else if (a_slot == 5'd23) begin
                    if (a_def != 24'd0) begin
                        a_rev   <= 1'b1;
                        a_slot  <= '0;
                        a_cs    <= FRAME_W'(T_C0 - T_AMARGIN);
                        a_state <= A_SCAN;
                    end else a_state <= A_IDLE;
                end else begin
                    a_slot  <= a_slot + 5'd1;
                    a_cs    <= a_cs + FRAME_W'(T_CSTEP);
                    a_state <= A_SEL;
                end
            //  slots put aside: take one whose header is in or whose deadline has passed
            A_SCAN:
                if (a_def == 24'd0) a_state <= A_IDLE;
                else if (a_def[a_slot] && (!hf_pending[a_slot] || a_past)) begin
                    a_def[a_slot] <= 1'b0;
                    a_state       <= A_SEL;
                end else if (a_slot == 5'd23) begin
                    a_slot <= '0;
                    a_cs   <= FRAME_W'(T_C0 - T_AMARGIN);
                end else begin
                    a_slot <= a_slot + 5'd1;
                    a_cs   <= a_cs + FRAME_W'(T_CSTEP);
                end
            default: a_state <= A_IDLE;
        endcase

        //  end of a pass: the next frame's counters
        if ((a_state == A_NEXT && !a_take && !a_rev && a_slot == 5'd23 && a_def == 24'd0) ||
            (a_state == A_SCAN && a_def == 24'd0)) begin
            a_busy <= 1'b0;
            a_fcnt <= a_fcnt + 16'd1;
            a_tl9  <= (a_tl9 == 4'd8) ? 4'd0 : a_tl9 + 4'd1;
            if (a_tl9 == 4'd8) a_tl3 <= (a_tl3 == 2'd2) ? 2'd0 : a_tl3 + 2'd1;
        end
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Pass B (data): slot s at frame_cycle C_s.  Plan, the four pair words, the two
// samples, interpolation, x env, x TL, x pan, accumulate -- one multiplier.
// ═══════════════════════════════════════════════════════════════════════════

//  plan0 without its stepPtr (B reads that again when it interpolates):
//  {zero, need, fmt, kb1, ob, kb0, ka1, oa, pb, pa}
logic [18:0] b_pf;
logic [3:0]  b_pan;
logic [7:0]  b_a0, b_a1, b_b0, b_b1;
logic        b_miss;               // a needed pair was not in by C_s
logic signed [15:0] b_smp;
logic [15:0] late_cnt;
logic signed [26:0] mul_a, mul_b;    // 27 x 27: the mix gain takes the whole accumulator
logic signed [53:0] mul_p;
logic signed [23:0] acc_l, acc_r;
logic        out_pend;              // a frame end has passed (no pcm_valid before the first)

logic [15:0] prev_m [0:31] /* synthesis ramstyle = "MLAB, no_rw_check" */;
always_ff @(posedge clk) if (b_state == B_SAVE) prev_m[b_cur] <= b_smp;

wire        bp_pa   = b_pf[0];
wire        bp_pb   = b_pf[1];
wire [1:0]  bp_oa   = b_pf[3:2];
wire [1:0]  bp_ka1  = b_pf[5:4];
wire [1:0]  bp_kb0  = b_pf[7:6];
wire [1:0]  bp_ob   = b_pf[9:8];
wire [1:0]  bp_kb1  = b_pf[11:10];
wire [1:0]  bp_fmt  = b_pf[13:12];
wire [3:0]  bp_need = b_pf[17:14];
wire        bp_zero = b_pf[18];

//  RAM-PD reads: w7 (status), plan0, the pairs k0-k3, plan0 again (stepPtr),
//  w1 {pan, env gain}, w6 {TL gain}
always_comb begin
    case (b_state)
        B_IDLE:                   pd_raddr = {b_slot, 3'd7};
        B_ST:                     pd_raddr = {b_cur, 3'd0};
        B_P0:                     pd_raddr = {b_cur, 3'd2};
        B_D0:                     pd_raddr = {b_cur, 3'd3};
        B_D1:                     pd_raddr = {b_cur, 3'd4};
        B_D2:                     pd_raddr = {b_cur, 3'd5};
        B_D3:                     pd_raddr = {b_cur, 3'd0};
        B_DEC, B_I1, B_I2:        pd_raddr = {b_cur, 3'd1};
        default:                  pd_raddr = {b_cur, 3'd6};
    endcase
end

// a sample from its two bytes: 8-bit {b0, 0}; 12-bit even {b0, b1[3:0] 0},
// odd {b1, b0[7:4] 0} (b0 is the shared byte); 16-bit {b0, b1}
function automatic logic signed [15:0] b_decode(input logic [1:0] fmt, input logic odd,
                                                input logic [7:0] x0, input logic [7:0] x1);
    case (fmt)
        2'd0:    return {x0, 8'h00};
        2'd1:    return odd ? {x1, x0[7:4], 4'h0} : {x0, x1[3:0], 4'h0};
        default: return {x0, x1};
    endcase
endfunction

always_ff @(posedge clk) mul_p <= mul_a * mul_b;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        b_state   <= B_IDLE;
        b_slot    <= '0;
        b_c       <= FRAME_W'(T_C0);
        b_cur     <= '0;
        b_busy    <= 1'b0;
        b_miss    <= 1'b0;
        late_cnt  <= '0;
        acc_l     <= '0;
        acc_r     <= '0;
        out_pend  <= 1'b0;
        pcm_left  <= '0;
        pcm_right <= '0;
        pcm_valid <= 1'b0;
        mul_a     <= '0;
        mul_b     <= '0;
    end else begin
        pcm_valid <= 1'b0;
        case (b_state)
            B_IDLE: if (b_take) begin
                b_cur   <= b_slot;
                b_miss  <= 1'b0;
                b_slot  <= b_slot + 5'd1;
                b_c     <= b_c + FRAME_W'(T_CSTEP);
                b_busy  <= 1'b1;
                b_state <= B_ST;
            end
            B_ST: begin
                logic ok;
                ok = (pd_q[3:2] == bfr);
                if (ok && pd_q[1:0] == ST_PLAN) b_state <= B_P0;
                else begin
                    //  no plan for this frame (pass A was behind or the slot stalled),
                    //  unless the slot is silent
                    if (!(ok && pd_q[1:0] == ST_QUIET) && late_cnt != 16'hFFFF)
                        late_cnt <= late_cnt + 16'd1;
                    b_busy  <= 1'b0;
                    b_state <= B_IDLE;
                end
            end
            B_P0: begin b_pf <= pd_q[34:16]; b_state <= B_D0; end
            B_D0, B_D1, B_D2, B_D3: begin
                logic [1:0] k;
                logic [31:0] w;
                k = (b_state == B_D0) ? 2'd0 : (b_state == B_D1) ? 2'd1 :
                    (b_state == B_D2) ? 2'd2 : 2'd3;
                w = pd_q[31:0];
                if (bp_need[k] && !pd_q[32]) b_miss <= 1'b1;
                if (k == 2'd0)   b_a0 <= w[{bp_oa, 3'd0} +: 8];
                if (k == bp_ka1) b_a1 <= w[{bp_oa + 2'd1, 3'd0} +: 8];
                if (k == bp_kb0) b_b0 <= w[{bp_ob, 3'd0} +: 8];
                if (k == bp_kb1) b_b1 <= w[{bp_ob + 2'd1, 3'd0} +: 8];
                b_state <= (b_state == B_D0) ? B_D1 : (b_state == B_D1) ? B_D2 :
                           (b_state == B_D2) ? B_D3 : B_DEC;
            end
            //  interpolation: sA + ((sB - sA) x stepPtr) >> 16 (plan0 is on pd_q again);
            //  a late slot plays its previous sample, or 0 after a restart
            B_DEC: begin
                logic signed [15:0] sa, sb;
                sa = b_decode(bp_fmt, bp_pa, b_a0, b_a1);
                sb = b_decode(bp_fmt, bp_pb, b_b0, b_b1);
                if (b_miss) begin
                    b_smp   <= bp_zero ? 16'sd0 : $signed(prev_m[b_cur]);
                    if (late_cnt != 16'hFFFF) late_cnt <= late_cnt + 16'd1;
                    b_state <= B_SAVE;
                end else begin
                    b_smp   <= sa;
                    mul_a   <= 27'($signed({sb[15], sb}) - $signed({sa[15], sa}));
                    mul_b   <= $signed({11'd0, pd_q[15:0]});
                    b_state <= B_I1;
                end
            end
            B_I1: b_state <= B_I2;
            B_I2: begin
                b_smp   <= b_smp + 16'(mul_p >>> 16);
                b_state <= B_SAVE;
            end
            //  vol_factor(vol_factor(sample, env), TL << 2): (x * scale) >> 15 twice
            B_SAVE: begin
                mul_a   <= 27'(b_smp);
                mul_b   <= $signed({11'd0, pd_q[15:0]});      // w1: env gain
                b_pan   <= pd_q[19:16];
                b_state <= B_E1;
            end
            B_E1: b_state <= B_E2;
            B_E2: begin
                mul_a   <= 27'($signed(18'(mul_p >>> 15)));
                mul_b   <= $signed({11'd0, pd_q[15:0]});      // w6: TL gain
                b_state <= B_T1;
            end
            B_T1: b_state <= B_T2;
            B_T2: begin
                mul_a   <= 27'($signed(18'(mul_p >>> 15)));
                mul_b   <= $signed({21'd0, pan_att_left(b_pan)});
                b_state <= B_L1;
            end
            B_L1: begin
                mul_b   <= $signed({21'd0, pan_att_right(b_pan)});
                b_state <= B_L2;
            end
            B_L2: begin
                acc_l   <= acc_l + 24'(mul_p >>> 5);
                b_state <= B_R2;
            end
            B_R2: begin
                acc_r   <= acc_r + 24'(mul_p >>> 5);
                b_busy  <= 1'b0;
                b_state <= B_IDLE;
            end
            default: b_state <= B_IDLE;
        endcase

        // ── frame output on the multiplier (pass B is done by CPF - 3): the mix
        //    gain {1, 3/4, 1/2, 3/8, 1/4, 3/16, 1/8, 0} is (x * g) >>> 4 with g =
        //    {16, 12, 8, 6, 4, 3, 2, 0}, the floors of pcm_mix_gain exactly.  L at
        //    CPF - 3, R at CPF - 2; pcm_valid at frame_cycle 1 as before ──
        if (frame_cycle == FRAME_W'(CPF - 3) || frame_cycle == FRAME_W'(CPF - 2)) begin
            logic r;
            logic [1:0] sh;
            r  = (frame_cycle == FRAME_W'(CPF - 2));
            sh = 2'd3 - pcm_vol;
            mul_a <= 27'((r ? acc_r : acc_l) >>> sh);
            mul_b <= $signed({22'd0, mix_g(r ? pcm_mix_r : pcm_mix_l)});
            if (r) begin acc_l <= '0; acc_r <= '0; end
        end
        if (frame_cycle == FRAME_W'(CPF - 1)) pcm_left <= sat16(24'(mul_p >>> 4));
        if (frame_cycle == FRAME_W'(0) && out_pend) begin
            pcm_right <= sat16(24'(mul_p >>> 4));
            pcm_valid <= 1'b1;
        end
        if (sample_start) begin
            out_pend <= 1'b1;
            b_slot   <= '0;
            b_c      <= FRAME_W'(T_C0);
        end
    end
end

function automatic logic [4:0] mix_g(input logic [2:0] i);
    case (i)
        3'd0: return 5'd16;  3'd1: return 5'd12;  3'd2: return 5'd8;  3'd3: return 5'd6;
        3'd4: return 5'd4;   3'd5: return 5'd3;   3'd6: return 5'd2;  default: return 5'd0;
    endcase
endfunction

function automatic signed [15:0] sat16(input signed [23:0] x);
    return (x > 24'sd32767) ? 16'sh7FFF : (x < -24'sd32768) ? 16'sh8000 : x[15:0];
endfunction

`ifndef SYNTHESIS
always @(posedge clk) if (rst_n && frame_cycle == FRAME_W'(CPF - 3) && b_state != B_IDLE)
    $error("ymf278_pcm_engine3: pass B still busy at the frame end");
`endif

// ═══════════════════════════════════════════════════════════════════════════
// Debug ports: engine2's taps that engine3 has; the rest are 0 (engine2 ties the
// slot-0 views to 0 too).  dbg_slot_active / envlive: SPEC H10, not yet.
// ═══════════════════════════════════════════════════════════════════════════
assign dbg_late_cnt    = late_cnt;
assign dbg_wavetblhdr  = wavetblhdr;
assign dbg_hf_pending  = hf_pending;
assign fm_mix_l_o      = fm_mix_l;
assign fm_mix_r_o      = fm_mix_r;
assign dbg_slot_keyon  = '0;
assign dbg_slot_active = '0;
assign dbg_slot_envlive = '0;
assign dbg_slot0_wave  = '0;
assign dbg_slot0_fn    = '0;
assign dbg_slot0_oct   = '0;
assign dbg_slot0_prvb  = 1'b0;
assign dbg_slot0_keyon = 1'b0;
assign dbg_slot0_damp  = 1'b0;
assign dbg_slot0_pan   = '0;
assign dbg_slot0_ar    = '0;
assign dbg_slot0_d1r   = '0;
assign dbg_slot5_wave  = '0;
assign dbg_slot23_wave = '0;
assign dbg_slot0_hdr_start = '0;
assign dbg_slot0_hdr_loop  = '0;
assign dbg_slot0_hdr_end   = '0;
assign dbg_slot0_hdr_bits  = '0;
assign dbg_slot0_dyn_pos       = '0;
assign dbg_slot0_dyn_stepPtr   = '0;
assign dbg_slot0_dyn_env_vol   = '0;
assign dbg_slot0_dyn_env_state = '0;
assign dbg_stage_b_bytes_done  = 1'b0;
assign dbg_stage_advance       = 1'b0;
assign dbg_stage_b_valid       = 1'b0;

endmodule

// RAM-R: 240 x 8, one write port, one registered read port.  Written in the
// shape Quartus maps to one M10K (simple dual-port); whether a build did is its
// fit report's RAM summary, never this comment (SKILL rule 3).
module pcm_regram (
    input  wire        clk,
    input  wire        we,
    input  wire  [7:0] waddr,
    input  wire  [7:0] wd,
    input  wire  [7:0] raddr,
    output logic [7:0] rd
);
    logic [7:0] m [0:239];
    always_ff @(posedge clk) begin
        if (we) m[waddr] <= wd;
        rd <= m[raddr];
    end
endmodule

// RAM-S / RAM-PD: one write port, one registered read port (one M10K each at
// 128 x 40 and 256 x 40; the fit report's RAM summary is the evidence).
module pcm_sdp #(
    parameter int W  = 40,
    parameter int AW = 7
) (
    input  wire           clk,
    input  wire           we,
    input  wire  [AW-1:0] waddr,
    input  wire  [W-1:0]  wd,
    input  wire  [AW-1:0] raddr,
    output logic [W-1:0]  rd
);
    logic [W-1:0] m [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) m[waddr] <= wd;
        rd <= m[raddr];
    end
endmodule
`default_nettype wire
