//  OPLL (YM2413) -- ONE IKAOPLL for the whole machine.
//
//  Until 2026-09-28 this wrapper held three IKAOPLL instances (built-in
//  MSX-MUSIC, slot A FM-PAC, slot B FM-PAC), 555 ALM + 3 M10K each, and summed
//  the outputs of the ones whose device was present.  The user decided on one
//  OPLL per machine:
//
//    * The OPLL is an I/O device at 7Ch/7Dh.  Every chip in the machine sits on
//      the same two ports, so software cannot tell them apart through I/O; when a
//      built-in one and an FM-PAC with its I/O enable (7FF6h bit 0) set were both
//      present, they received identical writes and played the same notes twice.
//    * The only path that could address a second chip separately is the FM-PAC's
//      memory-mapped 7FF4h/7FF5h.  Software that drives two chips that way at
//      once (18-channel setups) is what this gives up -- decided, not overlooked.
//
//  What stays per slot: the FM-PAC's ROM, 7FF6h register and PAC SRAM live in
//  fm_pac.sv, not here.  The OPLL has no readable registers, so no read path
//  changes.
//
//  Write gating -- the part that is easy to get wrong.  wr[2] is the raw 7C/7D
//  I/O write, wr[1:0] are the FM-PAC paths (I/O when that cart's enable is set,
//  or its 7FF4/7FF5).  In the three-instance design each wr[n] only reached a
//  chip whose i_CS_n was low, i.e. whose device existed (cs[n]).  Merged, the
//  gate has to stay per source: |(wr & cs), NOT |wr, or a machine with no OPLL
//  at all would play from a stray OUT (7C).  Bench: sim/opll_single/ -- the
//  mutant that drops the gate must fail.
//
//  Address: both paths present the CPU's A0 (7FF4/7C = address, 7FF5/7D = data)
//  and one bus cycle is either I/O or memory, never both, so ORing the strobes
//  cannot merge two different writes in one clock.
module opll
(
   input clk,
   input cen,
   input rst,
   input [7:0] din,
   input addr,
   input [2:0] wr,    // [2] built-in (7C/7D), [1] slot B FM-PAC, [0] slot A FM-PAC
   input [2:0] cs,    // same order: the device exists in this configuration
   output signed [15:0] sound
);

/*verilator tracing_off*/

wire cs_any = |cs;
wire wr_any = |(wr & cs);

wire signed [15:0] sound_OPL;
assign sound = cs_any ? sound_OPL : 16'd0;

IKAOPLL #(
    .FULLY_SYNCHRONOUS          (1                          ),
    .FAST_RESET                 (1                          ),
    .ALTPATCH_CONFIG_MODE       (0                          ),
    .USE_PIPELINED_MULTIPLIER   (1                          )
) ika_opll (
    .i_XIN_EMUCLK               (clk                        ),
    .o_XOUT                     (                           ),

    .i_phiM_PCEN_n              (~cen                       ),

    .i_IC_n                     (~rst                       ),

    .i_ALTPATCH_EN              (1'b0                       ),

    .i_CS_n                     (~cs_any                    ),
    .i_WR_n                     (~wr_any                    ),
    .i_A0                       (addr                       ),

    .i_D                        (din                        ),
    .o_D                        (                           ),
    .o_D_OE                     (                           ),

    .o_DAC_EN_MO                (                           ),
    .o_DAC_EN_RO                (                           ),
    .o_IMP_NOFLUC_SIGN          (                           ),
    .o_IMP_NOFLUC_MAG           (                           ),
    .o_IMP_FLUC_SIGNED_MO       (                           ),
    .o_IMP_FLUC_SIGNED_RO       (                           ),
    .i_ACC_SIGNED_MOVOL         (5'sd9                      ),
    .i_ACC_SIGNED_ROVOL         (5'sd15                     ),
    .o_ACC_SIGNED_STRB          (                           ),
    .o_ACC_SIGNED               (sound_OPL                  )
);

endmodule
