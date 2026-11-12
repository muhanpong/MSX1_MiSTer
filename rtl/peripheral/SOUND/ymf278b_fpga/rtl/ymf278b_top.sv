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

    // Direct (bridge-free) FM status path: live status byte out, and a pulse
    // in when the host served a direct status read (consumes the NEW2 one-shot).
    output wire  [7:0] status_export,
    input  wire        status_rd_notify,

    // External memory bus (for PCM sample data)
    output logic [21:0] mem_addr,
    output logic        mem_rd_req,
    input  wire  [7:0]  mem_rd_data,
    input  wire  [15:0] mem_rd_data16,
    input  wire  [15:0] mem_rd_data16b,  // the other word of the aligned 4-byte pair (engine3)
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
    input  wire  [3:0] pcm_vol,    // OSD OPL4 PCM trim, 2 dB ladder; see pcm_pre()/pcm_post()
    input  wire  [3:0] fm_vol,     // OSD OPL4 FM  trim, 2 dB ladder; see fm_gain()

    // MSX-AUDIO personality (Y8950): the OPL3 serves as the OPL, y8950_addon adds the
    // ADPCM unit, status and timers; ports C0h-C3h.  The MoonSound side (register
    // front end, PCM engine) is held in reset while this is 1.  Change it only
    // together with a reset (rst_n low).
    input  wire        audio_mode_i,  // quasi-static, from clk21m; changes only inside a reset
    input  wire        adpcm_mute,
    input  wire  [3:0] adpcm_vol,  // OSD ADPCM trim, same ladder as pcm_vol (adpcm_post())

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
    // slot-0 multi-probe taps (causal-chain capture in msx.sv)
    output wire [21:0] dbg_slot0_hdr_start,      // committed startAddr (header)
    output wire [15:0] dbg_slot0_dyn_pos,        // sample position
    output wire [9:0]  dbg_slot0_dyn_env_vol,    // envelope attenuation (loudness)
    output wire [2:0]  dbg_slot0_dyn_env_state,  // EG state
    output logic       dbg_ack_stopped   // reg4 (timer ack) writes stopped reaching OPL3
);
//  audio_mode comes from the clk21m domain.  It only changes in the middle of a
//  long reset, but STA sees a one-clock path from it into the mixer multiplier
//  (-1.6 ns on the first fit), so it is brought over through two flops.
(* preserve *) logic audio_mode_s1 = 1'b0, audio_mode = 1'b0;
always_ff @(posedge clk) begin audio_mode_s1 <= audio_mode_i; audio_mode <= audio_mode_s1; end


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
    // MUST clear on reset: a real YMF278B powers up / resets with NEW2 = 0.  If the
    // shadow survives a warm MSX reset, NEW2 stays 1, so a driver that re-runs its
    // detection writes reg 105h = 03h and produces NO rising edge -> the one-shot
    // device-ID (status = 02h) is never re-armed, and the first status read (the
    // driver's earlier BUSY check) has already consumed the one armed at reset.
    // Detection then reads 00h where it requires 02h and reports the chip as broken
    // until the core is reloaded (MSXdev25 GoFigure: ":-( Incomplete OPL4 support").
    if (!rst_n)
        opl3_reg_shadow[0] <= 8'h00;
    else if (opl3_reg_wr && opl3_reg_addr == 9'h105)
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
logic       opl3_irq_n;

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
    .irq_n        (opl3_irq_n),
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
wire [7:0] pcm_reg_rd_data_w;

//  PCM engine: engine2 (v3, the board build) unless PCM_ENGINE3 is defined, which
//  selects the from-scratch engine (ymf278_pcm_engine3.sv, opl4_scratch).  engine3
//  holds cpu_mem_busy until a wave-memory write has left the ch4 bridge, so the
//  reg 6 write WAIT drops from 1024 clk to openMSX's 28 master clocks (107 clk at
//  128.86 MHz, PLAN goal 5); engine2 releases at issue and keeps 1024.
//  engine2 leaves the delay to ymf278b_regs' own default, so a regs file with
//  another default (the harness memwr control) still takes effect.
`ifdef PCM_ENGINE3
`define YMF278_PCM_ENGINE ymf278_pcm_engine3
localparam int PCM_MEM_WRITE_DELAY = (28 * (CLK_HZ / 1000) + 33868 / 2) / 33868;
`define YMF278_REGS_PARAMS .CLK_HZ (CLK_HZ), .MEM_WRITE_DELAY (PCM_MEM_WRITE_DELAY)
`else
`define YMF278_PCM_ENGINE ymf278_pcm_engine2
`define YMF278_REGS_PARAMS .CLK_HZ (CLK_HZ)
`endif
`YMF278_PCM_ENGINE #(
    .CLK_HZ (CLK_HZ)
) u_pcm (
    .clk             (clk),
    .rst_n           (rst_n & ~audio_mode),

    // CPU Register Interface — reg 0x06 read path now wired through to engine
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),
    .reg_rd          (pcm_reg_rd),
    .cpu_mem_rd_data (pcm_cpu_mem_rd_data_w),
    .cpu_mem_busy    (pcm_cpu_mem_busy_w),
    .reg02_readback  (pcm_reg02_readback_w),
    .reg_rd_data     (pcm_reg_rd_data_w),

    // SDRAM Direct Port
    .mem_addr        (mem_addr),
    .mem_rd_en       (mem_rd_req),
    .mem_rd_data     (mem_rd_data),
    .mem_rd_data16   (mem_rd_data16),
`ifdef PCM_ENGINE3
    .mem_rd_data16b  (mem_rd_data16b),
`endif
    .mem_rd_valid    (mem_rd_valid),
    .mem_wr_en       (mem_wr_req),
    .mem_wr_data     (mem_wr_data),
    .mem_busy        (mem_busy),

    // Audio Output
    .pcm_vol         (PCM_HEADROOM),      // FIXED headroom, not the OSD trim; see above
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
    .dbg_slot0_hdr_start (dbg_slot0_hdr_start),
    .dbg_slot0_hdr_loop  (),
    .fm_mix_l_o          (fm_mix_l),
    .fm_mix_r_o          (fm_mix_r),
    .dbg_slot0_hdr_end   (),
    .dbg_slot0_hdr_bits  (),
    .dbg_slot0_dyn_pos      (dbg_slot0_dyn_pos),
    .dbg_slot0_dyn_env_vol  (dbg_slot0_dyn_env_vol),
    .dbg_slot0_dyn_env_state(dbg_slot0_dyn_env_state),
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
//   others   — the stored register byte (engine reg_rd_data), as openMSX
//              peekReg returns regs[reg]; header-loaded values included.  These
//              read 0 until 2026-10-04 ("write-only by spec", which nothing
//              backed) and Neon Horizon's read-modify-write of 68h-7Fh lost the pan.
// pcm_reg_addr is stable (latched in opl4latch); pcm_reg_rd is a 1-cycle pulse
// that doesn't line up with regs.sv's io_data_out capture, so don't gate on it.
assign pcm_reg_dout    = (pcm_reg_addr == 8'h02) ? pcm_reg02_readback_w :
                         (pcm_reg_addr == 8'h06) ? pcm_cpu_mem_rd_data_w :
                                                    pcm_reg_rd_data_w;
assign pcm_reg_rd_done = 1'b1; // Engine prefetches; CPU reads return immediately.
                               // Real chip uses BUSY status (D0) — TODO if needed.

// Unused legacy debug signals
assign dbg_keyon_count = 5'd0;
assign dbg_accum_cnt   = 5'd0;
assign dbg_env_min     = 10'd0;
assign dbg_mem_nonzero = 1'b0;

// ─── Register decode ─────────────────────────────────────────────────
logic busy_reg, load_busy_reg;
logic [7:0] r_io_data_out, r_status_export, r_opl3_reg_data;
logic [8:0] r_opl3_reg_addr;
logic       r_io_ack, r_opl3_reg_wr;

ymf278b_regs #(
    `YMF278_REGS_PARAMS
) u_regs (
    .clk            (clk),
    .rst_n          (rst_n & ~audio_mode),
    .io_port        (io_port),
    .io_data_in     (io_data_in),
    .io_wr          (io_wr & ~audio_mode),
    .io_rd          (io_rd & ~audio_mode),
    .io_data_out    (r_io_data_out),
    .io_ack         (r_io_ack),
    .new2           (new2),
    .opl3_reg_addr  (r_opl3_reg_addr),
    .opl3_reg_data  (r_opl3_reg_data),
    .opl3_reg_wr    (r_opl3_reg_wr),
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
    .status_live    (r_status_export),
    .status_rd_notify(status_rd_notify),
    .load_busy      (load_busy_reg)
);

// Real OPL3 status (synchronized) — replaces the old 0x00 stub that broke
// timer-based chip detection in MoonSound software (e.g. MBwave).
assign opl3_status = opl3_status_s2;

// ─── MSX-AUDIO (Y8950) personality ────────────────────────────────────
// Ports C0h/C2h = register latch (write) / status (read), C1h/C3h = data.
localparam int YA_RAM_AW   = 15;      // sample RAM: 32 KB, as in the NMS-1205 / HX-MU900 / FS-CA1
localparam int YA_SMP_HZ   = 49716;   // 3579545 / 72
//  ADPCM (+-2040 in openMSX, where one FM channel is +-2047) to the 16-bit PCM path: << 2
//  makes its full scale equal one OPL3 channel's (8186 against 8206, sim/msx_audio/run_top.sh).
localparam int ADPCM_SH    = 2;

logic [31:0] ya_acc;
logic        ya_tick;
always_ff @(posedge clk) begin
    ya_tick <= 1'b0;
    if (!rst_n) ya_acc <= '0;
    else if (ya_acc + YA_SMP_HZ >= CLK_HZ) begin
        ya_acc  <= ya_acc + YA_SMP_HZ - CLK_HZ;
        ya_tick <= audio_mode;
    end
    else ya_acc <= ya_acc + YA_SMP_HZ;
end

//  C0h/C1h only.  C2h/C3h is where software looks for a SECOND module (stereo
//  set-ups); a mirror there would be detected as one and get every ADPCM byte
//  twice.
wire        ya_sel = audio_mode && (io_port[7:1] == 7'b1100_000);
logic [7:0] ya_latch;
logic [1:0] ya_st;
logic       ya_ack;
logic [7:0] ya_dout;
wire  [7:0] ya_rdata, ya_status, ya_fm_addr, ya_fm_data, ya_mem_wdata;
wire        ya_busy, ya_irq_n, ya_fm_wr, ya_mem_rd, ya_mem_wr;
wire [17:0] ya_mem_addr;
wire signed [15:0] ya_adpcm, ya_dac;
wire        ya_wr = ya_sel & io_wr &  io_port[0];
wire        ya_rd = ya_sel & io_rd &  io_port[0];

always_ff @(posedge clk) begin
    ya_ack <= 1'b0;
    case (ya_st)
    2'd0: begin
        if (ya_wr | ya_rd) ya_st <= 2'd1;
        else if (ya_sel & io_wr) begin ya_latch <= io_data_in; ya_ack <= 1'b1; end
        else if (ya_sel & io_rd) begin ya_dout  <= ya_status;  ya_ack <= 1'b1; end
    end
    2'd1: ya_st <= 2'd2;                     // y8950_addon.busy is up from here
    2'd2: if (!ya_busy) begin ya_dout <= ya_rdata; ya_ack <= 1'b1; ya_st <= 2'd0; end
    default: ya_st <= 2'd0;
    endcase
    if (!rst_n || !audio_mode) begin ya_st <= 2'd0; ya_ack <= 1'b0; ya_latch <= 8'h00; end
end

//  sample RAM (block RAM).  Above 32 KB: reads 0, writes ignored (openMSX, a 32 KB module).
logic [7:0] ya_ram [0:(1 << YA_RAM_AW) - 1];
logic [7:0] ya_ram_q;
logic [1:0] ya_mph;
logic       ya_mem_done, ya_mem_in;
always_ff @(posedge clk) begin
    ya_mem_done <= 1'b0;
    case (ya_mph)
    2'd0: if (ya_mem_rd | ya_mem_wr) begin
        ya_mem_in <= (ya_mem_addr[17:YA_RAM_AW] == '0);
        ya_ram_q  <= ya_ram[ya_mem_addr[YA_RAM_AW-1:0]];
        if (ya_mem_wr && ya_mem_addr[17:YA_RAM_AW] == '0)
            ya_ram[ya_mem_addr[YA_RAM_AW-1:0]] <= ya_mem_wdata;
        ya_mph <= 2'd1;
    end
    2'd1: begin ya_mem_done <= 1'b1; ya_mph <= 2'd2; end
    default: if (!(ya_mem_rd | ya_mem_wr)) ya_mph <= 2'd0;
    endcase
    if (!rst_n) ya_mph <= 2'd0;
end

y8950_addon u_y8950 (
    .clk       (clk),
    .rst_n     (rst_n & audio_mode),
    .tick      (ya_tick),
    .addr      (ya_latch),
    .wdata     (io_data_in),
    .wr        (ya_wr),
    .rd        (ya_rd),
    .rdata     (ya_rdata),
    .busy      (ya_busy),
    .status    (ya_status),
    .irq_n     (ya_irq_n),
    .fm_wr     (ya_fm_wr),
    .fm_addr   (ya_fm_addr),
    .fm_data   (ya_fm_data),
    .mem_addr  (ya_mem_addr),
    .mem_rd    (ya_mem_rd),
    .mem_wr    (ya_mem_wr),
    .mem_wdata (ya_mem_wdata),
    .mem_rdata (ya_mem_in ? ya_ram_q : 8'h00),
    .mem_done  (ya_mem_done),
    .adpcm_out (ya_adpcm),
    .dac_out   (ya_dac)
);

assign io_data_out   = audio_mode ? ya_dout   : r_io_data_out;
assign io_ack        = audio_mode ? ya_ack    : r_io_ack;
assign status_export = audio_mode ? ya_status : r_status_export;
assign irq_n         = audio_mode ? ya_irq_n  : opl3_irq_n;
assign opl3_reg_wr   = audio_mode ? ya_fm_wr            : r_opl3_reg_wr;
assign opl3_reg_addr = audio_mode ? {1'b0, ya_fm_addr}  : r_opl3_reg_addr;
assign opl3_reg_data = audio_mode ? ya_fm_data          : r_opl3_reg_data;

//  ADPCM + DAC into the 16-bit PCM path of the mixer.  The OSD trim uses the FM ladder
//  (fm_gain), so equal settings on the two rows keep the openMSX balance.
wire signed [17:0] ya_sum = 18'(ya_adpcm <<< ADPCM_SH) + 18'(ya_dac >>> 1);
logic signed [15:0] ya_smp;
always_ff @(posedge clk)
    ya_smp <= (ya_sum >  18'sd32767) ? 16'sh7FFF :
              (ya_sum < -18'sd32768) ? 16'sh8000 : ya_sum[15:0];

// ─── Audio mixing ─────────────────────────────────────────────────────
// OPL3 at ~49.7kHz drives the output rate; latest PCM sample is held and added.
logic signed [15:0] pcm_left_hold, pcm_right_hold;
//  The card select sits in a register stage of its own, in front of the multiplier
//  (the mux straight into the DSP block missed timing by 1.6 ns).  The values are
//  held for a whole sample, so the extra clock changes nothing audible.
logic signed [15:0] pc_l_sel, pc_r_sel;
logic               pc_mute_sel;
logic        [11:0] pc_gain_sel;

// ── OPL4 output gain (OSD) ────────────────────────────────────
// Calibrated 2026-08-21 against a measured reference, not by ear.
//
// Reference level: openMSX playing SCMD "Out Run -Passing Breeze-" on an
// FS-A1ST -- the balance that sounds right -- gives SCC RMS -22.6 dBFS and
// MSX-MUSIC RMS -21.6 dBFS.  openMSX's own extension configs weight MoonSound
// <volume>17000 against SCC+/FMPAC 13000, i.e. +2.3 dB, so MoonSound's target
// is RMS ~= -20.3 dBFS.
//
// Measured source levels (golden model re-rendered WITHOUT saturation, so the
// true pre-clip amplitude is visible; FM via Nuked-OPL3):
//                       PCM peak   PCM RMS   FM RMS
//   MoonDriver TIME'S UP!  +11.0     -5.9     (no FM)
//   encounter the unkn.    +11.4     -5.9      -20.6
//   GoFigure (game)         +1.0    -20.1      -31.4
// The two music-disk pieces agree to 0.1 dB and overshoot full scale by 11 dB;
// GoFigure is simply mixed ~12 dB quieter in BOTH chips (its own choice, and
// it is quiet on real hardware too).  Hence a 5-step scale whose ends cover
// both camps: -8 lands the music disks at -22.0 dBFS clip-free, +8 lands
// GoFigure at -20.1 dBFS.
//
// PCM net gain is split in two, because the engine saturates to 16 bit
// INTERNALLY (ymf278_pcm_engine2.sv, frame output) -- a post-saturation trim
// would only make the clipping quieter, never undo it.  So most of the
// attenuation is done by the engine's own pre-saturation shift (6 dB steps,
// sh = 3 - pcm_vol) and the remainder by the multiplier here.  That way the
// clip point always sits at the final level instead of 12 dB above it.
//
// Defaults are the FIRST menu entry (MiSTer status resets to 0):
//   PCM -4dB  = net -12 dB, the loudest setting that clips 0.00% on all three
//   FM   0dB  = net  -4 dB, music-disk median lands at -21.7 dBFS
//
// The multiply keeps its own pipeline stage: chained onto fm_mix_gain()'s x3
// it would grow a combinational cloud in the clk_sdram domain, which is
// exactly what broke SDRAM_DQ IOB packing once before.

// Engine pre-saturation shift selector: engine computes sh = 3 - pcm_vol,
// so 2'd3 -> 0 dB, 2'd2 -> -6.02, 2'd1 -> -12.04, 2'd0 -> -18.06 dB.
// ---- fixed PCM headroom, NOT a user control -------------------------------
// The engine accumulates up to 24 slots and then clamps to 16 bit
// (ymf278_pcm_engine2.sv:455-465).  One full-scale voice is exactly 0 dBFS
// there, so two voices in phase already overflow -- "unity" is not a ceiling for
// a polyphonic sum, it is a level normal music passes straight through.
// Measured raw peak of the MoonSound music-disk tracks is +11.0 / +11.4 dBFS
// (~3.5 full-scale voices), so the engine needs ~12 dB of room BEFORE its clamp.
// That is structural and belongs here, not in the OSD: clipping inside the
// engine is unrecoverable downstream (it only gets quieter, crest 16.9->6.6 dB).
//
// The engine computes sh = 3 - pcm_vol, so 2'd1 gives sh = 2 = -12.04 dB.
// Before 2026-08-27 this shift WAS the OSD control, which is why the PCM menu
// used to be stuck at -20..-12 dB while every other menu ran -8..+8.
localparam [1:0] PCM_HEADROOM = 2'd1;   // sh = 2 => -12.04 dB before the clamp
// Post-saturation remainder, x/128.  net = pre + 20*log10(post/128).
function automatic [11:0] pcm_post(input [3:0] sel);
    // The USER trim, same 2 dB ring as every other volume menu.  Applied after
    // the engine clamp, so 0dB now means "this source's normal level" and the
    // ladder matches PSG/OPLL/SCC/FM.  Boosting loud material still clips at the
    // final mix, exactly as it does for the other sources.
    case (sel)
        4'd1: pcm_post = 12'd102;   //  -2dB
        4'd2: pcm_post = 12'd81;   //  -4dB
        4'd3: pcm_post = 12'd64;   //  -6dB
        4'd4: pcm_post = 12'd51;   //  -8dB
        4'd5: pcm_post = 12'd128;   //   0dB
        4'd6: pcm_post = 12'd161;   //  +2dB
        4'd7: pcm_post = 12'd203;   //  +4dB
        4'd8: pcm_post = 12'd255;   //  +6dB
        4'd9: pcm_post = 12'd322;   //  +8dB
        default: pcm_post = 12'd128;   //   0dB  <- entry 0 = OSD default / out of range
    endcase
endfunction
// FM has no internal saturation stage of its own, so one multiplier suffices.
function automatic [11:0] fm_gain(input [3:0] sel);
    // Same 2 dB ring as every other volume menu -- 0,-2,-4,-6,-8,0,+2,+4,+6,+8 (0 twice: down to -8, back through 0, up to +8) --
    // rotated so entry 0 (the OSD power-on default) is +4dB (mul 203): the gain the
    // user had been listening to, which the old menu mislabelled "+8dB".
    // Width: opl3_l_eff signed [16:0] x 13-bit gain -> 30-bit product into
    // fm_l_mul signed [29:0]; |322 * 65536| = 21.1M, well inside 2^29.
    case (sel)
        4'd1: fm_gain = 12'd255;   //  +6dB
        4'd2: fm_gain = 12'd322;   //  +8dB
        4'd3: fm_gain = 12'd128;   //   0dB
        4'd4: fm_gain = 12'd102;   //  -2dB
        4'd5: fm_gain = 12'd81;   //  -4dB
        4'd6: fm_gain = 12'd64;   //  -6dB
        4'd7: fm_gain = 12'd51;   //  -8dB
        4'd8: fm_gain = 12'd128;   //   0dB
        4'd9: fm_gain = 12'd161;   //  +2dB
        default: fm_gain = 12'd203;   //  +4dB  <- entry 0 = OSD default / out of range
    endcase
endfunction
//  MSX-AUDIO ADPCM trim.  It shares the OSD row of the OPL4 PCM trim (the status
//  word has no room for a row of its own), so it uses that row's ladder; the +4 dB
//  that the FM row has at its default entry is folded in, so that with both rows
//  at their defaults one ADPCM full scale equals one FM channel, as on openMSX.
function automatic [11:0] adpcm_post(input [3:0] sel);
    case (sel)
        4'd1: adpcm_post = 12'd161;   //  -2dB (+4)
        4'd2: adpcm_post = 12'd128;   //  -4dB (+4)
        4'd3: adpcm_post = 12'd102;   //  -6dB (+4)
        4'd4: adpcm_post = 12'd81;    //  -8dB (+4)
        4'd6: adpcm_post = 12'd255;   //  +2dB (+4)
        4'd7: adpcm_post = 12'd322;   //  +4dB (+4)
        4'd8: adpcm_post = 12'd405;   //  +6dB (+4)
        4'd9: adpcm_post = 12'd510;   //  +8dB (+4)
        default: adpcm_post = 12'd203; //  0dB (+4)  <- entries 0 and 5
    endcase
endfunction
localparam int GAIN_SH = 7;
logic signed [29:0] fm_l_mul, fm_r_mul, pc_l_mul, pc_r_mul;  // stage-1 registered products
always_ff @(posedge clk) begin
    pc_l_sel    <= audio_mode ? ya_smp : pcm_left_hold;
    pc_r_sel    <= audio_mode ? ya_smp : pcm_right_hold;
    pc_mute_sel <= audio_mode ? adpcm_mute : pcm_mute;
    pc_gain_sel <= audio_mode ? adpcm_post(adpcm_vol) : pcm_post(pcm_vol);
end
logic signed [21:0] sum_l, sum_r;                            // stage-2 combinational
logic               gain_v_q;

// FM/PCM mute mux — zero the respective path when muted.
// The FM level also follows wave register 0xF8 (FM MIX_CTRL), the FM twin of the
// 0xF9 PCM mix level.  Drivers fade BOTH together (GoFigure writes 0xF9 then
// DEC B -> 0xF8 with the same value); with 0xF8 unimplemented the PCM half faded
// on schedule while the FM half stayed at full level right through a song change,
// so the outgoing track blared over the transition until the new song's key-off
// blast silenced it.
logic [2:0] fm_mix_l, fm_mix_r;
function automatic signed [16:0] fm_mix_gain(input [2:0] idx, input signed [16:0] x);
    logic signed [20:0] x3;
    x3 = $signed(x) * 21'sd3;
    case (idx)
        3'd0: return x;                  // x1
        3'd1: return 17'(x3 >>> 2);      // x3/4
        3'd2: return x >>> 1;            // x1/2
        3'd3: return 17'(x3 >>> 3);      // x3/8
        3'd4: return x >>> 2;            // x1/4
        3'd5: return 17'(x3 >>> 4);      // x3/16
        3'd6: return x >>> 3;            // x1/8
        default: return 17'sd0;          // mute
    endcase
endfunction
logic signed [16:0] opl3_l_eff, opl3_r_eff;
//  MSX-AUDIO: the Y8950 is mono; C0-C8 are written with both OPL3 outputs on, so left = right.
assign opl3_l_eff    = fm_mute  ? 17'sh0 : fm_mix_gain(audio_mode ? 3'd0 : fm_mix_l, $signed({opl3_left[20],  opl3_left[20:5]}));
assign opl3_r_eff    = fm_mute  ? 17'sh0 : fm_mix_gain(audio_mode ? 3'd0 : fm_mix_r, $signed({opl3_right[20], opl3_right[20:5]}));

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

//  Stage 0 -- fm_mix_gain()'s x3 into a register.  The comment below used to
//  say the multiply never chained onto it; it did, through opl3_l_eff, and at
//  128.86 MHz that chain missed by 0.88 ns (sdram128 study, 7de0ebe).
logic signed [16:0] opl3_l_q, opl3_r_q;
logic               fm_v0_q;
always_ff @(posedge clk) begin
    fm_v0_q <= opl3_sample_valid;
    if (opl3_sample_valid) begin
        opl3_l_q <= opl3_l_eff;
        opl3_r_q <= opl3_r_eff;
    end
end

always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    gain_v_q    <= 1'b0;
    if (pcm_valid) begin
        pcm_left_hold  <= pcm_left;
        pcm_right_hold <= pcm_right;
    end
    // Stage 1 — apply the per-path OSD gain on the registered FM sample.
    if (fm_v0_q) begin
        fm_l_mul <= $signed(opl3_l_q) * $signed({1'b0, fm_gain(fm_vol)});
        fm_r_mul <= $signed(opl3_r_q) * $signed({1'b0, fm_gain(fm_vol)});
        //  MSX-AUDIO: the ADPCM / DAC sample takes the PCM path, with its own OSD trim
        pc_l_mul <= (pc_mute_sel ? 30'sh0 : $signed({pc_l_sel[15], pc_l_sel}) * $signed({1'b0, pc_gain_sel}));
        pc_r_mul <= (pc_mute_sel ? 30'sh0 : $signed({pc_r_sel[15], pc_r_sel}) * $signed({1'b0, pc_gain_sel}));
        gain_v_q <= 1'b1;
    end
    // Stage 2 — descale, sum, saturate ONCE to 16-bit signed.  Worst case after
    // >>>7 is FM +-65536*203/128 = +-103936 and PCM +-32768*162/128 = +-41472,
    // so the sum needs 19 bits incl. sign; 22 is comfortable.
    if (gain_v_q) begin
        sum_l = 22'(fm_l_mul >>> GAIN_SH) + 22'(pc_l_mul >>> GAIN_SH);
        sum_r = 22'(fm_r_mul >>> GAIN_SH) + 22'(pc_r_mul >>> GAIN_SH);
        audio_left  <= (sum_l >  22'sd32767) ? 16'sh7FFF :
                       (sum_l < -22'sd32768) ? 16'sh8000 : sum_l[15:0];
        audio_right <= (sum_r >  22'sd32767) ? 16'sh7FFF :
                       (sum_r < -22'sd32768) ? 16'sh8000 : sum_r[15:0];
        audio_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
