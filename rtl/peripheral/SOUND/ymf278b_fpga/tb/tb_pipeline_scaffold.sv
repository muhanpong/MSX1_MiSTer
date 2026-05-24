// Sanity test: verify slot pipeline shifts a slot ID through A→B→C→D
// at the expected cycle counts.
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
        .pcm_left    (pcm_left),
        .pcm_right   (pcm_right),
        .pcm_valid   (pcm_valid)
    );

    int passes = 0, fails = 0;
    task check(string name, logic ok);
        if (ok) begin $display("PASS: %s", name); passes++; end
        else    begin $display("FAIL: %s", name); fails++;  end
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Slot 0 dispatched at frame_cycle 0 (slot_phase==0).
        // Stage A latches slot 0 data on that cycle.
        @(posedge clk); // frame_cycle 0
        @(posedge clk); // frame_cycle 1 — stage_a_reg now visible with slot 0
        check("Stage A holds slot 0 after dispatch",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd0);

        // Wait until end of slot 0's window (frame_cycle 7).
        // At stage_advance (frame_cycle 7), Stage B latches Stage A.
        // We observe Stage B's new value one cycle later (frame_cycle 8).
        // We observe Stage A's NEW slot (slot 1) one cycle after its dispatch
        // (dispatch at frame_cycle 8 → observe at frame_cycle 9).
        repeat (7) @(posedge clk); // now frame_cycle 9
        check("Stage B has slot 0 at frame_cycle 9",
              dut.stage_b_reg.valid && dut.stage_b_reg.slot == 5'd0);
        check("Stage A has slot 1 at frame_cycle 9",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd1);

        // Wait another 8 cycles: stage C latches slot 0.
        repeat (8) @(posedge clk);
        check("Stage C has slot 0 at frame_cycle 17",
              dut.stage_c_reg.valid && dut.stage_c_reg.slot == 5'd0);
        check("Stage B has slot 1 at frame_cycle 17",
              dut.stage_b_reg.valid && dut.stage_b_reg.slot == 5'd1);
        check("Stage A has slot 2 at frame_cycle 17",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd2);

        // Wait until slot 23 dispatch (frame_cycle 184).
        // We're currently at frame_cycle 17, need 167 more cycles to reach 184,
        // then +1 to observe stage_a_reg latched (frame_cycle 185).
        repeat (168) @(posedge clk); // frame_cycle 185
        check("Stage A has slot 23 at frame_cycle 185",
              dut.stage_a_reg.valid && dut.stage_a_reg.slot == 5'd23);

        // Drain: stage_advance keeps firing every 8 cycles after dispatch
        // window ends, so in-flight slots can finish.
        // Slot 23: A done at 184-191, B at 192-199, C at 200-207, D at 208-215.
        // Observe Stage C at frame_cycle 201 (1 cycle after stage_advance at 200).
        repeat (16) @(posedge clk); // frame_cycle 201
        check("Stage C has slot 23 at frame_cycle 201 (drain)",
              dut.stage_c_reg.valid && dut.stage_c_reg.slot == 5'd23);

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
