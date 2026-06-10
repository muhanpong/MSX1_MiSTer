// Unit test: Header Fetch FSM.
// - CPU writes slot 0 wave[7:0] = 5 → hf_pending[0] set
// - Wait for idle window (frame_cycle >= 1728)
// - Fake SDRAM returns canned 12-byte header
// - Verify ram_header[0] gets correct startAddr/loopAddr/endAddr/bits
// - Verify hf_pending[0] cleared after fetch
`timescale 1ns/1ps
`default_nettype none

module tb_hf_fsm;
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
    logic [15:0] mem_rd_data16 = '0;
    logic        mem_rd_valid = 1'b0;
    logic        mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic signed [15:0] pcm_left, pcm_right;
    logic        pcm_valid;

    // Debug outputs
    logic [2:0]  dbg_wavetblhdr;
    logic [23:0] dbg_hf_pending;
    logic [8:0]  dbg_slot0_wave;
    logic [9:0]  dbg_slot0_fn;
    logic signed [3:0] dbg_slot0_oct;
    logic        dbg_slot0_prvb, dbg_slot0_keyon, dbg_slot0_damp;
    logic [3:0]  dbg_slot0_pan, dbg_slot0_ar, dbg_slot0_d1r;
    logic [8:0]  dbg_slot5_wave, dbg_slot23_wave;
    logic [21:0] dbg_slot0_hdr_start;
    logic [15:0] dbg_slot0_hdr_loop, dbg_slot0_hdr_end;
    logic [1:0]  dbg_slot0_hdr_bits;

    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
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
        .dbg_slot0_hdr_start(dbg_slot0_hdr_start),
        .dbg_slot0_hdr_loop(dbg_slot0_hdr_loop),
        .dbg_slot0_hdr_end(dbg_slot0_hdr_end),
        .dbg_slot0_hdr_bits(dbg_slot0_hdr_bits)
    );

    // ── Fake SDRAM bridge with canned ROM ────────────────────────────────────
    // Wave #5's 12-byte header lives at addr = 5*12 = 60..71.
    // Make byte 0 = 0xA1 → bits=10 (16-bit fmt), startAddr[21:16]=6'b100001
    //                       (= 0x21)
    // Bytes 1,2 = 0x23, 0x45 → startAddr = 22'h21_2345
    // Bytes 3,4 = 0x67, 0x89 → loopAddr  = 16'h6789
    // Bytes 5,6 = 0xAB, 0xCD → endAddr   = 16'hABCD
    // Bytes 7-11 = don't care for v2 MVP
    logic [7:0] rom [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        rom[60] = 8'hA1; // bits=2'b10, startHi=6'b100001
        rom[61] = 8'h23;
        rom[62] = 8'h45;
        rom[63] = 8'h67;
        rom[64] = 8'h89;
        rom[65] = 8'hAB;
        rom[66] = 8'hCD;
    end

    logic [3:0]  fake_lat;
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
                    mem_rd_data  <= rom[fake_addr[9:0]];
                    mem_rd_data16 <= {rom[{fake_addr[9:1],1'b1}], rom[{fake_addr[9:1],1'b0}]};
                end
            end
        end
    end

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

        // Set wavetblhdr to 0 (no offset)
        write_reg(8'h02, 8'h00);

        // Write slot 0 wave[7:0] = 5 → hf_pending[0] set
        write_reg(8'h08, 8'd5);
        @(posedge clk);
        check("hf_pending[0] set after wave write", dbg_hf_pending[0] == 1'b1);

        // Wait until well past PIPELINE_END (fc 1728) for HF to run + complete.
        // 12 bytes × ~7 cycles each ≈ 84 cycles, fits in 220-cycle idle window.
        // Use a long wait to also cover frame wrap.
        wait (dut.frame_cycle == 11'd1730);
        $display("  [info] frame_cycle = %0d, hf_state = %0d",
                 dut.frame_cycle, dut.hf_state);

        // Wait for HF_STORE to complete (hf_state returns to HF_IDLE).
        wait (dut.hf_state == 0); // HF_IDLE = 0 in enum
        repeat (2) @(posedge clk);

        check("hf_pending[0] cleared after fetch", dbg_hf_pending[0] == 1'b0);

        // Verify ram_header[0] via debug ports (staged through typed struct
        // intermediate inside engine due to iverilog limit).
        $display("  [info] startAddr=%h loopAddr=%h endAddr=%h bits=%h",
                 dbg_slot0_hdr_start, dbg_slot0_hdr_loop,
                 dbg_slot0_hdr_end,   dbg_slot0_hdr_bits);
        check("startAddr = 22'h212345", dbg_slot0_hdr_start == 22'h212345);
        check("loopAddr  = 16'h6789",   dbg_slot0_hdr_loop  == 16'h6789);
        check("endAddr   = 16'hABCD",   dbg_slot0_hdr_end   == 16'hABCD);
        check("bits      = 2'b10",      dbg_slot0_hdr_bits  == 2'b10);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin
        #50ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
