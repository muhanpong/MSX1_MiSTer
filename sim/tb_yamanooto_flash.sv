// tb_yamanooto_flash — Yamanooto JEDEC byte-program / erase gating
//
// Instantiates the REAL cart_yamanooto (not a copy) and drives CPU writes at it.
//
//   Y1  WREN clear -> no program, ever (openMSX: Yamanooto.cc:235 gates on WREN)
//   Y2  the Celica sequence works: #12 -> #7FFF, then AA/55/A0 at #4AAA/#4555
//   Y3  prog_we is exactly one CPU write wide and carries the banked address
//   Y4  ROMDIS blocks programming (openMSX gates on !(configReg & ROMDIS))
//   Y5  a broken unlock (wrong address / wrong byte) never arms
//   Y6  the erase sequence (80/AA/55/30) never asserts prog_we -- flash.sv fills
//   Y7  flash_rq excludes the register and SCC windows
//   Y10 an I/O cycle (cpu_mreq clear) must not reach the flash
//   Y8  bank registers are NOT written while WREN is set (writes are flash data)
//
// Negative control (+define+NEGCTL): the WREN gate is bypassed in the checker's
// expectation, so Y1/Y4 MUST fail.  A TB that passes either way proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_yamanooto_flash;

   logic        clk = 0, reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic        cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0;
   logic        cs = 1, cart_num = 0;
   logic [24:0] mem_size = 25'(8*1024*1024);

   wire         mem_unmaped, cart_dout_en, scc_req, flash_wr_en, flash_rq, prog_we;
   wire  [24:0] mem_addr;
   wire   [7:0] cart_dout;
   wire   [1:0] scc_mode;
   wire  [22:0] flash_addr;

   cart_yamanooto dut (
      .clk(clk), .reset(reset), .mem_size(mem_size), .cpu_addr(cpu_addr),
      .din(din), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .cs(cs), .cart_num(cart_num),
      .mem_unmaped(mem_unmaped), .mem_addr(mem_addr), .cart_dout(cart_dout),
      .cart_dout_en(cart_dout_en), .scc_req(scc_req), .scc_mode(scc_mode),
      .flash_wr_en(flash_wr_en), .flash_addr(flash_addr), .flash_rq(flash_rq),
      .prog_we(prog_we)
   );

   always #5 clk = ~clk;

   int errors = 0, checks = 0;
   task automatic chk(input string what, input bit ok);
      begin checks++; if (!ok) begin errors++; $display("FAIL: %s", what); end end
   endtask

   // one CPU write, and report whether prog_we was ever seen during it
   task automatic cpu_write(input [15:0] a, input [7:0] d, output bit saw_prog);
      begin
         saw_prog = 0;
         @(negedge clk); cpu_addr = a; din = d; cpu_mreq = 1; cpu_wr = 1;
         repeat (4) begin @(posedge clk); if (prog_we) saw_prog = 1; end
         @(negedge clk); cpu_mreq = 0; cpu_wr = 0;
         repeat (2) @(posedge clk);
      end
   endtask

   task automatic unlock_prog(input [7:0] data, input [15:0] target, output bit saw);
      bit s1, s2, s3;
      begin
         cpu_write(16'h4AAA, 8'hAA, s1);
         cpu_write(16'h4555, 8'h55, s2);
         cpu_write(16'h4AAA, 8'hA0, s3);
         cpu_write(target,   data,  saw);
         chk("unlock cycles themselves must never program", !s1 && !s2 && !s3);
      end
   endtask

   bit saw, s;
   initial begin
      repeat (4) @(posedge clk); reset = 0; repeat (4) @(posedge clk);

      // ---- Y1: WREN clear -> never programs -----------------------------
      unlock_prog(8'h5A, 16'h4000, saw);
`ifdef NEGCTL
      chk("Y1 WREN clear must block programming", saw);   // deliberately inverted
`else
      chk("Y1 WREN clear must block programming", !saw);
`endif

      // ---- Y2: the Celica sequence: #12 -> #7FFF -------------------------
      // NB #12 is WREN(bit4)|SPIEN(bit1); REGEN(bit0) is NOT in it.  WREN alone
      // is what opens the flash, which is why the games work without REGEN.
      cpu_write(16'h7FFF, 8'h12, s);
      chk("Y2 WREN is set by #12 -> #7FFF", flash_wr_en === 1'b1);
      unlock_prog(8'h5A, 16'h4000, saw);
      chk("Y2 program armed with WREN set", saw);

      // ---- Y3: prog_we carries the banked flash address ------------------
      // bank0 defaults to 0 and 0x4000 is page8kB 0 -> flash addr 0x0000.
      chk("Y3 flash_addr tracks the bank register", flash_addr === 23'h000000);

      // ---- Y4: ROMDIS blocks it (CFGR bit2) ------------------------------
      // CFGR is only writable once REGEN is set, so raise REGEN|WREN first.
      cpu_write(16'h7FFF, 8'h11, s);                 // ENAR <- REGEN|WREN
      chk("Y4 WREN still set with REGEN", flash_wr_en === 1'b1);
      cpu_write(16'h7FFD, 8'h04, s);                 // CFGR <- ROMDIS
      unlock_prog(8'h5A, 16'h4000, saw);
`ifdef NEGCTL
      chk("Y4 ROMDIS must block programming", saw);  // deliberately inverted
`else
      chk("Y4 ROMDIS must block programming", !saw);
`endif
      cpu_write(16'h7FFD, 8'h00, s);                 // clear ROMDIS
      cpu_write(16'h7FFF, 8'h12, s);                 // back to WREN only (REGEN clear)

      // ---- Y5: broken unlocks never arm ----------------------------------
      cpu_write(16'h4000, 8'hAA, s);                 // wrong unlock address
      cpu_write(16'h4555, 8'h55, s);
      cpu_write(16'h4AAA, 8'hA0, s);
      cpu_write(16'h4000, 8'h5A, saw);
      chk("Y5 wrong unlock address must not arm", !saw);

      cpu_write(16'h4AAA, 8'hAA, s);
      cpu_write(16'h4555, 8'h55, s);
      cpu_write(16'h4AAA, 8'hB0, s);                 // not A0
      cpu_write(16'h4000, 8'h5A, saw);
      chk("Y5 wrong command byte must not arm", !saw);

      // ---- Y6: erase sequence must not program ---------------------------
      cpu_write(16'h4AAA, 8'hAA, s);
      cpu_write(16'h4555, 8'h55, s);
      cpu_write(16'h4AAA, 8'h80, s);
      cpu_write(16'h4AAA, 8'hAA, s);
      cpu_write(16'h4555, 8'h55, s);
      cpu_write(16'h4000, 8'h30, saw);
      chk("Y6 erase confirm must not assert prog_we", !saw);

      // ---- Y7: flash_rq excludes register / SCC / out-of-page ------------
      // With REGEN clear the register window must NOT shadow the flash -- that is
      // the RC744 fix (reg_rd, not reg_hit): 0x7FFC-0x7FFF has to read ROM.
      @(negedge clk); cpu_addr = 16'h7FFF; cpu_mreq = 1; cpu_rd = 1; cpu_wr = 0;
      @(posedge clk);
      chk("Y7 REGEN clear -> register window still reads the flash", flash_rq === 1'b1);
      @(negedge clk); cpu_mreq = 0; cpu_rd = 0; @(posedge clk);
      cpu_write(16'h7FFF, 8'h11, s);                 // REGEN|WREN
      @(negedge clk); cpu_addr = 16'h7FFF; cpu_mreq = 1; cpu_rd = 1; cpu_wr = 0;
      @(posedge clk);
      chk("Y7 REGEN set -> register window shadows the flash", flash_rq === 1'b0);
      @(negedge clk); cpu_mreq = 0; cpu_rd = 0; @(posedge clk);
      cpu_write(16'h7FFF, 8'h12, s);                 // back to WREN only
      @(negedge clk); cpu_addr = 16'h0000; cpu_mreq = 1; cpu_rd = 1;
      @(posedge clk);
      chk("Y7 outside 0x4000-0xBFFF is not the flash", flash_rq === 1'b0);
      @(negedge clk); cpu_addr = 16'h4000; cpu_mreq = 1; cpu_rd = 1;
      @(posedge clk);
      chk("Y7 ROM window IS the flash", flash_rq === 1'b1);
      @(negedge clk); cpu_mreq = 0; cpu_rd = 0; @(posedge clk);

      // ---- Y10: an I/O cycle must not look like a memory cycle.
      // `IN A,(0x12)` puts {A,port} on cpu_addr, so A=0x50 gives 0x5012 -- inside
      // page_ok, cpu_rd asserted, cpu_mreq CLEAR.  Without the mreq term that
      // IORQ cycle asserts flash_rq and, while a driver legitimately has
      // autoselect or CFI active, the flash dout is ANDed into the shared
      // cpu_din tree and corrupts the IN result.
      @(negedge clk); cpu_addr = 16'h5012; cpu_mreq = 0; cpu_rd = 1; cpu_wr = 0;
      @(posedge clk);
      chk("Y10 I/O read (mreq clear) must not reach the flash", flash_rq === 1'b0);
      @(negedge clk); cpu_addr = 16'h5012; cpu_mreq = 1; cpu_rd = 1;
      @(posedge clk);
      chk("Y10 same address as a MEMORY read does reach the flash", flash_rq === 1'b1);
      @(negedge clk); cpu_mreq = 0; cpu_rd = 0;

      // ---- Y9: WREN clear -> WRITES must not reach the shared command FSM.
      // An ordinary K4 bank write carrying 0xAA at word offset 0x555 would
      // otherwise walk flash.sv's FSM toward autoselect, corrupting reads for
      // every cart.  Reads must still pass (openMSX readMem has no WREN test).
      cpu_write(16'h7FFF, 8'h00, s);                 // ENAR <- 0 (WREN clear)
      chk("Y9 WREN is clear", flash_wr_en === 1'b0);
      @(negedge clk); cpu_addr = 16'h4AAA; din = 8'hAA; cpu_mreq = 1; cpu_wr = 1; cpu_rd = 0;
      @(posedge clk);
      chk("Y9 WREN clear -> write must not reach the flash FSM", flash_rq === 1'b0);
      @(negedge clk); cpu_mreq = 0; cpu_wr = 0; @(posedge clk);
      @(negedge clk); cpu_addr = 16'h4AAA; cpu_mreq = 1; cpu_rd = 1; cpu_wr = 0;
      @(posedge clk);
      chk("Y9 WREN clear -> READ still reaches the flash", flash_rq === 1'b1);
      @(negedge clk); cpu_mreq = 0; cpu_rd = 0; @(posedge clk);
      cpu_write(16'h7FFF, 8'h12, s);                 // WREN back on
      @(negedge clk); cpu_addr = 16'h4AAA; din = 8'hAA; cpu_mreq = 1; cpu_wr = 1; cpu_rd = 0;
      @(posedge clk);
      chk("Y9 WREN set -> write reaches the flash FSM", flash_rq === 1'b1);
      @(negedge clk); cpu_mreq = 0; cpu_wr = 0; @(posedge clk);

      // ---- Y8: with WREN set, a bank write is flash data, not a bank -----
      begin
         automatic logic [24:0] before_addr;
         @(negedge clk); cpu_addr = 16'h4000; cpu_mreq = 1; cpu_rd = 1;
         @(posedge clk); before_addr = mem_addr;
         @(negedge clk); cpu_mreq = 0; cpu_rd = 0; @(posedge clk);
         cpu_write(16'h5000, 8'h33, s);              // K5 bank window for page 0
         @(negedge clk); cpu_addr = 16'h4000; cpu_mreq = 1; cpu_rd = 1;
         @(posedge clk);
         chk("Y8 bank register frozen while WREN is set", mem_addr === before_addr);
         @(negedge clk); cpu_mreq = 0; cpu_rd = 0;
      end

      $display("");
`ifdef NEGCTL
      $display("NEGATIVE CONTROL: WREN/ROMDIS gates inverted — Y1/Y4 MUST fail.");
      if (errors == 0)
         $fatal(1, "NEGCTL BROKEN: inverted expectations still passed. TB is worthless.");
      $display("negative control OK: %0d/%0d checks failed as required", errors, checks);
      $finish;
`else
      $display("tb_yamanooto_flash: %0d checks, %0d errors", checks, errors);
      if (errors) $fatal(1, "tb_yamanooto_flash: %0d of %0d checks FAILED", errors, checks);
      $finish;
`endif
   end
endmodule
`default_nettype wire
