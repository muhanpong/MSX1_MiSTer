// YMF278B (OPL4) Top-Level
// Integrates YMF262 (OPL3 FM) + YMF278 (PCM wave) with I/O port arbitration.
// Targets MSX MoonSound cartridge I/O map: WAVE=0x7E/7F, FM=0xC4-0xC7
`default_nettype none

module ymf278b_top #(
    parameter int CLK_HZ     = 33868800,
    parameter int CLK_OPL3   = 14318180  // OPL3 master clock (14.318MHz)
) (
    input  wire        clk,          // 33.8688 MHz master
    input  wire        clk_opl3,     // 14.318 MHz for OPL3 core
    input  wire        rst_n,

    // CPU I/O bus
    input  wire [7:0]  io_port,
    input  wire [7:0]  io_data_in,
    input  wire        io_wr,
    input  wire        io_rd,
    output logic [7:0] io_data_out,
    output logic       io_ack,

    // External memory bus (for PCM sample data)
    output logic [21:0] mem_addr,
    output logic        mem_rd_req,
    input  wire  [7:0]  mem_rd_data,
    input  wire  [15:0] mem_rd_data16,
    input  wire         mem_rd_valid,
    output logic        mem_wr_req,
    output logic [7:0]  mem_wr_data,
    input  wire         mem_busy,

    // Audio output
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid,

    // IRQ (from OPL3 timers)
    output logic       irq_n,

    // Audio mute controls (for debugging)
    input  wire        pcm_mute,
    input  wire        fm_mute,
    input  wire  [1:0] pcm_vol,    // OSD master PCM gain select

    // Debug outputs (clk_sdram domain)
    output wire        dbg_pcm_valid,
    output wire        dbg_opl3_valid,
    output wire signed [15:0] dbg_pcm_level,
    output wire        dbg_new2,
    output wire [4:0]  dbg_keyon_count,
    output wire [4:0]  dbg_accum_cnt,
    output wire [9:0]  dbg_env_min,
    output wire        dbg_mem_nonzero,
    output wire        dbg_pcm_base_set,
    output wire [23:0] dbg_slot_keyon,
    output wire [23:0] dbg_slot_active,
    output wire [23:0] dbg_slot_envlive,
    output logic       dbg_ack_stopped   // reg4 (timer ack) writes stopped reaching OPL3
);

// ─── OPL3 core (gtaylormb opl3.sv) ───────────────────────────────────
// The opl3 module uses its own internal clock divider to hit ~49.7kHz.
// We use it at 14.318MHz to get the standard OPL3 sample rate.
logic [7:0]  opl3_status;
logic        opl3_sample_valid;
logic signed [23:0] opl3_left, opl3_right;

// OPL3 register write signals from ymf278b_regs
logic [8:0]  opl3_reg_addr;
logic [7:0]  opl3_reg_data;
logic        opl3_reg_wr;
logic        opl3_status_rd;
logic        opl3_reg_rd;
logic [7:0]  opl3_reg_dout;

// NEW2 bit — from OPL3 register 0x105[1]
logic        new2;

// Register file from OPL3 (we tap register 0x105 via a small shadow)
logic [7:0]  opl3_reg_shadow [0:1];  // bank1[0x05]
always_ff @(posedge clk) begin
    if (opl3_reg_wr && opl3_reg_addr == 9'h105)
        opl3_reg_shadow[0] <= opl3_reg_data;
end
assign new2 = opl3_reg_shadow[0][1];

// Ack-reach detector (clk): latch if, WHILE the OPL irq is asserted (ft1 set →
// irq_n low), no reg4 (timer-control) write reaches the OPL3 write stage for too
// long (>~3ms).  Gating on irq_n means it only fires when an ack IS needed but
// isn't arriving — not in the idle/boot state (irq deasserted, no reg4 traffic).
//   dbg_ack_stopped LIT during the freeze => irq stuck AND ack never reaches here
//                                            → bridge/ymf278b_regs drop the ack
//   dbg_ack_stopped OFF during the freeze => the reg4 ack DOES reach here (resets
//                                            the gap) → afifo/timers drop/ignore it
logic [17:0] ack_gap_cnt;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ack_gap_cnt     <= 0;
        dbg_ack_stopped <= 0;
    end else begin
        if (opl3_reg_wr && opl3_reg_addr == 9'd4) ack_gap_cnt <= 0;  // ack reached → reset
        else if (irq_n)                           ack_gap_cnt <= 0;  // irq idle → not relevant
        else if (~&ack_gap_cnt)                   ack_gap_cnt <= ack_gap_cnt + 1'b1;
        if (&ack_gap_cnt) dbg_ack_stopped <= 1'b1;
    end
end

// OPL3 chip instantiation (gtaylormb opl3_fpga)
// host_if uses edge detection (wr_p1 && !wr_p2), so consecutive-cycle writes are dropped.
// Three-stage write protocol to meet the afifo write edge requirement:
//   Cycle 0 (wr):  cs_n=0, address[0]=0 → address-mode write (register number + bank)
//   Cycle 1 (d1):  cs_n=1                → idle gap (creates falling edge for d2)
//   Cycle 2 (d2):  cs_n=0, address[0]=1 → data-mode write (register value)
// clk_host=clk (clk_sdram): afifo write side matches the domain of opl3_reg_wr signals.
logic opl3_reg_wr_d1, opl3_reg_wr_d2;
always_ff @(posedge clk) begin
    opl3_reg_wr_d1 <= opl3_reg_wr;
    opl3_reg_wr_d2 <= opl3_reg_wr_d1;
end

logic [7:0] opl3_status_raw;

opl3 u_opl3 (
    .clk          (clk_opl3),
    .clk_host     (clk),           // host write signals are in clk (clk_sdram) domain
    .clk_dac      (clk_opl3),
    .ic_n         (rst_n),
    // cs_n/wr_n: active on wr (address phase) and d2 (data phase); d1 is idle gap
    .cs_n         (~(opl3_reg_wr | opl3_reg_wr_d2 | opl3_reg_rd)),
    .rd_n         (~opl3_reg_rd),
    .wr_n         (~(opl3_reg_wr | opl3_reg_wr_d2)),
    // wr: address[0]=0 (address mode); d2: address[0]=1 (data mode)
    .address      (opl3_reg_wr ? {opl3_reg_addr[8], 1'b0}   // address phase
                               : {opl3_reg_addr[8], 1'b1}),  // data phase (d2)
    .din          (opl3_reg_wr ? opl3_reg_addr[7:0] : opl3_reg_data),
    .dout         (opl3_reg_dout),
    .sample_valid (opl3_sample_valid),
    .sample_l     (opl3_left),
    .sample_r     (opl3_right),
    .led          (),
    .irq_n        (irq_n),
    .status_o     (opl3_status_raw)
);

// OPL3 status (timer1/2 overflow + IRQ) crosses from the OPL3 clock domain
// (clk_opl3) to clk (clk_sdram), where ymf278b_regs serves the CPU status
// read.  2-FF synchronizer; the status changes slowly (timer rates) and the
// CPU polls it repeatedly, so a rare incoherent multi-bit sample is harmless.
logic [7:0] opl3_status_s1, opl3_status_s2;
always_ff @(posedge clk) begin
    opl3_status_s1 <= opl3_status_raw;
    opl3_status_s2 <= opl3_status_s1;
end

// ─── PCM wave engine ─────────────────────────────────────────────────
logic [7:0]  pcm_reg_addr, pcm_reg_data;
logic        pcm_reg_wr, pcm_reg_rd;
logic [7:0]  pcm_reg_dout;
logic signed [15:0] pcm_left, pcm_right;
logic               pcm_valid;

// Memory interface
logic [21:0] pcm_mem_addr;
logic        pcm_mem_rd_req;
logic [7:0]  pcm_cpu_mem_reg, pcm_cpu_mem_data;
logic        pcm_cpu_mem_wr, pcm_cpu_mem_rd;
logic [7:0]  pcm_cpu_mem_rd_data;
logic        pcm_cpu_mem_ack;
logic        pcm_reg_rd_done;

wire [7:0] pcm_cpu_mem_rd_data_w;
wire       pcm_cpu_mem_busy_w;
wire [7:0] pcm_reg02_readback_w;

ymf278_pcm_engine #(
    .CLK_HZ (CLK_HZ)
) u_pcm (
    .clk             (clk),
    .rst_n           (rst_n),

    // CPU Register Interface — reg 0x06 read path now wired through to engine
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),
    .reg_rd          (pcm_reg_rd),
    .cpu_mem_rd_data (pcm_cpu_mem_rd_data_w),
    .cpu_mem_busy    (pcm_cpu_mem_busy_w),
    .reg02_readback  (pcm_reg02_readback_w),

    // SDRAM Direct Port
    .mem_addr        (mem_addr),
    .mem_rd_en       (mem_rd_req),
    .mem_rd_data     (mem_rd_data),
    .mem_rd_data16   (mem_rd_data16),
    .mem_rd_valid    (mem_rd_valid),
    .mem_wr_en       (mem_wr_req),
    .mem_wr_data     (mem_wr_data),
    .mem_busy        (mem_busy),

    // Audio Output
    .pcm_vol         (pcm_vol),
    .pcm_left        (pcm_left),
    .pcm_right       (pcm_right),
    .pcm_valid       (pcm_valid),

    // Debug observation ports (unused at top level — synthesis optimizes away)
    .dbg_wavetblhdr  (),
    .dbg_hf_pending  (),
    .dbg_slot0_wave  (),
    .dbg_slot0_fn    (),
    .dbg_slot0_oct   (),
    .dbg_slot0_prvb  (),
    .dbg_slot0_keyon (),
    .dbg_slot0_damp  (),
    .dbg_slot0_pan   (),
    .dbg_slot0_ar    (),
    .dbg_slot0_d1r   (),
    .dbg_slot5_wave  (),
    .dbg_slot23_wave (),
    .dbg_slot0_hdr_start (),
    .dbg_slot0_hdr_loop  (),
    .dbg_slot0_hdr_end   (),
    .dbg_slot0_hdr_bits  (),
    .dbg_slot_keyon  (dbg_slot_keyon),
    .dbg_slot_active (dbg_slot_active),
    .dbg_slot_envlive(dbg_slot_envlive)
);

// CPU register read mux.
//   reg 0x02 — Device ID (D7-D5 = 3'b001 = 0x20) OR'd with the latched write
//              bits (wavetblhdr / mem_type / mem_access_mode).  Some software
//              writes those bits then reads back expecting them reflected
//              (e.g. mem_type=1 → readback 0x22).
//   reg 0x06 — PCM RAM/ROM byte prefetched by the engine.
//   others   — return 0 (write-only by spec).
// pcm_reg_addr is stable (latched in opl4latch); pcm_reg_rd is a 1-cycle pulse
// that doesn't line up with regs.sv's io_data_out capture, so don't gate on it.
assign pcm_reg_dout    = (pcm_reg_addr == 8'h02) ? pcm_reg02_readback_w :
                         (pcm_reg_addr == 8'h06) ? pcm_cpu_mem_rd_data_w :
                                                    8'h00;
assign pcm_reg_rd_done = 1'b1; // Engine prefetches; CPU reads return immediately.
                               // Real chip uses BUSY status (D0) — TODO if needed.

// Unused legacy debug signals
assign dbg_keyon_count = 5'd0;
assign dbg_accum_cnt   = 5'd0;
assign dbg_env_min     = 10'd0;
assign dbg_mem_nonzero = 1'b0;

// ─── Register decode ─────────────────────────────────────────────────
logic busy_reg, load_busy_reg;

ymf278b_regs #(
    .CLK_HZ (CLK_HZ)
) u_regs (
    .clk            (clk),
    .rst_n          (rst_n),
    .io_port        (io_port),
    .io_data_in     (io_data_in),
    .io_wr          (io_wr),
    .io_rd          (io_rd),
    .io_data_out    (io_data_out),
    .io_ack         (io_ack),
    .new2           (new2),
    .opl3_reg_addr  (opl3_reg_addr),
    .opl3_reg_data  (opl3_reg_data),
    .opl3_reg_wr    (opl3_reg_wr),
    .opl3_status_rd (opl3_status_rd),
    .opl3_reg_rd    (opl3_reg_rd),
    .opl3_status    (opl3_status),
    .opl3_reg_dout  (opl3_reg_dout),
    .pcm_reg_addr   (pcm_reg_addr),
    .pcm_reg_data   (pcm_reg_data),
    .pcm_reg_wr     (pcm_reg_wr),
    .pcm_reg_rd     (pcm_reg_rd),
    .pcm_reg_dout   (pcm_reg_dout),
    .pcm_reg_rd_done(pcm_reg_rd_done),
    .pcm_cpu_mem_busy(pcm_cpu_mem_busy_w),
    .busy           (busy_reg),
    .load_busy      (load_busy_reg)
);

// Real OPL3 status (synchronized) — replaces the old 0x00 stub that broke
// timer-based chip detection in MoonSound software (e.g. MBwave).
assign opl3_status = opl3_status_s2;

// ─── Audio mixing ─────────────────────────────────────────────────────
// OPL3 at ~49.7kHz drives the output rate; latest PCM sample is held and added.
logic signed [16:0] mix_left_tmp, mix_right_tmp;
logic signed [15:0] pcm_left_hold, pcm_right_hold;

// FM/PCM mute mux — zero the respective path when muted
logic signed [16:0] opl3_l_eff, opl3_r_eff;
assign opl3_l_eff    = fm_mute  ? 17'sh0 : $signed({opl3_left[20],  opl3_left[20:5]});
assign opl3_r_eff    = fm_mute  ? 17'sh0 : $signed({opl3_right[20], opl3_right[20:5]});

// ─── DIAGNOSTIC MODE ────────────────────────────────────────────────────
// User reports overlay row 2 (PCM valid) OFF on hardware even after
// stretching dbg_pcm_valid to 32 cycles.  This means pcm_valid TRULY
// never pulses — engine's frame_cycle counter is not reaching 1947.
//
// To isolate whether the problem is (a) clk_sdram/rst_n at engine input,
// or (b) something inside the engine, route a FREE-RUNNING counter MSB
// to dbg_pcm_valid.  This counter lives in ymf278b_top (not engine),
// using the SAME clk and rst_n that feed the engine.
//
//   alive_counter[22] toggles every 2^22 / 85.9M ≈ 49ms → 10Hz blink
//
// Result interpretation (overlay row 2):
//   - BRIGHT GREEN constantly  → clk + rst_n + signal path all OK
//                                 → bug is INSIDE engine (e.g., frame_cycle
//                                   stuck, Stage D D3 always_ff not firing,
//                                   etc.).  TODO: deeper engine debug.
//   - STILL OFF / dim          → clk_sdram or rst_n is not reaching
//                                 ymf278b_top properly, or overlay path
//                                 is broken at a level we haven't checked.
//
// REVERT this after diagnosis — production should drive from pcm_valid.
// dbg_pcm_valid stretched to 32 clk_sdram cycles (~372ns) after each
// pcm_valid pulse so the 21MHz CDC in debug_overlay can reliably catch
// it.  Without stretching, a single-cycle 11.6ns pulse has only ~25%
// capture probability per dst clock edge, which can give visually OFF
// readings even when engine is running.  Does NOT affect audio path.
logic [4:0] dbg_pcm_valid_cnt;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dbg_pcm_valid_cnt <= 5'd0;
    else if (pcm_valid) dbg_pcm_valid_cnt <= 5'd31;
    else if (dbg_pcm_valid_cnt != 5'd0) dbg_pcm_valid_cnt <= dbg_pcm_valid_cnt - 5'd1;
end
assign dbg_pcm_valid  = pcm_valid | (dbg_pcm_valid_cnt != 5'd0);
assign dbg_opl3_valid = opl3_sample_valid;
assign dbg_pcm_level  = pcm_left_hold;
assign dbg_new2       = new2;

always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    if (pcm_valid) begin
        pcm_left_hold  <= pcm_left;
        pcm_right_hold <= pcm_right;
    end
    if (opl3_sample_valid) begin
        mix_left_tmp  = opl3_l_eff + (pcm_mute ? 17'sh0 : $signed({pcm_left_hold[15],  pcm_left_hold}));
        mix_right_tmp = opl3_r_eff + (pcm_mute ? 17'sh0 : $signed({pcm_right_hold[15], pcm_right_hold}));
        // Saturate 17-bit signed → 16-bit signed
        audio_left  <= (mix_left_tmp[16]  == mix_left_tmp[15])  ? mix_left_tmp[15:0]  : (mix_left_tmp[16]  ? 16'sh8000 : 16'sh7FFF);
        audio_right <= (mix_right_tmp[16] == mix_right_tmp[15]) ? mix_right_tmp[15:0] : (mix_right_tmp[16] ? 16'sh8000 : 16'sh7FFF);
        audio_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
