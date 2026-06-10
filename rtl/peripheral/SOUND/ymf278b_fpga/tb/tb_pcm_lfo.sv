// Testbench: PCM LFO — vibrato (vib_offset) and tremolo (am_atten)
// Drives slot 0 with controlled lfo_speed/vib_depth/am_depth/active/reset.
// Validates lfo_cnt accumulation, triangle-wave generation, and
// reset behavior against openMSX YMF278.cc compute_vib() / compute_am().
`timescale 1ns/1ps
`default_nettype none

module tb_pcm_lfo;

localparam real CLK_PERIOD = 1e9 / 33868800.0;

logic clk, rst_n;

// DUT inputs
logic [4:0]  slot_idx;
logic        slot_valid;
logic [2:0]  lfo_speed;
logic [2:0]  vib_depth_sel;
logic [2:0]  am_depth_sel;
logic        lfo_active;
logic        lfo_reset;

// DUT outputs
logic signed [15:0] vib_offset;
logic        [15:0] am_atten;

ymf278_pcm_lfo dut (.*);

// Clock
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// Tables (must match dut and reference_model.py)
logic [17:0] period_table [0:7];
logic signed [15:0] vib_depth_table [0:7];
logic [7:0]  am_depth_table  [0:7];
initial begin
    period_table[0]=18'd1;  period_table[1]=18'd12; period_table[2]=18'd19; period_table[3]=18'd25;
    period_table[4]=18'd31; period_table[5]=18'd35; period_table[6]=18'd37; period_table[7]=18'd42;
    vib_depth_table[0]=16'sd0;  vib_depth_table[1]=16'sd2;  vib_depth_table[2]=16'sd3;
    vib_depth_table[3]=16'sd4;  vib_depth_table[4]=16'sd6;  vib_depth_table[5]=16'sd12;
    vib_depth_table[6]=16'sd24; vib_depth_table[7]=16'sd48;
    am_depth_table[0]=8'h00; am_depth_table[1]=8'h14; am_depth_table[2]=8'h20;
    am_depth_table[3]=8'h28; am_depth_table[4]=8'h30; am_depth_table[5]=8'h40;
    am_depth_table[6]=8'h50; am_depth_table[7]=8'h80;
end

// Reference math (matches openMSX YMF278.cc compute_vib/compute_am exactly)
function automatic int compute_lfo_fm(input int lfo_cnt);
    int lfo_fm6;
    lfo_fm6 = (lfo_cnt >> 12) & 32'h3F;
    if (lfo_fm6 & 32'h10) lfo_fm6 = lfo_fm6 ^ 32'h1F;
    if (lfo_fm6 & 32'h20) lfo_fm6 = -(lfo_fm6 & 32'h0F);
    return lfo_fm6;
endfunction

function automatic int compute_lfo_am(input int lfo_cnt);
    int lfo_am8;
    lfo_am8 = (lfo_cnt >> 10) & 32'hFF;
    if (lfo_am8 & 32'h80) lfo_am8 = lfo_am8 ^ 32'hFF;
    return lfo_am8;
endfunction

function automatic int expected_vib(input int lfo_cnt, input int vib_sel);
    return (compute_lfo_fm(lfo_cnt) * int'(vib_depth_table[vib_sel])) / 12;
endfunction

function automatic int expected_am(input int lfo_cnt, input int am_sel);
    return (compute_lfo_am(lfo_cnt) * int'(am_depth_table[am_sel])) >> 7;
endfunction

int test_passes = 0;
int test_fails  = 0;
int am_before;
int expected_vib_t8;
int expected_am_t8;
task check(input string name, input bit ok);
    if (ok) begin $display("PASS: %s", name); test_passes++; end
    else    begin $display("FAIL: %s", name); test_fails++;  end
endtask

// Pulse slot 0 once.  Uses 4-cycle spacing so the BRAM read-then-write
// pipeline (read at T+1, write at end of T+1) always reads the latest
// value when the next pulse is issued at T+4.
task pulse_slot0(input bit active, input bit reset_flag);
    @(posedge clk);
    slot_idx     <= 5'd0;
    slot_valid   <= 1'b1;
    lfo_active   <= active;
    lfo_reset    <= reset_flag;
    @(posedge clk);
    slot_valid   <= 1'b0;
    @(posedge clk);
    @(posedge clk);
endtask

// Run N pulses with current lfo_speed setting.
task run_pulses(input int n);
    for (int i = 0; i < n; i++) pulse_slot0(.active(1'b1), .reset_flag(1'b0));
endtask

// Read out current vib_offset/am_atten by issuing one final pulse with
// the slot inactive (no increment), then waiting for outputs to settle.
// (vib_offset/am_atten only register on slot_valid_d1 = 1.)
task read_out();
    // The last increment pulse already updated outputs — just wait for them.
    @(posedge clk);
    @(posedge clk);
endtask

initial begin
    $dumpfile("tb_pcm_lfo.vcd");
    $dumpvars(0, tb_pcm_lfo);

    rst_n         = 0;
    slot_idx      = 0;
    slot_valid    = 0;
    lfo_speed     = 0;
    vib_depth_sel = 0;
    am_depth_sel  = 0;
    lfo_active    = 0;
    lfo_reset     = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // ── Test 1: lfo_reset forces counter and outputs to 0 ────────────
    $display("\n=== Test 1: lfo_reset forces counter to 0 ===");
    vib_depth_sel = 3'd7;  // max depth (48)
    am_depth_sel  = 3'd7;  // max depth (0x80)
    lfo_speed     = 3'd0;
    pulse_slot0(.active(1'b0), .reset_flag(1'b1));
    read_out();
    check("Test 1.a: vib_offset == 0 under lfo_reset", vib_offset == 16'sd0);
    check("Test 1.b: am_atten  == 0 under lfo_reset", am_atten  == 16'd0);

    // ── Test 2: One increment with lfo_speed=0 (period=1) ────────────
    // Starting from lfo_cnt=0, one pulse → lfo_cnt=1.
    // expected_vib(1, 7) = (lfo_fm(1) * 48)/12 = 0   (since 1>>12 = 0)
    // expected_am(1, 7)  = (lfo_am(1)  * 0x80)>>7 = 0 (since 1>>10 = 0)
    $display("\n=== Test 2: 1 pulse, lfo_speed=0 ===");
    lfo_speed = 3'd0;
    pulse_slot0(.active(1'b1), .reset_flag(1'b0));
    read_out();
    check("Test 2.a: vib_offset == 0 (lfo_cnt=1)", vib_offset == 16'sd0);
    check("Test 2.b: am_atten  == 0 (lfo_cnt=1)", am_atten  == 16'd0);

    // ── Test 3: Run to lfo_cnt = 1024 (am threshold) ──────────────────
    // Currently lfo_cnt = 1.  Run 1023 more pulses → lfo_cnt = 1024.
    // lfo_am = 1024 >> 10 = 1 → am = (1 * 0x80) >> 7 = 1
    $display("\n=== Test 3: lfo_cnt = 1024 (am threshold) ===");
    run_pulses(1023);
    read_out();
    check("Test 3.a: am_atten == 1 (lfo_cnt=1024, am_d=7)",
          am_atten == 16'd1);
    check("Test 3.b: vib_offset still 0 (lfo_cnt=1024)",
          vib_offset == 16'sd0);

    // ── Test 4: Run to lfo_cnt = 4096 (vib threshold) ─────────────────
    // Currently lfo_cnt = 1024.  Run 3072 more pulses → lfo_cnt = 4096.
    // lfo_fm = 4096 >> 12 = 1 → vib = (1 * 48)/12 = 4
    // lfo_am = 4096 >> 10 = 4 → am  = (4 * 0x80)>>7 = 4
    $display("\n=== Test 4: lfo_cnt = 4096 (vib threshold) ===");
    run_pulses(3072);
    read_out();
    check("Test 4.a: vib_offset == 4 (lfo_cnt=4096, vib_d=7)",
          vib_offset == 16'sd4);
    check("Test 4.b: am_atten  == 4 (lfo_cnt=4096, am_d=7)",
          am_atten  == 16'd4);

    // ── Test 5: vib_depth=0, am_depth=0 → both outputs 0 ──────────────
    $display("\n=== Test 5: depth selects 0 → outputs 0 ===");
    vib_depth_sel = 3'd0;
    am_depth_sel  = 3'd0;
    pulse_slot0(.active(1'b1), .reset_flag(1'b0));
    read_out();
    check("Test 5.a: vib_offset == 0 when vib_d=0", vib_offset == 16'sd0);
    check("Test 5.b: am_atten  == 0 when am_d=0",  am_atten  == 16'd0);

    // ── Test 6: lfo_active=0 holds counter (counter stays put) ────────
    // Re-enable depths so we can observe.  Increment a bit, then deassert
    // active and verify the counter does NOT advance.
    $display("\n=== Test 6: lfo_active=0 holds counter ===");
    vib_depth_sel = 3'd7;
    am_depth_sel  = 3'd7;
    // Reset and prime: drive lfo_cnt to a known value (1024).
    pulse_slot0(.active(1'b0), .reset_flag(1'b1));
    run_pulses(1024);
    read_out();
    am_before = int'(am_atten);
    // Now hold (lfo_active=0, lfo_reset=0): counter should not advance.
    for (int i = 0; i < 8; i++) pulse_slot0(.active(1'b0), .reset_flag(1'b0));
    read_out();
    check("Test 6: am_atten unchanged after 8 hold-pulses",
          int'(am_atten) == am_before);

    // ── Test 7: Reset clears counter again ────────────────────────────
    $display("\n=== Test 7: lfo_reset clears counter mid-run ===");
    pulse_slot0(.active(1'b0), .reset_flag(1'b1));
    read_out();
    check("Test 7.a: vib_offset == 0 after re-reset", vib_offset == 16'sd0);
    check("Test 7.b: am_atten  == 0 after re-reset", am_atten  == 16'd0);

    // ── Test 8: Negative vib region (lfo_cnt > 0x20000) ───────────────
    // After reset, run lfo_speed=7 (period=42) for many pulses so lfo_cnt
    // crosses 0x20000 → vib_fm becomes negative.
    // Target: lfo_cnt ≈ 0x30000 → lfo_fm6 = 0x30, XOR 0x1F = 0x2F = 47,
    //         bit 5 set → -(47 & 0xF) = -15.  vib = (-15*48)/12 = -60.
    $display("\n=== Test 8: negative vib region ===");
    lfo_speed = 3'd7;       // period = 42
    // 0x30000 / 42 ≈ 4681 pulses
    run_pulses(4681);
    read_out();
    // Actual lfo_cnt = 4681 * 42 = 196602 = 0x2FFFA
    // lfo_fm6 = 0x2F → XOR 0x1F: 0x2F & 0x10=0x10 → yes, XOR → 0x30
    //   Wait: 0x2F = 0b101111, bit 4 = 1 → XOR 0x1F: 0x2F ^ 0x1F = 0x30
    //   But then 0x30 has bit 4 = 1 too?  Re-read reference logic.
    //   Ref: `if (lfo_fm & 0x10) lfo_fm ^= 0x1F;` — only ONE XOR check.
    // After XOR: 0x30 (= 48).  Bit 5 of 48 = 1 → -(48 & 0xF) = -(0).
    // vib_fm = 0.  vib_offset = 0.
    expected_vib_t8 = expected_vib(196602, 7);
    expected_am_t8  = expected_am(196602, 7);
    $display("  lfo_cnt should be %d (0x%h)", 196602, 196602);
    $display("  vib_offset = %d (expected %d)", int'(vib_offset), expected_vib_t8);
    $display("  am_atten   = %d (expected %d)", int'(am_atten),   expected_am_t8);
    check("Test 8.a: vib_offset matches reference math",
          int'($signed(vib_offset)) == expected_vib_t8);
    check("Test 8.b: am_atten  matches reference math",
          int'(am_atten) == expected_am_t8);

    // ── Summary ───────────────────────────────────────────────────────
    $display("\n=== Results: %0d PASS, %0d FAIL ===", test_passes, test_fails);
    if (test_fails == 0) $display("*** ALL TESTS PASSED ***");
    else                 $display("*** %0d FAILURE(S) ***", test_fails);
    $finish;
end

initial begin
    #100ms;
    $display("TIMEOUT");
    $finish;
end

endmodule
`default_nettype wire
