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

// Bulletproof bus isolation: ONLY output data if cs, cpu_rd, cpu_mreq are active and address is < 0x80
assign scc_dout = (~cart_num & cs & cpu_rd & cpu_mreq & (cpu_addr[7:0] < 8'h80)) ? scc_dout_A_int :
                  ( cart_num & cs & cpu_rd & cpu_mreq & (cpu_addr[7:0] < 8'h80)) ? scc_dout_B_int : 8'hFF;


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
   .i_ABLO(cpu_addr[7:0]),
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
   .i_ABLO(cpu_addr[7:0]),
   .i_DB(din),
   .o_DB(scc_dout_B_int),
   .o_TEST(),
   .o_SOUND(wave_B)
);
endmodule
