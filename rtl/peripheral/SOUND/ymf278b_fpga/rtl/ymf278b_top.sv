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

    // Debug outputs (clk_sdram domain)
    output wire        dbg_pcm_valid,
    output wire        dbg_opl3_valid,
    output wire signed [15:0] dbg_pcm_level,
    output wire        dbg_new2,
    output wire [4:0]  dbg_keyon_count,
    output wire [4:0]  dbg_accum_cnt,
    output wire [9:0]  dbg_env_min,
    output wire        dbg_mem_nonzero,
    output wire        dbg_pcm_base_set
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
    .irq_n        (irq_n)
);

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

ymf278_pcm_engine #(
    .CLK_HZ (CLK_HZ)
) u_pcm (
    .clk             (clk),
    .rst_n           (rst_n),
    
    // CPU Register Interface (v2: write-only; reads stubbed below)
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),

    // SDRAM Direct Port
    .mem_addr        (mem_addr),
    .mem_rd_en       (mem_rd_req),
    .mem_rd_data     (mem_rd_data),
    .mem_rd_valid    (mem_rd_valid),
    .mem_wr_en       (mem_wr_req),
    .mem_wr_data     (mem_wr_data),
    
    // Audio Output
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
    .dbg_engine_alive    (engine_alive_internal)
);

logic engine_alive_internal;

// v2 engine has no CPU register read path yet.  Return YMF278B Device ID
// (0x20) on reg 0x02, zero elsewhere.  This matches legacy v1's minimal
// behavior for software detection probes.
assign pcm_reg_dout    = (pcm_reg_rd && pcm_reg_addr == 8'h02) ? 8'h20 : 8'h00;
assign pcm_reg_rd_done = 1'b1; // TODO: Implement CPU memory read completion in v2 engine

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
    .busy           (busy_reg),
    .load_busy      (load_busy_reg)
);

// Stub OPL3 status for now
assign opl3_status = 8'h00;

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
// User confirmed: top-level alive_counter heartbeat IS visible
// (overlay row 2 continuously ON).  Now route ENGINE'S internal
// heartbeat (engine_alive_internal) to dbg_pcm_valid instead.
// This isolates whether engine's clk/rst_n are actually working
// at the engine module level (deeper than ymf278b_top).
//
// Expected:
//   - Row 2 continuously ON  → engine's clk + rst_n + always_ff alive
//                                → bug is in pcm_valid generation logic
//                                  (sample_start never fires, etc.)
//   - Row 2 OFF              → engine's clk OR rst_n broken at module
//                                boundary (route/wiring issue)
logic [22:0] alive_counter;  // kept for future use; tied to top-level
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) alive_counter <= '0;
    else        alive_counter <= alive_counter + 23'd1;
end

// Heartbeat from ENGINE INTERNAL counter (not ymf278b_top's).
assign dbg_pcm_valid  = engine_alive_internal;
assign dbg_opl3_valid = opl3_sample_valid;
assign dbg_pcm_level  = pcm_left_hold;
assign dbg_new2       = new2;

// ─── DIAGNOSTIC: PCM PATH TEST TONE ─────────────────────────────────────
// Replace engine PCM output with a hardcoded 1311Hz square wave to verify
// the audio mixer + output path passes PCM contributions independently of
// the engine.
//
// If user hears the tone alongside FM music:
//   → mixer + audio output path are FINE
//   → bug is in engine producing samples (pipeline / pcm_valid / pcm_left)
//
// If user hears ONLY FM, no tone:
//   → mixer or downstream path is broken
//   → engine could be perfectly fine but its output never makes it out
//
// 17-bit counter MSB at 85.9MHz toggles every 65536 cycles = 763us = 1311Hz
// Amplitude ±0x1000 (~5% full scale) — clearly audible but not loud.
logic [16:0] test_tone_cnt;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) test_tone_cnt <= '0;
    else        test_tone_cnt <= test_tone_cnt + 17'd1;
end
wire signed [15:0] test_pcm_tone = test_tone_cnt[16] ? 16'sh1000 : -16'sh1000;

always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    if (pcm_valid) begin
        pcm_left_hold  <= pcm_left;
        pcm_right_hold <= pcm_right;
    end
    if (opl3_sample_valid) begin
        // DIAGNOSTIC: use test_pcm_tone instead of pcm_left_hold/pcm_right_hold
        mix_left_tmp  = opl3_l_eff + (pcm_mute ? 17'sh0 : $signed({test_pcm_tone[15], test_pcm_tone}));
        mix_right_tmp = opl3_r_eff + (pcm_mute ? 17'sh0 : $signed({test_pcm_tone[15], test_pcm_tone}));
        // Saturate 17-bit signed → 16-bit signed
        audio_left  <= (mix_left_tmp[16]  == mix_left_tmp[15])  ? mix_left_tmp[15:0]  : (mix_left_tmp[16]  ? 16'sh8000 : 16'sh7FFF);
        audio_right <= (mix_right_tmp[16] == mix_right_tmp[15]) ? mix_right_tmp[15:0] : (mix_right_tmp[16] ? 16'sh8000 : 16'sh7FFF);
        audio_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
