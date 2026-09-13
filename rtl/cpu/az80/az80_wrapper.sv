//
//  A-Z80 wrapper: unidirectional data bus, and the signal names this core uses.
//
//  A-Z80 reproduces the real Z80's pins, so its data bus is `inout [7:0] D`
//  driven by `bus_db_pin_oe` (data_pins.v:74).  Inside an FPGA that is a mux,
//  and Quartus resolves it, but the rest of this core speaks d_to_cpu/d_from_cpu
//  -- two unidirectional buses -- so the tri-state is terminated here rather
//  than being allowed to spread.  Everything else is a rename: A-Z80's control
//  pins are already active low with the same meanings as T80pa's.
//
//  Not provided, and deliberately not faked:
//    REG(211:0)/DIRSet/DIR.  T80 exposes its whole register file as one vector;
//    A-Z80 keeps each register in its own reg_latch instance hanging off an
//    internal tri-state bus (registers/reg_latch.v), so there is no bundle to
//    forward.  msx.sv's twenty t80_reg readers are all in dbg_* forensics --
//    checked one by one, including `booted` and `im2_tbl_hi`, which look
//    functional and are not -- so they tie off rather than break the machine.
//
module az80_wrapper
(
   input        clk,          // real Z80 clock, from az80_clkgen
   input        reset,        // active high
   input        wait_n,
   input        int_n,
   input        nmi_n,
   input        busrq_n,

   output       m1_n,
   output       mreq_n,
   output       iorq_n,
   output       rd_n,
   output       wr_n,
   output       rfsh_n,
   output       halt_n,
   output       busak_n,

   output [15:0] a,
   input   [7:0] di,
   output  [7:0] do_
);

   wire [7:0] D;

   //  Terminate the bidirectional pin here.  bus_db_pin_oe is internal, so the
   //  direction comes from the strobes, and it has to be the READ condition
   //  rather than ~wr_n: on an internal cycle wr_n is high too, and driving di
   //  then would fight the CPU.  Two cases fetch a byte --
   //    ~rd_n                  memory and I/O reads, and the M1 opcode fetch
   //    ~iorq_n & ~m1_n        interrupt acknowledge, where the device puts the
   //                           vector on the bus with RD_n staying HIGH
   //  -- and outside them nothing samples do_, so leaving D undriven is fine.
   wire fetching = ~rd_n | (~iorq_n & ~m1_n);
   assign D   = fetching ? di : 8'bz;

   //  do_ must NOT be a plain read of D.  While we are driving di onto D for a
   //  fetch, `assign do_ = D` makes do_ equal di, and the core's d_to_cpu and
   //  d_from_cpu become one combinational net THROUGH the CPU -- a path with no
   //  register in it from a clk_sdram source to a clk21m destination.  It showed
   //  up as -8.3 ns from MoonSound's ms_io_dout_lat to the SCC wavetable RAM,
   //  two blocks with no business being connected, on a clock pair whose edges
   //  nearly coincide so the requirement is ~0 ns.  Gating on wr_n leaves do_
   //  meaningful exactly when the CPU is the one driving.
   assign do_ = wr_n ? 8'h00 : D;

   z80_top_direct_n cpu
   (
      .nM1     (m1_n),
      .nMREQ   (mreq_n),
      .nIORQ   (iorq_n),
      .nRD     (rd_n),
      .nWR     (wr_n),
      .nRFSH   (rfsh_n),
      .nHALT   (halt_n),
      .nBUSACK (busak_n),
      .nWAIT   (wait_n),
      .nINT    (int_n),
      .nNMI    (nmi_n),
      .nRESET  (~reset),
      .nBUSRQ  (busrq_n),
      .CLK     (clk),
      .A       (a),
      .D       (D)
   );

endmodule
