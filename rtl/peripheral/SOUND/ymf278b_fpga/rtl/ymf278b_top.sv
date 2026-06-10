// YMF278B (OPL4) Top-Level — OPL3 FM ONLY (Stage 1; PCM wave engine deferred)
// MSX MoonSound I/O map: FM = 0xC4-0xC7.  WAVE (0x7E/0x7F) + PCM engine come later.
`default_nettype none

module ymf278b_top #(
    parameter int CLK_HZ     = 33868800,
    parameter int CLK_OPL3   = 14318180  // OPL3 master clock (14.318MHz)
) (
    input  wire        clk,          // master (clk_sdram)
    input  wire        clk_opl3,     // 14.318 MHz for OPL3 core
    input  wire        rst_n,

    // CPU I/O bus
    input  wire [7:0]  io_port,
    input  wire [7:0]  io_data_in,
    input  wire        io_wr,
    input  wire        io_rd,
    output logic [7:0] io_data_out,
    output logic       io_ack,

    // Audio output
    output logic signed [15:0] audio_left,
    output logic signed [15:0] audio_right,
    output logic               audio_valid,

    // IRQ (from OPL3 timers) — generated, left UNWIRED in Stage 1 (freeze avoidance)
    output logic       irq_n,

    // Audio mute
    input  wire        fm_mute
);

// ─── OPL3 core (gtaylormb opl3.sv) ───────────────────────────────────
// Run at 14.318MHz → standard OPL3 sample rate (~49.7kHz).
logic               opl3_sample_valid;
logic signed [23:0] opl3_left, opl3_right;
logic [7:0]         opl3_status, opl3_status_raw;
logic [7:0]         opl3_status_s1, opl3_status_s2;

// OPL3 register write signals from ymf278b_regs
logic [8:0]  opl3_reg_addr;
logic [7:0]  opl3_reg_data;
logic        opl3_reg_wr;
logic        opl3_status_rd;
logic        opl3_reg_rd;
logic [7:0]  opl3_reg_dout;

// NEW2 bit — from OPL3 register 0x105[1]
logic        new2;
logic [7:0]  opl3_reg_shadow0;
always_ff @(posedge clk)
    if (opl3_reg_wr && opl3_reg_addr == 9'h105) opl3_reg_shadow0 <= opl3_reg_data;
assign new2 = opl3_reg_shadow0[1];

// Three-stage write protocol — host_if uses edge detection (wr_p1 && !wr_p2), so
// consecutive-cycle writes are dropped:
//   Cycle 0 (wr):  cs_n=0, address[0]=0 → address-mode (register number + bank)
//   Cycle 1 (d1):  cs_n=1                → idle gap (creates falling edge for d2)
//   Cycle 2 (d2):  cs_n=0, address[0]=1 → data-mode (register value)
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
    .cs_n         (~(opl3_reg_wr | opl3_reg_wr_d2 | opl3_reg_rd)),
    .rd_n         (~opl3_reg_rd),
    .wr_n         (~(opl3_reg_wr | opl3_reg_wr_d2)),
    .address      (opl3_reg_wr ? {opl3_reg_addr[8], 1'b0}    // address phase
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

// OPL3 status (timer overflow + IRQ) CDC: clk_opl3 → clk (clk_sdram) for the CPU
// status read.  2-FF; status changes slowly and the CPU polls it repeatedly.
always_ff @(posedge clk) begin
    opl3_status_s1 <= opl3_status_raw;
    opl3_status_s2 <= opl3_status_s1;
end
assign opl3_status = opl3_status_s2;

// ─── Register decode (PCM register paths tied off in Stage 1) ─────────
// ymf278b_regs decodes both FM (0xC4-0xC7) and PCM (0x7E/0x7F) ports.  In Stage 1
// only the FM ports are routed here from msx.sv, so the PCM outputs never fire;
// the PCM read-back inputs are tied to safe constants.
logic [7:0]  pcm_reg_addr, pcm_reg_data;
logic        pcm_reg_wr, pcm_reg_rd;
logic        busy_reg, load_busy_reg;

// reg 0x02 (wavetable-header / memory-mode) read-back for MoonSound chip
// detection.  Bits 7:5 read as the hardwired device ID 001 (= 0x20; verified on
// real YMF278, see openMSX YMF278::peekReg case 2).  Detectors (vgmplay
// OPL4_Detect, MoonBlaster) read reg 0x02 COLD — without writing it first — and
// require (value & 0xE0) == 0x20, so the ID must not depend on written state.
// The PCM engine is deferred in Stage 1; shadow only the written low bits.
// Other PCM registers read back 0.
logic [7:0]  reg02_shadow;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                     reg02_shadow <= 8'h00;
    else if (pcm_reg_wr && pcm_reg_addr == 8'h02)   reg02_shadow <= pcm_reg_data;
end
wire [7:0] pcm_reg_dout_s1 = (pcm_reg_addr == 8'h02) ? ((reg02_shadow & 8'h1F) | 8'h20) : 8'h00;

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
    .pcm_reg_dout   (pcm_reg_dout_s1),
    .pcm_reg_rd_done(1'b1),
    .pcm_cpu_mem_busy(1'b0),
    .busy           (busy_reg),
    .load_busy      (load_busy_reg)
);

// ─── Audio (OPL3 only) ───────────────────────────────────────────────
logic signed [16:0] opl3_l_eff, opl3_r_eff;
assign opl3_l_eff = fm_mute ? 17'sh0 : $signed({opl3_left[20],  opl3_left[20:5]});
assign opl3_r_eff = fm_mute ? 17'sh0 : $signed({opl3_right[20], opl3_right[20:5]});

always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    if (opl3_sample_valid) begin
        // Saturate 17-bit signed → 16-bit signed
        audio_left  <= (opl3_l_eff[16] == opl3_l_eff[15]) ? opl3_l_eff[15:0] : (opl3_l_eff[16] ? 16'sh8000 : 16'sh7FFF);
        audio_right <= (opl3_r_eff[16] == opl3_r_eff[15]) ? opl3_r_eff[15:0] : (opl3_r_eff[16] ? 16'sh8000 : 16'sh7FFF);
        audio_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
