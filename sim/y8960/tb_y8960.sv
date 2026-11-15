// Unit bench of y8960_cart: drives the cartridge with core-style bus cycles and
// records the outputs of the two chips it brings (SSG2, OPM) once per 3.58 MHz enable.
//   -DTB_DIV=N clock enables per chip clock (6 = core clocking at 21.477 MHz,
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
   wire scc_req, ssg_mio_wr, opl2_mio_wr, opll_mio_wr;
   wire [7:0] vol_ssg, vol_opll, vol_opl2, vol_scc;
   wire io_en_ssg, io_en_opll, io_en_opl2, io_en_opm, io_en_timer;
   wire signed [23:0] al, ar; wire av;

   y8960_cart #(.ENABLE_DIV(`TB_DIV)) dut (
      .clk, .reset, .cpu_addr(a), .cpu_din(d), .cpu_iorq(iorq), .cpu_mreq_cs(mreq), .cpu_rd(rd), .cpu_wr(wr),
      .dout, .dout_en, .irq, .mem_bank, .mem_cs, .mem_writable,
      .scc_req, .ssg_mio_wr, .opl2_mio_wr, .opll_mio_wr, .vol_ssg, .vol_opll, .vol_opl2, .vol_scc,
      .io_en_ssg, .io_en_opll, .io_en_opl2, .io_en_opm, .io_en_timer,
      .audio_l(al), .audio_r(ar), .audio_valid(av));

   // time unit of the stimulus: one chip clock (DIV clk cycles).  Bus cycles start
   // right after an enable pulse, so both clockings place them in the same chip clock.
   task automatic ticks(input int n); repeat (n * DIV) @(posedge clk); endtask
   longint tclk = 0;
   always @(posedge clk) tclk <= tclk + 1;
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
   task automatic regw(input [7:0] p, input [7:0] r, input [7:0] v); iow(p, r); ticks(12); iow(p + 8'd1, v); ticks(84); endtask

   // per-enable record of the two chips the cartridge brings
   int fo; longint nrec = 0;
   longint nz_ssg = 0, nz_opm = 0, nz_mix = 0;
   logic [11:0] ssg0; bit ssg0_set = 0;
   always @(posedge clk) if (!reset && dut.enable) begin
      $fdisplay(fo, "%0d %0d %0d %0d", dut.ssg2_l, dut.ssg2_r, dut.opm_l, dut.opm_r);
      nrec++;
      if (!ssg0_set) begin ssg0 = dut.ssg2_l; ssg0_set = 1; end
      if (dut.ssg2_l != ssg0) nz_ssg++;
      if (dut.opm_l != 0)     nz_opm++;
   end
   always @(posedge clk) if (av && (al != 0 || ar != 0)) nz_mix++;

   longint m_ssg, m_opm;
   task automatic phase(input string name, input bit want_ssg, want_opm, input bit strict);
      bit g_ssg = (nz_ssg != m_ssg), g_opm = (nz_opm != m_opm);
      if ((want_ssg && !g_ssg) || (want_opm && !g_opm) || (strict && (g_ssg != want_ssg || g_opm != want_opm))) begin
         errors++; $display("FAIL phase %s: ssg2 %0d opm %0d", name, g_ssg, g_opm);
      end else $display("ok   phase %s: ssg2 %0d opm %0d", name, g_ssg, g_opm);
      m_ssg = nz_ssg; m_opm = nz_opm;
   endtask
   //  a strobe that must be 1 (or 0) while the CPU holds the given memory cycle
   //  which: 0 SCC request, 1 PSG write, 2 MSX-AUDIO write, 3 OPLL write
   task automatic strobe(input string what, input [15:0] adr, input bit is_wr, input bit want, input int which);
      logic sig;
      @(posedge clk); a <= adr; d <= 8'h00; mreq <= 1; wr <= is_wr; rd <= ~is_wr;
      repeat (2) @(posedge clk); #1;
      sig = (which == 0) ? scc_req : (which == 1) ? ssg_mio_wr : (which == 2) ? opl2_mio_wr : opll_mio_wr;
      if (sig !== want) begin errors++; $display("FAIL %s at %04x: %0d (want %0d)", what, adr, sig, want); end
      else $display("ok   %s at %04x: %0d", what, adr, sig);
      mreq <= 0; wr <= 0; rd <= 0; ticks(2);
   endtask

   initial begin
      DIV = `TB_DIV;
      if (!$value$plusargs("out=%s", outname)) outname = "y8960.txt";
      fo = $fopen(outname, "w");
      repeat (64) @(posedge clk); reset <= 0;
      ticks(40000);                               // chip reset sequences
      m_ssg = nz_ssg; m_opm = nz_opm;

      // ---- I/O ports are off after reset: writes must not reach the chips ----
      regw(8'hA0, 8'h10, 8'h55); regw(8'hA0, 8'h18, 8'h0C); regw(8'hA0, 8'h17, 8'h3E);
      regw(8'h7E, 8'h20, 8'hC7); regw(8'h7E, 8'h08, 8'h08);
      ticks(60000);
      phase("ports off", 0, 0, 1);
      expect_rd(1, 16'h007F, 0, 0, 0, "7Fh read, port off");
      expect_rd(0, 16'h7FFF, 1, 8'hFF, 8'h00, "7FFFh enabler read");
      if (io_en_ssg | io_en_opll | io_en_opl2 | io_en_opm | io_en_timer) begin errors++; $display("FAIL io_en after reset"); end
      if (vol_ssg !== 8'd128 || vol_opll !== 8'd128 || vol_opl2 !== 8'd128 || vol_scc !== 8'd128) begin
         errors++; $display("FAIL volumes after reset: %0d %0d %0d %0d", vol_ssg, vol_opll, vol_opl2, vol_scc);
      end

      // ---- enablers ----
      busw(0, 16'h7FF6, 8'h01);
      busw(0, 16'h7FFF, 8'h83);
      expect_rd(0, 16'h7FFF, 1, 8'hFF, 8'h83, "7FFFh = 83");
      if (!(io_en_ssg & io_en_opll & io_en_opl2 & io_en_timer) | io_en_opm) begin errors++; $display("FAIL io_en after 7FF6/7FFF"); end

      // ---- SSG2 (A0h-A2h, registers 10h..) ----
      regw(8'hA0, 8'h10, 8'h55); regw(8'hA0, 8'h11, 8'h00); regw(8'hA0, 8'h18, 8'h0C); regw(8'hA0, 8'h17, 8'h3E);
      regw(8'hA0, 8'h2C, 8'd40);
      iow(8'hA0, 8'h10); ticks(12);
      expect_rd(1, 16'h00A2, 1, 8'hFF, 8'h55, "SSG2 R#0 read at A2h");
      iow(8'hA0, 8'h00); ticks(12);
      expect_rd(1, 16'h00A2, 0, 0, 0, "SSG1 R#0 read at A2h (the main PSG's)");
      ticks(60000);
      phase("SSG2", 1, 0, 1);
      regw(8'hA0, 8'h18, 8'h00);
      ticks(2000);

      // ---- OPM (7Eh-7Fh) ----
      busw(0, 16'h7FFF, 8'h87);
      regw(8'h7E, 8'h20, 8'hC7); regw(8'h7E, 8'h28, 8'h4A); regw(8'h7E, 8'h30, 8'h00);
      regw(8'h7E, 8'h40, 8'h01); regw(8'h7E, 8'h60, 8'h00); regw(8'h7E, 8'h80, 8'h1F);
      regw(8'h7E, 8'hA0, 8'h00); regw(8'h7E, 8'hC0, 8'h00); regw(8'h7E, 8'hE0, 8'h0F);
      regw(8'h7E, 8'h08, 8'h08);
      ticks(120000);
      phase("OPM", 0, 1, 0);
      expect_rd(1, 16'h007F, 1, 8'h00, 8'h00, "OPM status at 7Fh");
      regw(8'h7E, 8'h08, 8'h00);
      ticks(20000);

      // ---- what goes to the machine's chips ----
      strobe("PSG write strobe",           16'h7FF0, 1, 1, 1);
      strobe("PSG write strobe",           16'h7FF1, 1, 1, 1);
      strobe("PSG strobe on a read",       16'h7FF1, 0, 0, 1);
      strobe("MSX-AUDIO write strobe",     16'h7FF3, 1, 1, 2);
      strobe("OPLL write strobe",          16'h7FF4, 1, 1, 3);
      strobe("OPLL strobe elsewhere",      16'h7FF6, 1, 0, 3);
      strobe("SCC request, bank 2 not 63", 16'h9800, 0, 0, 0);
      busw(0, 16'h7FF6, 8'h01);
      busw(0, 16'h9000, 8'h3F);
      strobe("SCC request, bank 2 = 63",   16'h9800, 0, 1, 0);
      strobe("SCC request at 9900h (pan)", 16'h9900, 1, 0, 0);
      a <= 16'h9800; mreq <= 1; @(posedge clk); #1;
      if (mem_cs) begin errors++; $display("FAIL bank 63 at 8000h still selects the memory"); end
      mreq <= 0;

      // ---- mixer volumes: chip x master, above 128 counts as 128 ----
      busw(0, 16'h7FF7, 8'd64); busw(0, 16'h7FF8, 8'd32); busw(0, 16'h7FF9, 8'd200); busw(0, 16'h7FFA, 8'd0);
      busw(0, 16'h7FFE, 8'd64); ticks(2);
      if (vol_ssg !== 8'd32 || vol_opll !== 8'd16 || vol_opl2 !== 8'd64 || vol_scc !== 8'd0) begin
         errors++; $display("FAIL volumes: ssg %0d opll %0d opl2 %0d scc %0d", vol_ssg, vol_opll, vol_opl2, vol_scc);
      end else $display("ok   volumes: ssg %0d opll %0d opl2 %0d scc %0d", vol_ssg, vol_opll, vol_opl2, vol_scc);
      busw(0, 16'h7FFE, 8'd128);

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
      busw(0, 16'h4FFD, 8'h3F);
      strobe("SCC request, RAM mode bank 1 = 63", 16'h7800, 0, 1, 0);

      // ---- MSX-TIMER period: counts the cartridge's 42.95 MHz system clock, i.e.
      //  (compare + 1) * 1024 system clocks at resolution 0 = (N+1)*1024*DIV/12 clk here,
      //  whatever clk the bench (or the core) runs at.  Measured between two /INT edges
      //  in repeat mode, the flag cleared in between (B2h).
      begin
         longint t1, t2, want; int n = 5;
         iow(8'hB0, 8'h00); iow(8'hB1, 8'h81);          // counter 0: irq on, reso 0, repeat
         iow(8'hB0, 8'h01); iow(8'hB1, 8'(n));          // compare
         iow(8'hB0, 8'h02); iow(8'hB1, 8'h03);          // clear + count
         t1 = 0; t2 = 0;
         fork
            begin
               @(posedge irq); t1 = tclk;
               iow(8'hB2, 8'h01);
               @(posedge irq); t2 = tclk;
            end
            begin ticks(20 * (n + 1) * 1024 / 12); end
         join_any
         disable fork;
         iow(8'hB0, 8'h02); iow(8'hB1, 8'h00); iow(8'hB2, 8'h0F);
         want = longint'(n + 1) * 1024 * DIV / 12;
         if (t2 == 0 || t2 - t1 != want) begin
            errors++; $display("FAIL timer period: %0d clk (want %0d)", t2 - t1, want);
         end else $display("ok   timer period: %0d clk = %0d system clocks", t2 - t1, (t2 - t1) * 12 / DIV);
      end

      if (nz_mix == 0) begin errors++; $display("FAIL mixer output stayed zero"); end
      $display("records %0d  mixer nonzero %0d  errors %0d", nrec, nz_mix, errors);
      if (errors == 0) $display("RESULT PASS"); else $display("RESULT FAIL");   // a ternary of strings printed as a number
      $fclose(fo);
      $finish;
   end
endmodule
