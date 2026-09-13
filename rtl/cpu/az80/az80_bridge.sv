//
//  A-Z80 bus bridge: the CPU's real-clock bus, retimed onto clk21m.
//
//  WHY THIS IS NOT OPTIONAL
//
//  A-Z80 runs on az80_clk, a clk_sdram divide, while the memory, the guard and
//  every peripheral stay on clk21m.  At the top speed a T-state is 46.6 ns and
//  a clk21m period is 46.57 ns, so a strobe asserted for one T-state can fall
//  ENTIRELY BETWEEN two clk21m edges and be seen by nothing.  Measured in
//  rtl/cpu/az80/sim/tb_az80_domain.sv, writes observed per write strobe:
//
//      3.58MHz  min 3      5.37MHz  min 2      7.16MHz  min 1
//      10.7MHz  min 1      21.5MHz  a whole write vanished
//
//  The two that "passed" with min 1 passed by luck -- exactly one clk21m edge
//  happened to land inside -- and a phase shift would take them too.  Nor can
//  the turbo guard fix it: the guard only engages once it SEES a strobe on
//  clk21m, so an invisible strobe never arms it.
//
//  WHAT IT DOES
//
//  Sample the CPU on clk_sdram, where az80_clk is a divide of the sampling
//  clock and therefore nothing can be missed.  Turn each bus cycle into a
//  request that is held across at least one whole clk21m period, present it to
//  the fabric aligned to clk21m, and hold the CPU with WAIT_n until the fabric
//  has answered.  The CPU sees a slower memory; the fabric sees the strobes it
//  has always seen.
//
//  Everything here is synchronous -- clk21m and az80_clk both come from
//  clk_sdram through integer dividers off one PLL -- so this is retiming, not
//  a clock-domain crossing, and needs no synchronisers.
//
module az80_bridge
(
   input         clk_sdram,
   input         clk21m,
   input         reset,

   //  From the CPU (az80_clk domain, sampled here on clk_sdram)
   input         cpu_mreq_n,
   input         cpu_iorq_n,
   input         cpu_rd_n,
   input         cpu_wr_n,
   input         cpu_m1_n,
   input         cpu_rfsh_n,
   input  [15:0] cpu_a,
   input   [7:0] cpu_do,
   output        cpu_wait_n,      // to A-Z80's nWAIT
   output  [7:0] cpu_di,          // to A-Z80's data in

   //  To the clk21m fabric -- same names and polarity the core already uses
   output logic        mreq_n,
   output logic        iorq_n,
   output logic        rd_n,
   output logic        wr_n,
   output logic        m1_n,
   output logic        rfsh_n,
   output logic [15:0] a,
   output logic  [7:0] d_from_cpu,
   input         [7:0] d_to_cpu,
   input               fabric_wait_n   // wait_m1_n & bus_guard_n & the pacers
);

   //  clk21m seen from clk_sdram.  clk21m is clk_sdram/4 off the same PLL, so a
   //  rising edge of it is a known position in the clk_sdram count rather than
   //  something to be detected asynchronously.
   logic clk21m_q = 1'b0;
   wire  clk21m_rise = ~clk21m_q & clk21m;
   always @(posedge clk_sdram) clk21m_q <= clk21m;

   wire cpu_cycle = ~cpu_mreq_n | ~cpu_iorq_n;

   //  MIRROR the CPU's strobes rather than snapshotting them, with a minimum
   //  hold.  A snapshot needs a definite end, and there is not always one to
   //  find: inside M1 the CPU goes straight from the opcode fetch's MREQ to the
   //  refresh's MREQ with no gap at this granularity, so "wait for cpu_cycle to
   //  fall" locks up on the first instruction.  Following the CPU and only
   //  STRETCHING it keeps the CPU's own sequencing intact.
   logic [1:0] hold = 2'd0;      // whole clk21m periods this cycle has been up
   logic       di_valid = 1'b0;
   logic [7:0] di_lat = 8'hFF;
   logic [5:0] cpu_ctl_q = 6'b111111;

   wire [5:0] cpu_ctl = {cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n, cpu_rfsh_n};
   //  A new cycle is a change in the TRANSFER-defining strobes only.  m1_n and
   //  rfsh_n move inside a cycle without changing what the transfer is, and
   //  letting them restart the hold chops a single write into two short windows
   //  -- which is exactly the thing the fabric's guard measures and the thing
   //  this bridge exists to stop.
   wire       new_cycle = cpu_cycle & (cpu_ctl[5:2] != cpu_ctl_q[5:2]);

   always @(posedge clk_sdram) begin
      if (reset) begin
         hold <= 2'd0; di_valid <= 1'b0; di_lat <= 8'hFF; cpu_ctl_q <= 6'b111111;
         {mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n} <= 6'b111111;
         a <= 16'd0; d_from_cpu <= 8'd0;
      end else begin
         cpu_ctl_q <= cpu_ctl;
         a          <= cpu_a;
         d_from_cpu <= cpu_do;

         if (new_cycle) begin
            //  A different strobe pattern with a cycle active: present it and
            //  restart the hold.
            {mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n} <= cpu_ctl;
            hold     <= 2'd0;
            di_valid <= 1'b0;
         end else if (cpu_cycle) begin
            if (clk21m_rise && hold != 2'd3) hold <= hold + 2'd1;
            //  Two whole clk21m periods: one to put the address in front of a
            //  registered-q memory, one to take its answer.
            if (clk21m_rise && hold >= 2'd2 && fabric_wait_n) begin
               di_valid <= 1'b1;
               di_lat   <= d_to_cpu;
            end
         end else begin
            //  CPU has finished: drop the fabric strobes with it.
            {mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n} <= 6'b111111;
            hold     <= 2'd0;
            di_valid <= 1'b0;
         end
      end
   end

   //  Hold the CPU while its cycle has not been answered.
   assign cpu_wait_n = cpu_cycle ? di_valid : fabric_wait_n;
   assign cpu_di     = di_valid ? di_lat : d_to_cpu;

endmodule
