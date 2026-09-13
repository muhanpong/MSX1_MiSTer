//
//  A-Z80 wrapper: unidirectional buses, board pull-ups, and the signal names
//  this core uses.
//
//  A-Z80 reproduces the real Z80's pins.  Two of its habits are fine on a PCB
//  and wrong inside this core, and both are handled here:
//
//  1) The data pin was `inout D`.  A wrapper that drives di onto D and also
//     reads its do_ back off D gives static timing a combinational route from
//     d_to_cpu to d_from_cpu THROUGH the CPU -- gating do_ with wr_n does not
//     help, STA does no case analysis and walks both muxes.  Build ca97172:
//     -8.125 ns, sdram ch2_saved_a0 -> SCC wavetable data-in, six logic levels
//     on a clock pair whose edges coincide (clk_sdram -> clk21m), an earlier
//     build showed the same path from MoonSound.  data_pins.v is therefore
//     split into D_in / D_out (+ D_oe): D_out comes straight from its `dout`
//     flop, so no topological path from di to do_ exists at all.  No SDC
//     exception is needed and none should be added.
//
//  2) MREQ/IORQ/RD/WR tri-state while pin_control_oe is low -- during reset
//     and bus grant (control_pins_n.v).  A real board has pull-ups, so the
//     lines read inactive-high; leave them 'z' in here and the bus logic sees
//     whatever the simulator or fitter turns 'z' into.  In Verilator that was
//     LOW: tb_az80_bringup showed write strobes DURING RESET, which the old
//     bidirectional wrapper masked by accident (do_ echoed di, so the phantom
//     writes wrote back the bytes already there).  ctl_oe is pin_control_oe
//     brought out, and the four strobes are forced inactive while it is low --
//     the pull-ups, in mux form.
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

   wire [7:0] D_out;
   wire       D_oe;
   wire       ctl_oe;
   wire       mreq_n_pin, iorq_n_pin, rd_n_pin, wr_n_pin;

   //  The pull-ups (habit 2 above).  m1_n/rfsh_n/halt_n/busak_n are plain
   //  outputs in control_pins_n and never float.
   assign mreq_n = ctl_oe ? mreq_n_pin : 1'b1;
   assign iorq_n = ctl_oe ? iorq_n_pin : 1'b1;
   assign rd_n   = ctl_oe ? rd_n_pin   : 1'b1;
   assign wr_n   = ctl_oe ? wr_n_pin   : 1'b1;

   //  do_ (habit 1 above).  D_out is data_pins' `dout` flop, but that flop is
   //  ONE register shared by both directions (`ctl_bus_db_we | bus_db_pin_re`
   //  loads it), so a read reloads the very register the write data lives in.
   //  D_oe marks the window where dout is the core's own output; hold the last
   //  value seen inside that window and present it the rest of the time.  Both
   //  mux inputs are registers, so the di -> do_ route stays broken.
   reg [7:0] do_hold;
   always @(posedge clk) if (D_oe) do_hold <= D_out;
   assign do_ = D_oe ? D_out : do_hold;

   z80_top_direct_n cpu
   (
      .nM1     (m1_n),
      .nMREQ   (mreq_n_pin),
      .nIORQ   (iorq_n_pin),
      .nRD     (rd_n_pin),
      .nWR     (wr_n_pin),
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
      .D_in    (di),
      .D_out   (D_out),
      .D_oe    (D_oe),
      .ctl_oe  (ctl_oe)
   );

endmodule
