// tb_mfrsd_sccmode -- mapper_mfrsd1's scc_mode must be the SCC+ MODE, not the
// window enable.
//
// Why this exists.  scc_mode used to be assigned EN_SCCPLUS, which folds in
// `cpu_addr[15:8] == 8'hB8`.  It was therefore true ONLY while the CPU happened to
// be addressing the SCC+ register window.  msx_slots feeds it to scc_sound as
// sccPlusMode, and IKASCC consumes i_SCCP_MODE CONTINUOUSLY in its audio path --
// IKASCC_player_s.v:309 latches ch5's waveform from the shared ch4 RAM unless the
// mode reads Plus, on a sample-rate tick that essentially never coincides with a
// CPU access.  So ch5 played ch4's waveform even in Plus mode, while register
// reads and writes all behaved correctly.  That is the same defect commit be52736
// fixed for konami_scc, reached through a different mapper.
//
// The test: put the mapper in Plus mode, then sweep the CPU address over the whole
// 64K and require scc_mode to stay asserted the entire time.  scc_req is checked
// the other way round -- it MUST follow the window, because that is its job.
//
// Negative control (+define+NEGCTL): re-derive the mode the old way inside the TB
// and require the sweep to fail.  A test that passes either way proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_mfrsd_sccmode;

   logic clk = 0;  always #5 clk = ~clk;
   logic reset = 1'b1;

   logic [15:0] cpu_addr = 16'h0000;
   logic  [7:0] din      = 8'h00;
   logic        cpu_mreq = 1'b0, cpu_wr = 1'b0, cpu_rd = 1'b0;
   logic        cs       = 1'b1;

   wire         scc_mode, scc_req, mem_unmaped, flash_rq;
   wire  [26:0] mem_addr;
   wire  [22:0] flash_addr;
   wire   [7:0] configReg;
   wire   [3:0] mapper_mask;

   mapper_mfrsd1 dut (
      .clk(clk), .reset(reset), .cs(cs), .slot(2'd1),
      .cpu_addr(cpu_addr), .din(din),
      .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .mfrsd_base_ram(27'd0),
      .configReg(configReg), .mapper_mask(mapper_mask),
      .mem_addr(mem_addr), .mem_unmaped(mem_unmaped),
      .flash_addr(flash_addr), .flash_rq(flash_rq),
      .scc_req(scc_req), .scc_mode(scc_mode)
   );

   // the pre-fix expression, for the negative control
   wire mode_old = scc_mode & (cpu_addr[15:8] == 8'hB8);
`ifdef NEGCTL
   wire mode_dut = mode_old;
`else
   wire mode_dut = scc_mode;
`endif

   int errors = 0, checks = 0;
   task automatic chk(input string what, input bit ok);
      begin checks++; if (!ok) begin errors++; $display("FAIL: %s", what); end end
   endtask

   task automatic wr(input [15:0] a, input [7:0] d);
      begin
         @(posedge clk); cpu_addr <= a; din <= d; cpu_mreq <= 1; cpu_wr <= 1;
         @(posedge clk); cpu_mreq <= 0; cpu_wr <= 0;
         @(posedge clk);
      end
   endtask

   task automatic idle_at(input [15:0] a);
      begin @(posedge clk); cpu_addr <= a; cpu_mreq <= 0; cpu_wr <= 0; cpu_rd <= 0; @(posedge clk); #1; end
   endtask

   int n_hi, n_lo, req_in, req_out;

   initial begin
      repeat (4) @(posedge clk);
      reset = 1'b0;
      repeat (4) @(posedge clk);

      // ---- default state: Compatible, mode must be low everywhere ----------
      n_hi = 0;
      for (int a = 0; a < 65536; a += 37) begin
         idle_at(a[15:0]);
         if (mode_dut) n_hi++;
      end
      chk($sformatf("T1 out of reset the mode is Compatible everywhere (got %0d hi)", n_hi),
          n_hi == 0);

      // ---- enter Plus mode -------------------------------------------------
      // mapperReg[7:5] must be 0 (KONAMI-SCC) for 0xBFFE to be decoded; it is 0
      // out of reset.  bank register 3 needs bit7 set, written through 0xB000.
      wr(16'hB000, 8'h80);          // sccBanks[3] = 0x80
      wr(16'hBFFE, 8'h20);          // sccMode[5] = 1 -> Plus

      // ---- the point of the test ------------------------------------------
      n_lo = 0;
      for (int a = 0; a < 65536; a += 37) begin
         idle_at(a[15:0]);
         if (!mode_dut) n_lo++;
      end
      chk($sformatf("T2 Plus mode holds across the whole address space (got %0d lo)", n_lo),
          n_lo == 0);

      // and specifically away from the window, which is where ch5 latches
      idle_at(16'h4000);  chk("T2a Plus holds at 0x4000", mode_dut);
      idle_at(16'h8000);  chk("T2b Plus holds at 0x8000", mode_dut);
      idle_at(16'hFFFF);  chk("T2c Plus holds at 0xFFFF", mode_dut);
      idle_at(16'hB800);  chk("T2d Plus holds inside the window too", mode_dut);

      // ---- scc_req must STILL follow the window ---------------------------
      req_in = 0; req_out = 0;
      for (int a = 0; a < 65536; a += 37) begin
         @(posedge clk); cpu_addr <= a[15:0]; cpu_mreq <= 1; cpu_rd <= 1;
         @(posedge clk); #1;
         if (scc_req) begin
            if (cpu_addr[15:8] == 8'hB8) req_in++; else req_out++;
         end
         @(posedge clk); cpu_mreq <= 0; cpu_rd <= 0;
      end
      chk($sformatf("T3 scc_req fires inside the SCC+ window (got %0d)", req_in), req_in > 0);
      chk($sformatf("T3a scc_req never fires outside it (got %0d)", req_out), req_out == 0);

      // ---- leaving Plus mode must take the mode down ----------------------
      wr(16'hBFFE, 8'h00);
      idle_at(16'h8000);
      chk("T4 clearing bit5 returns to Compatible", !mode_dut);

`ifdef NEGCTL
      $display("");
      $display("NEGATIVE CONTROL: mode re-derived the old way (AND the window decode).");
      $display("T2 and T2a-T2c MUST fail above.");
      if (errors == 0) begin
         $display("NEGCTL BROKEN: the window-gated mode passed a stability test.");
         $finish(1);
      end
      $display("negative control OK: %0d/%0d checks failed as required", errors, checks);
      $finish(0);
`else
      $display("");
      $display("tb_mfrsd_sccmode: %0d checks, %0d errors", checks, errors);
      $finish(errors ? 1 : 0);
`endif
   end
endmodule
`default_nettype wire
