//  Verilog stand-ins for what Verilator cannot read.
//
//  rtl/peripheral/bram.vhd wraps Altera's altsyncram, so it is VHDL AND it
//  instantiates a megafunction -- neither ghdl synth nor Verilator can carry it
//  across.  These replacements match bram.vhd exactly where it matters:
//
//    * the address is registered, the output is NOT (outdata_reg_a =>
//      "UNREGISTERED"), so `q` presents the addressed word in the same cycle the
//      address is clocked in -- one cycle of latency from `address` to `q`.
//    * read-during-write returns the NEW data ("NEW_DATA_NO_NBE_READ").
//    * `cs = 0` forces `q` to all ones, not to the stored word (bram.vhd:35).
//      An MSX reads FFh from a deselected slot, which is how a runaway ends up
//      executing RST 38h, so getting this wrong would hide the very thing the
//      bench exists to find.
`timescale 1ns/1ns

module spram #(parameter addr_width = 8, data_width = 8,
               parameter mem_init_file = " ", mem_name = "MEM")
(input  wire                    clock,
 input  wire [addr_width-1:0]   address,
 input  wire [data_width-1:0]   data,
 input  wire                    enable,
 input  wire                    wren,
 output wire [data_width-1:0]   q,
 input  wire                    cs);
   reg [data_width-1:0] mem [0:(2**addr_width)-1];
   reg [data_width-1:0] q0;
   integer i;
   initial begin q0 = '0; for (i = 0; i < 2**addr_width; i = i + 1) mem[i] = '0; end
   always @(posedge clock) if (enable) begin
      if (wren) mem[address] <= data;
      q0 <= wren ? data : mem[address];
   end
   assign q = cs ? q0 : {data_width{1'b1}};
endmodule

module dpram_dif #(parameter addr_width_a = 8, data_width_a = 8,
                   parameter addr_width_b = 8, data_width_b = 8,
                   parameter mem_init_file = " ")
(input  wire                      clock,
 input  wire [addr_width_a-1:0]   address_a,
 input  wire [data_width_a-1:0]   data_a,
 input  wire                      enable_a,
 input  wire                      wren_a,
 output wire [data_width_a-1:0]   q_a,
 input  wire                      cs_a,
 input  wire [addr_width_b-1:0]   address_b,
 input  wire [data_width_b-1:0]   data_b,
 input  wire                      enable_b,
 input  wire                      wren_b,
 output wire [data_width_b-1:0]   q_b,
 input  wire                      cs_b);
   localparam DEPTH = (2**addr_width_a);
   reg [data_width_a-1:0] mem [0:DEPTH-1];
   reg [data_width_a-1:0] qa0;
   reg [data_width_b-1:0] qb0;
   integer i;
   initial begin qa0 = '0; qb0 = '0; for (i = 0; i < DEPTH; i = i + 1) mem[i] = '0; end
   always @(posedge clock) begin
      if (enable_a) begin
         if (wren_a) mem[address_a] <= data_a;
         qa0 <= wren_a ? data_a : mem[address_a];
      end
      if (enable_b) begin
         if (wren_b) mem[address_b] <= data_b;
         qb0 <= wren_b ? data_b : mem[address_b];
      end
   end
   assign q_a = cs_a ? qa0 : {data_width_a{1'b1}};
   assign q_b = cs_b ? qb0 : {data_width_b{1'b1}};
endmodule

module dpram #(parameter addr_width = 8, data_width = 8, parameter mem_init_file = " ")
(input  wire                  clock,
 input  wire [addr_width-1:0] address_a,
 input  wire [data_width-1:0] data_a,
 input  wire                  enable_a,
 input  wire                  wren_a,
 output wire [data_width-1:0] q_a,
 input  wire                  cs_a,
 input  wire [addr_width-1:0] address_b,
 input  wire [data_width-1:0] data_b,
 input  wire                  enable_b,
 input  wire                  wren_b,
 output wire [data_width-1:0] q_b,
 input  wire                  cs_b);
   dpram_dif #(addr_width, data_width, addr_width, data_width, mem_init_file) ram
     (clock, address_a, data_a, enable_a, wren_a, q_a, cs_a,
             address_b, data_b, enable_b, wren_b, q_b, cs_b);
endmodule

//  altsyncram as used directly by the JTAG diagnostic rings (evt_trace,
//  vdp_regprobe).  Write-only in normal operation; the ring is read over JTAG.
module altsyncram #(parameter operation_mode = "", width_a = 1, widthad_a = 1,
                    numwords_a = 1, outdata_reg_a = "", lpm_hint = "", lpm_type = "",
                    parameter width_b = 1, widthad_b = 1, numwords_b = 1,
                    parameter init_file = " ", intended_device_family = "",
                    parameter ram_block_type = "", power_up_uninitialized = "")
(input clock0, input [widthad_a-1:0] address_a, input [width_a-1:0] data_a, input wren_a,
 output [width_a-1:0] q_a, input aclr0, aclr1, addressstall_a, addressstall_b,
 input byteena_a, byteena_b, clock1, clocken0, clocken1, clocken2, clocken3,
 input [widthad_b-1:0] address_b, input [width_b-1:0] data_b, output [width_b-1:0] q_b,
 output eccstatus, input rden_a, rden_b, wren_b);
   reg [width_a-1:0] mem [0:numwords_a-1];
   always @(posedge clock0) if (wren_a) mem[address_a] <= data_a;
   assign q_a = mem[address_a];
   assign q_b = '0;
   assign eccstatus = '0;
endmodule
