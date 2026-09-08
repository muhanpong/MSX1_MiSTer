// save_guard: reset and ROM load must be DEFERRED across a .sav write, never
// dropped, and the reset must still be reachable if a save engine wedges.
// GUARD_BITS is shrunk to 8 so the watchdog case runs in a few hundred clocks.
`timescale 1ns/1ps

module tb_save_guard;

reg clk = 0;
always #5 clk = ~clk;

reg  saving = 0, reset_btn = 0;
wire reset_now, hold_load;

localparam GB = 8;                     // watchdog fires after 2^7 = 128 saving clocks
save_guard #(.GUARD_BITS(GB)) dut (
    .clk(clk), .saving(saving), .reset_btn(reset_btn),
    .reset_now(reset_now), .hold_load(hold_load)
);

integer errors = 0, i;
task check(input cond, input [200*8-1:0] name);
begin
    if (cond) $display("PASS: %0s", name);
    else begin $display("FAIL: %0s", name); errors = errors + 1; end
end
endtask

// Stimulus is applied on the NEGEDGE.  In the real core `saving` and the status
// bits are registers on this same clock, so they settle after the edge; driving
// them at the posedge instead races the DUT's own sampling and reports failures
// that the hardware cannot produce.
task press(input integer cycles);       // hold the button for `cycles` clocks
integer k;
begin
    @(negedge clk); reset_btn = 1;
    for (k = 0; k < cycles; k = k + 1) @(posedge clk);
    @(negedge clk); reset_btn = 0;
end
endtask

initial begin
    @(posedge clk);

    // ---- 1. idle: a press passes straight through -----------------------------
    @(negedge clk); reset_btn = 1; #1;
    check(reset_now === 1'b1, "T1 not saving -> reset passes immediately");
    @(negedge clk); reset_btn = 0; @(posedge clk); #1;
    check(reset_now === 1'b0, "T1 reset drops with the button");

    // ---- 2. hold_load simply mirrors saving ------------------------------------
    check(hold_load === 1'b0, "T2 hold_load low while idle");
    @(negedge clk); saving = 1; #1;
    check(hold_load === 1'b1, "T2 hold_load high while saving");

    // ---- 3. a press during a save is swallowed NOW but remembered --------------
    // The check has to happen WHILE the button is down: testing only after it is
    // released passes even on a DUT with no gate at all (found by mutating
    // reset_now to a bare reset_btn -- the release made the bug invisible).
    @(negedge clk); reset_btn = 1;
    @(posedge clk); #1;
    check(reset_now === 1'b0, "T3 reset suppressed WHILE the button is held");
    @(posedge clk); #1;
    check(reset_now === 1'b0, "T3 still suppressed on the next clock");
    @(negedge clk); reset_btn = 0;
    for (i = 0; i < 20; i = i + 1) @(posedge clk);
    #1;
    check(reset_now === 1'b0, "T3 still suppressed 20 clocks later");

    // ---- 4. it fires the moment the save finishes ------------------------------
    @(negedge clk); saving = 0; #1;
    check(reset_now === 1'b1, "T4 deferred reset fires when saving drops");
    @(posedge clk); #1;
    check(reset_now === 1'b0, "T4 and is a one-shot, not a stuck level");

    // ---- 5. no press, no reset -------------------------------------------------
    @(negedge clk); saving = 1;
    for (i = 0; i < 20; i = i + 1) @(posedge clk);
    @(negedge clk); saving = 0; #1;
    check(reset_now === 1'b0, "T5 a save alone never synthesises a reset");

    // ---- 6. watchdog: a wedged save must not lock the core out -----------------
    @(negedge clk); saving = 1; reset_btn = 1;
    for (i = 0; i < (1 << (GB-1)) + 4; i = i + 1) @(posedge clk);
    #1;
    check(reset_now === 1'b1, "T6 watchdog lets the button win on a wedged save");
    @(negedge clk); reset_btn = 0; saving = 0;
    @(posedge clk);

    // ---- 7. the guard restarts for the next save -------------------------------
    @(negedge clk); saving = 1;
    for (i = 0; i < 8; i = i + 1) @(posedge clk);
    press(2); #1;
    check(reset_now === 1'b0, "T7 guard rearmed: next save suppresses again");
    @(negedge clk); saving = 0; #1;
    check(reset_now === 1'b1, "T7 and still defers the press correctly");
    @(posedge clk);

    $display("RESULT: %0d error(s)", errors);
    if (errors) $fatal(1, "tb_save_guard FAILED");
    $finish;
end

endmodule
