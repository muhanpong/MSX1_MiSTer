// Testbench: YMF278 PCM Envelope Generator
// Tests: ATT→DEC→SUS→REL→OFF cycle, AR=15 instant attack,
//        DAMP mode, pseudo-reverb, VCD dump.
`timescale 1ns/1ps
`default_nettype none

module tb_pcm_envelope;

// 33.8688 MHz clock
localparam real CLK_PERIOD = 1e9 / 33868800.0;  // ~29.53 ns

logic clk, rst_n;

// DUT signals
logic [4:0]  slot_idx;
logic        slot_valid;
logic [3:0]  AR, D1R, D2R, RR, RC;
logic [9:0]  FN;
logic signed [3:0] OCT;
logic [15:0] DL;
logic        PRVB, DAMP;
logic        key_on, key_on_pulse, key_off_pulse;
logic [23:0] eg_cnt;
logic [9:0]  env_vol;

// dl_tab values used in tests
localparam logic [15:0] DL_0  = 16'h0000;   //  0 dB
localparam logic [15:0] DL_6  = 16'h00C0;   // dl_tab[6] = -18dB threshold for PRVB
localparam logic [15:0] DL_15 = 16'h03E0;   // -93dB (max)

ymf278_pcm_envelope dut (.*);

// Clock generation
initial clk = 0;
always #(CLK_PERIOD/2.0) clk = ~clk;

// Slot scheduler: single-slot test, slot_idx fixed at 0.
// slot_valid fires once every 24 cycles, aligned so the EG pipeline
// sees slot_valid_d1=1 with slot_idx_d1=0.
logic [4:0] sched_cnt;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        sched_cnt  <= 5'd23;  // start at 23 so first fire occurs after reset
        slot_idx   <= 5'd0;
        slot_valid <= 1'b0;
        eg_cnt     <= 24'd0;
    end else begin
        slot_valid <= 1'b0;
        if (sched_cnt == 5'd23) begin
            sched_cnt  <= 5'd0;
            eg_cnt     <= eg_cnt + 24'd1;
            slot_valid <= 1'b1;   // slot_idx stays 0; pipeline will see d1=0
        end else begin
            sched_cnt <= sched_cnt + 5'd1;
        end
        // slot_idx stays fixed at 0 for single-slot test
    end
end

// Reset
task do_reset();
    rst_n = 0;
    key_on_pulse  = 0;
    key_off_pulse = 0;
    key_on        = 0;
    AR = 4'h5; D1R = 4'h5; D2R = 4'h2; RR = 4'h5;
    RC = 4'hF; FN = 10'd512; OCT = 4'sd0;
    DL = DL_6; PRVB = 0; DAMP = 0;
    @(posedge clk); @(posedge clk);
    rst_n = 1;
    @(posedge clk);
endtask

// Fire key-on pulse; hold for 24 cycles so it aligns with slot_valid for slot 0
task do_key_on();
    key_on = 1;
    key_on_pulse = 1;
    repeat (24) @(posedge clk);
    key_on_pulse = 0;
endtask

// Fire key-off pulse; hold for 24 cycles to align with slot_valid for slot 0
task do_key_off();
    key_on = 0;
    key_off_pulse = 1;
    repeat (24) @(posedge clk);
    key_off_pulse = 0;
endtask

// Wait N sample periods (each = 24 slot cycles)
task wait_samples(input int n);
    repeat (n * 24) @(posedge clk);
endtask

// VCD dump
initial begin
    $dumpfile("tb_pcm_envelope.vcd");
    $dumpvars(0, tb_pcm_envelope);
end

// ─── Test sequences ───────────────────────────────────────────────────
int errors = 0;

task check(input string msg, input logic cond);
    if (!cond) begin
        $display("FAIL: %s  env_vol=%0h at time %0t", msg, env_vol, $time);
        errors++;
    end else begin
        $display("PASS: %s", msg);
    end
endtask

initial begin
    // ── Test 1: Normal ADSR cycle ──────────────────────────────────
    // AR=12 → rate=48, shift=0: attack updates every sample period.
    // RR=15 → rate=63, shift=0, inc=4: silence in ~160 samples.
    $display("\n=== Test 1: Normal ADSR cycle ===");
    do_reset();
    AR=4'hC; D1R=4'h6; D2R=4'h3; RR=4'hF; DL=16'h00C0; PRVB=0; DAMP=0;

    do_key_on();
    wait_samples(10);
    check("After 10 samples in ATT, env_vol < 0x280", env_vol < 10'h280);

    wait_samples(100);
    check("After 110 samples still not silence", env_vol < 10'h280);

    do_key_off();
    wait_samples(197);
    check("After release, env_vol should reach max", env_vol == 10'h280);

    // ── Test 2: AR=15 instant attack ──────────────────────────────
    $display("\n=== Test 2: AR=15 instant attack ===");
    do_reset();
    AR=4'hF; D1R=4'h5; D2R=4'h2; RR=4'h5; DL=DL_6;

    do_key_on();
    @(posedge clk); @(posedge clk);
    check("AR=15: env_vol should be 0 immediately", env_vol == 10'h000);

    // ── Test 3: DAMP mode ─────────────────────────────────────────
    // AR=15 instant; D1R=D2R=15 (rate=63, inc=4/sample) bring env_vol
    // to ~520 after 130 samples; DAMP at that point silences in ~30 more.
    $display("\n=== Test 3: DAMP mode ===");
    do_reset();
    AR=4'hF; D1R=4'hF; D2R=4'hF; RR=4'h3; DL=DL_6; DAMP=0;

    do_key_on();
    wait_samples(130);   // attack+decay bring env_vol near silence level
    DAMP = 1;            // activate damping
    wait_samples(30);
    check("DAMP: env_vol reaches silence within 30 samples", env_vol == 10'h280);

    // ── Test 4: Pseudo-reverb ────────────────────────────────────
    $display("\n=== Test 4: Pseudo-reverb (PRVB) ===");
    do_reset();
    AR=4'h8; D1R=4'h3; D2R=4'h0; RR=4'h3; DL=16'h0040; PRVB=1;

    do_key_on();
    wait_samples(200);   // should engage reverb at -18dB
    check("PRVB: env_vol should be at or above dl_tab[6]=0x00C0",
          env_vol >= 10'h0C0);

    // ── Test 5: 24-slot independence ────────────────────────────
    $display("\n=== Test 5: All slots in silence after reset ===");
    do_reset();
    wait_samples(5);
    check("All slots idle: slot 0 at MAX_ATT", env_vol == 10'h280);

    // ── Summary ──────────────────────────────────────────────────
    if (errors == 0)
        $display("\n*** ALL TESTS PASSED ***");
    else
        $display("\n*** %0d TEST(S) FAILED ***", errors);

    #1000;
    $finish;
end

endmodule
`default_nettype wire
