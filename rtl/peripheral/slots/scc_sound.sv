module scc_sound
(
   input                clk,
   input                clk_en,
   input                reset,
   input                cart_num,
   input                cs,
   input          [1:0] oe,
   input                cpu_rd,
   input                cpu_wr,
   input                cpu_mreq,
   input         [15:0] cpu_addr,
   input          [7:0] din,
   output         [7:0] scc_dout,
   output signed [15:0] wave,
   input          [1:0] sccPlusChip,
   input          [1:0] sccPlusMode,
   output               debug_scc_wr
);

wire signed [10:0] wave_A, wave_B;

assign wave = (oe[0] ? {wave_A[10], wave_A, 4'b0000} : 16'd0) +
              (oe[1] ? {wave_B[10], wave_B, 4'b0000} : 16'd0) ;

wire [7:0] scc_dout_A_int;
wire [7:0] scc_dout_B_int;

// ---------------------------------------------------------------------------
// SCC / SCC+ mode per cartridge (docs/sccplus_spec.md, S2)
//   0 = Real  (SCC chip)                    ~sccPlusChip
//   1 = Compat(SCC+ chip in SCC mode)       sccPlusChip & ~sccPlusMode
//   2 = Plus  (SCC+ chip in SCC+ mode)      sccPlusChip &  sccPlusMode
// ---------------------------------------------------------------------------
wire [1:0] mode_A = sccPlusChip[0] ? (sccPlusMode[0] ? 2'd2 : 2'd1) : 2'd0;
wire [1:0] mode_B = sccPlusChip[1] ? (sccPlusMode[1] ? 2'd2 : 2'd1) : 2'd0;

// ABLO remap: CPU register offset -> IKASCC internal coordinates
// (IKASCC: wave ch1-4 0x00-0x7F, FREQ/VOL 0x80-0x9F, ch5 RAM 0xA0-0xBF, deform 0xE0-0xFF,
//  0xC0-0xDF decodes to nothing = safe sink for "no function" areas)
//   Real  : pass-through (0xA0-0xDF hits nothing usable; ch5 RAM ports are gated off)
//   Compat: ch5 is a ch4 mirror on the real SCC-I, so 0xA0-0xBF is NOT the private ch5 RAM here:
//             read  0xA0-0xBF -> 0x60-0x7F (shared ch4/ch5 RAM)  [openMSX peekMem: readWave(4,..)]
//             write 0xA0-0xBF -> 0xC0-0xDF (sink)                [openMSX writeMem: ignored]
//           0xC0-0xDF -> 0xE0-0xFF (deform), rest pass-through
//   Plus  : 0x80-0x9F -> 0xA0-0xBF (private ch5 RAM), 0xA0-0xBF -> 0x80-0x9F (FREQ/VOL),
//           0xC0-0xDF -> 0xE0-0xFF (deform), rest pass-through
function [7:0] scc_ablo_remap(input [1:0] mode, input rd, input [7:0] a);
   begin
      scc_ablo_remap = a;
      case (mode)
         2'd1: case (a[7:5])
                  3'b101:  scc_ablo_remap = rd ? {3'b011, a[4:0]} : {3'b110, a[4:0]};
                  3'b110:  scc_ablo_remap = {3'b111, a[4:0]};
                  default: ;
               endcase
         2'd2: case (a[7:5])
                  3'b100:  scc_ablo_remap = {3'b101, a[4:0]};
                  3'b101:  scc_ablo_remap = {3'b100, a[4:0]};
                  3'b110:  scc_ablo_remap = {3'b111, a[4:0]};
                  default: ;
               endcase
         default: ;
      endcase
   end
endfunction

wire [7:0] ablo_A = scc_ablo_remap(mode_A, cpu_rd, cpu_addr[7:0]);
wire [7:0] ablo_B = scc_ablo_remap(mode_B, cpu_rd, cpu_addr[7:0]);

// Read window (openMSX SCC::peekMem). Outside the window the bus reads 0xFF.
//   Real  : 0x00-0x7F wave            (0x80-0xFF -> 0xFF)
//   Compat: 0x00-0x7F wave, 0xA0-0xBF ch5 RAM (0x80-0x9F, 0xC0-0xFF -> 0xFF)
//   Plus  : 0x00-0x9F wave ch1-5      (0xA0-0xFF -> 0xFF)
function scc_rd_window(input [1:0] mode, input [7:0] a);
   begin
      case (mode)
         2'd1:    scc_rd_window = (a[7] == 1'b0) | (a[7:5] == 3'b101);
         2'd2:    scc_rd_window = (a[7:5] < 3'b101);
         default: scc_rd_window = (a[7] == 1'b0);
      endcase
   end
endfunction

wire rd_ok_A = scc_rd_window(mode_A, cpu_addr[7:0]);
wire rd_ok_B = scc_rd_window(mode_B, cpu_addr[7:0]);

// Bulletproof bus isolation: ONLY output data if cs, cpu_rd, cpu_mreq are active and address is inside the mode's read window
assign scc_dout = (~cart_num & cs & cpu_rd & cpu_mreq & rd_ok_A) ? scc_dout_A_int :
                  ( cart_num & cs & cpu_rd & cpu_mreq & rd_ok_B) ? scc_dout_B_int : 8'hFF;


// --- Channel A Logic ---
wire scc_cs_A  = ~cart_num & cs;
wire scc_rdrq_A = scc_cs_A & cpu_rd & cpu_mreq;
wire scc_wr_A   = scc_cs_A & cpu_wr & cpu_mreq;

// Debug: Pulse high for 1 second on ANY write to SCC registers
reg [24:0] dbg_cnt;
always @(posedge clk) begin
   if (reset) dbg_cnt <= 0;
   else if (scc_wr_A | (cart_num & cs & cpu_wr & cpu_mreq)) dbg_cnt <= 25'd21000000;
   else if (dbg_cnt > 0) dbg_cnt <= dbg_cnt - 1;
end
assign debug_scc_wr = (dbg_cnt > 0);

// RDRQ/WRRQ are driven directly (combinational) so player_s registers sample
// data at the same clk_en edge the CPU asserts cpu_wr — no 1-cycle lag.
// RAMCTRL_ASYNC=1 makes RAM R/W use raw CS_n/WR_n signals, which is also
// combinationally correct for a synchronous (clk_en-gated) bus.
IKASCC_player_s #(.RAM_TYPE(1), .FAST_CLOCK(1), .RAMCTRL_ASYNC(1)) scc_wave_A
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_SCCREG_EN(1'b1),
   .i_CS_n(~scc_cs_A),
   .i_RD_n(~(cpu_rd & cpu_mreq)),
   .i_WR_n(~scc_wr_A),
   .i_RDRQ(scc_rdrq_A),
   .i_WRRQ(scc_wr_A),
   .i_SCCP_MODE(mode_A),
   .i_ABLO(ablo_A),
   .i_DB(din),
   .o_DB(scc_dout_A_int),
   .o_TEST(),
   .o_SOUND(wave_A)
);

// --- Channel B Logic ---
wire scc_cs_B   = cart_num & cs;
wire scc_rdrq_B = scc_cs_B & cpu_rd & cpu_mreq;
wire scc_wr_B   = scc_cs_B & cpu_wr & cpu_mreq;

IKASCC_player_s #(.RAM_TYPE(1), .FAST_CLOCK(1), .RAMCTRL_ASYNC(1)) scc_wave_B
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_SCCREG_EN(1'b1),
   .i_CS_n(~scc_cs_B),
   .i_RD_n(~(cpu_rd & cpu_mreq)),
   .i_WR_n(~scc_wr_B),
   .i_RDRQ(scc_rdrq_B),
   .i_WRRQ(scc_wr_B),
   .i_SCCP_MODE(mode_B),
   .i_ABLO(ablo_B),
   .i_DB(din),
   .o_DB(scc_dout_B_int),
   .o_TEST(),
   .o_SOUND(wave_B)
);
endmodule
