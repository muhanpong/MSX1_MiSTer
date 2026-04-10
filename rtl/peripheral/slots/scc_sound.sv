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

assign scc_dout = scc_dout_A & scc_dout_B;

assign wave = (oe[0] ? { {5{wave_A[10]}}, wave_A } : 16'd0) +
              (oe[1] ? { {5{wave_B[10]}}, wave_B } : 16'd0) ;


wire [7:0] scc_dout_A;
IKASCC #(.IMPL_TYPE(1), .RAM_BLOCK(1)) scc_wave_A
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_CS_n(~(~cart_num & cs)),   
   .o_DB_OE(),
   .i_RD_n(~(cpu_rd & cpu_mreq)),
   .i_WR_n(~(cpu_wr & cpu_mreq)),
   .i_ABLO(cpu_addr[7:0]),
   .i_ABHI(cpu_addr[15:11]),
   .i_DB(din),
   .o_DB(scc_dout_A),
   .o_SOUND(wave_A)
);


wire [7:0] scc_dout_B;
IKASCC #(.IMPL_TYPE(1), .RAM_BLOCK(1)) scc_wave_B
(
   .i_EMUCLK(clk),
   .i_MCLK_PCEN_n(~clk_en),
   .i_RST_n(~reset),
   .i_CS_n(~(cart_num & cs)),   
   .o_DB_OE(),
   .i_RD_n(~(cpu_rd & cpu_mreq)),
   .i_WR_n(~(cpu_wr & cpu_mreq)),
   .i_ABLO(cpu_addr[7:0]),
   .i_ABHI(cpu_addr[15:11]),
   .i_DB(din),
   .o_DB(scc_dout_B),
   .o_SOUND(wave_B)
);
endmodule
