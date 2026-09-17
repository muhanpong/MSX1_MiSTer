//  nz_bus -- NextZ80 on the MSX bus: half-rate enable, Z80-level strobes.
//
//  NextZ80 does one bus access per clock: ADDR/MREQ/IORQ/WR are combinational
//  out of the current stage and DI is sampled on the same edge that starts the
//  next one.  The fabric expects a Z80: a registered BRAM read (1 clk21m), edge-
//  detected SDRAM requests and I/O one-shots (`req`), strobes that FALL between
//  M-cycles, and WAIT sampled somewhere it can still hold the cycle.  So:
//
//    clock 0  (after an enabled edge)  new stage; strobes MASKED (bus idle)
//    clock 1                            strobes visible; BRAM registers the address
//    edge 2   if wait_n: enabled edge -- NextZ80 samples DI / commits the write,
//             next stage.  If not: stalled, strobes stay visible (Tw).
//
//  One clk21m of strobe per stage minimum, exactly one idle clock between any
//  two stages, WAIT extends the strobe.  Two consecutive writes (PUSH) or reads
//  to different addresses therefore never merge into one long cycle.
//
//  Z80 levels: NextZ80 has no RD and no refresh.  rd = (MREQ | IORQ) & ~WR,
//  except the interrupt acknowledge (IORQ & M1), which a Z80 does with RD high
//  so the read mux returns FFh (the MSX IM 2 vector / RST 38h byte).
module nz_bus
(
   input  logic clk,
   input  logic reset,
   input  logic en,        // NextZ80 owns the bus
   input  logic hold,      // hand-over freeze (cpuswap_ctl nz_hold)
   input  logic pause,
   input  logic load,      // state load: restart the stage phase
   input  logic wait_n,    // fabric WAIT (guard, pacers, MoonSound)
   input  logic n_mreq, n_iorq, n_wr, n_m1,
   output logic nz_wait,   // -> NextZ80 WAIT
   output logic vis,       // strobes visible this clock
   output logic mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n
);

logic ph = 1'b0;                       // 0 = masked clock, 1 = strobes visible
wire  run = en & ~hold & ~pause;
wire  adv = run & ph & wait_n;
assign nz_wait = ~adv;

always_ff @(posedge clk) begin
   if (reset | load | adv) ph <= 1'b0;
   else if (run)           ph <= 1'b1;
end

assign vis    = ph;
wire   cyc    = vis & (n_mreq | n_iorq);
assign mreq_n = ~(vis & n_mreq);
assign iorq_n = ~(vis & n_iorq);
assign wr_n   = ~(cyc & n_wr);
assign rd_n   = ~(vis & ~n_wr & (n_mreq | (n_iorq & ~n_m1)));
assign m1_n   = ~(cyc & n_m1);
assign rfsh_n = 1'b1;

endmodule
