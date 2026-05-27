// Sanity test: verify slot pipeline shifts a slot ID through A→B→C→D
// at the expected cycle counts, and that Stage B's serial sequencer
// issues exactly 4 SDRAM reads per slot when valid.
`timescale 1ns/1ps
`default_nettype none

module tb_pipeline_scaffold;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    logic [21:0] mem_addr;
    logic        mem_rd_en;
    logic [7:0]  mem_rd_data = '0;
    logic        mem_rd_valid = 1'b0;
    logic        mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic signed [15:0] pcm_left, pcm_right;
    logic               pcm_valid;

    ymf278_pcm_engine dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .reg_addr    (8'd0),
        .reg_data    (8'd0),
        .reg_wr      (1'b0),
        .mem_addr    (mem_addr),
        .mem_rd_en   (mem_rd_en),
        .mem_rd_data (mem_rd_data),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en   (mem_wr_en),
        .mem_wr_data (mem_wr_data),
        .mem_busy    (1'b0),
        .pcm_left    (pcm_left),
        .pcm_right   (pcm_right),
        .pcm_valid   (pcm_valid)
    );

    // ── Fake SDRAM bridge ─────────────────────────────────────────────────────
    // Models a 5-cycle round-trip: pulse mem_rd_en → 5 cycles later mem_rd_valid.
    // The engine's Stage B sequencer ISSUE→WAIT_VALID→NEXT loop must tolerate
    // this latency.  Total per byte ≈ 7 cycles; 4 bytes ≈ 28 cycles, well
    // under the 64-cycle slot window.
    logic [3:0] fake_lat;
    logic [21:0] fake_addr;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fake_lat     <= '0;
            mem_rd_valid <= 1'b0;
            mem_rd_data  <= '0;
        end else begin
            mem_rd_valid <= 1'b0;
            if (mem_rd_en) begin
                fake_lat  <= 4'd5;
                fake_addr <= mem_addr;
            end else if (fake_lat != 0) begin
                fake_lat <= fake_lat - 4'd1;
                if (fake_lat == 4'd1) begin
                    mem_rd_valid <= 1'b1;
                    mem_rd_data  <= fake_addr[7:0]; // dummy data
                end
            end
        end
    end

    int passes = 0, fails = 0;
    task check(string name, logic ok);
        if (ok) begin $display("PASS: %s", name); passes++; end
        else    begin $display("FAIL: %s", name); fails++;  end
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // ─── Stage propagation through 64-cycle slot windows ─────────────────
        // Slot 0 dispatched at frame_cycle 0 (slot_phase==0). Stage A latches
        // on that cycle; observed one cycle later at frame_cycle 1.
        @(posedge clk); // frame_cycle 0
        @(posedge clk); // frame_cycle 1 — stage_a_reg now visible with slot 0
        check("Stage A holds slot 0 after dispatch",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd0);

        // Wait until end of slot 0's window (frame_cycle 63).  stage_advance
        // fires there; Stage B latches Stage A's slot 0.  Stage A re-dispatches
        // slot 1 at frame_cycle 64.  Observe at fc 65.
        while (dut.frame_cycle < 11'd65) @(posedge clk);
        check("Stage B has slot 0 at frame_cycle 65",
              dut.stage_b_reg.valid && dut.stage_b_reg.slot == 5'd0);
        check("Stage A has slot 1 at frame_cycle 65",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd1);

        // After another 64 cycles: Stage C latches slot 0.
        while (dut.frame_cycle < 11'd129) @(posedge clk);
        check("Stage C has slot 0 at frame_cycle 129",
              dut.stage_c_reg.valid && dut.stage_c_reg.slot == 5'd0);
        check("Stage B has slot 1 at frame_cycle 129",
              dut.stage_b_reg.valid && dut.stage_b_reg.slot == 5'd1);
        check("Stage A has slot 2 at frame_cycle 129",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd2);

        // Slot 23 dispatches at frame_cycle 23*64 = 1472.  Stage A holds it
        // from fc 1473 through fc 1535.
        while (dut.frame_cycle < 11'd1473) @(posedge clk);
        check("Stage A has slot 23 at frame_cycle 1473",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd23);

        // Drain: Stage B latches slot 23 at fc 1536, Stage C at fc 1600,
        // Stage D writeback at fc 1664.  Pipeline window ends at fc 1727.
        // Observe Stage C @ fc 1601.
        while (dut.frame_cycle < 11'd1601) @(posedge clk);
        check("Stage C has slot 23 at frame_cycle 1601 (drain)",
              dut.stage_c_reg.valid && dut.stage_c_reg.slot == 5'd23);

        // ─── Stage B SDRAM sequencer: count read pulses in slot 0 window ─────
        // Slot 0 Stage A: fc 0..63.  Slot 0 Stage B: fc 64..127.
        // Sequencer issues exactly 5 mem_rd_en pulses during fc 64..127
        // (a0, a1, a2, b0, b1 — supports 12-bit format).
        @(posedge clk);
        wait (dut.frame_cycle == 11'd64);
        begin
            int rd_high_cnt = 0;
            for (int fc = 64; fc < 128; fc++) begin
                if (mem_rd_en) rd_high_cnt++;
                @(posedge clk);
            end
            $display("  mem_rd_en HIGH cycles over fc 64..127: %0d (expect 5)", rd_high_cnt);
            check("Stage B sequencer issued exactly 5 SDRAM reads in slot 0 window",
                  rd_high_cnt == 5);
        end

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin
        #100ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
