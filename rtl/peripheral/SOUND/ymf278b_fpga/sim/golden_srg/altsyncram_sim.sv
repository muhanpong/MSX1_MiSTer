// Behavioural altsyncram -- ONLY the configuration YMF278B.sv (srg320, commit
// 28ddb1b) instantiates in OPL4_CH_RAM / OPL4_REG_RAM:
//
//   operation_mode      = DUAL_PORT  (port A write-only, port B read-only)
//   clock0 only; all clock enables BYPASS; no aclr
//   address_reg_b       = CLOCK0     -> read address registered on clock0
//   outdata_reg_b       = UNREGISTERED -> q_b = mem[registered address]
//   power_up_uninitialized = FALSE   -> contents start at 0
//   read_during_write_mode_mixed_ports = DONT_CARE
//
// DONT_CARE means hardware may return either the old or the new word when
// port A writes the address port B reads at the same edge.  RDW_NEW selects
// which one this model returns (0 = old data, the default; 1 = new data) so
// the testbench can show whether the result depends on it (run_srg_golden.sh
// runs both).  Any other configuration is rejected at elaboration time.
`timescale 1ns/1ps
module altsyncram #(
    parameter address_aclr_b = "NONE",
    parameter address_reg_b = "CLOCK0",
    parameter byte_size = 8,
    parameter clock_enable_input_a = "BYPASS",
    parameter clock_enable_input_b = "BYPASS",
    parameter clock_enable_output_b = "BYPASS",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_type = "altsyncram",
    parameter numwords_a = 32,
    parameter numwords_b = 32,
    parameter operation_mode = "DUAL_PORT",
    parameter outdata_aclr_b = "NONE",
    parameter outdata_reg_b = "UNREGISTERED",
    parameter power_up_uninitialized = "FALSE",
    parameter ram_block_type = "M10K",
    parameter read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter widthad_a = 5,
    parameter widthad_b = 5,
    parameter width_a = 8,
    parameter width_b = 8,
    parameter width_byteena_a = 1
) (
    input  [widthad_a-1:0] address_a,
    input  [width_byteena_a-1:0] byteena_a,
    input                  clock0,
    input  [width_a-1:0]   data_a,
    input                  wren_a,
    input  [widthad_b-1:0] address_b,
    output [width_b-1:0]   q_b,
    input aclr0, aclr1, addressstall_a, addressstall_b,
    input byteena_b, clock1, clocken0, clocken1, clocken2, clocken3,
    input  [width_b-1:0]   data_b,
    output                 eccstatus,
    output [width_a-1:0]   q_a,
    input rden_a, rden_b, wren_b
);
`ifndef RDW_NEW
    localparam bit RDW_NEW = 1'b0;
`else
    localparam bit RDW_NEW = 1'b1;
`endif
    initial begin
        if (operation_mode != "DUAL_PORT" || address_reg_b != "CLOCK0" ||
            outdata_reg_b != "UNREGISTERED" || width_a != width_b ||
            widthad_a != widthad_b || power_up_uninitialized != "FALSE") begin
            $display("FATAL: altsyncram_sim: unsupported configuration");
            $finish;
        end
    end

    logic [width_a-1:0] mem [0:numwords_a-1];
    logic [widthad_b-1:0] rd_addr_q;
    logic [width_b-1:0]   old_q;
    initial for (int i = 0; i < numwords_a; i++) mem[i] = '0;

    always @(posedge clock0) begin
        old_q     <= mem[address_b];       // value before this edge's write
        rd_addr_q <= address_b;
        if (wren_a) mem[address_a] <= data_a;
    end
    // old-data: the word as it was when the address was registered;
    // new-data: the array as it is now (includes a same-edge write)
    assign q_b = RDW_NEW ? mem[rd_addr_q] : old_q;
    assign q_a = '0;
    assign eccstatus = 1'b0;
endmodule
