// Unit bench of y8960_cart: drives the cartridge with core-style bus cycles and
// records every chip's output once per 3.58 MHz enable.
//   +div=N     clock enables per chip clock (6 = core clocking at 21.477 MHz,
//              12 = upstream clocking at 42.95 MHz); bus timing scales with it
//   +out=FILE  per-enable chip outputs (text)
`timescale 1ns/1ps
module tb_y8960;
   int DIV;
   string outname;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic [15:0] a = 0; logic [7:0] d = 0;
   logic iorq = 0, mreq = 0, rd = 0, wr = 0;
   wire [7:0] dout; wire dout_en, irq;
   wire [4:0] mem_bank; wire mem_cs, mem_writable;
   wire [17:0] ya_addr; wire ya_valid, ya_write; wire [7:0] ya_wdata;
   logic ya_rdata_en = 0; logic [7:0] ya_rdata = 8'hFF;
   wire io_en_ssg, io_en_opll, io_en_opl2, io_en_opm, io_en_timer;
   wire signed [23:0] al, ar; wire av;

   // ADPCM RAM model: accept at once, data one clock later
   logic [7:0] yram [0:262143];
   wire ya_ready = ya_valid;
   always @(posedge clk) begin
      ya_rdata_en <= ya_valid & ~ya_write;
      if (ya_valid & ya_write) yram[ya_addr] <= ya_wdata;
      if (ya_valid & ~ya_write) ya_rdata <= yram[ya_addr];
   end

   y8960_cart #(.ENABLE_DIV(`TB_DIV)) dut (
      .clk, .reset, .cpu_addr(a), .cpu_din(d), .cpu_iorq(iorq), .cpu_mreq_cs(mreq), .cpu_rd(rd), .cpu_wr(wr),
      .dout, .dout_en, .irq, .mem_bank, .mem_cs, .mem_writable,
      .ya_addr, .ya_valid, .ya_write, .ya_wdata, .ya_ready, .ya_rdata, .ya_rdata_en,
      .io_en_ssg, .io_en_opll, .io_en_opl2, .io_en_opm, .io_en_timer,
      .audio_l(al), .audio_r(ar), .audio_valid(av));

   // time unit of the stimulus: one chip clock (DIV clk cycles)
   task automatic ticks(input int n); repeat (n * DIV) @(posedge clk); endtask
   int errors = 0;
   task automatic busw(input bit io, input [15:0] adr, input [7:0] dat);
      @(posedge clk); while (!dut.enable) @(posedge clk);
      a <= adr; d <= dat; iorq <= io; mreq <= ~io; wr <= 1;
      ticks(2);
      wr <= 0; iorq <= 0; mreq <= 0;
      ticks(2);
   endtask
   task automatic busr(input bit io, input [15:0] adr, output [7:0] dat, output bit en);
      @(posedge clk); while (!dut.enable) @(posedge clk);
      a <= adr; iorq <= io; mreq <= ~io; rd <= 1;
      ticks(2);
      dat = dout; en = dout_en;
      rd <= 0; iorq <= 0; mreq <= 0;
      ticks(2);
   endtask
   task automatic expect_rd(input bit io, input [15:0] adr, input bit en, input [7:0] mask, input [7:0] val, input string what);
      logic [7:0] v; bit e;
      busr(io, adr, v, e);
      if (e !== en || (en && (v & mask) !== (val & mask))) begin
         errors++; $display("FAIL %s: addr %04x en=%0d data=%02x (want en=%0d %02x mask %02x)", what, adr, e, v, en, val, mask);
      end else $display("ok   %s: en=%0d data=%02x", what, e, v);
   endtask
   task automatic iow(input [7:0] p, input [7:0] v); busw(1, {8'h00, p}, v); endtask
   // OPLL writes go through a handshake of a few master clocks, so they can land one
   // chip clock apart in the two clockings; the chip takes a register up once per
   // 72-clock sample.  Issue them at a fixed place of that period, away from the
   // uptake, so that both clockings see the write in the same sample.
   longint ecnt = 0;
   int kalign;
   always @(posedge clk) if (!reset && dut.enable) ecnt++;
   task automatic opll_align; while ((ecnt % 72) != kalign) @(posedge clk); endtask
   task automatic regw(input [7:0] p, input [7:0] r, input [7:0] v);
      if (p == 8'h7C) opll_align();
      iow(p, r); ticks(12);
      if (p == 8'h7C) opll_align();
      iow(p + 8'd1, v); ticks(84);
   endtask

   // per-enable record
   int fo; longint nrec = 0;
   longint nz_ssg = 0, nz_opll = 0, nz_opl2 = 0, nz_scc = 0, nz_opm = 0, nz_mix = 0;
   logic [12:0] ssg0; bit ssg0_set = 0;
   always @(posedge clk) if (!reset && dut.enable) begin
      $fdisplay(fo, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", dut.ssg_l, dut.ssg_r, dut.opll_l, dut.opll_r,
                dut.opl2_l, dut.opl2_r, dut.scc_l, dut.scc_r, dut.opm_l, dut.opm_r);
      nrec++;
      if (!ssg0_set) begin ssg0 = dut.ssg_l; ssg0_set = 1; end
      if (dut.ssg_l != ssg0)  nz_ssg++;
      if (dut.opll_l != 0)    nz_opll++;
      if (dut.opl2_l != 0)    nz_opl2++;
      if (dut.scc_l != 0)     nz_scc++;
      if (dut.opm_l != 0)     nz_opm++;
   end
   always @(posedge clk) if (av && (al != 0 || ar != 0)) nz_mix++;

   longint m_ssg, m_opll, m_opl2, m_scc, m_opm;
   task automatic phase(input string name, input bit want_ssg, want_opll, want_opl2, want_scc, want_opm);
      bit g_ssg  = (nz_ssg  != m_ssg),  g_opll = (nz_opll != m_opll), g_opl2 = (nz_opl2 != m_opl2);
      bit g_scc  = (nz_scc  != m_scc),  g_opm  = (nz_opm  != m_opm);
      if ((want_ssg && !g_ssg) || (want_opll && !g_opll) || (want_opl2 && !g_opl2) || (want_scc && !g_scc) || (want_opm && !g_opm)
          || (name == "ports off" && (g_ssg || g_opll || g_opl2 || g_scc || g_opm))) begin
         errors++; $display("FAIL phase %s: ssg %0d opll %0d opl2 %0d scc %0d opm %0d", name, g_ssg, g_opll, g_opl2, g_scc, g_opm);
      end else $display("ok   phase %s: ssg %0d opll %0d opl2 %0d scc %0d opm %0d", name, g_ssg, g_opll, g_opl2, g_scc, g_opm);
      m_ssg = nz_ssg; m_opll = nz_opll; m_opl2 = nz_opl2; m_scc = nz_scc; m_opm = nz_opm;
   endtask

   initial begin
      DIV = `TB_DIV;
      if (!$value$plusargs("kalign=%d", kalign)) kalign = 10;
      if (!$value$plusargs("out=%s", outname)) outname = "y8960.txt";
      fo = $fopen(outname, "w");
      for (int i = 0; i < 262144; i++) yram[i] = 8'h80;
      repeat (64) @(posedge clk); reset <= 0;
      ticks(40000);                               // chip reset sequences
      m_ssg = nz_ssg; m_opll = nz_opll; m_opl2 = nz_opl2; m_scc = nz_scc; m_opm = nz_opm;

      // ---- I/O ports are off after reset: writes must not reach the chips ----
      regw(8'hA0, 8'h00, 8'h40); regw(8'hA0, 8'h08, 8'h0F); regw(8'hA0, 8'h07, 8'h3E);
      regw(8'h7C, 8'h10, 8'h80); regw(8'h7C, 8'h30, 8'h10); regw(8'h7C, 8'h20, 8'h1C);
      regw(8'hC0, 8'h20, 8'h01); regw(8'hC0, 8'h40, 8'h00); regw(8'hC0, 8'h60, 8'hF0); regw(8'hC0, 8'h80, 8'h0F);
      regw(8'hC0, 8'h23, 8'h01); regw(8'hC0, 8'h43, 8'h00); regw(8'hC0, 8'h63, 8'hF0); regw(8'hC0, 8'h83, 8'h0F);
      regw(8'hC0, 8'hA0, 8'h98); regw(8'hC0, 8'hB0, 8'h31);
      ticks(60000);
      phase("ports off", 0, 0, 0, 0, 0);
      expect_rd(1, 16'h00C0, 0, 0, 0, "C0h read, port off");
      expect_rd(0, 16'h7FFF, 1, 8'hFF, 8'h00, "7FFFh enabler read");
      if (io_en_ssg | io_en_opll | io_en_opl2 | io_en_opm | io_en_timer) begin errors++; $display("FAIL io_en after reset"); end
      if (mem_bank !== 5'd1) begin errors++; $display("FAIL bank of 7FFFh = %0d", mem_bank); end

      // ---- SSG (A0h-A2h) ----
      busw(0, 16'h7FFF, 8'h02);
      expect_rd(0, 16'h7FFF, 1, 8'hFF, 8'h02, "7FFFh = 02");
      regw(8'hA0, 8'h00, 8'h40); regw(8'hA0, 8'h01, 8'h00); regw(8'hA0, 8'h08, 8'h0F); regw(8'hA0, 8'h07, 8'h3E);
      ticks(60000);
      phase("SSG1", 1, 0, 0, 0, 0);
      regw(8'hA0, 8'h08, 8'h00);
      regw(8'hA0, 8'h10, 8'h55); regw(8'hA0, 8'h11, 8'h00); regw(8'hA0, 8'h18, 8'h0C); regw(8'hA0, 8'h17, 8'h3E);
      regw(8'hA0, 8'h2C, 8'd40);
      iow(8'hA0, 8'h10); ticks(12);
      expect_rd(1, 16'h00A2, 1, 8'hFF, 8'h55, "SSG2 R#0 read at A2h");
      iow(8'hA0, 8'h00); ticks(12);
      expect_rd(1, 16'h00A2, 0, 0, 0, "SSG1 R#0 read at A2h (left to the main PSG)");
      ticks(60000);
      phase("SSG2", 1, 0, 0, 0, 0);
      regw(8'hA0, 8'h18, 8'h00);
      ticks(2000);

      // ---- OPLL (7Ch-7Dh) ----
      busw(0, 16'h7FF6, 8'h01);
      regw(8'h7C, 8'h10, 8'h80); regw(8'h7C, 8'h30, 8'h10); regw(8'h7C, 8'h50, 8'd200); regw(8'h7C, 8'h20, 8'h1C);
      ticks(120000);
      phase("OPLL", 0, 1, 0, 0, 0);
      regw(8'h7C, 8'h20, 8'h0C); regw(8'h7C, 8'h30, 8'h1F);
      ticks(400000);

      // ---- OPL2 + ADPCM (C0h-C1h) ----
      busw(0, 16'h7FFF, 8'h03);
      regw(8'hC0, 8'h20, 8'h01); regw(8'hC0, 8'h40, 8'h10); regw(8'hC0, 8'h60, 8'hF0); regw(8'hC0, 8'h80, 8'h0F);
      regw(8'hC0, 8'h23, 8'h01); regw(8'hC0, 8'h43, 8'h00); regw(8'hC0, 8'h63, 8'hF0); regw(8'hC0, 8'h83, 8'h0F);
      regw(8'hC0, 8'hF6, 8'd60);
      regw(8'hC0, 8'hA0, 8'h98); regw(8'hC0, 8'hB0, 8'h31);
      ticks(120000);
      phase("OPL2", 0, 0, 1, 0, 0);
      expect_rd(1, 16'h00C0, 1, 8'h06, 8'h06, "OPL2 status at C0h");
      regw(8'hC0, 8'hB0, 8'h11); regw(8'hC0, 8'h40, 8'h3F); regw(8'hC0, 8'h43, 8'h3F);
      // ADPCM: write 256 bytes of a square pattern into the RAM, then play them
      regw(8'hC0, 8'h07, 8'h01); regw(8'hC0, 8'h07, 8'h60); regw(8'hC0, 8'h08, 8'h00);
      regw(8'hC0, 8'h09, 8'h00); regw(8'hC0, 8'h0A, 8'h00); regw(8'hC0, 8'h0B, 8'h3F); regw(8'hC0, 8'h0C, 8'h00);
      for (int i = 0; i < 256; i++) regw(8'hC0, 8'h0F, (i & 8) ? 8'h77 : 8'hFF);
      regw(8'hC0, 8'h07, 8'h01);
      begin
         int n = 0;
         for (int i = 0; i < 256; i++) if (yram[i] != 8'h80) n++;
         if (n < 200) begin errors++; $display("FAIL ADPCM RAM writes: %0d of 256 bytes changed", n); end
         else $display("ok   ADPCM RAM writes: %0d bytes", n);
      end
      ticks(400000);
      m_opl2 = nz_opl2;
      regw(8'hC0, 8'h10, 8'h00); regw(8'hC0, 8'h11, 8'h40); regw(8'hC0, 8'h12, 8'hFF);
      regw(8'hC0, 8'h09, 8'h00); regw(8'hC0, 8'h0A, 8'h00); regw(8'hC0, 8'h0B, 8'h3F); regw(8'hC0, 8'h0C, 8'h00);
      regw(8'hC0, 8'h07, 8'hA0);
      ticks(200000);
      phase("ADPCM", 0, 0, 1, 0, 0);
      regw(8'hC0, 8'h07, 8'h01);
      ticks(100000);

      // ---- SCC (memory mapped, bank 2 = 63) ----
      busw(0, 16'h9000, 8'h3F);
      a <= 16'h9800; mreq <= 1; @(posedge clk); #1;
      if (mem_cs) begin errors++; $display("FAIL bank 63 at 8000h still selects the memory"); end
      mreq <= 0;
      for (int i = 0; i < 32; i++) busw(0, 16'h9800 + 16'(i), (i < 16) ? 8'h60 : 8'hA0);
      busw(0, 16'h9880, 8'h80); busw(0, 16'h9881, 8'h00); busw(0, 16'h988A, 8'h0F); busw(0, 16'h9900, 8'd30);
      busw(0, 16'h988F, 8'h01);
      ticks(60000);
      phase("SCC", 0, 0, 0, 1, 0);
      expect_rd(0, 16'h9800, 1, 8'hFF, 8'h60, "SCC wave RAM read");
      busw(0, 16'h988F, 8'h00);
      ticks(2000);

      // ---- OPM (7Eh-7Fh) ----
      busw(0, 16'h7FFF, 8'h07);
      regw(8'h7E, 8'h20, 8'hC7); regw(8'h7E, 8'h28, 8'h4A); regw(8'h7E, 8'h30, 8'h00);
      regw(8'h7E, 8'h40, 8'h01); regw(8'h7E, 8'h60, 8'h00); regw(8'h7E, 8'h80, 8'h1F);
      regw(8'h7E, 8'hA0, 8'h00); regw(8'h7E, 8'hC0, 8'h00); regw(8'h7E, 8'hE0, 8'h0F);
      regw(8'h7E, 8'h08, 8'h08);
      ticks(120000);
      phase("OPM", 0, 0, 0, 0, 1);
      expect_rd(1, 16'h007F, 1, 8'h00, 8'h00, "OPM status at 7Fh");
      regw(8'h7E, 8'h08, 8'h00);
      ticks(20000);

      // ---- mapper: RAM mode, bank registers ----
      busw(0, 16'h9000, 8'h02);
      busw(0, 16'h4FFB, 8'h01);
      busw(0, 16'h4FFE, 8'h13);
      a <= 16'h8123; mreq <= 1; @(posedge clk); #1;
      if (mem_bank !== 5'h13 || !mem_cs || !mem_writable) begin errors++; $display("FAIL RAM mode bank2: bank %0d cs %0d wr %0d", mem_bank, mem_cs, mem_writable); end
      else $display("ok   RAM mode bank 13h at 8000h is writable");
      a <= 16'h4123; @(posedge clk); #1;
      if (mem_bank !== 5'h00 || !mem_cs || mem_writable) begin errors++; $display("FAIL bank0: bank %0d cs %0d wr %0d", mem_bank, mem_cs, mem_writable); end
      else $display("ok   bank 0 at 4000h is read-only");
      a <= 16'h0123; @(posedge clk); #1;
      if (mem_cs) begin errors++; $display("FAIL page 0 selected"); end
      mreq <= 0;

      if (nz_mix == 0) begin errors++; $display("FAIL mixer output stayed zero"); end
      $display("records %0d  mixer nonzero %0d  errors %0d", nrec, nz_mix, errors);
      $display(errors == 0 ? "RESULT PASS" : "RESULT FAIL");
      $fclose(fo);
      $finish;
   end
endmodule
