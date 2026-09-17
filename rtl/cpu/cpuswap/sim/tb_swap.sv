//  Lockstep bench for cpuswap_ctl: T80s (GHDL-synthesised from rtl/cpu) and the
//  patched NextZ80 share one 64K memory and one I/O space.  The program writes its
//  results to RAM and reports through OUT; the log of data writes and OUTs must be
//  identical whichever core runs it and however often the bus is handed over.
//
//  plusargs
//    +prog=<hex>     $readmemh image (64K)
//    +mode=0|1|2|3   0 = T80s only, 1 = NextZ80 (swap once at the first point), 2 = random swaps,
//                    3 = software: the program selects the CPU through S1990 register 6 (E4h/E5h)
//    +seed=<n>       LFSR seed for mode 2
//    +swapmin/+swapmax  clocks between swap requests in mode 2
//    +t80div=<n>     T80s CEN every n clocks (1 = every clock)
//    +intper=<n>     raise INT every n clocks (0 = never); IN (99h) clears it, like the VDP
//    +eipc=<hex>     directed EI-delay check: raise INT on a transfer whose PC is this address
//                    (the instruction after the program's EI); the program records an interrupt
//                    taken before that instruction ran
//    +corrupt=<n>    negative control: flip L bit 0 in the n-th transfer (0 = off)
//    +maxclk=<n>     timeout
module tb (input logic clk);

logic [7:0] mem [0:65535];
string prog;
int mode, seed, swapmin, swapmax, t80div, intper, eipc, corrupt, maxclk;
initial begin
   if (!$value$plusargs("prog=%s", prog)) prog = "prog.hex";
   if (!$value$plusargs("mode=%d", mode)) mode = 0;
   if (!$value$plusargs("seed=%d", seed)) seed = 1;
   if (!$value$plusargs("swapmin=%d", swapmin)) swapmin = 20;
   if (!$value$plusargs("swapmax=%d", swapmax)) swapmax = 3000;
   if (!$value$plusargs("t80div=%d", t80div)) t80div = 1;
   if (!$value$plusargs("intper=%d", intper)) intper = 0;
   if (!$value$plusargs("eipc=%h", eipc)) eipc = -1;
   if (!$value$plusargs("corrupt=%d", corrupt)) corrupt = 0;
   if (!$value$plusargs("maxclk=%d", maxclk)) maxclk = 50000000;
   for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
   $readmemh(prog, mem);
end

//  ---------------------------------------------------------------- clocking
int unsigned clk_n = 0;
logic reset = 1'b1;
always_ff @(posedge clk) begin
   clk_n <= clk_n + 1;
   if (clk_n == 8) reset <= 1'b0;
end

int unsigned divc = 0;
wire ce_t80 = (divc == 0);
always_ff @(posedge clk) divc <= (divc + 1 >= t80div) ? 0 : divc + 1;

logic ce_nz = 1'b0;                         // half rate: the spare clock is the memory's read latency
always_ff @(posedge clk) ce_nz <= ~ce_nz;

//  ---------------------------------------------------------------- swap request
logic want_nz = 1'b0;
logic [31:0] lfsr;
int unsigned next_req = 0;
logic use_nz, t80_hold, nz_hold, t80_dirset, nz_load, busy;
logic s1990_r800;
int unsigned swaps = 0;
always_ff @(posedge clk) begin
   if (reset) begin
      lfsr <= 32'hACE1_0000 ^ seed;
      next_req <= 100;
      want_nz <= (mode == 1);
   end else if (mode == 3) begin
      want_nz <= s1990_r800;
   end else if (mode == 2) begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (clk_n >= next_req && !busy && want_nz == use_nz) begin
         want_nz <= ~want_nz;
         next_req <= clk_n + swapmin + (lfsr % (swapmax - swapmin + 1));
      end
   end
end

//  ---------------------------------------------------------------- interrupt
logic int_req = 1'b0;

//  ---------------------------------------------------------------- T80s
logic t_m1_n, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_rfsh_n, t_halt_n, t_busak_n;
logic [15:0] t_a;
logic [7:0] t_di, t_do;
logic [211:0] t_reg, t_dir;
logic t_swappt;

T80s T80 (
   .RESET_n(~reset), .CLK(clk), .CEN(ce_t80 & ~t80_hold & ~tr_pause), .WAIT_n(1'b1),
   .INT_n(~int_req), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
   .M1_n(t_m1_n), .MREQ_n(t_mreq_n), .IORQ_n(t_iorq_n), .RD_n(t_rd_n), .WR_n(t_wr_n),
   .RFSH_n(t_rfsh_n), .HALT_n(t_halt_n), .BUSAK_n(t_busak_n),
   .A(t_a), .DI(t_di), .DO(t_do),
   .REG(t_reg), .DIRSet(t80_dirset), .DIR(t_dir), .SWAPPT(t_swappt)
);

//  ---------------------------------------------------------------- NextZ80
logic n_wr, n_mreq, n_iorq, n_halt, n_m1;
logic [15:0] n_a;
logic [7:0] n_di = 8'h00, n_do;
logic [211:0] n_xreg, n_ldir;
logic n_swappt;
wire  n_wait = ~ce_nz | nz_hold | tr_pause;

NextZ80 NZ (
   .DI(n_di), .DO(n_do), .ADDR(n_a), .WR(n_wr), .MREQ(n_mreq), .IORQ(n_iorq), .HALT(n_halt), .M1(n_m1),
   .CLK(clk), .RESET(reset), .INT(int_req), .NMI(1'b0), .WAIT(n_wait),
   .LOAD(nz_load), .LDIR(n_ldir), .XREG(n_xreg), .SWAPPT(n_swappt)
);

//  ---------------------------------------------------------------- controller
cpuswap_ctl CTL (
   .clk(clk), .reset(reset), .want_nz(want_nz),
   .t80_swappt(t_swappt), .nz_swappt(n_swappt),
   .use_nz(use_nz), .t80_hold(t80_hold), .nz_hold(nz_hold),
   .t80_dirset(t80_dirset), .nz_load(nz_load), .busy(busy)
);

int unsigned xfers = 0;
wire corrupt_now = (corrupt != 0) && (xfers + 1 == corrupt);
assign t_dir  = n_xreg ^ (corrupt_now ? 212'd1 << 112 : 212'd0);
assign n_ldir = t_reg  ^ (corrupt_now ? 212'd1 << 112 : 212'd0);

//  ---------------------------------------------------------------- turbo R block
//  One Z80-level view of whichever core owns the bus.  NextZ80 strobes are active
//  high and have no RD: a read is MREQ or IORQ without WR.
wire [15:0] b_a      = use_nz ? n_a : t_a;
wire        b_mreq_n = use_nz ? ~n_mreq : t_mreq_n;
wire        b_iorq_n = use_nz ? ~n_iorq : t_iorq_n;
wire        b_rd_n   = use_nz ? ~((n_mreq | n_iorq) & ~n_wr) : t_rd_n;
wire        b_m1_n   = use_nz ? ~n_m1 : t_m1_n;
logic       s_sel, s_wr, s_dram, tr_ov, tr_mute, tr_pause, tr_pled, tr_tled;
logic [7:0] s_dout, tr_dac;
logic [10:0] ps2_key = 11'd0;
int unsigned ce3_div = 0;
always_ff @(posedge clk) ce3_div <= (ce3_div == 5) ? 0 : ce3_div + 1;
wire ce_3m58 = (ce3_div == 0) & ~tr_pause;
turbor TR (
   .clk(clk), .reset(reset), .en(1'b1), .ce_3m58(ce_3m58),
   .a(b_a), .din(use_nz ? n_do : t_do), .mreq_n(b_mreq_n), .iorq_n(b_iorq_n), .rd_n(b_rd_n), .m1_n(b_m1_n),
   .iowr_stb(s_wr), .main_rom0(b_a[15:14] == 2'b00), .mem_ov(tr_ov), .io_sel(s_sel), .dout(s_dout),
   .set_stb(1'b0), .set_r800(1'b0), .r800(s1990_r800), .dram(s_dram),
   .pcm_dac(tr_dac), .mute_all(tr_mute), .ps2_key(ps2_key),
   .hw_pause(tr_pause), .pause_led(tr_pled), .turbo_led(tr_tled)
);

//  Hardware pause: the first time the program enables it (A7h bit 1), press Pause,
//  hold for 3000 clocks checking that nothing moves on the bus, press it again.
int unsigned pause_t = 0;
logic pause_done = 1'b0, pause_moved = 1'b0;
always_ff @(posedge clk) begin
   if (!reset && TR.pau_st[1] && !pause_done) begin
      if (pause_t == 0)    ps2_key <= {~ps2_key[10], 10'h377};
      if (pause_t == 3000) begin
         ps2_key <= {~ps2_key[10], 10'h377};
         pause_done <= 1'b1;
         $display("Z pause held, bus %s", pause_moved ? "MOVED" : "still");
      end
      pause_t <= pause_t + 1;
   end
end

//  PCM D/A value and the all-sound mute, as the program drives them
logic [7:0] dac_q = 8'h80;
logic       mute_q = 1'b0;
always_ff @(posedge clk) begin
   dac_q <= tr_dac;
   mute_q <= tr_mute;
   if (!reset && dac_q != tr_dac) $display("D %02x", tr_dac);
   if (!reset && mute_q != tr_mute) $display("M %0d", tr_mute);
end

//  ---------------------------------------------------------------- bus
function automatic [7:0] io_in(input [7:0] port);
   io_in = port ^ 8'h5A;
endfunction

//  T80s: asynchronous read, a write lands on the first clock its strobes are seen.
always_comb begin
   if (!t_iorq_n && !t_m1_n)  t_di = 8'hFF;                 // interrupt acknowledge: RST 38h / IM2 vector FFh
   else if (!t_iorq_n)        t_di = (s_sel && !use_nz) ? s_dout : io_in(t_a[7:0]);
   else                       t_di = (tr_ov && !use_nz) ? s_dout : mem[t_a];
end

logic t_wr_q = 1'b1, t_iowr_q = 1'b1, t_iord_q = 1'b1;
logic [20:0] t_bus_q = 21'd0;
logic tr_pause_q = 1'b0;
assign s_wr = use_nz ? (!n_wait && n_iorq && !n_m1 && n_wr)
                     : (!t_iorq_n && !t_wr_n && t_m1_n && t_iowr_q);

always_ff @(posedge clk) begin
   if (reset) begin
      int_req <= 1'b0;
   end else begin
      if (intper != 0 && (clk_n % intper) == 0) int_req <= 1'b1;
      if (nz_load && t_reg[79:64] == eipc[15:0] || t80_dirset && n_xreg[79:64] == eipc[15:0]) begin
         int_req <= 1'b1;
         $display("E transfer at the EI-delay instruction, INT raised");
      end

      if (t80_dirset | nz_load) begin
         xfers <= xfers + 1;
         swaps <= swaps + 1;
         //  coverage: direction, PC, IFF1, IM (T80 encoding), NextZ80 bank bits
         if (nz_load) $display("X t2n pc=%04x iff1=%0d im=%0d", t_reg[79:64], t_reg[210], t_reg[209:208]);
         else         $display("X n2t pc=%04x iff1=%0d im=%0d cs=%x", n_xreg[79:64], n_xreg[210], n_xreg[209:208], NZ.CPUStatus[3:0]);
      end

      //  NextZ80: registered read, the core samples it on its next enabled edge
      if (n_iorq && n_m1)      n_di <= 8'hFF;
      else if (n_iorq)         n_di <= (s_sel && use_nz) ? s_dout : io_in(n_a[7:0]);
      else                     n_di <= (tr_ov && use_nz) ? s_dout : mem[n_a];
      //  while paused the owning core's bus must not change (T80s) / take an edge (NextZ80)
      t_bus_q <= {t_a, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_m1_n};
      tr_pause_q <= tr_pause;
      if (tr_pause && tr_pause_q && ((!use_nz && t_bus_q != {t_a, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_m1_n}) || (use_nz && !n_wait)))
         pause_moved <= 1'b1;

      if (!use_nz) begin
         t_wr_q   <= t_mreq_n | t_wr_n;
         t_iowr_q <= t_iorq_n | t_wr_n | ~t_m1_n;
         t_iord_q <= t_iorq_n | t_rd_n | ~t_m1_n;
         if (!t_mreq_n && !t_wr_n && t_wr_q) begin
            mem[t_a] <= t_do;
            $display("W %04x %02x", t_a, t_do);
         end
         if (!t_iorq_n && !t_wr_n && t_m1_n && t_iowr_q) out_port(t_a[7:0], t_do);
         if (!t_iorq_n && !t_rd_n && t_m1_n && t_iord_q && t_a[7:0] == 8'h99) ack99();
      end else begin
         t_wr_q <= 1'b1; t_iowr_q <= 1'b1; t_iord_q <= 1'b1;
         if (!n_wait && n_mreq && n_wr) begin
            mem[n_a] <= n_do;
            $display("W %04x %02x", n_a, n_do);
         end
         if (!n_wait && n_iorq && !n_m1 && n_wr) out_port(n_a[7:0], n_do);
         if (!n_wait && n_iorq && !n_m1 && !n_wr && n_a[7:0] == 8'h99) ack99();
      end
      if (clk_n >= maxclk) begin
         $display("TIMEOUT clk=%0d swaps=%0d pc_t80=%04x", clk_n, swaps, t_reg[79:64]);
         $finish;
      end
   end
end

//  IN (99h) is only executed by the ISRs, and INT only drops on it: an ISR that
//  finds INT already low was entered without a pending interrupt (a phantom).
task automatic ack99();
   if (!int_req) $display("P phantom interrupt clk=%0d", clk_n);
   int_req <= 1'b0;
endtask

task automatic out_port(input [7:0] p, input [7:0] d);
   if (p == 8'hFF) begin
      $display("END clk=%0d swaps=%0d", clk_n, swaps);
      $finish;
   end else
      $display("O %02x %02x", p, d);
endtask

endmodule
