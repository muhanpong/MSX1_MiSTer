//  A-Z80 bus trace ring, readable over JTAG with the In-System Memory Content
//  Editor (quartus_stp -t tools/dump_aztrace.tcl), the same mechanism as
//  vdp_regprobe's MPRB.  Diagnostic only.
//
//  PRE-TRIGGER capture.  One 48-bit sample per az80_clk edge (both polarities)
//  into a 1024-word ring that runs continuously from FPGA configuration and
//  WRAPS.  When the trigger fires -- an M1 fetch from 0x0038, the RST 38h
//  storm every failed boot ends in -- it records POST more samples and stops
//  for good, then writes one MARKER word at the stop position.  The parser
//  finds the marker and unrolls the ring, so the dump reads oldest -> newest
//  with the divergence roughly in the middle.  Resets do not re-arm it: the
//  bit-46 az_reset flag in each sample shows where resets happened instead.
//
//  Word layout (bit numbers):
//    15:0  a        23:16 di        31:24 do_
//    32 mreq_n  33 iorq_n  34 rd_n  35 wr_n  36 m1_n  37 rfsh_n  38 wait_n
//    39 az80_clk (level after the edge: 1 = this was a rising edge)
//    40 sdram_ce  41 ram_rnw  42 az_rd_pace_n  43 wait_m1_n
//    44 sdram_hit 45 sdram_rdtog  46 az_reset  47 use_t80
//    marker: a = FFFF, di = 00, do_ = 00, bits 47:32 all 1
module az80_trace
(
   input         clk_sdram,
   input         az80_clk,
   input         az_reset,
   input  [47:0] sample        // everything but bit 39, which is filled in here
);
   localparam POST = 10'd512;
   logic        az_q = 1'b0;
   logic [9:0]  ptr = 10'd0;
   logic        trig = 1'b0, stopped = 1'b0, marked = 1'b0;
   logic [9:0]  post = 10'd0;
   logic        we = 1'b0;
   logic [9:0]  wa = 10'd0;
   logic [47:0] wd = 48'd0;

   wire m1_fetch_38 = ~sample[32] & ~sample[34] & ~sample[36] & (sample[15:0] == 16'h0038);

   always_ff @(posedge clk_sdram) begin
      az_q <= az80_clk;
      we   <= 1'b0;
      if (stopped) begin
         if (!marked) begin
            marked <= 1'b1;
            we <= 1'b1; wa <= ptr;
            wd <= {16'hFFFF, 8'h00, 8'h00, 16'hFFFF};
         end
      end else if (az_q != az80_clk) begin
         we  <= 1'b1;
         wa  <= ptr;
         wd  <= {sample[47:40], az80_clk, sample[38:0]};
         ptr <= ptr + 10'd1;
         if (!trig && m1_fetch_38) begin trig <= 1'b1; post <= POST; end
         else if (trig) begin
            if (post == 10'd1) stopped <= 1'b1;
            post <= post - 10'd1;
         end
      end
   end

   altsyncram #(
      .operation_mode("SINGLE_PORT"),
      .width_a(48), .widthad_a(10), .numwords_a(1024),
      .outdata_reg_a("UNREGISTERED"),
      .lpm_hint("ENABLE_RUNTIME_MOD=YES, INSTANCE_NAME=CPUT"),
      .lpm_type("altsyncram")
   ) u_cput (
      .clock0(clk_sdram), .address_a(wa), .data_a(wd), .wren_a(we), .q_a(),
      .aclr0(1'b0), .aclr1(1'b0), .address_b(1'b1), .addressstall_a(1'b0),
      .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1),
      .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
      .data_b(1'b1), .eccstatus(), .q_b(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
   );
endmodule
