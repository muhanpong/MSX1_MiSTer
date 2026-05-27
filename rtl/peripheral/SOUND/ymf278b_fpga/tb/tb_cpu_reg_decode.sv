// Unit test: CPU register decoder.
// Drives reg_addr/reg_data/reg_wr pulses and verifies that ram_regs[slot]
// fields update correctly per the YMF278B register map.
`timescale 1ns/1ps
`default_nettype none

module tb_cpu_reg_decode;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    logic [7:0]  reg_addr  = '0;
    logic [7:0]  reg_data  = '0;
    logic        reg_wr    = 1'b0;
    logic [21:0] mem_addr;
    logic        mem_rd_en;
    logic [7:0]  mem_rd_data = '0;
    logic        mem_rd_valid = 1'b0;
    logic        mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic signed [15:0] pcm_left, pcm_right;
    logic        pcm_valid;

    // Debug observation ports
    logic [2:0]  dbg_wavetblhdr;
    logic [23:0] dbg_hf_pending;
    logic [8:0]  dbg_slot0_wave;
    logic [9:0]  dbg_slot0_fn;
    logic signed [3:0] dbg_slot0_oct;
    logic        dbg_slot0_prvb, dbg_slot0_keyon, dbg_slot0_damp;
    logic [3:0]  dbg_slot0_pan, dbg_slot0_ar, dbg_slot0_d1r;
    logic [8:0]  dbg_slot5_wave, dbg_slot23_wave;

    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(1'b0),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_wavetblhdr(dbg_wavetblhdr),
        .dbg_hf_pending(dbg_hf_pending),
        .dbg_slot0_wave(dbg_slot0_wave),
        .dbg_slot0_fn(dbg_slot0_fn),
        .dbg_slot0_oct(dbg_slot0_oct),
        .dbg_slot0_prvb(dbg_slot0_prvb),
        .dbg_slot0_keyon(dbg_slot0_keyon),
        .dbg_slot0_damp(dbg_slot0_damp),
        .dbg_slot0_pan(dbg_slot0_pan),
        .dbg_slot0_ar(dbg_slot0_ar),
        .dbg_slot0_d1r(dbg_slot0_d1r),
        .dbg_slot5_wave(dbg_slot5_wave),
        .dbg_slot23_wave(dbg_slot23_wave),
        .dbg_slot0_hdr_start(),
        .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(),
        .dbg_slot0_hdr_bits()
    );

    int passes = 0, fails = 0;
    task check(string name, logic ok);
        if (ok) begin $display("PASS: %s", name); passes++; end
        else    begin $display("FAIL: %s", name); fails++;  end
    endtask

    task write_reg(input [7:0] a, input [7:0] d);
        @(negedge clk);
        reg_addr = a; reg_data = d; reg_wr = 1'b1;
        @(negedge clk);
        reg_wr = 1'b0;
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ─── 0x02: wavetblhdr (bits[4:2]) ────────────────────────────────────
        write_reg(8'h02, 8'b000_101_00); // bits[4:2] = 3'b101
        @(posedge clk);
        check("0x02 → wavetblhdr == 3'b101", dbg_wavetblhdr == 3'b101);

        // ─── Slot 0 field 0 (addr 0x08): wave[7:0] + hf_pending ─────────────
        write_reg(8'h08, 8'hAA);
        @(posedge clk);
        check("slot0 wave = 9'h0AA",         dbg_slot0_wave == 9'h0AA);
        check("slot0 hf_pending set",        dbg_hf_pending[0] == 1'b1);

        // ─── Slot 0 field 1 (addr 0x20): wave[8] + fn[6:0] ──────────────────
        // Now wave[7:0] is still 0xAA from above; bit 8 set → 9'h1AA.
        write_reg(8'h20, 8'b1010101_1);  // fn[6:0] = 7'b1010101, wave[8] = 1
        @(posedge clk);
        check("slot0 wave = 9'h1AA (bit8 set)", dbg_slot0_wave == 9'h1AA);
        check("slot0 fn (low7 = 0x55) = 0x55",  dbg_slot0_fn == 10'h055);

        // ─── Slot 0 field 2 (addr 0x38): fn[9:7], prvb, oct ─────────────────
        // Adds fn[9:7]=3'b011 → fn = 10'b011_1010101 = 0x1D5
        write_reg(8'h38, 8'b0011_1_011); // oct=4'b0011=3, prvb=1, fn[9:7]=3'b011
        @(posedge clk);
        check("slot0 fn = 10'h1D5",          dbg_slot0_fn == 10'h1D5);
        check("slot0 prvb = 1",              dbg_slot0_prvb == 1'b1);
        check("slot0 oct = +3",              dbg_slot0_oct == 4'sd3);

        // ─── Slot 0 field 4 (addr 0x68): pan + damp + keyon ─────────────────
        write_reg(8'h68, 8'b1_1_0_0_0011); // keyon=1, damp=1, lfo=0, mute=0, pan=3
        @(posedge clk);
        check("slot0 pan = 3",               dbg_slot0_pan == 4'd3);
        check("slot0 damp = 1",              dbg_slot0_damp == 1'b1);
        check("slot0 keyon = 1",             dbg_slot0_keyon == 1'b1);

        // ─── Slot 5 field 0 (addr 0x08 + 5 = 0x0D): wave[7:0] ───────────────
        write_reg(8'h0D, 8'h5A);
        @(posedge clk);
        check("slot5 wave = 9'h05A",         dbg_slot5_wave == 9'h05A);
        check("slot5 hf_pending set",        dbg_hf_pending[5] == 1'b1);

        // ─── Slot 23 field 0 (addr 0x08 + 23 = 0x1F): wave[7:0] ─────────────
        write_reg(8'h1F, 8'hC3);
        @(posedge clk);
        check("slot23 wave = 9'h0C3",        dbg_slot23_wave == 9'h0C3);

        // ─── Slot 0 field 6 (addr 0x08 + 6*24 = 0x98): ar + d1r ─────────────
        write_reg(8'h98, 8'h7B);
        @(posedge clk);
        check("slot0 ar = 0x7",              dbg_slot0_ar == 4'h7);
        check("slot0 d1r = 0xB",             dbg_slot0_d1r == 4'hB);

        // ─── Out-of-range addresses must NOT modify slot regs ───────────────
        write_reg(8'hF8, 8'hFF); // > 0xF7, should be ignored
        @(posedge clk);
        // Verify slot 0 wave unchanged from 9'h1AA
        check("0xF8 write ignored (slot0 wave still 9'h1AA)",
              dbg_slot0_wave == 9'h1AA);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin
        #10ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
