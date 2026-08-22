// CRITIC TB #4 — remaining probes on the new Yamanooto flash path.
`timescale 1ns/1ps
`default_nettype none
module tb_probe;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0; logic [7:0] cpu_dout=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0, cart_num=0;
   wire mem_unmaped_y, cart_dout_en, scc_req, flash_wr_en, y_flash_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode;
   wire [22:0] y_flash_addr;
   cart_yamanooto y (.clk(clk), .reset(reset), .mem_size(25'(8*1024*1024)),
      .cpu_addr(cpu_addr), .din(cpu_dout), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr),
      .cpu_rd(cpu_rd), .cs(1'b1), .cart_num(cart_num),
      .mem_unmaped(mem_unmaped_y), .mem_addr(mem_addr), .cart_dout(cart_dout),
      .cart_dout_en(cart_dout_en), .scc_req(scc_req), .scc_mode(scc_mode),
      .flash_wr_en(flash_wr_en), .flash_addr(y_flash_addr), .flash_rq(y_flash_rq),
      .prog_we(prog_we));
   wire [7:0] flash_dout; wire flash_rq; wire debug_erase;
   wire [26:0] f_sa; wire [7:0] f_sd; wire f_sr;
   logic sdram_ready=1; logic sdram_done=0;
   flash flash (.clk(clk), .clk_sdram(clk), .addr(23'(y_flash_addr)), .din(cpu_dout),
      .dout(flash_dout), .data_valid(flash_rq), .we(cpu_mreq & cpu_wr), .ce(y_flash_rq),
      .sdram_addr(f_sa), .sdram_din(f_sd), .sdram_req(f_sr),
      .sdram_ready(sdram_ready), .sdram_done(sdram_done), .sdram_offset(27'h0C00000),
      .amd_family(y_flash_rq), .boot_sector(1'b0), .erase_limit(27'h800000),
      .debug_erase(debug_erase));
   always #5 clk = ~clk;
   always @(posedge clk) begin sdram_done <= 1'b0; if (f_sr & ~sdram_done) sdram_done <= 1'b1; end

   int pw_cycles;
   task automatic w(input [15:0] a, input [7:0] d, input int hold);
      begin
         pw_cycles = 0;
         @(negedge clk); cpu_addr=a; cpu_dout=d; cpu_mreq=1; cpu_wr=1;
         repeat(hold) begin @(posedge clk); if (prog_we) pw_cycles++; end
         @(negedge clk); cpu_mreq=0; cpu_wr=0;
         repeat(2) begin @(posedge clk); if (prog_we) pw_cycles++; end
      end
   endtask

   logic [7:0] v; int c;
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      w(16'h7FFF, 8'h12, 4);                            // WREN

      // P1: prog_we width vs a LONG CPU write (WAIT states -> 12 clk M-cycle)
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4); w(16'h4AAA,8'hA0,4);
      w(16'h4100,8'h5A,12);
      $display("P1 prog_we asserted for %0d clk cycles on a 12-cycle write (addr 0x%07h)",
               pw_cycles, y_flash_addr);

      // P2: does prog_arm survive into the NEXT write?
      w(16'h4200,8'h99,4);
      $display("P2 next unrelated write: prog_we cycles = %0d  %s", pw_cycles,
               pw_cycles==0 ? "(clean)" : "*** prog_arm STUCK ***");

      // P3: bank switch between the unlock and the data byte.
      //     WREN is set, so bank_hit is suppressed -> the 0x5000 write is *flash data*.
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4); w(16'h4AAA,8'hA0,4);
      w(16'h5000,8'h40,4);
      $display("P3 program data written to the K5 bank window: prog_we cycles=%0d addr=0x%07h",
               pw_cycles, y_flash_addr);

      // P4: flash_rq / flash_dout during a NON-memory (I/O) cycle while the chip
      //     is in autoselect.  flash_rq has no cpu_mreq term.
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4); w(16'h4AAA,8'h90,4);   // autoselect
      @(negedge clk); cpu_addr=16'h5012; cpu_mreq=0; cpu_rd=1; cpu_wr=0;  // IN A,(0x12) w/ A=0x50
      @(posedge clk);
      $display("P4 IORQ cycle (mreq=0) addr=0x%04h: y_flash_rq=%0d data_valid=%0d flash_dout=0x%02h",
               cpu_addr, y_flash_rq, flash_rq, flash_dout);
      if (flash_rq) $display("   *** flash drives cpu_din during an I/O cycle ***");
      @(negedge clk); cpu_rd=0; repeat(2)@(posedge clk);
      w(16'h4000,8'hF0,4);

      // P5: partial sequence then a long gap -- does the mapper FSM desync?
      w(16'h4AAA,8'hAA,4);
      repeat(200) @(posedge clk);
      w(16'h4554,8'h55,4); w(16'h4AAA,8'hA0,4); w(16'h4300,8'h77,4);
      $display("P5 unlock with a 200-cycle gap still programs: prog_we cycles=%0d", pw_cycles);

      // P6: is the mapper's OWN state machine desynced by the flash FSM? interleave
      //     an unrelated cart read in the middle of the unlock.
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4);
      @(negedge clk); cpu_addr=16'h8000; cpu_mreq=1; cpu_rd=1; @(posedge clk);
      @(negedge clk); cpu_mreq=0; cpu_rd=0; repeat(2)@(posedge clk);
      w(16'h4AAA,8'hA0,4); w(16'h4400,8'h11,4);
      $display("P6 read interleaved into the unlock: prog_we cycles=%0d (0 = read broke it)", pw_cycles);

      // P7: program the byte at flash offset 0x?AAA (a legal target address)
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4); w(16'h4AAA,8'hA0,4); w(16'h4AAA,8'h33,4);
      $display("P7 program data AT the unlock offset: prog_we cycles=%0d, flash.index=%0d cmd[3]=0x%02h",
               pw_cycles, flash.index, flash.cmd[3]);

      // P8: ROMDIS while a program is armed
      w(16'h7FFF,8'h11,4);          // REGEN|WREN
      w(16'h4AAA,8'hAA,4); w(16'h4554,8'h55,4); w(16'h4AAA,8'hA0,4);
      w(16'h7FFD,8'h04,4);          // <- the "data" write is CFGR = ROMDIS
      $display("P8 data write lands on CFGR (ROMDIS): prog_we cycles=%0d, ROMDIS now=%0d",
               pw_cycles, y.configReg[0][2]);
      $finish;
   end
endmodule
`default_nettype wire
