// MFRSD SD pacing bench: Nextor MFRSD driver access spacing vs spi_divmmc.
//  +design=0 old (mfrsd3 as of 0e04047 + old read-only pacer), 1 new
//  +turbo=0/1  (turbo: 21.5 MHz T80s spacing, 1 T = 1 clk21m; stock: x6)
//  +cmp=1      run old and new side by side at stock spacing and compare SPI fire trains
`timescale 1ns/1ps
module tb;
  reg clk = 0; always #23.28 clk = ~clk;
  reg reset = 1;
  integer dsel = 1, turbo = 1, cmp = 0;
  reg [15:0] addr = 0; reg [7:0] din = 0; reg mreq = 0, rd = 0, wr = 0;

  // ---- DUT A (selected dsel) + its SPI + card ----
  wire rxA, txA, holdA_new, dbgA_old, rdyA; wire [7:0] dA, txdA, doutA_new, doutA_old, dfromA;
  wire rxN, txN, rxO, txO;
  mapper_mfrsd3 N(.clk(clk), .reset(reset), .cs(1'b1), .cpu_addr(addr), .din(din), .mapper_dout(doutA_new),
     .cpu_mreq(mreq), .cpu_wr(wr), .cpu_rd(rd), .mfrsd_base_ram(27'd0), .configReg(8'd0), .mem_addr(), .flash_addr(),
     .mem_unmaped(), .sd_rx(rxN), .sd_tx(txN), .d_from_sd(dfromN), .sd_ready(rdyN), .sd_txdata(txdN), .flash_rq(), .sd_hold(holdA_new));
  mapper_mfrsd3_old O(.clk(clk), .reset(reset), .cs(1'b1), .cpu_addr(addr), .din(din), .mapper_dout(doutA_old),
     .cpu_mreq(mreq), .cpu_wr(wr), .cpu_rd(rd), .mfrsd_base_ram(27'd0), .configReg(8'd0), .mem_addr(), .flash_addr(),
     .mem_unmaped(), .sd_rx(rxO), .sd_tx(txO), .d_from_sd(dfromO), .flash_rq(), .debug_sd_card(dbgA_old));
  wire rdyN, rdyO; wire [7:0] dfromN, dfromO, txdN;
  wire sclkN, sdoN, sclkO, sdoO; reg sdiN, sdiO;
  spi_divmmc SN(.clk_sys(clk), .ready(rdyN), .tx(txN), .rx(rxN), .din(txdN), .dout(dfromN), .spi_ce(1'b1), .spi_clk(sclkN), .spi_di(sdiN), .spi_do(sdoN));
  spi_divmmc SO(.clk_sys(clk), .ready(rdyO), .tx(txO), .rx(rxO), .din(din),  .dout(dfromO), .spi_ce(1'b1), .spi_clk(sclkO), .spi_di(sdiO), .spi_do(sdoO));
  // card: transfer K sends byte K (MSB first)
  integer kN = 0, kO = 0, dropN = 0, dropO = 0, reqN = 0, reqO = 0;
  always @* begin sdiN = kN[7 - SN.counter[4:1]]; sdiO = kO[7 - SO.counter[4:1]]; end
  always @(posedge clk) begin
    if (rxN | txN) begin reqN = reqN + 1; if (SN.counter[4]) kN <= kN + 1; else dropN = dropN + 1; end
    if (rxO | txO) begin reqO = reqO + 1; if (SO.counter[4]) kO <= kO + 1; else dropO = dropO + 1; end
  end
  // old read-only pacer (msx.sv @0e04047)
  reg xseen = 0; reg [5:0] pcnt = 0;
  always @(posedge clk) if (reset | ~dbgA_old) begin xseen <= 0; pcnt <= 0; end else begin if (~rdyO) xseen <= 1; if (pcnt != 32) pcnt <= pcnt + 1; end
  wire hold_old = dbgA_old & ~(xseen & rdyO) & (pcnt != 32);
  reg [6:0] ncnt = 0;
  always @(posedge clk) if (reset | ~holdA_new) ncnt <= 0; else if (ncnt != 64) ncnt <= ncnt + 1;
  wire hold_new = holdA_new & (ncnt != 64);
  wire hold = (turbo != 0) & (dsel ? hold_new : hold_old);
  wire [7:0] dout_sel = dsel ? doutA_new : doutA_old;

  // fire-train comparison (stock, cmp mode)
  integer fires = 0, mism = 0;
  always @(posedge clk) if (!reset && cmp) begin
    if ({rxN,txN} != {rxO,txO}) mism = mism + 1;
    if (rxN | txN) fires = fires + 1;
  end

  // ---- CPU model ----
  integer scale; integer spi_acc = 0, rd_err = 0, rd_n = 0, extend_max = 0;
  integer tmark;
  reg [7:0] last_rd = 8'hFF; integer have_last = 0;
  task access(input [15:0] a, input w, input [7:0] d, input integer spacing, input spi);
    integer ext, i;
    begin
      @(negedge clk); addr = a; din = d; mreq = 1; rd = !w; wr = w;
      ext = 0;
      for (i = 0; i < 2*scale; i = i + 1) @(negedge clk);   // strobe length 2 T
      while (hold) begin @(negedge clk); ext = ext + 1; end
      if (ext > extend_max) extend_max = ext;
      if (!w && spi) begin
        rd_n = rd_n + 1;
        if (have_last && dout_sel !== last_rd + 8'd1 && !(last_rd == 8'hFF && dout_sel == 8'hFF)) rd_err = rd_err + 1;
        last_rd = dout_sel; have_last = 1;
      end
      if (spi) spi_acc = spi_acc + 1;
      mreq = 0; rd = 0; wr = 0;
      for (i = 2*scale; i < spacing*scale; i = i + 1) @(negedge clk);
    end
  endtask
  // with the card model every SPI transfer K returns K, so each SPI read returns (its predecessor's K);
  // consecutive SPI reads/writes advance K by one each -> reads see +1 only when no write intervened.
  // So check reads only inside pure read runs (reset have_last on writes).
  task wr_sd(input [7:0] d, input integer sp); begin access(16'h4000, 1, d, sp, 1); have_last = 0; end endtask
  task rd_sd(input integer sp); begin access(16'h4000, 0, 8'h00, sp, 1); end endtask

  integer r, i;
  initial begin
    if ($value$plusargs("design=%d", dsel)) ; if ($value$plusargs("turbo=%d", turbo)) ; if ($value$plusargs("cmp=%d", cmp)) ;
    scale = turbo ? 1 : 6;
    repeat (10) @(negedge clk); reset = 0; repeat (40) @(negedge clk);
    access(16'h6000, 1, 8'h40, 20, 0);    // bank0 = 40 -> SD window on
    access(16'h5800, 1, 8'h00, 20, 0);    // select SD
    for (r = 0; r < 20; r = r + 1) begin
      // MMCCMD: ld l,(hl) / nop / nop / 6 x (ld (hl),x / nop) / ld (hl),#95 then 2 reads / CMD_L1 reads
      rd_sd(18);
      for (i = 0; i < 5; i = i + 1) wr_sd(8'h40 + i, 13);
      wr_sd(8'h95, 11);
      rd_sd(11); rd_sd(20);
      for (i = 0; i < 4; i = i + 1) rd_sd(20);
      // sector: 512 LDI reads, 18 T each
      have_last = 0;
      for (i = 0; i < 512; i = i + 1) rd_sd(18);
    end
    repeat (200) @(negedge clk);
    if (cmp)
      $display("CMP stock: fires=%0d fire-train mismatches old/new=%0d  dropN=%0d dropO=%0d", fires, mism, dropN, dropO);
    else
      $display("design=%0s turbo=%0d: spi accesses=%0d requests=%0d dropped=%0d  read-sequence errors=%0d/%0d  max WAIT extension=%0d clk21m",
        dsel ? "new" : "old", turbo, spi_acc, dsel ? reqN : reqO, dsel ? dropN : dropO, rd_err, rd_n, extend_max);
    $finish;
  end
endmodule
