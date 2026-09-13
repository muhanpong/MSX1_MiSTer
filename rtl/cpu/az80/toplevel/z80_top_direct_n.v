//============================================================================
// Z80 Top level using the direct module declaration
//============================================================================
`timescale 1us/ 100 ns

module z80_top_direct_n(
    output wire nM1,
    output wire nMREQ,
    output wire nIORQ,
    output wire nRD,
    output wire nWR,
    output wire nRFSH,
    output wire nHALT,
    output wire nBUSACK,

    input wire nWAIT,
    input wire nINT,
    input wire nNMI,
    input wire nRESET,
    input wire nBUSRQ,

    input wire CLK,
    output wire [15:0] A,
    // MSX1 core change -- see data_pins.v.  D_in/D_out replace the bidirectional
    // D pin; D_oe is bus_db_pin_oe (D_out is the core's own drive exactly while
    // it is high).  ctl_oe is pin_control_oe: LOW while the real chip would
    // tri-state MREQ/IORQ/RD/WR (reset, bus grant), so the wrapper can stand in
    // for the pull-up resistors a real board has on those lines.
    input wire [7:0] D_in,
    output wire [7:0] D_out,
    output wire D_oe,
    output wire ctl_oe
);

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Include core A-Z80 level connecting all internal modules
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
`include "core.vh"

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Address, Data and Control bus drivers connecting to external pins
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
address_pins address_pins_(
    .clk            (clk),
    .bus_ab_pin_we  (bus_ab_pin_we),
    .pin_control_oe (pin_control_oe),
    .address        (address),
    .abus           (A)
);

data_pins data_pins_(
    .bus_db_pin_oe  (bus_db_pin_oe),
    .bus_db_pin_re  (bus_db_pin_re),
    .ctl_bus_db_we  (ctl_bus_db_we),
    .ctl_bus_db_oe  (ctl_bus_db_oe),
    .clk            (clk),
    .db             (db0),
    .D_in           (D_in),
    .D_out          (D_out),
    .D_oe           (D_oe)
);

assign ctl_oe = pin_control_oe;

control_pins_n control_pins_(
    .busack        (busack),
    .CPUCLK        (CLK),
    .pin_control_oe(pin_control_oe),
    .in_halt       (in_halt),
    .pin_nWAIT     (nWAIT),
    .pin_nBUSRQ    (nBUSRQ),
    .pin_nINT      (nINT),
    .pin_nNMI      (nNMI),
    .pin_nRESET    (nRESET),
    .nM1_out       (nM1_out),
    .nRFSH_out     (nRFSH_out),
    .nRD_out       (nRD_out),
    .nWR_out       (nWR_out),
    .nIORQ_out     (nIORQ_out),
    .nMREQ_out     (nMREQ_out),
    .nmi           (nmi),
    .busrq         (busrq),
    .clk           (clk),
    .intr          (intr),
    .mwait         (mwait),
    .reset_in      (reset_in),
    .pin_nM1       (nM1),
    .pin_nMREQ     (nMREQ),
    .pin_nIORQ     (nIORQ),
    .pin_nRD       (nRD),
    .pin_nWR       (nWR),
    .pin_nRFSH     (nRFSH),
    .pin_nHALT     (nHALT),
    .pin_nBUSACK   (nBUSACK)
 );

endmodule
