// TB: OPL3/OPL4 detection + OPLTimer sequences against timers.sv
// Verifies:
//  1. OPL3_DetectPort: RST → timer1=0xFF → 0x39(start) → status reads 0xC0
//     within 80µs; closing 0x78 write (MT1|MT2, RST=0) makes status read 0x00.
//  2. OPL4_Detect precondition: status & 0xFD == 0 after the OPL3 detect.
//  3. OPLTimer: timer1=0xF5(-11), 0x80(RST), 0x39(start) → irq_n asserts every
//     ~880µs; handler ack 0xBF (RST=1) clears irq and the timer keeps running.
`timescale 1ns / 1ps

module tb_timers_detect
    import opl3_pkg::*;
();
    logic clk = 0;
    logic reset = 1;
    opl3_reg_wr_t opl3_reg_wr = '0;
    logic irq_n;
    logic [REG_FILE_DATA_WIDTH-1:0] status;

    timers dut (
        .clk,
        .reset,
        .opl3_reg_wr,
        .irq_n,
        .status,
        .force_timer_overflow(1'b0)
    );

    // 14.318182 MHz → 69.84 ns period
    always #34.92 clk = ~clk;

    int errors = 0;

    task automatic wr(input [7:0] addr, input [7:0] data);
        @(negedge clk);
        opl3_reg_wr.valid    = 1;
        opl3_reg_wr.bank_num = 0;
        opl3_reg_wr.address  = addr;
        opl3_reg_wr.data     = data;
        @(negedge clk);
        opl3_reg_wr = '0;
    endtask

    task automatic check(input [7:0] exp_mask, input [7:0] exp_val, input string what);
        if ((status & exp_mask) !== exp_val) begin
            $display("FAIL: %s — status=%02x, expected (st & %02x)==%02x", what, status, exp_mask, exp_val);
            errors++;
        end else
            $display("PASS: %s — status=%02x", what, status);
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        repeat (4) @(negedge clk);

        // ── 1. OPL3_DetectPort sequence ──
        wr(8'h04, 8'h80);          // RST: clear flags
        wr(8'h02, 8'hFF);          // timer1 = 0xFF (overflow after 1 tick = 80µs)
        wr(8'h04, 8'h39);          // MT2=1, ST1=1 (start timer 1)
        #90us;                     // detect routine waits >80µs
        check(8'hFF, 8'hC0, "detect: status 0xC0 after timer1 overflow");

        wr(8'h04, 8'h78);          // closing write: MT1|MT2, RST=0
        repeat (4) @(negedge clk);
        check(8'hFF, 8'h00, "detect-exit: 0x78 write hides/clears flags");
        if (irq_n !== 1'b1) begin $display("FAIL: irq_n still asserted after 0x78"); errors++; end

        // ── 2. OPL4_Detect precondition ──
        check(8'hFD, 8'h00, "OPL4_Detect: status & 0xFD == 0");

        // ── 3. OPLTimer start ──
        wr(8'h02, 8'hF5);          // timer1 = -11 → overflow after 11 ticks = 880µs
        wr(8'h04, 8'h80);          // RST (ST/MT must be ignored)
        wr(8'h04, 8'h39);          // MT2=1, ST1=1
        #100us;
        check(8'h40, 8'h00, "OPLTimer: no early overflow at 100µs");
        #800us;                    // total 900µs > 880µs
        check(8'hC0, 8'hC0, "OPLTimer: tick 1 fired by 900µs");
        if (irq_n !== 1'b0) begin $display("FAIL: irq_n not asserted on tick"); errors++; end

        wr(8'h04, 8'hBF);          // handler ack: RST=1, other bits don't-care
        repeat (4) @(negedge clk);
        check(8'hC0, 8'h00, "OPLTimer: ack 0xBF clears flag");
        if (irq_n !== 1'b1) begin $display("FAIL: irq_n stuck after ack"); errors++; end

        #900us;                    // timer must still be running (RST=1 ignored ST bits)
        check(8'hC0, 8'hC0, "OPLTimer: tick 2 fired ~880µs after ack");
        wr(8'h04, 8'hBF);
        repeat (4) @(negedge clk);
        #900us;
        check(8'hC0, 8'hC0, "OPLTimer: tick 3 — continuous ticking");

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
