// Y8960 Cartridge (github.com/hra1129/Y8960_Cartridge) on the core bus.
//
// The cartridge is SSG x2, OPLL, OPL2 + ADPCM, SCC and OPM behind an SCC-style mapper.
// The machine already has a PSG, an OPLL, SCCs and an MSX-AUDIO, and every chip the
// machine has is used instead of a second copy:
//
//   cartridge chip   here
//   SSG1             the main PSG (same registers at A0h/A1h; 7FF0h/7FF1h reach it too)
//   SSG2             upstream ssg_core, the second chip of upstream's dual_ssg
//   OPLL             the core's OPLL (7Ch/7Dh, 7FF4h/7FF5h)
//   OPL2 + ADPCM     the Audio Card as MSX-AUDIO, forced while the cartridge is in a
//                    slot (C0h/C1h, 7FF2h/7FF3h)
//   SCC              the SCC of the cartridge's slot
//   OPM              upstream IKAOPM + its wrapper
//   timer, enablers  upstream
//
// What the reused chips do not have is given up: the per-channel pan registers, the
// OPLL voice banks and the OPL2 waveform select.  The mixer volume registers
// (7FF7h-7FFAh, 7FFDh, 7FFEh) are kept: vol_* go to the core, which scales its chips
// with them (PSG, OPLL, card, SCC); SSG2 and the OPM go through upstream's mixer.
//
//  * clock: upstream runs at 42.95 MHz with a 1-in-12 enable (3.579545 MHz).  Here
//    it is clk (21.477 MHz) with a 1-in-6 enable; the chips only advance on the
//    enable (sim/y8960 compares the two clockings sample by sample).
//  * memory: banks #0-15 are the BIOS ROM, #16-31 RAM, 256 KB in all, served by the
//    core's slot memory.  The bank registers are here (upstream keeps them inside its
//    patched IKASCC).
//  * I/O: every I/O port of the cartridge is off after reset and is switched on by
//    the cartridge's own memory mapped registers (7FF6h, 7FFFh).  io_en_* tell the
//    core which ports the cartridge has switched on.

module y8960_cart
(
   input                clk,           // 21.477 MHz
   input                reset,
   // ---- CPU bus (levels, synchronous to clk) ----
   input         [15:0] cpu_addr,
   input          [7:0] cpu_din,
   input                cpu_iorq,      // I/O cycle (m1 excluded by the caller)
   input                cpu_mreq_cs,   // memory cycle in the cartridge's (sub)slot
   input                cpu_rd,
   input                cpu_wr,
   output         [7:0] dout,
   output               dout_en,       // the cartridge drives the bus (registers only)
   output               irq,
   // ---- slot memory (BIOS ROM + RAM, 256 KB), served by the core ----
   output         [4:0] mem_bank,      // 8 KB bank of the current page, 0-31
   output               mem_cs,        // current memory cycle addresses the bank memory
   output               mem_writable,  // ... and may write it (RAM mode, bank 16-31)
   // ---- the machine's chips, driven from the cartridge's slot ----
   output               scc_req,       // current memory cycle addresses the SCC registers
   output               ssg_mio_wr,    // write to 7FF0h/7FF1h: main PSG address / data (a[0])
   output               opl2_mio_wr,   // write to 7FF2h/7FF3h: MSX-AUDIO address / data
   output               opll_mio_wr,   // write to 7FF4h/7FF5h: OPLL address / data
   // ---- mixer volumes for the machine's chips: 0..128 = x0..x1, master included ----
   output         [7:0] vol_ssg,
   output         [7:0] vol_opll,
   output         [7:0] vol_opl2,
   output         [7:0] vol_scc,
   // ---- claimed I/O ports ----
   output               io_en_ssg,     // A0h-A3h
   output               io_en_opll,    // 7Ch-7Dh
   output               io_en_opl2,    // C0h-C1h
   output               io_en_opm,     // 7Eh-7Fh
   output               io_en_timer,   // B0h-B3h
   // ---- audio ----
   output signed [23:0] audio_l,
   output signed [23:0] audio_r,
   output               audio_valid
);

wire reset_n = ~reset;

// ---------------------------------------------------------------------------------
// 3.579545 MHz enable
// ---------------------------------------------------------------------------------
parameter int ENABLE_DIV = 6;
logic [3:0] div_cnt;
logic       enable;
always_ff @(posedge clk) begin
   if (reset) begin
      div_cnt <= 4'd0;
      enable  <= 1'b0;
   end else if (div_cnt == 4'(ENABLE_DIV - 1)) begin
      div_cnt <= 4'd0;
      enable  <= 1'b1;
   end else begin
      div_cnt <= div_cnt + 4'd1;
      enable  <= 1'b0;
   end
end

// ---------------------------------------------------------------------------------
// Bus front end (upstream: msx_slot.v, minus the pin synchronizers and the WR delay,
// which the synchronous core bus does not need).  One bus_valid transaction per CPU
// access, held until bus_ready or the end of the strobe.
// ---------------------------------------------------------------------------------
wire io_wr  = cpu_iorq    & cpu_wr;
wire io_rd  = cpu_iorq    & cpu_rd;
wire mem_wr = cpu_mreq_cs & cpu_wr;
wire mem_rd = cpu_mreq_cs & cpu_rd;
wire strobe = io_wr | io_rd | mem_wr | mem_rd;

logic        strobe_d;
logic        bus_valid_r, bus_write_r, bus_io_r, active;
logic [15:0] bus_address;
logic  [7:0] bus_wdata;
logic  [7:0] rdata_r;
logic        rdata_en_r;

wire         bus_ready;
wire   [7:0] bus_rdata;
wire         bus_rdata_en;
wire         mixer_reg_en;
wire         mixer_address = (bus_address[15:4] == 12'h7FF) &
                             ((bus_address[3:0] >= 4'd7 & bus_address[3:0] <= 4'd10) |
                              bus_address[3:0] == 4'd13 | bus_address[3:0] == 4'd14);
wire         mixer_access  = bus_valid_r & ~bus_io_r & bus_write_r & mixer_reg_en & mixer_address;
wire         bus_valid     = bus_valid_r & ~mixer_access;
wire         bus_write     = bus_write_r;
wire         bus_io        = bus_io_r;
logic  [3:0] ssg_rd_cnt;
wire         bus_ssg_cs;
wire         ssg_rd_hold   = bus_ssg_cs & ~bus_write_r & ~bus_rdata_en & (ssg_rd_cnt != 4'(ENABLE_DIV + 1));

always_ff @(posedge clk) begin
   strobe_d <= strobe;
   if (reset) begin
      bus_valid_r <= 1'b0;
      bus_write_r <= 1'b1;
      bus_io_r    <= 1'b0;
      active      <= 1'b0;
      rdata_r     <= 8'hFF;
      rdata_en_r  <= 1'b0;
   end else begin
      if (strobe & ~strobe_d) begin
         bus_valid_r <= 1'b1;
         bus_write_r <= io_wr | mem_wr;
         bus_io_r    <= io_wr | io_rd;
         bus_address <= cpu_addr;
         bus_wdata   <= cpu_din;
         active      <= 1'b1;
      end else begin
         if ((bus_ready & ~ssg_rd_hold) | mixer_access | ~strobe) bus_valid_r <= 1'b0;
         if (~strobe)                                             active      <= 1'b0;
      end
      // SSG register reads: ssg_core answers a read only on a clock where its 3.58 MHz
      // enable is high, but reports ready at once -- with the upstream front end the
      // request is gone before the next enable most of the time, and the read of an
      // SSG2 register (A2h) goes unanswered.  Keep the request up for one enable
      // period.  An SSG read has no side effect.
      if (~bus_valid_r)       ssg_rd_cnt <= 4'd0;
      else if (ssg_rd_hold)   ssg_rd_cnt <= ssg_rd_cnt + 4'd1;
      if (~strobe)
         rdata_en_r <= 1'b0;
      else if (active & ~bus_write_r & bus_rdata_en & ~rdata_en_r) begin
         rdata_r    <= bus_rdata;
         rdata_en_r <= 1'b1;
      end
   end
end

assign dout    = rdata_r;
assign dout_en = rdata_en_r;

// mixer volumes, 7FF7h-7FFAh, 7FFDh, 7FFEh (upstream: msx_slot.v)
logic [7:0] ssg_volume, opll_volume, opl2_volume, scc_volume, opm_volume, master_volume;
always_ff @(posedge clk) begin
   if (reset) begin
      ssg_volume    <= 8'd128;
      opll_volume   <= 8'd128;
      opl2_volume   <= 8'd128;
      scc_volume    <= 8'd128;
      opm_volume    <= 8'd128;
      master_volume <= 8'd128;
   end else if (mixer_access) begin
      case (bus_address[3:0])
         4'd7:    ssg_volume    <= bus_wdata;
         4'd8:    opll_volume   <= bus_wdata;
         4'd9:    opl2_volume   <= bus_wdata;
         4'd10:   scc_volume    <= bus_wdata;
         4'd13:   opm_volume    <= bus_wdata;
         4'd14:   master_volume <= bus_wdata;
         default: ;
      endcase
   end
end

// ---------------------------------------------------------------------------------
// Bank registers and RAM mode (upstream IKASCC_vrc_s.v: same write rules).  Bank #63
// is the SCC register window: bank 2 always (9800h-9FFFh), bank 1 in RAM mode
// (7800h-7FFFh).  Writes in 7FF0h-7FFFh never get here while that window is open.
// ---------------------------------------------------------------------------------
logic [5:0] bankreg[4];
logic       rammode;
wire        bus_scc_cs;
wire        mem_wr_plain = bus_valid & bus_scc_cs & bus_write;
always_ff @(posedge clk) begin
   if (reset) begin
      rammode    <= 1'b0;
      bankreg[0] <= 6'h00;
      bankreg[1] <= 6'h01;
      bankreg[2] <= 6'h02;
      bankreg[3] <= 6'h03;
   end else if (mem_wr_plain) begin
      if (bus_address[15:11] == 5'b0100_1) begin               // 4800h-4FFFh
         if (bus_address[7:0] == 8'hFB)
            rammode <= bus_wdata[0];
         else if (bus_address[7:2] == 6'b1111_11 & rammode)
            bankreg[bus_address[1:0]] <= bus_wdata[5:0];
      end else if (bus_address[12:11] == 2'b10 & ~rammode) begin // x000h-x7FFh
         case (bus_address[15:13])
            3'b010:  bankreg[0] <= bus_wdata[5:0];
            3'b011:  bankreg[1] <= bus_wdata[5:0];
            3'b100:  bankreg[2] <= bus_wdata[5:0];
            3'b101:  bankreg[3] <= bus_wdata[5:0];
            default: ;
         endcase
      end
   end
end

//  7FF0h-7FFFh are registers unless bank 1 is a RAM bank in RAM mode (upstream:
//  ~ma[18] | ~ma[17] of that page).
assign mixer_reg_en = ~rammode | ~bankreg[1][4];

wire [5:0] live_bank = bankreg[{~cpu_addr[14], cpu_addr[13]}];
wire       mio_live  = mixer_reg_en & (cpu_addr[15:4] == 12'h7FF);
wire       scc_win   = ((bankreg[2] == 6'h3F) & (cpu_addr[15:11] == 5'b1001_1)) |
                       (rammode & (bankreg[1] == 6'h3F) & (cpu_addr[15:11] == 5'b0111_1));
assign mem_bank     = live_bank[4:0];
assign mem_cs       = cpu_mreq_cs & (cpu_addr[15] ^ cpu_addr[14]) & (live_bank != 6'h3F);
assign mem_writable = rammode & live_bank[4] & (cpu_addr[15:13] != 3'b010) & ~mio_live;
//  The SCC of the slot: x800h-x8FFh of the window.  x900h-x904h are the cartridge's
//  pan registers and the rest is reserved; on a plain SCC all of it mirrors x8xxh,
//  so it is kept away from the chip.
assign scc_req      = cpu_mreq_cs & scc_win & (cpu_addr[10:8] == 3'b000) & ~mio_live;

wire mio_wr = cpu_mreq_cs & cpu_wr & mio_live;
assign ssg_mio_wr  = mio_wr & (cpu_addr[3:1] == 3'b000);
assign opl2_mio_wr = mio_wr & (cpu_addr[3:1] == 3'b001);
assign opll_mio_wr = mio_wr & (cpu_addr[3:1] == 3'b010);

// ---------------------------------------------------------------------------------
// Upstream blocks
// ---------------------------------------------------------------------------------
wire        bus_timer_cs, bus_opl2_cs, bus_opll_cs, bus_opm_cs;
wire        bus_timer_ready, bus_ssg_ready, bus_opm_ready;
wire  [7:0] bus_timer_rdata, bus_ssg_rdata, bus_opm_rdata, bus_decode_rdata;
wire        bus_timer_rdata_en, bus_ssg_rdata_en, bus_opm_rdata_en, bus_decode_rdata_en;
wire        timer_intr_n, opm_intr_n;

assign bus_rdata    = bus_timer_rdata & bus_ssg_rdata & bus_opm_rdata & bus_decode_rdata;
assign bus_rdata_en = bus_timer_rdata_en | bus_ssg_rdata_en | bus_opm_rdata_en | bus_decode_rdata_en;
assign irq          = ~(timer_intr_n & opm_intr_n);

//  The OPLL, OPL2 and SCC selects go to chips of the machine, which take the cycle
//  from the CPU bus themselves; here they are only acknowledged.
y8960_address_decode u_address_decode (
   .clk(clk), .reset_n(reset_n),
   .bus_address(bus_address), .bus_io(bus_io), .bus_write(bus_write), .bus_valid(bus_valid),
   .bus_ready(bus_ready), .bus_wdata(bus_wdata),
   .bus_rdata(bus_decode_rdata), .bus_rdata_en(bus_decode_rdata_en),
   .bus_timer_cs(bus_timer_cs), .bus_opll_cs(bus_opll_cs), .bus_opl2_cs(bus_opl2_cs),
   .bus_ssg_cs(bus_ssg_cs), .bus_scc_cs(bus_scc_cs), .bus_opm_cs(bus_opm_cs), .bus_sysctrl_cs(),
   .bus_timer_ready(bus_timer_ready), .bus_opll_ready(1'b1), .bus_opl2_ready(1'b1),
   .bus_ssg_ready(bus_ssg_ready), .bus_scc_ready(1'b1), .bus_opm_ready(bus_opm_ready),
   .bus_sysctrl_ready(1'b1),
   .memory_io_en(mixer_reg_en), .led()
);

// I/O enablers: a copy of the decoder's own registers (7FF6h bit0; 7FFFh bits 0,1,2,7),
// for the core.  Same write condition as the decoder.
logic en_opll, en_opl2, en_ssg, en_opm, en_timer;
wire  mio_bus_wr = bus_valid & ~bus_io & bus_write & mixer_reg_en & (bus_address[15:4] == 12'h7FF);
always_ff @(posedge clk) begin
   if (reset) begin
      en_opll <= 1'b0; en_opl2 <= 1'b0; en_ssg <= 1'b0; en_opm <= 1'b0; en_timer <= 1'b0;
   end else if (mio_bus_wr & bus_address[3:0] == 4'h6) begin
      en_opll <= bus_wdata[0];
   end else if (mio_bus_wr & bus_address[3:0] == 4'hF) begin
      en_opl2  <= bus_wdata[0];
      en_ssg   <= bus_wdata[1];
      en_opm   <= bus_wdata[2];
      en_timer <= bus_wdata[7];
   end
end
assign io_en_opll  = en_opll;
assign io_en_opl2  = en_opl2;
assign io_en_ssg   = en_ssg;
assign io_en_opm   = en_opm;
assign io_en_timer = en_timer;

//  The timer counts its clk, upstream the 42.95 MHz system clock (12 x 3.58 MHz).
//  At ENABLE_DIV = 6 clk is half that: HALF_CLK keeps the periods (sim/y8960 measures).
msx_timer #(.HALF_CLK(ENABLE_DIV == 6)) u_msx_timer (
   .clk(clk), .reset_n(reset_n),
   .bus_cs(bus_timer_cs), .bus_address(bus_address[1:0]), .bus_write(bus_write), .bus_valid(bus_valid),
   .bus_ready(bus_timer_ready), .bus_wdata(bus_wdata),
   .bus_rdata(bus_timer_rdata), .bus_rdata_en(bus_timer_rdata_en), .intr_n(timer_intr_n)
);

wire signed [15:0] opm_l, opm_r;
wire        [11:0] ssg2_l, ssg2_r;

opm u_opm (
   .clk(clk), .reset_n(reset_n), .enable(enable),
   .bus_cs(bus_opm_cs), .bus_io(bus_io), .bus_address(bus_address[0]), .bus_write(bus_write),
   .bus_valid(bus_valid), .bus_ready(bus_opm_ready), .bus_wdata(bus_wdata),
   .bus_rdata(bus_opm_rdata), .bus_rdata_en(bus_opm_rdata_en),
   .wait_n(), .intr_n(opm_intr_n), .sound_l_out(opm_l), .sound_r_out(opm_r)
);

//  SSG2: registers 10h-1Fh, its volume (24h-26h) and pan (2Ch-2Eh) registers, read at
//  A2h.  As the second core of upstream's dual_ssg (BUILTIN = 0): it answers only
//  reads of its own registers, the main PSG answers the rest.
ssg_core #(.builtin(1'b1), .core_number(1'b1), .read_others(1'b0)) u_ssg2 (
   .clk(clk), .reset_n(reset_n), .enable(enable),
   .bus_ioreq(bus_ssg_cs), .bus_valid(bus_valid), .bus_write(bus_write), .bus_address(bus_address[1:0]),
   .bus_ready(bus_ssg_ready), .bus_wdata(bus_wdata),
   .bus_rdata(bus_ssg_rdata), .bus_rdata_en(bus_ssg_rdata_en),
   .ssg_ioa(8'd0), .ssg_iob(),
   .sound_l_out(ssg2_l), .sound_r_out(ssg2_r), .mode(2'b11)
);

//  Upstream's mixer for the two chips that are here (SSG DC removal, SSG / OPM /
//  master volume).
mixier u_mixier (
   .clk(clk), .reset_n(reset_n),
   .ssg_l({1'b0, ssg2_l}), .ssg_r({1'b0, ssg2_r}), .opll_l(16'sd0), .opll_r(16'sd0), .opl2_l(16'sd0), .opl2_r(16'sd0),
   .scc_l(11'sd0), .scc_r(11'sd0), .opm_l(opm_l), .opm_r(opm_r),
   .ssg_volume(ssg_volume), .opll_volume(8'd0), .opl2_volume(8'd0),
   .scc_volume(8'd0), .opm_volume(opm_volume), .master_volume(master_volume),
   .audio_l_out(audio_l), .audio_r_out(audio_r), .audio_valid(audio_valid)
);

//  Volumes for the machine's chips: chip volume x master volume, 128 = x1.  A value
//  above 128 counts as 128 (upstream mixier.v).
function automatic [7:0] vclip(input [7:0] v); vclip = v[7] ? 8'd128 : v; endfunction
function automatic [7:0] vmul(input [7:0] v, input [7:0] m);
   logic [15:0] p;
   p = vclip(v) * vclip(m);
   vmul = p[14:7];
endfunction
logic [7:0] vol_ssg_r, vol_opll_r, vol_opl2_r, vol_scc_r;
always_ff @(posedge clk) begin
   vol_ssg_r  <= vmul(ssg_volume,  master_volume);
   vol_opll_r <= vmul(opll_volume, master_volume);
   vol_opl2_r <= vmul(opl2_volume, master_volume);
   vol_scc_r  <= vmul(scc_volume,  master_volume);
end
assign vol_ssg  = vol_ssg_r;
assign vol_opll = vol_opll_r;
assign vol_opl2 = vol_opl2_r;
assign vol_scc  = vol_scc_r;

endmodule
