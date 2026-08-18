// SCC / SCC+ integration testbench (docs/sccplus_spec.md, S3)
//
// DUT = scc_sound (wrapper) + IKASCC_player_s (black box).  All stimulus is
// applied at the CPU side of the wrapper using the real SCC / SCC+ register
// map, so the internal ABLO remap is never referenced directly.
//
// Scenarios
//   T1 Real   (sccPlusChip=0)               ch1-4 wave R/W + playback, ch5 = ch4 mirror,
//                                           0x80-0xFF read = 0xFF.  Every clk_en sample of
//                                           `wave` in T1 is dumped to a file for golden
//                                           (pre-change RTL) bit-compare -> run_sccplus.sh.
//   T2 Compat (chip=1, mode=0)              ch5 RAM at 0xA0-0xBF (R/W, independent of ch4),
//                                           deform write at 0xC0 accepted, 0x80-0x9F/0xC0-0xFF read = 0xFF.
//   T3 Plus   (chip=1, mode=1)              5 independent waves at 0x00-0x9F, FREQ/VOL/EN at
//                                           0xA0-0xBF, 0xA0-0xFF read = 0xFF, 0x80-0x9F FREQ/VOL ignored.
//   T4 mode switch                          Plus -> Compat -> Plus, ch5 RAM (and ch1 RAM) preserved.
//   T5 A/B cart independence                different waves per cart, picked with oe[].
//
// Waveform checks are phase independent: channels under test are loaded with a
// CONSTANT sample value, so a solo channel yields a constant-sign output whose
// sign/level tells which RAM the channel actually plays from.
//
// usage: see sim/run_sccplus.sh   (+dump=<file> enables the T1 wave dump)
`timescale 1ns/1ps

module tb_sccplus;

// ---------------------------------------------------------------- clocks
reg clk = 0;
always #23.28 clk = ~clk;                 // ~21.48 MHz
reg [2:0] ce_cnt = 0;
reg clk_en = 0;
always @(posedge clk) begin
   ce_cnt <= (ce_cnt == 3'd5) ? 3'd0 : ce_cnt + 3'd1;
   clk_en <= (ce_cnt == 3'd5);
end

// ---------------------------------------------------------------- DUT
reg         reset    = 1;
reg         cart_num = 0;
reg         cs       = 0;
reg  [1:0]  oe       = 2'b01;
reg         cpu_rd   = 0;
reg         cpu_wr   = 0;
reg         cpu_mreq = 0;
reg  [15:0] cpu_addr = 16'h9800;
reg  [7:0]  din      = 8'h00;
wire [7:0]  scc_dout;
wire signed [15:0] wave;
reg  [1:0]  sccPlusChip = 2'b00;          // bit0 = cart A, bit1 = cart B
reg  [1:0]  sccPlusMode = 2'b00;
wire        debug_scc_wr;

scc_sound dut (
   .clk(clk), .clk_en(clk_en), .reset(reset),
   .cart_num(cart_num), .cs(cs), .oe(oe),
   .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr), .din(din), .scc_dout(scc_dout), .wave(wave),
   .sccPlusChip(sccPlusChip), .sccPlusMode(sccPlusMode),
   .debug_scc_wr(debug_scc_wr)
);

// ---------------------------------------------------------------- wave dump (golden compare)
integer dump_fd = 0;
reg     dump_en = 0;
reg [1023:0] dump_name;
initial begin
   if ($value$plusargs("dump=%s", dump_name)) begin
      dump_fd = $fopen(dump_name, "w");
      if (dump_fd == 0) begin $display("ERROR: cannot open dump file"); $finish; end
   end
end
always @(posedge clk) if (clk_en && dump_en && dump_fd != 0) $fdisplay(dump_fd, "%0d", wave);

// ---------------------------------------------------------------- bookkeeping
integer n_pass = 0, n_fail = 0;
task check(input string name, input cond);
   begin
      if (cond) begin n_pass = n_pass + 1; $display("PASS: %0s", name); end
      else      begin n_fail = n_fail + 1; $display("FAIL: %0s", name); end
   end
endtask

// ---------------------------------------------------------------- bus tasks
// wait for the negedge right after a clk_en pulse so a 9-clock access window
// contains exactly one clk_en edge (like a ~1.5T Z80 /WR pulse at 3.58 MHz)
task align;
   begin
      @(posedge clk); while (!clk_en) @(posedge clk);
      @(negedge clk);
   end
endtask

task idle(input integer n);
   repeat (n) @(posedge clk);
endtask

task wr(input cart, input [7:0] off, input [7:0] d);
   begin
      align;
      cart_num = cart; cpu_addr = {8'h98, off}; din = d;
      cs = 1; cpu_mreq = 1; cpu_wr = 1;
      repeat (9) @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_wr = 0;
      idle(6);
   end
endtask

task rd(input cart, input [7:0] off, output [7:0] d);
   begin
      align;
      cart_num = cart; cpu_addr = {8'h98, off};
      cs = 1; cpu_mreq = 1; cpu_rd = 1;
      repeat (8) @(posedge clk);
      #1 d = scc_dout;
      @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_rd = 0;
      idle(6);
   end
endtask

// wave patterns
localparam P_CONST = 0, P_SAW = 1, P_SQUARE = 2, P_RAMP = 3;
function [7:0] pat(input integer kind, input [7:0] arg, input integer i);
   case (kind)
      P_CONST:  pat = arg;
      P_SAW:    pat = (i * 8) - 128;
      P_SQUARE: pat = (i < 16) ? 8'h7F : 8'h80;
      default:  pat = arg + i * 4;             // P_RAMP
   endcase
endfunction

task write_wave(input cart, input [7:0] base, input integer kind, input [7:0] arg);
   integer i;
   for (i = 0; i < 32; i = i + 1) wr(cart, base + i[7:0], pat(kind, arg, i));
endtask

// count mismatches on readback of a 32-byte block
task verify_block(input cart, input [7:0] base, input integer kind, input [7:0] arg, output integer bad);
   integer i; reg [7:0] d;
   begin
      bad = 0;
      for (i = 0; i < 32; i = i + 1) begin
         rd(cart, base + i[7:0], d);
         if (d !== pat(kind, arg, i)) begin
            bad = bad + 1;
            if (bad <= 3) $display("   readback 0x%02X = 0x%02X, expected 0x%02X", base + i[7:0], d, pat(kind, arg, i));
         end
      end
   end
endtask

// count bytes != 0xFF over [lo, hi]
task verify_ff(input cart, input [7:0] lo, input [7:0] hi, output integer bad);
   integer i; reg [7:0] d;
   begin
      bad = 0;
      for (i = lo; i <= hi; i = i + 1) begin
         rd(cart, i[7:0], d);
         if (d !== 8'hFF) begin
            bad = bad + 1;
            if (bad <= 3) $display("   read 0x%02X = 0x%02X, expected 0xFF", i[7:0], d);
         end
      end
   end
endtask

// FREQ/VOL/EN block base: 0x80 (Real/Compat) or 0xA0 (Plus)
task set_freq_vol(input cart, input [7:0] rb, input [11:0] f);
   integer c;
   begin
      for (c = 0; c < 5; c = c + 1) begin
         wr(cart, rb + 8'h0A + c[7:0], 8'h0F);          // VOL = 15
         wr(cart, rb + (c[7:0] << 1),     f[7:0]);      // FREQ lo
         wr(cart, rb + (c[7:0] << 1) + 1, {4'h0, f[11:8]});
      end
   end
endtask

task set_en(input cart, input [7:0] rb, input [7:0] mask);
   wr(cart, rb + 8'h0F, mask);
endtask

// ---------------------------------------------------------------- wave measurement
integer m_min, m_max, m_nz, m_last;
task measure(input integer settle, input integer nsamp);
   integer i;
   begin
      repeat (settle) begin @(posedge clk); while (!clk_en) @(posedge clk); end
      m_min = 100000; m_max = -100000; m_nz = 0; m_last = 0;
      for (i = 0; i < nsamp; i = i + 1) begin
         @(posedge clk); while (!clk_en) @(posedge clk);
         #1;
         m_last = wave;
         if (wave < m_min) m_min = wave;
         if (wave > m_max) m_max = wave;
         if (wave != 0) m_nz = m_nz + 1;
      end
   end
endtask

localparam SETTLE = 3000, NSAMP = 4096;
localparam [11:0] FREQ = 12'h040;

task do_reset;
   begin
      cs = 0; cpu_rd = 0; cpu_wr = 0; cpu_mreq = 0; oe = 2'b01; cart_num = 0;
      reset = 1; idle(60); @(negedge clk); reset = 0; idle(30);
   end
endtask

// ---------------------------------------------------------------- main
integer bad, bad2, i;
reg [7:0] d, d2;
integer lv1, lv2, lv3, lv4, lv5;
integer plus_pos, plus_neg;

initial begin
   $display("=== tb_sccplus ===");
   idle(10);

   // ============================================================ T1 Real
   $display("--- T1 Real (sccPlusChip=0)");
   sccPlusChip = 2'b00; sccPlusMode = 2'b00;
   do_reset;
   dump_en = 1;

   write_wave(0, 8'h00, P_SAW,    0);
   write_wave(0, 8'h20, P_SQUARE, 0);
   write_wave(0, 8'h40, P_CONST,  8'h40);
   write_wave(0, 8'h60, P_CONST,  8'h80);   // ch4 = -128 constant

   verify_block(0, 8'h00, P_SAW,    0,     bad);
   verify_block(0, 8'h20, P_SQUARE, 0,     bad2); bad = bad + bad2;
   verify_block(0, 8'h40, P_CONST,  8'h40, bad2); bad = bad + bad2;
   verify_block(0, 8'h60, P_CONST,  8'h80, bad2); bad = bad + bad2;
   check("T1 Real: 0x00-0x7F readback == written", bad == 0);

   verify_ff(0, 8'h80, 8'hFF, bad);
   check("T1 Real: 0x80-0xFF read == 0xFF", bad == 0);

   set_freq_vol(0, 8'h80, FREQ);

   set_en(0, 8'h80, 8'h01); measure(SETTLE, NSAMP);
   check("T1 Real: ch1 solo (saw) produces output", m_nz > 0 && m_min < 0 && m_max > 0);
   set_en(0, 8'h80, 8'h02); measure(SETTLE, NSAMP);
   check("T1 Real: ch2 solo (square) produces output", m_nz > 0 && m_min < 0 && m_max > 0);
   set_en(0, 8'h80, 8'h04); measure(SETTLE, NSAMP);
   check("T1 Real: ch3 solo (+0x40) output positive", m_nz == NSAMP && m_min > 0);
   set_en(0, 8'h80, 8'h08); measure(SETTLE, NSAMP);
   check("T1 Real: ch4 solo (-128) output negative", m_nz == NSAMP && m_max < 0);
   set_en(0, 8'h80, 8'h10); measure(SETTLE, NSAMP);
   check("T1 Real: ch5 solo mirrors ch4 (negative)", m_nz == NSAMP && m_max < 0);

   // Real mode: writes to 0xA0-0xBF must have no effect (no ch5 RAM), read stays 0xFF
   write_wave(0, 8'hA0, P_CONST, 8'h7F);
   verify_ff(0, 8'hA0, 8'hBF, bad);
   check("T1 Real: 0xA0-0xBF read == 0xFF after write attempt", bad == 0);
   set_en(0, 8'h80, 8'h10); measure(SETTLE, NSAMP);
   check("T1 Real: ch5 still mirrors ch4 after 0xA0-0xBF write", m_nz == NSAMP && m_max < 0);
   verify_block(0, 8'h60, P_CONST, 8'h80, bad);
   check("T1 Real: ch4 RAM intact after 0xA0-0xBF write", bad == 0);
   set_en(0, 8'h80, 8'h1F); measure(SETTLE, NSAMP);
   check("T1 Real: all channels on -> output", m_nz > 0);
   set_en(0, 8'h80, 8'h00); measure(300, 256);
   check("T1 Real: all muted -> silence", m_nz == 0);

   dump_en = 0;

   // ============================================================ T2 Compat
   $display("--- T2 Compat (sccPlusChip=1, sccPlusMode=0)");
   sccPlusChip = 2'b01; sccPlusMode = 2'b00;
   do_reset;

   write_wave(0, 8'h00, P_SAW,   0);
   write_wave(0, 8'h20, P_RAMP,  8'h11);
   write_wave(0, 8'h40, P_CONST, 8'h40);
   write_wave(0, 8'h60, P_CONST, 8'h80);   // ch4 = -128

   // openMSX SCC::writeWave: when mode != Plus, writing wave4 copies it into wave5,
   // and SCC::writeMem ignores writes to 0xA0-0xBF. So in Compat ch5 IS ch4.
   verify_block(0, 8'hA0, P_CONST, 8'h80, bad);
   check("T2 Compat: 0xA0-0xBF read == ch4 wave (ch5 mirrors ch4)", bad == 0);
   write_wave(0, 8'hA0, P_CONST, 8'h7F);   // must be ignored entirely
   verify_block(0, 8'h60, P_CONST, 8'h80, bad);
   check("T2 Compat: ch4 RAM 0x60-0x7F not clobbered by 0xA0-0xBF write", bad == 0);
   verify_block(0, 8'hA0, P_CONST, 8'h80, bad);
   check("T2 Compat: 0xA0-0xBF write ignored (still reads ch4 wave)", bad == 0);
   verify_ff(0, 8'h80, 8'h9F, bad);
   check("T2 Compat: 0x80-0x9F read == 0xFF", bad == 0);
   verify_ff(0, 8'hC0, 8'hFF, bad);
   check("T2 Compat: 0xC0-0xFF read == 0xFF", bad == 0);

   set_freq_vol(0, 8'h80, FREQ);
   set_en(0, 8'h80, 8'h08); measure(SETTLE, NSAMP);
   check("T2 Compat: ch4 solo (-128) output negative", m_nz == NSAMP && m_max < 0);
   set_en(0, 8'h80, 8'h10); measure(SETTLE, NSAMP);
   check("T2 Compat: ch5 solo mirrors ch4 (-128) -> output negative", m_nz == NSAMP && m_max < 0);

   // deform register at 0xC0-0xDF: accepted, no side effect on RAM / playback
   wr(0, 8'hC0, 8'h00);
   wr(0, 8'hC5, 8'hAA);
   wr(0, 8'hDF, 8'h55);
   rd(0, 8'hC0, d);
   check("T2 Compat: 0xC0 read == 0xFF after deform write", d === 8'hFF);
   verify_block(0, 8'hA0, P_CONST, 8'h80, bad);
   verify_block(0, 8'h00, P_SAW,   0,     bad2); bad = bad + bad2;
   check("T2 Compat: RAM intact after deform writes", bad == 0);
   measure(SETTLE, NSAMP);
   check("T2 Compat: ch5 keeps playing after deform write", m_nz == NSAMP && m_max < 0);
   set_en(0, 8'h80, 8'h00);

   // ============================================================ T3 Plus
   $display("--- T3 Plus (sccPlusChip=1, sccPlusMode=1)");
   sccPlusChip = 2'b01; sccPlusMode = 2'b01;
   do_reset;

   // negative test first: 0x80-0x9F is ch5 RAM in Plus mode, not FREQ/VOL/EN
   set_freq_vol(0, 8'h80, FREQ);
   set_en(0, 8'h80, 8'h1F);
   write_wave(0, 8'h00, P_CONST, 8'h10);
   measure(1000, 512);
   check("T3 Plus: FREQ/VOL/EN writes at 0x80-0x9F do not enable output", m_nz == 0);

   write_wave(0, 8'h20, P_CONST, 8'h20);
   write_wave(0, 8'h40, P_CONST, 8'h30);
   write_wave(0, 8'h60, P_CONST, 8'h40);
   write_wave(0, 8'h80, P_CONST, 8'h50);   // ch5 wave at 0x80-0x9F

   bad = 0;
   verify_block(0, 8'h00, P_CONST, 8'h10, bad2); bad = bad + bad2;
   verify_block(0, 8'h20, P_CONST, 8'h20, bad2); bad = bad + bad2;
   verify_block(0, 8'h40, P_CONST, 8'h30, bad2); bad = bad + bad2;
   verify_block(0, 8'h60, P_CONST, 8'h40, bad2); bad = bad + bad2;
   verify_block(0, 8'h80, P_CONST, 8'h50, bad2); bad = bad + bad2;
   check("T3 Plus: 0x00-0x9F readback == written (5 channels)", bad == 0);
   verify_ff(0, 8'hA0, 8'hFF, bad);
   check("T3 Plus: 0xA0-0xFF read == 0xFF", bad == 0);

   set_freq_vol(0, 8'hA0, FREQ);
   set_en(0, 8'hA0, 8'h01); measure(SETTLE, NSAMP); lv1 = m_last;
   check("T3 Plus: ch1 solo constant output", m_nz == NSAMP && m_min == m_max && m_min > 0);
   set_en(0, 8'hA0, 8'h02); measure(SETTLE, NSAMP); lv2 = m_last;
   check("T3 Plus: ch2 solo constant output", m_nz == NSAMP && m_min == m_max && m_min > 0);
   set_en(0, 8'hA0, 8'h04); measure(SETTLE, NSAMP); lv3 = m_last;
   check("T3 Plus: ch3 solo constant output", m_nz == NSAMP && m_min == m_max && m_min > 0);
   set_en(0, 8'hA0, 8'h08); measure(SETTLE, NSAMP); lv4 = m_last;
   check("T3 Plus: ch4 solo constant output", m_nz == NSAMP && m_min == m_max && m_min > 0);
   set_en(0, 8'hA0, 8'h10); measure(SETTLE, NSAMP); lv5 = m_last;
   check("T3 Plus: ch5 solo constant output", m_nz == NSAMP && m_min == m_max && m_min > 0);
   $display("   levels ch1..5 = %0d %0d %0d %0d %0d", lv1, lv2, lv3, lv4, lv5);
   check("T3 Plus: 5 channels play 5 distinct waves",
         lv1 != lv2 && lv1 != lv3 && lv1 != lv4 && lv1 != lv5 &&
         lv2 != lv3 && lv2 != lv4 && lv2 != lv5 &&
         lv3 != lv4 && lv3 != lv5 && lv4 != lv5);
   check("T3 Plus: ch5 != ch4 (independent RAM)", lv5 != lv4);
   // VOL at 0xAE really controls ch5
   wr(0, 8'hAE, 8'h00); measure(SETTLE, 512);
   check("T3 Plus: ch5 VOL=0 via 0xAE silences ch5", m_nz == 0 && lv5 != 0);
   wr(0, 8'hAE, 8'h0F);
   set_en(0, 8'hA0, 8'h00);

   // ============================================================ T4 mode switch
   $display("--- T4 Plus -> Compat -> Plus, RAM preserved");
   write_wave(0, 8'h80, P_RAMP, 8'h03);          // ch5 RAM (Plus coordinates)
   verify_block(0, 8'h80, P_RAMP, 8'h03, bad);
   check("T4: Plus 0x80-0x9F readback == ramp", bad == 0);

   sccPlusMode = 2'b00; idle(30);                // -> Compat
   // In Compat the 0xA0-0xBF window is the ch4 mirror, NOT the private ch5 RAM
   // (openMSX peekMem Compat -> readWave(4,..), and wave5 tracks wave4 when mode != Plus).
   verify_block(0, 8'hA0, P_CONST, 8'h40, bad);
   check("T4: Compat 0xA0-0xBF reads ch4 wave (mirror), not private ch5 RAM", bad == 0);
   verify_block(0, 8'h00, P_CONST, 8'h10, bad);
   check("T4: Compat ch1 RAM preserved", bad == 0);
   verify_ff(0, 8'h80, 8'h9F, bad);
   check("T4: Compat 0x80-0x9F read == 0xFF", bad == 0);

   sccPlusMode = 2'b01; idle(30);                // -> Plus again
   verify_block(0, 8'h80, P_RAMP, 8'h03, bad);
   check("T4: Plus again 0x80-0x9F == ramp", bad == 0);
   verify_ff(0, 8'hA0, 8'hBF, bad);
   check("T4: Plus again 0xA0-0xBF read == 0xFF", bad == 0);

   // ============================================================ T5 A/B cart independence
   $display("--- T5 A/B cart independence (both Real)");
   sccPlusChip = 2'b00; sccPlusMode = 2'b00;
   do_reset;

   write_wave(0, 8'h00, P_CONST, 8'h7F);   // cart A ch1 = +127
   write_wave(1, 8'h00, P_CONST, 8'h80);   // cart B ch1 = -128
   verify_block(0, 8'h00, P_CONST, 8'h7F, bad);
   verify_block(1, 8'h00, P_CONST, 8'h80, bad2);
   check("T5: cart A / cart B ch1 RAM independent (readback)", bad == 0 && bad2 == 0);

   set_freq_vol(0, 8'h80, FREQ);
   set_freq_vol(1, 8'h80, FREQ);
   set_en(1, 8'h80, 8'h01);                // only cart B enabled
   oe = 2'b01; measure(SETTLE, 512);
   check("T5: cart B EN write does not enable cart A (oe=A -> silence)", m_nz == 0);
   oe = 2'b10; measure(SETTLE, NSAMP);
   check("T5: oe=B -> cart B (-128) negative", m_nz == NSAMP && m_max < 0);
   set_en(0, 8'h80, 8'h01);
   oe = 2'b01; measure(SETTLE, NSAMP);
   check("T5: oe=A -> cart A (+127) positive", m_nz == NSAMP && m_min > 0);
   oe = 2'b10; measure(SETTLE, NSAMP);
   check("T5: oe=B -> cart B still negative", m_nz == NSAMP && m_max < 0);
   oe = 2'b00; measure(300, 256);
   check("T5: oe=00 -> silence", m_nz == 0);

   // ============================================================ result
   $display("RESULT: %0d passed, %0d failed", n_pass, n_fail);
   if (dump_fd != 0) $fclose(dump_fd);
   $finish;
end

endmodule
