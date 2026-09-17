//  Lockstep bench for cpuswap_ctl: T80s (GHDL-synthesised from rtl/cpu) and the
//  patched NextZ80 drive ONE Z80-level bus through the same mux msx.sv will use;
//  NextZ80 goes through nz_bus.  The fabric side is modelled the way msx.sv sees
//  it: a registered memory read (one clock), writes / OUTs / the IN 99h acknowledge
//  taken on the edge-detected `req` one-shot (a strobe that never falls between two
//  cycles merges them), one `iowr_stb` per I/O write, and a WAIT source (I/O reads
//  of 12h / 60h-63h and writes to 56h take three extra clocks).  The program writes
//  its results to RAM and reports through OUT; the log of data writes and OUTs must
//  be identical whichever core runs it and however often the bus is handed over.
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
//    +nowait=1       WAIT source off
//    +sdlat=<n>      SDRAM-like memory: a read's data is valid n clocks after its `req` edge
//                    (junk before).  0 = BRAM (registered read only).  WAIT holds the read until
//                    the data is home when the pacer applies: NextZ80, +turbo=1, or the resume
//                    guard right after a hand-over (msx.sv resume_guard)
//    +turbo=1        pace every T80s read too (cpu_turbo); 0 = stock, T80s relies on its own latency
//    +norg=1         mutation: no resume guard
//    +maxclk=<n>     timeout
module tb (input logic clk);

logic [7:0] mem [0:65535];
string prog;
int mode, seed, swapmin, swapmax, t80div, intper, eipc, corrupt, nowait, sdlat, turbo, norg, maxclk;
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
   if (!$value$plusargs("nowait=%d", nowait)) nowait = 0;
   if (!$value$plusargs("sdlat=%d", sdlat)) sdlat = 0;
   if (!$value$plusargs("turbo=%d", turbo)) turbo = 0;
   if (!$value$plusargs("norg=%d", norg)) norg = 0;
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

//  ---------------------------------------------------------------- fabric side
logic       wait_n;                      // WAIT to whichever core owns the bus
logic [7:0] d_to_cpu;
logic       tr_pause;

//  ---------------------------------------------------------------- T80s
logic t_m1_n, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_rfsh_n, t_halt_n, t_busak_n;
logic [15:0] t_a;
logic [7:0] t_do;
logic [211:0] t_reg, t_dir;
logic t_swappt;

T80s T80 (
   .RESET_n(~reset), .CLK(clk), .CEN(ce_t80 & ~t80_hold & ~tr_pause), .WAIT_n(wait_n),
   .INT_n(~int_req), .NMI_n(1'b1), .BUSRQ_n(1'b1), .OUT0(1'b0),
   .M1_n(t_m1_n), .MREQ_n(t_mreq_n), .IORQ_n(t_iorq_n), .RD_n(t_rd_n), .WR_n(t_wr_n),
   .RFSH_n(t_rfsh_n), .HALT_n(t_halt_n), .BUSAK_n(t_busak_n),
   .A(t_a), .DI(d_to_cpu), .DO(t_do),
   .REG(t_reg), .DIRSet(t80_dirset), .DIR(t_dir), .SWAPPT(t_swappt)
);

//  ---------------------------------------------------------------- NextZ80 + nz_bus
logic n_wr, n_mreq, n_iorq, n_halt, n_m1;
logic [15:0] n_a;
logic [7:0] n_do;
logic [211:0] n_xreg, n_ldir;
logic n_swappt, n_wait, n_vis;
logic n_mreq_n, n_iorq_n, n_rd_n, n_wr_n, n_m1_n, n_rfsh_n;

NextZ80 NZ (
   .DI(d_to_cpu), .DO(n_do), .ADDR(n_a), .WR(n_wr), .MREQ(n_mreq), .IORQ(n_iorq), .HALT(n_halt), .M1(n_m1),
   .CLK(clk), .RESET(1'b0), .INT(int_req), .NMI(1'b0), .WAIT(n_wait),   // LOAD is the only entry (msx.sv)
   .LOAD(nz_load), .LDIR(n_ldir), .XREG(n_xreg), .SWAPPT(n_swappt)
);

nz_bus NZB (
   .clk(clk), .reset(reset), .en(use_nz), .hold(nz_hold | reset), .pause(tr_pause), .load(nz_load), .wait_n(wait_n),
   .n_mreq(n_mreq), .n_iorq(n_iorq), .n_wr(n_wr), .n_m1(n_m1),
   .nz_wait(n_wait), .vis(n_vis),
   .mreq_n(n_mreq_n), .iorq_n(n_iorq_n), .rd_n(n_rd_n), .wr_n(n_wr_n), .m1_n(n_m1_n), .rfsh_n(n_rfsh_n)
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

//  ---------------------------------------------------------------- the bus (msx.sv mux)
//  The owner's strobes, forced idle while the controller is busy so that `req`
//  re-arms and a registered read is re-issued by the core that resumes.
wire        idle       = busy;
wire [15:0] a          = use_nz ? n_a  : t_a;
wire  [7:0] d_from_cpu = use_nz ? n_do : t_do;
wire        mreq_n     = idle | (use_nz ? n_mreq_n : t_mreq_n);
wire        iorq_n     = idle | (use_nz ? n_iorq_n : t_iorq_n);
wire        rd_n       = idle | (use_nz ? n_rd_n   : t_rd_n);
wire        wr_n       = idle | (use_nz ? n_wr_n   : t_wr_n);
wire        m1_n       = idle | (use_nz ? n_m1_n   : t_m1_n);
wire        rfsh_n     = idle | (use_nz ? n_rfsh_n : t_rfsh_n);

//  msx.sv one-shot: one `req` per bus cycle, re-armed when both strobes are up.
logic iack_q = 1'b0;
wire  req = ~((iorq_n & mreq_n) | (wr_n & rd_n) | iack_q);
always_ff @(posedge clk) begin
   if (reset)                 iack_q <= 1'b0;
   else if (iorq_n & mreq_n)  iack_q <= 1'b0;
   else if (req)              iack_q <= 1'b1;
end
logic tr_iow_q = 1'b0;
always_ff @(posedge clk) tr_iow_q <= ~iorq_n & ~wr_n & m1_n;
wire  iowr_stb = ~iorq_n & ~wr_n & m1_n & ~tr_iow_q;

//  WAIT source: some I/O cycles take three extra clocks (like a slow device).
wire  slow_cyc = ~iorq_n & m1_n & ((~rd_n & (a[7:0] == 8'h12 || a[7:2] == 6'b011000)) | (~wr_n & a[7:0] == 8'h56));
logic [2:0] wcnt = 3'd0;
always_ff @(posedge clk) wcnt <= slow_cyc ? (wcnt == 3'd7 ? wcnt : wcnt + 3'd1) : 3'd0;
wire  io_wait_n = nowait ? 1'b1 : ~(slow_cyc & (wcnt < 3'd3));

//  SDRAM-like read latency and its pacer (msx.sv: hs_win / nz_rd_pace_n / resume_guard).
//  The request is the `req` edge of a memory read; the data is home sdlat clocks later.
wire  mem_rd = ~mreq_n & ~rd_n;
logic [3:0] sd_cnt = 4'd0;
logic       sd_home = 1'b0;
always_ff @(posedge clk) begin
   if (~mem_rd) begin
      sd_cnt  <= 4'd0;
      sd_home <= 1'b0;
   end else if (req) begin
      sd_cnt  <= sdlat[3:0];
      sd_home <= (sdlat == 0);
   end else if (sd_cnt != 4'd0) begin
      sd_cnt  <= sd_cnt - 4'd1;
      if (sd_cnt == 4'd1) sd_home <= 1'b1;
   end
end
//  resume_guard: set while the controller is busy, cleared when the first bus cycle
//  of the resumed core has ended.  A resumed T80s sits in T2 of the interrupted
//  cycle and samples DI on its next CEN, before a fresh SDRAM read can be home.
logic rg = 1'b0, rg_seen = 1'b0;
always_ff @(posedge clk) begin
   if (reset) begin
      rg <= 1'b0; rg_seen <= 1'b0;
   end else if (busy) begin
      rg <= ~norg[0]; rg_seen <= 1'b0;
   end else if (rg) begin
      if (~mreq_n | ~iorq_n) rg_seen <= 1'b1;
      else if (rg_seen)      rg      <= 1'b0;
   end
end
wire  home    = sd_home | (sdlat == 0);
wire  paced   = use_nz | turbo[0] | rg;
wire  sd_wait_n = ~(paced & mem_rd & ~home);
assign wait_n = io_wait_n & sd_wait_n;

//  ---------------------------------------------------------------- turbo R block
logic       s_sel, s_dram, tr_ov, tr_mute, tr_pled, tr_tled;
logic [7:0] s_dout, tr_dac;
logic [10:0] ps2_key = 11'd0;
int unsigned ce3_div = 0;
always_ff @(posedge clk) ce3_div <= (ce3_div == 5) ? 0 : ce3_div + 1;
wire ce_3m58 = (ce3_div == 0) & ~tr_pause;
turbor TR (
   .clk(clk), .reset(reset), .en(1'b1), .ce_3m58(ce_3m58),
   .a(a), .din(d_from_cpu), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .m1_n(m1_n),
   .iowr_stb(iowr_stb), .main_rom0(a[15:14] == 2'b00), .mem_ov(tr_ov), .io_sel(s_sel), .dout(s_dout),
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

//  ---------------------------------------------------------------- read data
function automatic [7:0] io_in(input [7:0] port);
   io_in = port ^ 8'h5A;
endfunction

//  Memory is a registered read of the bus address (BRAM); I/O and the BIOS overlay are
//  combinational, as in msx.sv.  Interrupt acknowledge: RST 38h / IM2 vector FFh.
logic [7:0] mem_q = 8'h00;
always_ff @(posedge clk) mem_q <= mem[a];
always_comb begin
   if (!iorq_n && !m1_n)  d_to_cpu = 8'hFF;
   else if (!iorq_n)      d_to_cpu = s_sel ? s_dout : (slow_cyc && wcnt < 3'd3) ? ~io_in(a[7:0]) : io_in(a[7:0]);   // slow device: junk until its WAIT ends
   else                   d_to_cpu = tr_ov ? s_dout : (home | ~mem_rd) ? mem_q : ~mem_q;   // junk until home
end

//  ---------------------------------------------------------------- side effects
logic [20:0] t_bus_q = 21'd0;
logic tr_pause_q = 1'b0;
int unsigned wait_clks = 0;

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

      //  while paused the owning core's bus must not change (T80s) / take an edge (NextZ80)
      t_bus_q <= {t_a, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_m1_n};
      tr_pause_q <= tr_pause;
      if (tr_pause && tr_pause_q && ((!use_nz && t_bus_q != {t_a, t_mreq_n, t_iorq_n, t_rd_n, t_wr_n, t_m1_n}) || (use_nz && !n_wait)))
         pause_moved <= 1'b1;
      if (!wait_n) wait_clks <= wait_clks + 1;

      //  a bus cycle has effect once, on the `req` one-shot
      if (req && !mreq_n && !wr_n) begin
         mem[a] <= d_from_cpu;
         $display("W %04x %02x", a, d_from_cpu);
      end
      if (req && !iorq_n && !wr_n && m1_n) out_port(a[7:0], d_from_cpu);
      if (req && !iorq_n && !rd_n && m1_n && a[7:0] == 8'h99) ack99();
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
      $display("END clk=%0d swaps=%0d waits=%0d", clk_n, swaps, wait_clks);
      $finish;
   end else
      $display("O %02x %02x", p, d);
endtask

endmodule
