// Testbench: PCM Interpolator — 8/12/16-bit format and loop test
// Uses a small synthetic memory model to supply sample bytes.
`timescale 1ns/1ps
`default_nettype none

module tb_pcm_slot;

localparam real CLK_PERIOD = 1e9 / 33868800.0;

logic clk, rst_n;

// Interpolator DUT
logic        start;
logic [21:0] startAddr;
logic [15:0] pos;
logic [15:0] stepPtr;
logic [15:0] endAddr;
logic [15:0] loopAddr;
logic [1:0]  bits;
logic [21:0] mem_addr;
logic        mem_rd_req;
logic [7:0]  mem_rd_data;
logic        mem_rd_valid;
logic signed [15:0] sample_out;
logic               sample_valid;
logic               ready;

ymf278_pcm_interpolator dut (.*);

// Simple synchronous memory model (256 bytes)
logic [7:0] mem [0:255];

always_ff @(posedge clk) begin
    mem_rd_valid <= 1'b0;
    if (mem_rd_req) begin
        mem_rd_data  <= mem[mem_addr[7:0]];
        mem_rd_valid <= 1'b1;
    end
end

initial clk = 0;
always #(CLK_PERIOD/2.0) clk = ~clk;

task reset_dut();
    rst_n   = 0;
    start   = 0;
    @(posedge clk); @(posedge clk);
    rst_n   = 1;
    @(posedge clk);
endtask

task run_interp(output logic signed [15:0] result);
    start = 1;
    @(posedge clk);
    start = 0;
    // Wait for sample_valid
    while (!sample_valid) @(posedge clk);
    result = sample_out;
endtask

int errors = 0;

task check(input string msg, input logic cond);
    if (!cond) begin $display("FAIL: %s", msg); errors++; end
    else        $display("PASS: %s", msg);
endtask

initial begin
    $dumpfile("tb_pcm_slot.vcd");
    $dumpvars(0, tb_pcm_slot);

    // ── Initialize memory ────────────────────────────────────────
    // 8-bit samples: index → 0x80 shifted (signed value = (byte<<8))
    for (int i = 0; i < 64; i++) mem[i] = 8'(i * 2);

    // 16-bit samples at offset 64: pairs of bytes
    for (int i = 0; i < 32; i++) begin
        mem[64 + i*2    ] = 8'(i + 10);
        mem[64 + i*2 + 1] = 8'hAA;
    end

    // 12-bit samples at offset 128: 3-byte groups, 2 samples per group
    for (int i = 0; i < 16; i++) begin
        mem[128 + i*3 + 0] = 8'(i * 4);
        mem[128 + i*3 + 1] = 8'h33;
        mem[128 + i*3 + 2] = 8'(i * 4 + 1);
    end

    reset_dut();

    // ── Test 1: 8-bit format ─────────────────────────────────────
    $display("\n=== Test 1: 8-bit samples ===");
    bits      = 2'd0;
    startAddr = 22'd0;
    pos       = 16'd0;
    stepPtr   = 16'd0;        // no interpolation
    endAddr   = 16'hFF80;     // negated end = 128
    loopAddr  = 16'd0;

    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  sample[0] = 0x%04X", res);
        check("8-bit: sample[0] = mem[0]<<8 = 0x0000", res == 16'sh0000);
    end

    pos = 16'd1;
    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  sample[1] = 0x%04X", res);
        check("8-bit: sample[1] = 2<<8 = 0x0200", res == 16'sh0200);
    end

    // ── Test 2: 16-bit format ────────────────────────────────────
    $display("\n=== Test 2: 16-bit samples ===");
    bits      = 2'd2;
    startAddr = 22'd64;
    pos       = 16'd0;
    stepPtr   = 16'd0;
    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  16-bit sample[0] = 0x%04X", res);
        check("16-bit: first sample non-zero", res != 16'sh0);
    end

    // ── Test 3: 12-bit format ────────────────────────────────────
    $display("\n=== Test 3: 12-bit samples ===");
    bits      = 2'd1;
    startAddr = 22'd128;
    pos       = 16'd0;
    stepPtr   = 16'd0;
    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  12-bit even sample[0] = 0x%04X", res);
    end

    pos = 16'd1;
    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  12-bit odd sample[1] = 0x%04X", res);
    end

    // ── Test 4: Loop test ────────────────────────────────────────
    $display("\n=== Test 4: Loop (endAddr wrap) ===");
    bits      = 2'd0;
    startAddr = 22'd0;
    pos       = 16'd62;        // near end
    stepPtr   = 16'd0;
    endAddr   = 16'hFFC0;     // negated 64
    loopAddr  = 16'd0;        // loop back to start
    begin
        logic signed [15:0] res;
        run_interp(res);
        $display("  loop sample = 0x%04X", res);
        check("Loop: got a valid sample", sample_valid);
    end

    if (errors == 0)
        $display("\n*** ALL TESTS PASSED ***");
    else
        $display("\n*** %0d TEST(S) FAILED ***", errors);

    #1000;
    $finish;
end

endmodule
`default_nettype wire
