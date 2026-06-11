// TB: vgmplay OPL4_Detect sequence against ymf278b_top (Stage 1).
//   1. FM status read           → (status & 0xFD) must be 0
//   2. reg 0x105 ← 0x03         → NEW2|NEW on
//   3. WAVE reg 0x02 COLD read  → (value & 0xE0) must be 0x20 (device ID)
//   4. reg 0x105 ← 0x00         → NEW2 off
// Plus: reg 0x02 write 0x11 → read back 0x31 ((wr & 0x1F) | 0x20).
`timescale 1ns / 1ps

module tb_opl4_detect;
    logic clk = 0;       // 85.909 MHz (clk_sdram)
    logic clk_opl3 = 0;  // 14.318 MHz
    logic rst_n = 0;

    logic [7:0] io_port = 0, io_data_in = 0;
    logic       io_wr = 0, io_rd = 0;
    wire  [7:0] io_data_out;
    wire        io_ack;
    wire signed [15:0] audio_left, audio_right;
    wire        audio_valid, irq_n;

    wire [21:0] mem_addr;
    wire        mem_rd_req, mem_wr_req;
    wire [7:0]  mem_wr_data;

    ymf278b_top #(
        .CLK_HZ   (85909090),
        .CLK_OPL3 (14318182)
    ) dut (
        .clk, .clk_opl3, .rst_n,
        .io_port, .io_data_in, .io_wr, .io_rd,
        .io_data_out, .io_ack,
        .status_export(), .status_rd_notify(1'b0),
        .mem_addr      (mem_addr),
        .mem_rd_req    (mem_rd_req),
        .mem_rd_data   (8'h00),
        .mem_rd_data16 (16'h0000),
        .mem_rd_valid  (mem_rd_req),   // immediate zero data
        .mem_wr_req    (mem_wr_req),
        .mem_wr_data   (mem_wr_data),
        .mem_busy      (1'b0),
        .audio_left, .audio_right, .audio_valid,
        .irq_n,
        .pcm_mute (1'b0),
        .fm_mute  (1'b0),
        .pcm_vol  (2'd0),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(),
        .dbg_keyon_count(), .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(),
        .dbg_pcm_base_set(), .dbg_slot_keyon(), .dbg_slot_active()
    );

    always #5.82  clk      = ~clk;
    always #34.92 clk_opl3 = ~clk_opl3;

    int errors = 0;
    logic [7:0] rd_data;

    task automatic wait_ack(input [7:0] port, input bit is_read);
        int t;
        t = 0;
        while (!io_ack && t < 500000) begin @(negedge clk); t++; end
        if (!io_ack) begin
            $display("FAIL: ack timeout port %02x", port); errors++; rd_data = 8'hXX;
        end else if (is_read)
            rd_data = io_data_out;
        repeat (8) @(negedge clk);
    endtask

    task automatic io_write(input [7:0] port, input [7:0] data);
        @(negedge clk);
        io_port = port; io_data_in = data; io_wr = 1;
        @(negedge clk);
        io_wr = 0;
        wait_ack(port, 0);
    endtask

    task automatic io_read(input [7:0] port);
        @(negedge clk);
        io_port = port; io_rd = 1;
        @(negedge clk);
        io_rd = 0;
        wait_ack(port, 1);
    endtask

    initial begin
        repeat (20) @(negedge clk);
        rst_n = 1;
        repeat (50) @(negedge clk);

        // ── OPL4_Detect step 1: status & 0xFD == 0 ──
        io_read(8'hC4);
        if ((rd_data & 8'hFD) !== 8'h00) begin
            $display("FAIL: initial status=%02x, (st & FD) != 0", rd_data); errors++;
        end else $display("PASS: initial status=%02x", rd_data);

        // ── step 2: NEW2|NEW on (FM2 bank1, reg 0x05 = 0x03) ──
        io_write(8'hC6, 8'h05);
        io_write(8'hC7, 8'h03);
        repeat (100) @(negedge clk);  // let NEW2 shadow settle

        // ── step 3: WAVE reg 0x02 cold read ──
        io_write(8'h7E, 8'h02);       // select reg 2
        io_read (8'h7F);
        if ((rd_data & 8'hE0) !== 8'h20) begin
            $display("FAIL: reg02 cold read=%02x, (v & E0) != 20 — OPL4 DETECT FAILS", rd_data); errors++;
        end else $display("PASS: reg02 cold read=%02x → device ID OK", rd_data);

        // ── write/readback of low bits ──
        io_write(8'h7E, 8'h02);
        io_write(8'h7F, 8'h11);
        io_write(8'h7E, 8'h02);
        io_read (8'h7F);
        if (rd_data !== 8'h31) begin
            $display("FAIL: reg02 readback after write 0x11 = %02x, expected 31", rd_data); errors++;
        end else $display("PASS: reg02 readback after write 0x11 = %02x", rd_data);

        // ── step 4: NEW2 off, then FM detect still clean ──
        io_write(8'hC6, 8'h05);
        io_write(8'hC7, 8'h00);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
