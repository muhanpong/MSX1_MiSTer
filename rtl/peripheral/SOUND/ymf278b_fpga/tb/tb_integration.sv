// Integration test: full v2 PCM engine end-to-end.
// - CPU writes slot 0 reg fields to start a 16-bit sample at pos=0
// - Fake SDRAM serves canned header (wave #5) + canned sample bytes
// - Wait for HF + several audio frames
// - Verify pcm_valid pulses occur each frame
// - Verify master accumulator integrates non-zero audio after key_on
`timescale 1ns/1ps
`default_nettype none

module tb_integration;
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

    // Debug ports
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
        .mem_rd_data(mem_rd_data), .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
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

    // ── Canned ROM ──────────────────────────────────────────────────────────
    // Wave #5 header at rom[60..71] (5 * 12 = 60):
    //   byte 0 = 0x80 → bits=10 (16-bit), startHi[5:0]=0
    //   byte 1 = 0x00 → start[15:8] = 0
    //   byte 2 = 0x80 → start[7:0]  = 0x80  → startAddr = 22'h000080
    //   byte 3,4 = loop  (16'h0000)
    //   byte 5,6 = end   (16'hFFF0) — 2's complement: pos must reach 0x10 to wrap
    //   byte 7-11 = 0   (LFO/AR/etc defaults — ignored)
    //
    // Sample data at rom[0x80..]: alternating ±0x4000 (16-bit big-endian).
    //   rom[0x80] = 0x40, rom[0x81] = 0x00  → sample 0 = +0x4000
    //   rom[0x82] = 0xC0, rom[0x83] = 0x00  → sample 1 = -0x4000
    //   ...
    logic [7:0] rom [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        // Header for wave #5
        rom[60] = 8'h80; rom[61] = 8'h00; rom[62] = 8'h80; // bits=10, start=0x80
        rom[63] = 8'h00; rom[64] = 8'h00;                  // loop = 0
        rom[65] = 8'hFF; rom[66] = 8'hF0;                  // end (signed-ish)
        // bytes 7..11 = LFO/AR/D1R/DL/D2R/RC/RR/AM (chip auto-backfills these
        // from header into slot regs).  Put AR=15 / D1R=0 for fast attack.
        rom[67] = 8'h00;   // LFO_SPEED=0, VIB=0
        rom[68] = 8'hF0;   // AR=15 (instant attack), D1R=0
        rom[69] = 8'h00;   // DL=0, D2R=0
        rom[70] = 8'h00;   // RC=0, RR=0
        rom[71] = 8'h00;   // AM=0
        // Sample data (16-bit big-endian)
        for (int i = 0; i < 32; i++) begin
            if (i[0]) begin // odd index → negative
                rom[8'h80 + i*2]     = 8'hC0;
                rom[8'h80 + i*2 + 1] = 8'h00;
            end else begin
                rom[8'h80 + i*2]     = 8'h40;
                rom[8'h80 + i*2 + 1] = 8'h00;
            end
        end
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

    // ── Track pcm_valid pulses + max sample magnitude ──────────────────────
    int pcm_valid_count = 0;
    int max_abs_left = 0;
    int abs_l;
    always_ff @(posedge clk) begin
        if (pcm_valid) begin
            pcm_valid_count <= pcm_valid_count + 1;
            abs_l = pcm_left[15] ? -pcm_left : pcm_left;
            if (abs_l > max_abs_left) max_abs_left <= abs_l;
        end
    end

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // wavetblhdr = 0
        write_reg(8'h02, 8'h00);
        // slot 0 wave[7:0] = 5
        write_reg(8'h08, 8'd5);
        // slot 0 wave[8] = 0, fn[6:0] = 0
        write_reg(8'h20, 8'h00);
        // slot 0 fn[9:7] = 0, prvb = 0, oct = 0
        write_reg(8'h38, 8'h00);
        // slot 0 TL = 0 (no attenuation), bit 0 = 1 (load immediate)
        write_reg(8'h50, 8'h01);
        // slot 0 pan + keyon: keyon=1, damp=0, lfo=0, mute=0, pan=0 (center, both full)
        // NOTE: pan=8 is MUTE per YMF278B spec (both channels silent).
        write_reg(8'h68, 8'h80);
        // slot 0 AR=15, D1R=0 → instant attack
        write_reg(8'h98, 8'hF0);

        // Wait for HF to start (pending set after wave write).
        wait (dbg_hf_pending[0] == 1'b1);
        $display("  [info] HF pending set, waiting for completion");
        // hf_pending[0] clears at HF_IDLE→HF_REQ entry (pickup), not at
        // HF_STORE.  Header bytes are written to ram_header[0] only after
        // 12 byte fetches complete (~100 cycles).  Wait for the START byte
        // to become non-zero — surely indicates HF_STORE has run.
        wait (dbg_slot0_hdr_start != 22'd0);
        $display("  [info] HF done: bits=%h start=%h loop=%h end=%h",
                 dbg_slot0_hdr_bits, dbg_slot0_hdr_start,
                 dbg_slot0_hdr_loop, dbg_slot0_hdr_end);
        check("HF populated header: bits=10", dbg_slot0_hdr_bits == 2'b10);
        check("HF populated header: start=0x80", dbg_slot0_hdr_start == 22'h80);

        // Let ~12 audio frames go by (1948 cycles each).
        pcm_valid_count = 0;
        max_abs_left    = 0;
        repeat (12 * 1948) @(posedge clk);

        $display("  [info] %0d pcm_valid pulses, max |pcm_left| = %0d (0x%h)",
                 pcm_valid_count, max_abs_left, max_abs_left[15:0]);
        check("pcm_valid fired at least 10 times in test window",
              pcm_valid_count >= 10);
        // Quantitative check: with TL=0, env_vol=0, pan=center, and 16-bit
        // samples at ±0x4000 in fake ROM, pcm_left peak should reach full
        // amplitude (~0x4000).  Prior bug (master_accum[23:8] vs [15:0])
        // divided by 256 → peak only 0x40 → silently passed the original
        // ">0" check.  Require >0x1000 to catch >>>16x attenuation regressions.
        check("pcm_left peak ≥ 0x1000 (no major attenuation regression)",
              max_abs_left >= 16'h1000);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin
        #200ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
