// tb_scc_subslot -- cart_konami_scc keeps bank/mode state per (cart slot, subslot).
//
// An expanded cart slot can hold a KonamiSCC game in one subslot and an SCC+
// cartridge in another.  On real hardware those are two chips with two register
// sets; here they are one module, so its state must be indexed by subslot as
// well as by cart slot.  This bench writes bank 1 through two different subslots
// of the same cart slot and checks that each reads back its own value.
//
// NEGCTL=1 ties the DUT's subslot input to 0 (the pre-change behaviour): the
// second write then clobbers the first and the "subslot 0 kept its bank" check
// MUST fail.

`timescale 1ns/1ps

module tb_scc_subslot;

   logic        clk = 0;
   logic        reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic        cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0;
   logic        cart_num = 0;
   logic  [1:0] subslot = 0, dut_subslot;
   wire         mem_unmaped, scc_req;
   wire  [20:0] mem_addr;
   wire   [1:0] scc_mode;

   always #10 clk = ~clk;

`ifdef NEGCTL
   assign dut_subslot = 2'd0;
`else
   assign dut_subslot = subslot;
`endif

   cart_konami_scc dut (
      .clk(clk), .reset(reset),
      .mem_size(25'd128 << 14),
      .cpu_addr(cpu_addr), .din(din),
      .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .cs(1'b1), .cart_num(cart_num), .subslot(dut_subslot),
      .sccDevice(1'b1),
      .mem_unmaped(mem_unmaped), .mem_addr(mem_addr),
      .scc_req(scc_req), .scc_mode(scc_mode)
   );

   int errors = 0;

   task automatic wr(input logic c, input logic [1:0] ss, input logic [15:0] a, input logic [7:0] d);
      begin
         cart_num = c; subslot = ss; cpu_addr = a; din = d;
         cpu_mreq = 1; cpu_wr = 1;
         @(posedge clk); #1;
         cpu_mreq = 0; cpu_wr = 0;
         @(posedge clk); #1;
      end
   endtask

   task automatic expect_bank(input string name, input logic c, input logic [1:0] ss,
                              input logic [15:0] a, input logic [7:0] want);
      begin
         cart_num = c; subslot = ss; cpu_addr = a; cpu_mreq = 1; cpu_rd = 1;
         #1;
         if (mem_addr[20:13] !== want) begin
            $display("FAIL %-36s bank = %02h, expected %02h", name, mem_addr[20:13], want);
            errors++;
         end
         cpu_mreq = 0; cpu_rd = 0;
         #1;
      end
   endtask

   initial begin
      repeat (2) @(posedge clk);
      reset = 0;
      @(posedge clk); #1;

      // reset values: bank n = n, for every (cart, subslot)
      expect_bank("reset  A/ss0 bank1", 0, 0, 16'h6000, 8'h01);
      expect_bank("reset  A/ss3 bank3", 0, 3, 16'hA000, 8'h03);
      expect_bank("reset  B/ss1 bank2", 1, 1, 16'h8000, 8'h02);

      // bank 1 window write at 0x7000: through subslot 0, then subslot 1, same slot
      wr(0, 0, 16'h7000, 8'h11);
      wr(0, 1, 16'h7000, 8'h22);

      expect_bank("A/ss0 kept its bank1",       0, 0, 16'h6000, 8'h11);   // <- NEGCTL breaks this
      expect_bank("A/ss1 has its own bank1",    0, 1, 16'h6000, 8'h22);
      expect_bank("A/ss2 untouched",            0, 2, 16'h6000, 8'h01);
      expect_bank("B/ss0 untouched",            1, 0, 16'h6000, 8'h01);
      expect_bank("B/ss1 untouched",            1, 1, 16'h6000, 8'h01);

      // the other cart slot is still independent too
      wr(1, 2, 16'h9000, 8'h33);
      expect_bank("B/ss2 bank2",                1, 2, 16'h8000, 8'h33);
      expect_bank("A/ss2 bank2 untouched",      0, 2, 16'h8000, 8'h02);

      // SCC+ mode is per CART SLOT: any subslot in SCC+ mode with bank3 bit7 set
      wr(0, 3, 16'hBFFE, 8'h20);           // mode reg, subslot 3 -> SCC+ mode
      wr(0, 3, 16'hB000, 8'h80);           // bank3 bit7
      #1;
      if (scc_mode !== 2'b01) begin
         $display("FAIL scc_mode = %b, expected 01 (slot A via subslot 3)", scc_mode); errors++;
      end

      if (errors == 0) begin
         $display("PASS: konami_scc bank/mode state is per (cart slot, subslot)");
         $finish;
      end else begin
         $display("FAILURES: %0d", errors);
         $fatal(1, "scc subslot checks failed");
      end
   end

endmodule
