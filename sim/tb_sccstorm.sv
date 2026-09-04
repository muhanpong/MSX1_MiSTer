// SCC+ wave-rewrite disturbance quantifier (docs/handoff_scc_crackle_20260904.md)
//
// Twin scc_sound DUTs share every input except cs:
//   dut_ref : init only (clean playback)
//   dut_sut : init + "percussion storm" = rewriting the SAME 32-byte waveform
//             at OTIR pacing while the channel plays.
// RAM content never changes during the storm, so any (wave_sut - wave_ref)
// delta is pure CPU-access disturbance (the ram_rdrq hijack under test).
//
// Phases (all in Plus mode, chip A):
//   S1 control        no storm            -> delta must be exactly 0 (twin sanity)
//   S2 ch1 wr storm   rewrite 0x00-0x1F   -> per-write disturbance stats
//   S3 ch1 rd storm   read    0x00-0x1F   -> per-read  disturbance stats
//   S4 ch4 wr storm   rewrite 0x60-0x7F   -> shared ch4/5 RAM + wavelatch path
//
// usage: iverilog -g2012 tb + scc_sound + IKASCC_player_s + IKASCC_primitives
`timescale 1ns/1ps

module tb_sccstorm;

reg clk = 0;
always #23.28 clk = ~clk;                 // ~21.48 MHz
reg [2:0] ce_cnt = 0;
reg clk_en = 0;
always @(posedge clk) begin
   ce_cnt <= (ce_cnt == 3'd5) ? 3'd0 : ce_cnt + 3'd1;
   clk_en <= (ce_cnt == 3'd5);
end

// ------------------------------------------------------------- shared bus
reg         reset    = 1;
reg         cart_num = 0;
reg         cs       = 0;      // gated per-DUT by tgt[]
reg  [1:0]  tgt      = 2'b11;  // bit0=ref, bit1=sut
reg         cpu_rd   = 0;
reg         cpu_wr   = 0;
reg         cpu_mreq = 0;
reg  [15:0] cpu_addr = 16'h9800;
reg  [7:0]  din      = 8'h00;
wire [7:0]  dout_ref, dout_sut;
wire signed [15:0] wave_ref, wave_sut;

scc_sound dut_ref (
   .clk(clk), .clk_en(clk_en), .reset(reset),
   .cart_num(cart_num), .cs(cs & tgt[0]), .oe(2'b01),
   .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr), .din(din), .scc_dout(dout_ref), .wave(wave_ref),
   .sccPlusChip(2'b01), .sccPlusMode(2'b01), .debug_scc_wr()
);
scc_sound dut_sut (
   .clk(clk), .clk_en(clk_en), .reset(reset),
   .cart_num(cart_num), .cs(cs & tgt[1]), .oe(2'b01),
   .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr), .din(din), .scc_dout(dout_sut), .wave(wave_sut),
   .sccPlusChip(2'b01), .sccPlusMode(2'b01), .debug_scc_wr()
);

// ------------------------------------------------------------- bus tasks
task align;
   begin
      @(posedge clk); while (!clk_en) @(posedge clk);
      @(negedge clk);
   end
endtask

task idle(input integer n);
   repeat (n) @(posedge clk);
endtask

task wr(input [7:0] off, input [7:0] d);
   begin
      align;
      cpu_addr = {8'h98, off}; din = d;
      cs = 1; cpu_mreq = 1; cpu_wr = 1;
      repeat (9) @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_wr = 0;
      idle(6);
   end
endtask

task rd(input [7:0] off);
   begin
      align;
      cpu_addr = {8'h98, off};
      cs = 1; cpu_mreq = 1; cpu_rd = 1;
      repeat (9) @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_rd = 0;
      idle(6);
   end
endtask

// OTIR pacing: 21 T-states/byte at 3.58MHz -> pad each 2.5T access to 21T
task otir_gap;
   repeat (18) begin @(posedge clk); while (!clk_en) @(posedge clk); end
endtask

function [7:0] saw(input integer i);
   saw = (i * 8) - 128;
endfunction

// ------------------------------------------------------------- delta meter
integer m_n, m_nz, m_maxabs;
real    m_sumsq;
reg     meter_en = 0;
integer d_now;
always @(posedge clk) if (clk_en && meter_en) begin
   #1;
   d_now = wave_sut - wave_ref;
   m_n = m_n + 1;
   if (d_now != 0) begin
      m_nz = m_nz + 1;
      if (d_now < 0) d_now = -d_now;
      if (d_now > m_maxabs) m_maxabs = d_now;
   end
   m_sumsq = m_sumsq + $itor(wave_sut - wave_ref) * $itor(wave_sut - wave_ref);
end

task meter_start;
   begin m_n = 0; m_nz = 0; m_maxabs = 0; m_sumsq = 0.0; meter_en = 1; end
endtask

task meter_report(input string name, input integer n_access);
   real rms;
   begin
      meter_en = 0;
      rms = (m_n > 0) ? $sqrt(m_sumsq / m_n) : 0.0;
      $display("METER %-14s samples=%0d nonzero=%0d (%0.2f%%) maxabs=%0d rms=%0.2f accesses=%0d nz/access=%0.2f",
               name, m_n, m_nz, 100.0*m_nz/m_n, m_maxabs, rms, n_access,
               (n_access>0) ? 1.0*m_nz/n_access : 0.0);
   end
endtask

// ------------------------------------------------------------- checks
integer n_pass = 0, n_fail = 0;
task check(input string name, input cond);
   begin
      if (cond) begin n_pass = n_pass + 1; $display("PASS: %0s", name); end
      else      begin n_fail = n_fail + 1; $display("FAIL: %0s", name); end
   end
endtask

// ------------------------------------------------------------- main
integer i, r;
integer nacc;
integer s1_nz;
localparam ROUNDS = 40;

initial begin
   $display("=== tb_sccstorm ===");
   idle(60); @(negedge clk); reset = 0; idle(30);

   // ---- init both DUTs identically (tgt=11): Plus mode register base = 0xA0
   tgt = 2'b11;
   for (i = 0; i < 32; i = i + 1) wr(8'h00 + i[7:0], saw(i));        // ch1 wave: saw
   for (i = 0; i < 32; i = i + 1) wr(8'h60 + i[7:0], saw(31 - i));   // ch4 wave: reverse saw
   // ch1 + ch4 on, vol 15, mid frequency
   wr(8'hAA, 8'h0F);            // ch1 vol
   wr(8'hAD, 8'h0F);            // ch4 vol
   wr(8'hA0, 8'h40); wr(8'hA1, 8'h00);   // ch1 freq
   wr(8'hA6, 8'h55); wr(8'hA7, 8'h00);   // ch4 freq
   wr(8'hAF, 8'h09);            // EN: ch1 + ch4

   // settle
   repeat (2000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   check("playback alive", wave_ref != 0 || wave_sut != 0);

   // ---- S1 control: no storm, twins must stay bit-identical
   meter_start;
   repeat (20000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   s1_nz = m_nz;
   meter_report("S1_control", 0);
   check("S1 twins identical with no storm", s1_nz == 0);

   // ---- S2 ch1 write storm (identical content)
   tgt = 2'b10;  nacc = 0;
   meter_start;
   for (r = 0; r < ROUNDS; r = r + 1) begin
      for (i = 0; i < 32; i = i + 1) begin
         wr(8'h00 + i[7:0], saw(i)); nacc = nacc + 1;
         otir_gap;
      end
      repeat (200) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   end
   meter_report("S2_ch1_wr", nacc);

   // quiesce and re-verify twins re-converge
   tgt = 2'b11;
   repeat (2000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   meter_start;
   repeat (8000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   meter_report("S2_post", 0);
   check("S2 twins re-converge after storm", m_nz == 0);

   // ---- S3 ch1 read storm
   tgt = 2'b10;  nacc = 0;
   meter_start;
   for (r = 0; r < ROUNDS; r = r + 1) begin
      for (i = 0; i < 32; i = i + 1) begin
         rd(8'h00 + i[7:0]); nacc = nacc + 1;
         otir_gap;
      end
      repeat (200) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   end
   meter_report("S3_ch1_rd", nacc);

   tgt = 2'b11;
   repeat (2000) begin @(posedge clk); while (!clk_en) @(posedge clk); end

   // ---- S4 ch4 write storm (shared ch4/5 RAM, wavelatch path)
   tgt = 2'b10;  nacc = 0;
   meter_start;
   for (r = 0; r < ROUNDS; r = r + 1) begin
      for (i = 0; i < 32; i = i + 1) begin
         wr(8'h60 + i[7:0], saw(31 - i)); nacc = nacc + 1;
         otir_gap;
      end
      repeat (200) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   end
   meter_report("S4_ch4_wr", nacc);

   tgt = 2'b11;
   repeat (2000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   meter_start;
   repeat (8000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   meter_report("S4_post", 0);
   check("S4 twins re-converge after storm", m_nz == 0);

   // ---- S5 deform 0x20: FREQ write resets waveform position (SCMD percussion)
   tgt = 2'b10;
   wr(8'hC0, 8'h20);                          // deform (Plus: 0xC0-0xDF -> internal 0xE0)
   // park position away from 0: wait, then check it moved
   repeat (1000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   check("S5 position advanced before test", dut_sut.scc_wave_A.u_ctrl_ch1.o_RAM_ADDR_CNTR > 5'd2);
   wr(8'hA0, 8'h40);                          // rewrite same FREQ lo
   repeat (3) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   check("S5 deform 0x20: freq write resets position", dut_sut.scc_wave_A.u_ctrl_ch1.o_RAM_ADDR_CNTR <= 5'd1);

   // ---- S6 deform 0x00: FREQ write does NOT reset position
   wr(8'hC0, 8'h00);
   repeat (1000) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   if (dut_sut.scc_wave_A.u_ctrl_ch1.o_RAM_ADDR_CNTR <= 5'd4)
      repeat (400) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   begin : s6
      reg [4:0] pos_before;
      pos_before = dut_sut.scc_wave_A.u_ctrl_ch1.o_RAM_ADDR_CNTR;
      wr(8'hA0, 8'h40);
      repeat (3) begin @(posedge clk); while (!clk_en) @(posedge clk); end
      check("S6 deform 0x00: freq write keeps position",
            (dut_sut.scc_wave_A.u_ctrl_ch1.o_RAM_ADDR_CNTR - pos_before) <= 5'd1);
   end

   $display("RESULT: %0d passed, %0d failed", n_pass, n_fail);
   $finish;
end

endmodule
