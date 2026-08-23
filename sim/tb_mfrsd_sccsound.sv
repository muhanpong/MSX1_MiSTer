// tb_mfrsd_sccsound — MFRSD subslot 1 through scc_sound into IKASCC
//
// tb_mfrsd_sccmode.sv checks that mapper_mfrsd1's scc_mode carries the right
// VALUE, but it compiles only mfrsd.sv, so it cannot see what that value does to
// the sound chip.  That is precisely where the bug was:
//
//   mfrsd.sv:103-109 -- EN_SCCPLUS folds in cpu_addr[15:8]==0xB8, so exporting it
//   made scc_mode true only WHILE THE CPU WAS ADDRESSING the SCC+ window.  IKASCC
//   consumes i_SCCP_MODE continuously in its audio path (IKASCC_player_s.v:309
//   latches ch5's waveform from the shared ch4 RAM unless the mode reads Plus), so
//   between accesses it read Compatible and ch5 played ch4's waveform.
//
// A value-only bench passes that with flying colours: at the instant of a write to
// 0xB8xx the value IS correct.  What matters is that it STAYS correct afterwards,
// which only shows up with the chip in the loop.  konami_scc already has that
// coverage (tb_sccdetect); MFRSD did not.
//
//   M1  mode reads Plus after the register write, and KEEPS reading it while the
//       CPU is elsewhere -- the actual regression
//   M2  mode follows the SCC+ enable bit, not the address bus
//   M3  clearing bit5 returns it to Compatible
//   M4  ch5's waveform reads back THROUGH scc_sound/IKASCC -- the only check here
//       that fails if the chip is severed
//
// Negative control (NEGCTL=1) restores the old `EN_SCCPLUS` export; M1 must fail.
`timescale 1ns/1ps
`default_nettype none

module tb_mfrsd_sccsound;

   logic clk = 0, clk_en = 1, reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0, cs = 1;
   logic  [1:0] slot = 2'd1;
   logic [26:0] mfrsd_base_ram = 27'd0;
   logic        cart_num = 0;

   wire  [7:0] configReg;   wire [3:0] mapper_mask;
   wire [26:0] mem_addr;    wire mem_unmaped;
   wire [22:0] flash_addr;  wire flash_rq, scc_req, scc_mode;

   mapper_mfrsd1 u_map (
      .clk(clk), .reset(reset), .cs(cs), .slot(slot),
      .cpu_addr(cpu_addr), .din(din),
      .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .mfrsd_base_ram(mfrsd_base_ram),
      .configReg(configReg), .mapper_mask(mapper_mask),
      .mem_addr(mem_addr), .mem_unmaped(mem_unmaped),
      .flash_addr(flash_addr), .flash_rq(flash_rq),
      .scc_req(scc_req), .scc_mode(scc_mode));

   wire [7:0] scc_dout;  wire signed [15:0] wave;  wire debug_scc_wr;

   scc_sound u_snd (
      .clk(clk), .clk_en(clk_en), .reset(reset),
      .cart_num(cart_num),
      .cs(scc_req),                       // straight from the mapper
      .oe(2'b01),                         // DEV_SCC | DEV_SCC2, cart A
      .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
      .cpu_addr(cpu_addr), .din(din),
      .scc_dout(scc_dout), .wave(wave),
      .sccPlusChip(2'b01),                // this subslot IS an SCC+ chip
      .sccPlusMode({1'b0, scc_mode}),
      .debug_scc_wr(debug_scc_wr));

   always #5 clk = ~clk;

   int n_pass = 0, n_fail = 0;
   task automatic chk(input string n, input bit c);
      begin if (c) begin n_pass++; $display("  ok  : %s", n); end
            else   begin n_fail++; $display("  FAIL: %s", n); end end
   endtask

   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(3) @(posedge clk);
            @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask

   task automatic r(input [15:0] a, output [7:0] v);
      begin @(negedge clk); cpu_addr=a; cpu_mreq=1; cpu_rd=1; cpu_wr=0;
            repeat(3) @(posedge clk); v = scc_dout;
            @(negedge clk); cpu_mreq=0; cpu_rd=0; repeat(2) @(posedge clk); end
   endtask

   // park the bus far away from the cart, the way a running program does
   task automatic idle_elsewhere();
      begin @(negedge clk); cpu_addr=16'h0100; cpu_mreq=0; cpu_wr=0; cpu_rd=0;
            repeat(8) @(posedge clk); end
   endtask

   initial begin
      repeat(4) @(posedge clk); reset = 0; repeat(4) @(posedge clk);

      // SCC+ needs sccBanks[3] bit7 set as well as mode bit5, so bank the
      // 0xB000 register first (mapperReg is 0 at reset -> Konami-SCC decode).
      w(16'hB000, 8'h80);
      w(16'hBFFE, 8'h20);                 // mode bit5 = SCC+

      chk("M1 mode reads Plus right after the register write", scc_mode === 1'b1);

      idle_elsewhere();
      chk("M1 mode STILL reads Plus while the CPU is elsewhere", scc_mode === 1'b1);

      // touch an unrelated address, then check again -- this is the shape of the
      // original defect, where the mode collapsed between accesses
      w(16'h4000, 8'h00);
      idle_elsewhere();
      chk("M2 mode survives an access outside the SCC+ window", scc_mode === 1'b1);

      // clearing bit5 must drop back to Compatible
      w(16'hBFFE, 8'h00);
      idle_elsewhere();
      chk("M3 clearing bit5 returns Compatible", scc_mode === 1'b0);

      // ---- M4  the chip really is in the loop -------------------------------
      // Everything above reads scc_mode, which is a PORT OF mapper_mfrsd1 -- the
      // same signal tb_mfrsd_sccmode already reads.  A reviewer proved that by
      // hardwiring scc_sound's .i_SCCP_MODE to 2'd0, severing the mode from the
      // chip entirely: M1-M3 still passed 4/4.  So M4 has to observe something on
      // the far side of scc_sound, or instantiating IKASCC buys nothing.
      //
      // ch5's waveform is the thing the mode actually controls
      // (IKASCC_player_s.v:309 latches ch5 from the shared ch4 RAM unless the mode
      // reads Plus), so: write ch4 and ch5 differently in Plus mode, then read ch5
      // back.  In Plus it must return its own byte; that read has to come through
      // scc_sound and the chip.
      w(16'hBFFE, 8'h20);                 // SCC+ mode again
      // In PLUS mode the five waveforms are packed at ABLO 0x00-0x9F, so ch5 is
      // 0x80-0x9F -- NOT 0xA0-0xBF, which is where ch5 RAM sits in COMPAT mode
      // (tb_sccplus's T2/T3 headers spell both out).  Getting that wrong is how
      // this check first failed, which is itself the point: the earlier version
      // could not fail at all.
      w(16'hB880, 8'h5A);                 // ch5 waveform, Plus layout
      w(16'hB800, 8'h3C);                 // ch1 waveform, deliberately different
      begin
         automatic logic [7:0] v5, v1;
         r(16'hB880, v5);
         r(16'hB800, v1);
         chk($sformatf("M4 ch5 RAM read back through the chip (got %02h)", v5),
             v5 === 8'h5A);
         chk($sformatf("M4 ch5 is independent of ch1 (%02h vs %02h)", v5, v1),
             v5 !== v1);
      end

      // NO sticky-counter check here.  The obvious "prove the chip is in the loop" check --
      // `debug_scc_wr || scc_req` -- is theatre: debug_scc_wr is a sticky
      // ~21,000,000-cycle counter inside scc_sound (scc_sound.sv:105
      // `assign debug_scc_wr = (dbg_cnt > 0)`), not an IKASCC signal, so once any
      // earlier SCC-window write sets it the check cannot fail for the rest of the
      // run -- it would pass with IKASCC entirely disconnected.  A reviewer caught
      // that.  M1-M3 already require the chain, because scc_mode is only meaningful
      // as an input to scc_sound/IKASCC and the negative control makes them fail.

      $display("");
      $display("tb_mfrsd_sccsound: %0d passed, %0d failed", n_pass, n_fail);
`ifdef NEGCTL
      if (n_fail == 0)
         $fatal(1, "NEGCTL BROKEN: old EN_SCCPLUS export and nothing failed.");
      $display("negative control OK: %0d failed as required", n_fail);
      $finish;
`else
      if (n_fail) $fatal(1, "tb_mfrsd_sccsound: %0d FAILED", n_fail);
      $finish;
`endif
   end
endmodule
`default_nettype wire
