`default_nettype none
// ═══════════════════════════════════════════════════════════════════════════
// YMF278B PCM engine v4 -- from-scratch rebuild (docs/opl4_scratch/PLAN.md, DESIGN.md)
// ═══════════════════════════════════════════════════════════════════════════
// P2 skeleton: the CPU side only.  Register file, header fetch + backfill, the
// reg 3-6 wave-memory port and its BUSY, reset.  No slot is played yet: the
// output is silence at 44.1 kHz (P3 adds the datapath).
//
// Same module ports as ymf278_pcm_engine2, and the same CPU-visible semantics
// (SPEC.md sections B-C; cpuvis flags D3, D4, D7 are kept on purpose until the
// DESIGN decision 1 is taken), with three differences:
//   * the slot registers live in ONE memory (RAM-R, 48 words x 5 bytes, byte
//     enables: M10K), not in 30 MLABs;
//   * a reg 6 write keeps cpu_mem_busy up until the write has left the ch4
//     bridge (PLAN goal 5), not only until it was issued -- the top then needs
//     no 1024-clk MEM_WRITE_DELAY to keep an R800 OTIR from outrunning SDRAM;
//   * a wave-number write that lands while that slot's header is being fetched
//     makes the fetch run again (engine2 stored the header of the old number);
//   * after reset the registers read as openMSX's reset leaves them (field 4 = 0,
//     fields 5-9 = wave 0's header), not engine2's 20h / 0 (cpuvis D10, D11).
`default_nettype none

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
    input  wire         mem_rd_valid,
    output logic        mem_wr_en,
    output logic [7:0]  mem_wr_data,
    input  wire         mem_busy,

    input  wire  [1:0]         pcm_vol,

    // Audio output
    output logic signed [15:0] pcm_left,
    output logic signed [15:0] pcm_right,
    output logic               pcm_valid,

    // Debug ports (engine2's set; the P2 skeleton drives the CPU-side ones)
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
    output logic [23:0] dbg_slot_envlive
);

// ═══════════════════════════════════════════════════════════════════════════
// Frame
// ═══════════════════════════════════════════════════════════════════════════
localparam int CYCLES_PER_FRAME = CLK_HZ / 44100;
localparam int FRAME_W          = $clog2(CYCLES_PER_FRAME);

logic [FRAME_W-1:0] frame_cycle;
wire sample_start = (frame_cycle == FRAME_W'(CYCLES_PER_FRAME - 1));

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_cycle <= '0;
        pcm_valid   <= 1'b0;
    end else begin
        frame_cycle <= sample_start ? '0 : frame_cycle + 1'd1;
        pcm_valid   <= sample_start;
    end
end
assign pcm_left  = '0;
assign pcm_right = '0;

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

// Fields are stored as written.  (engine2 stores field 4 with bit 5 inverted, so its
// all-zero reset image reads back 20h; openMSX's reset writes 0 to every register,
// reads back 0 and leaves the LFO running: cpuvis D10.)

// ═══════════════════════════════════════════════════════════════════════════
// RAM-R: slot s, fields 0-4 at word 2s, fields 5-9 at word 2s+1, byte lane =
// field mod 5.  Port B: every write (reset sweep, header backfill, CPU) and,
// when no write needs it, the CPU readback.  Port A: the engine (P2: the wave
// number for a header fetch; P3: the slot load).
// ═══════════════════════════════════════════════════════════════════════════
logic        rb_we;
logic [4:0]  rb_be;
logic [5:0]  rb_addr;
logic [39:0] rb_wd, rb_rd;
logic [5:0]  ra_addr;
logic [39:0] ra_rd;
pcm_regram u_regram (.clk, .we_b(rb_we), .be_b(rb_be), .addr_b(rb_addr), .wd_b(rb_wd), .rd_b(rb_rd),
                     .addr_a(ra_addr), .rd_a(ra_rd));

// Reset: the memory has no reset, so zeros are swept through all 48 words while
// rst_n is low.  LOAD-BEARING: rst_n must stay low >= 48 clk (engine2: 24).  The
// MSX reset (rst_hold, 252 clk) and upload_hold are longer; the harness `reset`
// gate runs the cpuvis warm reset at 48 (pass) and 40 (must fail).
wire        clr_run = ~rst_n;
logic [5:0] clr_idx = '0;
always_ff @(posedge clk) clr_idx <= (clr_idx == 6'd47) ? 6'd0 : clr_idx + 6'd1;

// header backfill request (from the service FSM below)
logic        bf_now;
logic [4:0]  bf_slot;
logic [4:0]  bf_be;
logic [39:0] bf_wd;

// CPU slot-register write, queued one entry deep: it waits while the sweep or a
// backfill holds port B, and it always goes AFTER a backfill of the same cycle,
// so a CPU write wins over the header as openMSX's synchronous backfill does.
logic        wq_v;
logic [5:0]  wq_word;
logic [2:0]  wq_lane;
logic [7:0]  wq_d;
wire         wq_go = wq_v && !clr_run && !bf_now;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wq_v <= 1'b0;
    else begin
        if (wq_go) wq_v <= 1'b0;
        if (wr_slot_reg) begin
            wq_v    <= 1'b1;
            wq_word <= {wr_snum, wr_field >= 4'd5};
            wq_lane <= 3'((wr_field >= 4'd5) ? wr_field - 4'd5 : wr_field);
            wq_d    <= reg_data;
        end
    end
end
`ifndef SYNTHESIS
always @(posedge clk) if (rst_n && wr_slot_reg && wq_v && !wq_go)
    $display("ymf278_pcm_engine3: CPU write queue overflow (writes closer than 2 clk)");
`endif

// readback pipeline: address (q1), port B read (q2), byte select (reg_rd_data)
logic [5:0] rd_word_q1;
logic [2:0] rd_lane_q1, rd_lane_q2;
logic       rd_ns_q1, rd_ns_q2, rd_upd_q2;
logic [3:0] rd_nsidx_q1, rd_nsidx_q2;
wire        ns_hit = (reg_addr <= 8'h07) || (reg_addr >= 8'hF8);
wire [3:0]  ns_idx = {reg_addr[7], reg_addr[2:0]};

always_comb begin
    rb_we   = 1'b0;
    rb_be   = '0;
    rb_addr = rd_word_q1;
    rb_wd   = '0;
    if (clr_run) begin
        rb_we = 1'b1; rb_be = '1; rb_addr = clr_idx;
    end else if (bf_now) begin
        rb_we = 1'b1; rb_be = bf_be; rb_addr = {bf_slot, 1'b1}; rb_wd = bf_wd;
    end else if (wq_v) begin
        rb_we = 1'b1; rb_addr = wq_word;
        rb_be[wq_lane] = 1'b1;
        rb_wd = {5{wq_d}};
    end
end

logic [7:0] ns_reg [0:15];    // 00h-07h -> 0..7, F8h-FFh -> 8..15
always_ff @(posedge clk) begin
    rd_word_q1  <= {wr_snum, wr_field >= 4'd5};
    rd_lane_q1  <= 3'((wr_field >= 4'd5) ? wr_field - 4'd5 : wr_field);
    rd_ns_q1    <= ns_hit;
    rd_nsidx_q1 <= ns_idx;
    rd_lane_q2  <= rd_lane_q1;
    rd_ns_q2    <= rd_ns_q1;
    rd_nsidx_q2 <= rd_nsidx_q1;
    rd_upd_q2   <= !rb_we;            // port B read this cycle (not a write)
    if (rd_ns_q2)       reg_rd_data <= ns_reg[rd_nsidx_q2];
    else if (rd_upd_q2) reg_rd_data <= rb_rd[8*rd_lane_q2 +: 8];
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
            reg02_mem_access_mode <= reg_data[0];   // not consulted by reg 6 (cpuvis D3)
        end
        if (reg_addr == 8'hF8) begin fm_mix_l  <= reg_data[2:0]; fm_mix_r  <= reg_data[5:3]; end
        if (reg_addr == 8'hF9) begin pcm_mix_l <= reg_data[2:0]; pcm_mix_r <= reg_data[5:3]; end
    end
end
assign reg02_readback = {3'b001, wavetblhdr, reg02_mem_type, reg02_mem_access_mode};

// ═══════════════════════════════════════════════════════════════════════════
// Per-slot flags
// ═══════════════════════════════════════════════════════════════════════════
logic [23:0] keyon_v;
logic [23:0] hf_pending;      // header fetch wanted (set by a wave-number write)
logic [4:0]  bf_dirty [0:23]; // fields 5..9 written since the wave-number write: no backfill
logic        hf_busy;         // the service FSM is fetching hf_slot's header
logic [4:0]  hf_slot;
logic        hf_again;        // hf_slot's wave number was written during its fetch
wire         wr_wave = wr_slot_reg && (wr_field == 4'd0);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        keyon_v    <= '0;
        //  openMSX's reset writes 0 to every register, so the last writes, wave
        //  number 0 on each slot, load wave 0's header and backfill fields 5-9 from
        //  it (YMF278.cc reset -> writeRegDirect case 0).  engine2 leaves them 0
        //  (cpuvis D11).  All 24 fetches are queued here.
        hf_pending <= '1;
        hf_again   <= 1'b0;
        for (int i = 0; i < 24; i++) bf_dirty[i] <= '0;
    end else begin
        if (bf_now) begin
            if (!hf_again) hf_pending[hf_slot] <= 1'b0;
            hf_again <= 1'b0;
        end
        if (wr_wave) begin
            hf_pending[wr_snum] <= 1'b1;
            if (hf_busy && wr_snum == hf_slot) hf_again <= 1'b1;
        end
        if (wr_slot_reg) begin
            case (wr_field)
                4'd0: bf_dirty[wr_snum] <= '0;
                4'd4: keyon_v[wr_snum]  <= reg_data[7];
                4'd5, 4'd6, 4'd7, 4'd8, 4'd9: bf_dirty[wr_snum][wr_field - 4'd5] <= 1'b1;
                default: ;
            endcase
        end
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// CPU wave-memory port (regs 3-6), engine2 semantics: reg 3/4 move the address
// at once (cpuvis D4), a reg 5 write or reg 6 read prefetches the next byte
// (D7), reg 6 reads/writes do not look at reg 2 bit 0 (D3).
// ═══════════════════════════════════════════════════════════════════════════
logic [23:0] cpu_mem_adr;
logic [7:0]  cpu_wr_data;
logic        cpu_rd_pend, cpu_wr_pend, cpu_rd_out, cpu_wr_out;
logic        cpu_rd_issue, cpu_wr_issue, cpu_wr_done;
logic [7:0]  cpu_mem_rd_buf;
wire cpu_adr_set_l = reg_wr && (reg_addr == 8'h05);
wire cpu_rd_06     = reg_rd && (reg_addr == 8'h06);
wire cpu_wr_06     = reg_wr && (reg_addr == 8'h06);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_mem_adr <= '0;
        cpu_wr_data <= '0;
        cpu_rd_pend <= 1'b0;
        cpu_wr_pend <= 1'b0;
        cpu_rd_out  <= 1'b0;
        cpu_wr_out  <= 1'b0;
        cpu_mem_rd_buf <= '0;
    end else begin
        if (reg_wr && reg_addr == 8'h03) cpu_mem_adr[23:16] <= reg_data;
        if (reg_wr && reg_addr == 8'h04) cpu_mem_adr[15:8]  <= reg_data;
        if (cpu_adr_set_l)               cpu_mem_adr[7:0]   <= reg_data;
        if ((cpu_rd_06 || cpu_wr_issue) && !cpu_adr_set_l) cpu_mem_adr <= cpu_mem_adr + 24'd1;
        if (cpu_wr_06) cpu_wr_data <= reg_data;

        if (cpu_rd_issue) cpu_rd_pend <= 1'b0;
        if (cpu_adr_set_l || cpu_rd_06) cpu_rd_pend <= 1'b1;
        if (cpu_wr_issue) cpu_wr_pend <= 1'b0;
        if (cpu_wr_06)    cpu_wr_pend <= 1'b1;

        if (cpu_rd_issue) cpu_rd_out <= 1'b1;
        else if (mem_rd_valid && cpu_rd_out) begin
            cpu_rd_out     <= 1'b0;
            cpu_mem_rd_buf <= mem_rd_data;
        end
        if (cpu_wr_issue)     cpu_wr_out <= 1'b1;
        else if (cpu_wr_done) cpu_wr_out <= 1'b0;
    end
end
assign cpu_mem_rd_data = cpu_mem_rd_buf;
//  a write counts until it has left the bridge (cpu_wr_out), not until it is issued
assign cpu_mem_busy    = cpu_rd_pend | cpu_wr_pend | cpu_rd_out | cpu_wr_out;

// ═══════════════════════════════════════════════════════════════════════════
// Service FSM: owns the memory port.  A CPU read, a CPU write, then the header
// fetch; a header fetch steps aside for a CPU op between two of its words
// (hf_resume) and picks up where it left off.  Every request waits for the
// bridge to be free (it takes one at a time).
// ═══════════════════════════════════════════════════════════════════════════
typedef enum logic [3:0] {
    SV_IDLE, SV_RD_WAIT, SV_WR_SETTLE, SV_WR_COMMIT,
    SV_HDR_WAVE, SV_HDR_WREAD, SV_HDR_BASE, SV_HDR_ISSUE, SV_HDR_WAIT, SV_HDR_STORE
} sv_state_t;
sv_state_t   sv_state;
logic [1:0]  sv_cnt;
logic        hf_resume;             // a header fetch is parked behind a CPU op
logic [2:0]  hf_widx;               // header word 0..6 (7 words cover 12 bytes at any alignment)
logic [7:0]  hf_buf [0:13];
logic [21:0] hf_base;
logic [8:0]  hf_wave;

wire mem_free = !mem_busy && !mem_rd_en && !mem_wr_en;
wire cpu_op   = (cpu_rd_pend || cpu_wr_pend) && !cpu_rd_issue && !cpu_wr_issue;

// lowest pending slot
logic       hf_found;
logic [4:0] hf_pick;
always_comb begin
    hf_found = 1'b0;
    hf_pick  = '0;
    for (int i = 23; i >= 0; i--)
        if (hf_pending[i]) begin hf_found = 1'b1; hf_pick = 5'(i); end
end

assign ra_addr = {hf_slot, 1'b0};    // fields 0/1 of the slot being fetched
assign hf_busy = hf_resume || (sv_state >= SV_HDR_WAVE);

wire [21:0] hf_base_c = (hf_wave < 9'd384 || wavetblhdr == 3'd0)
    ? 22'({13'd0, hf_wave} * 22'd12)
    : 22'({wavetblhdr, 19'd0} + ({13'd0, hf_wave - 9'd384} * 22'd12));
wire [21:0] hf_word_addr = {hf_base[21:1] + 21'(hf_widx), 1'b0};

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sv_state     <= SV_IDLE;
        sv_cnt       <= '0;
        hf_resume    <= 1'b0;
        hf_slot      <= '0;
        hf_widx      <= '0;
        hf_base      <= '0;
        hf_wave      <= '0;
        mem_addr     <= '0;
        mem_rd_en    <= 1'b0;
        mem_wr_en    <= 1'b0;
        mem_wr_data  <= '0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        cpu_wr_done  <= 1'b0;
        bf_now       <= 1'b0;
    end else begin
        mem_rd_en    <= 1'b0;
        mem_wr_en    <= 1'b0;
        cpu_rd_issue <= 1'b0;
        cpu_wr_issue <= 1'b0;
        cpu_wr_done  <= 1'b0;
        bf_now       <= 1'b0;
        case (sv_state)
            SV_IDLE:
                if (cpu_op) begin
                    if (mem_free) begin
                        mem_addr <= cpu_mem_adr[21:0];
                        if (cpu_rd_pend) begin
                            mem_rd_en    <= 1'b1;
                            cpu_rd_issue <= 1'b1;
                            sv_state     <= SV_RD_WAIT;
                        end else begin
                            mem_wr_data  <= cpu_wr_data;
                            mem_wr_en    <= 1'b1;
                            cpu_wr_issue <= 1'b1;
                            sv_cnt       <= '0;
                            sv_state     <= SV_WR_SETTLE;
                        end
                    end
                end else if (hf_resume) begin
                    hf_resume <= 1'b0;
                    sv_state  <= SV_HDR_ISSUE;
                //  not while a CPU slot-register write is still queued (the wave
                //  number read below must see it), and not in the backfill cycle
                //  (hf_pending of the slot just stored clears at its end)
                end else if (hf_found && !wq_v && !bf_now) begin
                    hf_slot  <= hf_pick;
                    hf_widx  <= '0;
                    sv_state <= SV_HDR_WAVE;
                end
            SV_RD_WAIT:
                if (mem_rd_valid) sv_state <= SV_IDLE;
            //  A write is done when the bridge is idle again.  Wait 3 clk first so it
            //  has left IDLE (a memory that never raises mem_busy for a write, the
            //  benches' model, is done after those 3 clk).
            SV_WR_SETTLE: begin
                sv_cnt <= sv_cnt + 2'd1;
                if (sv_cnt == 2'd2) sv_state <= SV_WR_COMMIT;
            end
            SV_WR_COMMIT:
                if (!mem_busy) begin
                    cpu_wr_done <= 1'b1;
                    sv_state    <= SV_IDLE;
                end
            SV_HDR_WAVE:  sv_state <= SV_HDR_WREAD;      // port A address -> read
            SV_HDR_WREAD: begin
                hf_wave  <= {ra_rd[8], ra_rd[7:0]};       // field 1 bit 0, field 0
                sv_state <= SV_HDR_BASE;
            end
            SV_HDR_BASE: begin
                hf_base  <= hf_base_c;
                sv_state <= SV_HDR_ISSUE;
            end
            SV_HDR_ISSUE:
                if (cpu_op) begin
                    hf_resume <= 1'b1;
                    sv_state  <= SV_IDLE;
                end else if (mem_free) begin
                    mem_addr  <= hf_word_addr;
                    mem_rd_en <= 1'b1;
                    sv_state  <= SV_HDR_WAIT;
                end
            SV_HDR_WAIT:
                if (mem_rd_valid) begin
                    logic [22:0] off;
                    off = {1'b0, hf_word_addr} - {1'b0, hf_base};
                    if (off <= 23'd13)         hf_buf[off[3:0]]        <= mem_rd_data16[7:0];
                    if (off + 23'd1 <= 23'd13) hf_buf[off[3:0] + 4'd1] <= mem_rd_data16[15:8];
                    if (hf_widx == 3'd6) sv_state <= SV_HDR_STORE;
                    else begin
                        hf_widx  <= hf_widx + 3'd1;
                        sv_state <= SV_HDR_ISSUE;
                    end
                end
            SV_HDR_STORE: begin
                bf_now   <= 1'b1;
                sv_state <= SV_IDLE;
            end
            default: sv_state <= SV_IDLE;
        endcase
    end
end

// backfill: header bytes 7..11 -> fields 5..9, except the ones the CPU wrote
always_comb begin
    bf_slot = hf_slot;
    bf_be   = ~bf_dirty[hf_slot];
    bf_wd   = {hf_buf[11], hf_buf[10], hf_buf[9], hf_buf[8], hf_buf[7]};
end

// The header itself (bits / start / loop / end), for the P3 datapath.
typedef struct packed {
    logic [21:0] startAddr;
    logic [15:0] loopAddr;
    logic [15:0] endAddr;     // stored 2's-complement form (header bytes 5-6)
    logic [1:0]  bits;
} slot_header_t;
slot_header_t hdr_ram [0:23];
always_ff @(posedge clk) if (bf_now)
    hdr_ram[hf_slot] <= '{startAddr: {hf_buf[0][5:0], hf_buf[1], hf_buf[2]},
                          loopAddr:  {hf_buf[3], hf_buf[4]},
                          endAddr:   {hf_buf[5], hf_buf[6]},
                          bits:      hf_buf[0][7:6]};

// ═══════════════════════════════════════════════════════════════════════════
// Debug ports: engine2's taps that the P2 skeleton has; the rest are 0
// (engine2 ties the slot-0 views to 0 too).  dbg_slot_active / envlive come
// with the P3 datapath (SPEC H10).
// ═══════════════════════════════════════════════════════════════════════════
assign dbg_wavetblhdr  = wavetblhdr;
assign dbg_hf_pending  = hf_pending;
assign fm_mix_l_o      = fm_mix_l;
assign fm_mix_r_o      = fm_mix_r;
assign dbg_slot_keyon  = keyon_v;
assign dbg_slot_active = '0;
assign dbg_slot_envlive = '0;
assign dbg_slot0_wave  = '0;
assign dbg_slot0_fn    = '0;
assign dbg_slot0_oct   = '0;
assign dbg_slot0_prvb  = 1'b0;
assign dbg_slot0_keyon = keyon_v[0];
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

// RAM-R: 48 x 40, byte enables on port B (read/write), port A read only.  Both
// reads registered.  Written in the shape Quartus maps to one M10K; whether it did
// is the map report's RAM summary, never this comment (SKILL rule 3).
module pcm_regram (
    input  wire         clk,
    input  wire         we_b,
    input  wire  [4:0]  be_b,
    input  wire  [5:0]  addr_b,
    input  wire  [39:0] wd_b,
    output logic [39:0] rd_b,
    input  wire  [5:0]  addr_a,
    output logic [39:0] rd_a
);
    logic [4:0][7:0] m [0:47];
    always_ff @(posedge clk) begin
        if (we_b)
            for (int i = 0; i < 5; i++)
                if (be_b[i]) m[addr_b][i] <= wd_b[8*i +: 8];
        rd_b <= m[addr_b];
    end
    always_ff @(posedge clk) rd_a <= m[addr_a];
endmodule
`default_nettype wire
