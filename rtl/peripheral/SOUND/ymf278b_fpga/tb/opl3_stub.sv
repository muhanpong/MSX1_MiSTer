// Stub of gtaylormb's opl3 module — used to allow compile-only verification
// of ymf278b_top.sv's PCM-side wiring without pulling in the full opl3 dep chain.
// Tie outputs to zero; ignore writes.
`timescale 1ns/1ps
`default_nettype none

module opl3 (
    input  wire        clk,
    input  wire        clk_host,
    input  wire        clk_dac,
    input  wire        ic_n,
    input  wire        cs_n,
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire [1:0]  address,
    input  wire [7:0]  din,
    output logic [7:0] dout,
    output logic       sample_valid,
    output logic signed [23:0] sample_l,
    output logic signed [23:0] sample_r,
    output logic [3:0] led,
    output logic       irq_n
);
    assign dout         = '0;
    assign sample_valid = 1'b0;
    assign sample_l     = '0;
    assign sample_r     = '0;
    assign led          = '0;
    assign irq_n        = 1'b1;
endmodule

`default_nettype wire
