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
    
    // CPU Register Interface
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),
    .reg_rd          (pcm_reg_rd),
    .reg_dout        (pcm_reg_dout),
    
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
    .dbg_slot23_wave ()
);

assign pcm_reg_rd_done = 1'b1; // TODO: Implement CPU memory read completion in engine

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

// Debug signal passthrough
assign dbg_pcm_valid  = pcm_valid;
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
