// Shared simulation models for the sdram testbenches.

`timescale 1ns/1ps

// Altera DDR output primitive used for SDRAM_CLK; not needed functionally.
module altddio_out #(
    parameter extend_oe_disable = "OFF", parameter intended_device_family = "",
    parameter invert_output = "OFF",     parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out",  parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",     parameter width = 1
)(
    input datain_h, input datain_l, input outclock, output dataout,
    input aclr, input aset, input oe, input outclocken, input sclr, input sset
);
    assign dataout = outclock;
endmodule

// Behavioural SDRAM: ACTIVE latches the row, READ/WRITE use the column,
// CAS latency 2, burst length 1 -- matching the controller's mode word.
module sdram_model (
    input               clk,
    output wire [15:0]  DQ,
    input       [15:0]  DQ_in,
    input        [12:0] A,
    input         [1:0] BA,
    input nCS, input nWE, input nRAS, input nCAS, input DQML, input DQMH
);
    reg [15:0] mem [0:65535];
    reg [12:0] row [0:3];
    reg [15:0] dq_p0, dq_p1;
    reg  [1:0] oe_p;
    integer    i;

    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = i[15:0] ^ 16'hA5C3;
        oe_p = 2'b00;
    end

    assign DQ = oe_p[1] ? dq_p1 : 16'h0000;

    wire [2:0] cmd = {nRAS, nCAS, nWE};
    localparam [2:0] C_ACTIVE = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100;
    wire [15:0] idx = {BA, row[BA][4:0], A[8:0]};

    always @(posedge clk) begin
        oe_p  <= {oe_p[0], 1'b0};
        dq_p1 <= dq_p0;
        if (!nCS) begin
            case (cmd)
                C_ACTIVE: row[BA] <= A;
                C_READ  : begin dq_p0 <= mem[idx]; oe_p <= {oe_p[0], 1'b1}; end
                C_WRITE : begin
                    if (!DQML) mem[idx][7:0]  <= DQ_in[7:0];
                    if (!DQMH) mem[idx][15:8] <= DQ_in[15:8];
                end
                default : ;
            endcase
        end
    end
endmodule

