// Copyright (C) 1991-2013 Altera Corporation
// Your use of Altera Corporation's design tools, logic functions 
// and other software and tools, and its AMPP partner logic 
// functions, and any output files from any of the foregoing 
// (including device programming or simulation files), and any 
// associated documentation or information are expressly subject 
// to the terms and conditions of the Altera Program License 
// Subscription Agreement, Altera MegaCore Function License 
// Agreement, or other applicable license agreement, including, 
// without limitation, that your use is for the sole purpose of 
// programming logic devices manufactured by Altera and sold by 
// Altera or its authorized distributors.  Please refer to the 
// applicable agreement for further details.

// PROGRAM		"Quartus II 64-Bit"
// VERSION		"Version 13.0.1 Build 232 06/12/2013 Service Pack 1 SJ Web Edition"
// CREATED		"Thu Nov 06 23:28:26 2014"

module data_pins(
	bus_db_pin_oe,
	bus_db_pin_re,
	ctl_bus_db_we,
	clk,
	ctl_bus_db_oe,
	D_in,
	db,
	D_out,
	D_oe
);


input wire	bus_db_pin_oe;
input wire	bus_db_pin_re;
input wire	ctl_bus_db_we;
input wire	clk;
input wire	ctl_bus_db_oe;
// MSX1 core change: the external data pins are unidirectional here.  The
// original had `inout D` driven by bus_db_pin_oe; inside an FPGA that becomes
// a mux, and any wrapper that also has to READ the net ends up with a
// combinational route from data-in to data-out straight through the CPU
// (-8.1 ns clk_sdram -> clk21m in build ca97172).  Splitting the pin kills
// that route topologically.  `dout` (below) is already a flop, so D_out is
// registered by construction.  The internal bus `db` keeps its tri-states --
// they never leave the core.
input wire	[7:0] D_in;
inout wire	[7:0] db;
output wire	[7:0] D_out;
output wire	D_oe;

reg	[7:0] dout;
wire	[7:0] SYNTHESIZED_WIRE_0;
wire	SYNTHESIZED_WIRE_1;
wire	SYNTHESIZED_WIRE_2;
wire	[7:0] SYNTHESIZED_WIRE_3;
wire	[7:0] SYNTHESIZED_WIRE_4;





always@(posedge SYNTHESIZED_WIRE_1)
begin
if (SYNTHESIZED_WIRE_2)
	begin
	dout[7:0] <= SYNTHESIZED_WIRE_0[7:0];
	end
end

assign	SYNTHESIZED_WIRE_4 = {ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we,ctl_bus_db_we} & db;

assign	SYNTHESIZED_WIRE_3 = {bus_db_pin_re,bus_db_pin_re,bus_db_pin_re,bus_db_pin_re,bus_db_pin_re,bus_db_pin_re,bus_db_pin_re,bus_db_pin_re} & D_in;

assign	SYNTHESIZED_WIRE_0 = SYNTHESIZED_WIRE_3 | SYNTHESIZED_WIRE_4;

assign	SYNTHESIZED_WIRE_2 = ctl_bus_db_we | bus_db_pin_re;

assign	db[7] = ctl_bus_db_oe ? dout[7] : 1'bz;
assign	db[6] = ctl_bus_db_oe ? dout[6] : 1'bz;
assign	db[5] = ctl_bus_db_oe ? dout[5] : 1'bz;
assign	db[4] = ctl_bus_db_oe ? dout[4] : 1'bz;
assign	db[3] = ctl_bus_db_oe ? dout[3] : 1'bz;
assign	db[2] = ctl_bus_db_oe ? dout[2] : 1'bz;
assign	db[1] = ctl_bus_db_oe ? dout[1] : 1'bz;
assign	db[0] = ctl_bus_db_oe ? dout[0] : 1'bz;


assign	SYNTHESIZED_WIRE_1 =  ~clk;

assign	D_out = dout;
assign	D_oe  = bus_db_pin_oe;


endmodule
