// Sim-only stub of the gtaylormb opl3 core for tb_opl4_detect.
// Timers/status behavior is verified separately in tb_timers_detect; here the
// core only needs to exist so ymf278b_top elaborates.  Includes the REAL
// timers module driven by the same 3-stage write protocol decode as host_if,
// so the FM status path is still exercised end-to-end.
`timescale 1ns / 1ps

module opl3
    import opl3_pkg::*;
(
    input wire clk,
    input wire clk_host,
    input wire clk_dac,
    input wire ic_n,
    input wire cs_n,
    input wire rd_n,
    input wire wr_n,
    input wire [1:0] address,
    input wire [REG_FILE_DATA_WIDTH-1:0] din,
    output logic [REG_FILE_DATA_WIDTH-1:0] dout,
    output logic sample_valid,
    output logic signed [DAC_OUTPUT_WIDTH-1:0] sample_l,
    output logic signed [DAC_OUTPUT_WIDTH-1:0] sample_r,
    output logic [NUM_LEDS-1:0] led,
    output logic irq_n,
    output logic [REG_FILE_DATA_WIDTH-1:0] status_o
);
    // Reconstruct register writes from the host 3-stage protocol (clk_host
    // domain — skip the afifo; timers behave identically).
    logic wr_prev = 0;
    logic bank = 0;
    logic [7:0] regnum = 0;
    opl3_reg_wr_t opl3_reg_wr = '0;
    logic [REG_FILE_DATA_WIDTH-1:0] status;

    wire wr_strobe = !cs_n && !wr_n;
    always_ff @(posedge clk_host) begin
        opl3_reg_wr.valid <= 0;
        wr_prev <= wr_strobe;
        if (wr_strobe && !wr_prev) begin
            if (!address[0]) begin
                bank   <= address[1];
                regnum <= din;
            end else begin
                opl3_reg_wr.bank_num <= bank;
                opl3_reg_wr.address  <= regnum;
                opl3_reg_wr.data     <= din;
                opl3_reg_wr.valid    <= 1;
            end
        end
    end

    timers timers (
        .clk                 (clk_host),
        .reset               (~ic_n),
        .opl3_reg_wr         (opl3_reg_wr),
        .irq_n               (irq_n),
        .status              (status),
        .force_timer_overflow(1'b0)
    );

    assign status_o     = status;
    assign dout         = address == 0 ? status : '1;
    assign sample_valid = 0;
    assign sample_l     = '0;
    assign sample_r     = '0;
    assign led          = '0;
endmodule
