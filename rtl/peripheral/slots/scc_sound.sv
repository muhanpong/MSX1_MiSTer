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
   input          [1:0] sccPlusMode
);

wire signed [10:0] wave_A, wave_B;

assign wave = (oe[0] ? {wave_A[10], wave_A, 4'b0000} : 16'd0) +
              (oe[1] ? {wave_B[10], wave_B, 4'b0000} : 16'd0) ;

wire [7:0] scc_dout_A_int;
wire [7:0] scc_dout_B_int;

// Bulletproof bus isolation: ONLY output data if cs, cpu_rd, cpu_mreq are active and address is < 0x80
assign scc_dout = (~cart_num & cs & cpu_rd & cpu_mreq & (cpu_addr[7:0] < 8'h80)) ? scc_dout_A_int :
                  ( cart_num & cs & cpu_rd & cpu_mreq & (cpu_addr[7:0] < 8'h80)) ? scc_dout_B_int : 8'hFF;


wire scc_cs_A = ~cart_num & cs;
wire scc_rdrq_A = scc_cs_A & cpu_rd & cpu_mreq;
wire scc_wrrq_A = scc_cs_A & cpu_wr & cpu_mreq;

IKASCC_player_s #(.RAM_TYPE(1), .FAST_CLOCK(0), .RAMCTRL_ASYNC(1)) scc_wave_A
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_SCCREG_EN(1'b1),
   .i_CS_n(~(scc_rdrq_A | scc_wrrq_A)),   
   .i_RD_n(~scc_rdrq_A),
   .i_WR_n(~scc_wrrq_A),
   .i_RDRQ(scc_rdrq_A),
   .i_WRRQ(scc_wrrq_A),
   .i_ABLO(cpu_addr[7:0]),
   .i_DB(din),
   .o_DB(scc_dout_A_int),
   .o_TEST(),
   .o_SOUND(wave_A)
);


wire scc_cs_B = cart_num & cs;
wire scc_rdrq_B = scc_cs_B & cpu_rd & cpu_mreq;
wire scc_wrrq_B = scc_cs_B & cpu_wr & cpu_mreq;

IKASCC_player_s #(.RAM_TYPE(1), .FAST_CLOCK(0), .RAMCTRL_ASYNC(1)) scc_wave_B
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_SCCREG_EN(1'b1),
   .i_CS_n(~(scc_rdrq_B | scc_wrrq_B)),   
   .i_RD_n(~scc_rdrq_B),
   .i_WR_n(~scc_wrrq_B),
   .i_RDRQ(scc_rdrq_B),
   .i_WRRQ(scc_wrrq_B),
   .i_ABLO(cpu_addr[7:0]),
   .i_DB(din),
   .o_DB(scc_dout_B_int),
   .o_TEST(),
   .o_SOUND(wave_B)
);
endmodule