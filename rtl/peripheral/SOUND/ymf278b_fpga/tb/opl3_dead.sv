// Silent OPL3 stub that DOES pulse sample_valid at the native OPL3 rate
// (clk/288 ≈ 49.7kHz) so ymf278b_top's audio output path (PCM 44.1k → 49.7k
// zero-order-hold resample at sample_valid) is actually exercised.
`timescale 1ns / 1ps
module opl3 import opl3_pkg::*;
( input wire clk, clk_host, clk_dac, ic_n, cs_n, rd_n, wr_n,
  input wire [1:0] address, input wire [REG_FILE_DATA_WIDTH-1:0] din,
  output logic [REG_FILE_DATA_WIDTH-1:0] dout, output logic sample_valid,
  output logic signed [DAC_OUTPUT_WIDTH-1:0] sample_l, sample_r,
  output logic [NUM_LEDS-1:0] led, output logic irq_n,
  output logic [REG_FILE_DATA_WIDTH-1:0] status_o );
  assign dout='0; assign sample_l='0; assign sample_r='0; assign led='0; assign irq_n=1'b1; assign status_o='0;
  logic [8:0] cnt=0;
  always_ff @(posedge clk) begin
    sample_valid <= 1'b0;
    if (cnt==9'd287) begin cnt<=0; sample_valid<=1'b1; end else cnt<=cnt+1'b1;
  end
endmodule
