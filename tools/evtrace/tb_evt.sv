//  Bench for evt_trace's loop folding and the time-based wedge trigger.
//  The stub prints every ring write in order, so the dump the board would produce
//  is exactly this transcript.
`timescale 1ns/1ns

module altsyncram #(parameter operation_mode="", width_a=1, widthad_a=1, numwords_a=1, outdata_reg_a="", lpm_hint="", lpm_type="")
(input clock0, input [widthad_a-1:0] address_a, input [width_a-1:0] data_a, input wren_a, output [width_a-1:0] q_a,
 input aclr0, aclr1, address_b, addressstall_a, addressstall_b, byteena_a, byteena_b, clock1, clocken0, clocken1, clocken2, clocken3,
 data_b, output eccstatus, output q_b, input rden_a, rden_b, wren_b);
   assign q_a = '0; assign q_b = '0; assign eccstatus = '0;
   always @(posedge clock0) if (wren_a) begin
      if (&data_a) $display("W %4d MARKER", address_a);
      else $display("W %4d kind=%2d pc=%04x port=%02x data=%02x", address_a,
                    data_a[51:48], data_a[15:0], data_a[47:40], data_a[39:32]);
   end
endmodule

module tb;
   logic clk = 0;
   always #1 clk = ~clk;

   logic        reset = 1'b1;
   logic [15:0] pc_bus = 16'd0, pc = 16'd0;
   logic        m1_n = 1'b1, mreq_n = 1'b1, iorq_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1;
   logic  [7:0] a_lo = 8'd0, d_rd = 8'd0;

   evt_trace dut (.clk(clk), .reset(reset), .pc(pc), .pc_bus(pc_bus), .sp(16'hF000),
                  .iff1(1'b0), .use_nz(1'b0), .vdp_int_n(1'b1), .ms_int_n(1'b1),
                  .mreq_n(mreq_n), .m1_n(m1_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
                  .a_lo(a_lo), .d_rd(d_rd), .d_wr(8'd0));

   task fetch(input [15:0] a, input [7:0] op);   // one M1 opcode fetch, 6 clocks
      begin
         @(posedge clk); pc_bus <= a; pc <= a; d_rd <= op; m1_n <= 0; mreq_n <= 0; rd_n <= 0;
         @(posedge clk); @(posedge clk); @(posedge clk);
         m1_n <= 1; mreq_n <= 1; rd_n <= 1;
         @(posedge clk); @(posedge clk);
      end
   endtask

   task io_in(input [7:0] p);                    // an IN from 98h..9Bh: an IOR event
      begin
         @(posedge clk); a_lo <= p; iorq_n <= 0; rd_n <= 0;
         @(posedge clk); @(posedge clk);
         iorq_n <= 1; rd_n <= 1;
         @(posedge clk); @(posedge clk);
      end
   endtask

   integer i;
   initial begin
      repeat (8) @(posedge clk);
      reset <= 1'b0;
      repeat (8) @(posedge clk);

      $display("--- T1: five distinct branches (expect five BR words) ---");
      for (i = 0; i < 5; i = i + 1) fetch(16'h1000 + i[15:0]*16'h100, 8'hC3);

      $display("--- T1b: RST 38 storm, 8 in a row (expect trigger, +64, MARKER), then re-arm ---");
      for (i = 0; i < 80; i = i + 1) begin fetch(16'hE000 + i[15:0], 8'hFF); fetch(16'h0038, 8'hF5); end
      $display("--- T1c: reset re-arms, ring kept ---");
      @(posedge clk); reset <= 1'b1; repeat (8) @(posedge clk); reset <= 1'b0; repeat (8) @(posedge clk);

      $display("--- T2: LDIR at 7B78, 2000 iterations (expect 8 BR, then one LOOP x2000) ---");
      for (i = 0; i < 2000; i = i + 1) begin fetch(16'h7B78, 8'hED); fetch(16'h7B79, 8'hB0); end
      fetch(16'h7B80, 8'hC9);

      $display("--- T3: the BIOS RAM search, 30000 single-address repeats, no trigger ---");
      for (i = 0; i < 30000; i = i + 1) fetch(16'h7D60, 8'h7E);
      fetch(16'h7D71, 8'h2E);

      $display("--- T4: a polling loop: BR + IN 98h, 500 turns (the INs must be folded too) ---");
      for (i = 0; i < 500; i = i + 1) begin fetch(16'h2D30, 8'hDB); io_in(8'h98); end
      fetch(16'h2D40, 8'hC9);

      $display("--- T5: the wedge: jr $ at 2D30 forever (expect trigger, +64, MARKER) ---");
      for (i = 0; i < 9000000; i = i + 1) fetch(16'h2D30, 8'h18);
      $display("--- done ---");
      $finish;
   end
endmodule
