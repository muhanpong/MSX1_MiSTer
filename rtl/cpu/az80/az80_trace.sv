//  A-Z80 bus trace ring, readable over JTAG with the In-System Memory Content
//  Editor (quartus_stp -t tools/dump_aztrace.tcl), the same mechanism as
//  vdp_regprobe's MPRB.  Diagnostic only.
//
//  One 48-bit sample is written on EVERY az80_clk edge (both polarities), so
//  1024 words hold the first 512 T-states after the CPU comes out of reset --
//  roughly the first 120 instructions of the BIOS.  (2048 x 48 = 12 M10K
//  next to the CPU pushed the router into congestion failure; 6 fit.)  Sampling is done on
//  clk_sdram one cycle after the CPU edge (az80_clk edges sit on clk_sdram
//  edges), so each word is the bus as the fabric sees it right after that
//  edge.  Recording arms itself when az_reset falls and stops when the ring is
//  full; the next reset re-arms it, so the ring always holds the most recent
//  boot attempt.
//
//  Word layout (bit numbers):
//    15:0  a        23:16 di        31:24 do_
//    32 mreq_n  33 iorq_n  34 rd_n  35 wr_n  36 m1_n  37 rfsh_n  38 wait_n
//    39 az80_clk (level after the edge: 1 = this was a rising edge)
//    40 sdram_ce  41 ram_rnw  42 az_rd_pace_n  43 wait_m1_n
//    44 sdram_hit 45 sdram_rdtog  46 az_reset  47 use_t80
module az80_trace
(
   input         clk_sdram,
   input         az80_clk,
   input         az_reset,
   input  [47:0] sample        // everything but bit 39, which is filled in here
);
   logic        az_q = 1'b0, rst_q = 1'b1;
   logic [9:0]  ptr = 10'd0;
   logic        full = 1'b0;
   logic        we = 1'b0;
   logic [9:0]  wa = 10'd0;
   logic [47:0] wd = 48'd0;

   always_ff @(posedge clk_sdram) begin
      az_q  <= az80_clk;
      rst_q <= az_reset;
      we    <= 1'b0;
      if (az_reset) begin
         ptr  <= 10'd0;               // re-arm: next release records from 0
         full <= 1'b0;
      end else if (az_q != az80_clk && !full) begin
         we  <= 1'b1;
         wa  <= ptr;
         wd  <= {sample[47:40], az80_clk, sample[38:0]};
         ptr <= ptr + 10'd1;
         if (ptr == 10'd1023) full <= 1'b1;
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
