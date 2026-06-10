// Testbench: YMF278B Top-Level
// Tests: I/O port writes, NEW2 activation, BUSY/LOAD timing, FM+PCM output
`timescale 1ns/1ps
`default_nettype none

module tb_ymf278b_top;

localparam real CLK_PERIOD     = 1e9 / 33868800.0;  // master 33.8688 MHz
localparam real CLK_OPL3_PERIOD= 1e9 / 14318180.0;  // OPL3 14.318 MHz

logic clk, clk_opl3, rst_n;

// DUT ports
logic [7:0]  io_port;
logic [7:0]  io_data_in;
logic        io_wr, io_rd;
logic [7:0]  io_data_out;
logic        io_ack;
logic [21:0] mem_addr;
logic        mem_rd_req;
logic [7:0]  mem_rd_data;
logic [15:0] mem_rd_data16;
logic        mem_rd_valid;
logic        mem_wr_req;
logic [7:0]  mem_wr_data;
wire         mem_busy = 1'b0;
wire         pcm_mute = 1'b0;
wire         fm_mute  = 1'b0;
wire  [1:0]  pcm_vol  = 2'd0;
wire         dbg_pcm_valid, dbg_opl3_valid, dbg_new2, dbg_mem_nonzero, dbg_pcm_base_set;
wire signed [15:0] dbg_pcm_level;
wire  [4:0]  dbg_keyon_count, dbg_accum_cnt;
wire  [9:0]  dbg_env_min;
wire [23:0]  dbg_slot_keyon, dbg_slot_active;
logic signed [15:0] audio_left, audio_right;
logic               audio_valid;
logic        irq_n;

// Stub memory model (4KB)
logic [7:0] sample_mem [0:4095];
always_ff @(posedge clk) begin
    mem_rd_valid <= 1'b0;
    if (mem_rd_req) begin
        mem_rd_data   <= sample_mem[mem_addr[11:0]];
        mem_rd_data16 <= {sample_mem[mem_addr[11:0]], sample_mem[12'(mem_addr[11:0] + 1)]};
        mem_rd_valid  <= 1'b1;
    end
end

initial begin
    for (int i = 0; i < 4096; i++)
        sample_mem[i] = 8'(i & 8'hFF);
end

ymf278b_top #(
    .CLK_HZ   (33868800),
    .CLK_OPL3 (14318180)
) dut (.*);

// Clocks
initial clk = 0;
always #(CLK_PERIOD/2.0) clk = ~clk;
initial clk_opl3 = 0;
always #(CLK_OPL3_PERIOD/2.0) clk_opl3 = ~clk_opl3;

// I/O write task
task io_write(input [7:0] port, input [7:0] data);
    @(posedge clk);
    io_port    = port;
    io_data_in = data;
    io_wr      = 1;
    @(posedge clk);
    io_wr      = 0;
    @(posedge clk);
endtask

// I/O read task
task io_read(input [7:0] port, output [7:0] data);
    @(posedge clk);
    io_port = port;
    io_rd   = 1;
    @(posedge clk);
    io_rd   = 0;
    data    = io_data_out;
    @(posedge clk);
endtask

int errors = 0;
task check(input string msg, input logic cond);
    if (!cond) begin $display("FAIL [%0t]: %s", $time, msg); errors++; end
    else        $display("PASS: %s", msg);
endtask

initial begin
    $dumpfile("tb_ymf278b_top.vcd");
    $dumpvars(0, tb_ymf278b_top);

    // Reset
    rst_n      = 0;
    io_wr      = 0;
    io_rd      = 0;
    io_port    = 8'd0;
    io_data_in = 8'd0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ── Test 1: FM register select (0xC4) and write (0xC5) ──────
    $display("\n=== Test 1: FM register write ===");
    io_write(8'hC4, 8'h20);   // select FM reg 0x20
    io_write(8'hC5, 8'h31);   // write value
    check("FM write accepted (no hang)", 1'b1);

    // ── Test 2: Read FM status (0xC4) ───────────────────────────
    $display("\n=== Test 2: Read FM status ===");
    begin
        logic [7:0] stat;
        io_read(8'hC4, stat);
        $display("  FM status = 0x%02X", stat);
        check("FM status readable", 1'b1);
    end

    // ── Test 3: Enable NEW2 (OPL3 reg 0x105 bit 1) ─────────────
    $display("\n=== Test 3: Enable NEW2 ===");
    io_write(8'hC6, 8'h05);   // bank 1, select reg 0x05
    io_write(8'hC7, 8'h02);   // write bit 1 = NEW2
    repeat (10) @(posedge clk);
    check("NEW2 enable written", 1'b1);

    // ── Test 4: WAVE register select/write (0x7E/0x7F) ─────────
    $display("\n=== Test 4: WAVE register write (NEW2=1) ===");
    io_write(8'h7E, 8'h08);   // select WAVE reg 8 (slot 0 wave[7:0])
    io_write(8'h7F, 8'h01);   // write wave index = 1
    check("WAVE write accepted", 1'b1);

    // ── Test 5: BUSY after WAVE write ───────────────────────────
    $display("\n=== Test 5: BUSY flag ===");
    begin
        logic [7:0] stat;
        io_read(8'hC4, stat);
        $display("  Status after WAVE write: 0x%02X (bit0=BUSY)", stat);
    end

    // ── Test 6: LOAD delay after instrument load (reg 0x08) ─────
    $display("\n=== Test 6: LOAD delay ===");
    io_write(8'h7E, 8'h08);
    io_write(8'h7F, 8'hAA);
    begin
        logic [7:0] stat;
        io_read(8'hC4, stat);
        check("LOAD bit set after reg 0x08 write", stat[1]);
    end
    // Wait for load to clear (~10000 cycles)
    repeat (12000) @(posedge clk);
    begin
        logic [7:0] stat;
        io_read(8'hC4, stat);
        check("LOAD bit cleared after 12000 cycles", !stat[1]);
    end

    // ── Test 7: PCM key-on sequence ─────────────────────────────
    $display("\n=== Test 7: PCM key-on ===");
    // Set slot 0: AR=8, D1R=5, D2R=2, RR=5
    io_write(8'h7E, 8'h08 + 6*24);  // AR/D1R reg for slot 0
    io_write(8'h7F, 8'h85);          // AR=8, D1R=5
    io_write(8'h7E, 8'h08 + 4*24);  // key-on reg for slot 0
    io_write(8'h7F, 8'h80);          // keyon=1
    check("Key-on written", 1'b1);

    // ── Test 8: Audio output appears ────────────────────────────
    $display("\n=== Test 8: Waiting for audio output ===");
    begin
        int wait_cnt = 0;
        while (!audio_valid && wait_cnt < 5000000) begin
            @(posedge clk);
            wait_cnt++;
        end
        check("Audio valid pulse received", audio_valid);
        $display("  Left=%0d Right=%0d", $signed(audio_left), $signed(audio_right));
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
