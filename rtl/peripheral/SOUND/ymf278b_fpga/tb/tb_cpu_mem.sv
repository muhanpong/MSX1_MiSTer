// Unit test: CPU memory access via PCM registers 0x02..0x06.
//
// Verifies the CPU↔YMF278B↔external memory path implemented in v2:
//   1. Reg 0x02 mode/type bits latch.
//   2. Reg 0x03/04/05 build cpu_mem_adr; reg 0x05 write triggers prefetch.
//   3. After SDRAM responds, cpu_mem_rd_buf holds memory[adr].
//   4. Reg 0x06 read advances cpu_mem_adr and re-prefetches.
//   5. Auto-increment is correct across multiple reads.
//
// Fake SDRAM holds a known sequence so we can compare returned bytes.
`timescale 1ns/1ps
`default_nettype none

module tb_cpu_mem;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // Engine interface
    logic [7:0]  reg_addr  = '0;
    logic [7:0]  reg_data  = '0;
    logic        reg_wr    = 1'b0;
    logic        reg_rd    = 1'b0;
    logic [7:0]  cpu_mem_rd_data;
    logic        cpu_mem_busy;
    logic [7:0]  reg02_readback;

    logic [21:0] mem_addr;
    logic        mem_rd_en;
    logic [7:0]  mem_rd_data = '0;
    logic        mem_rd_valid = 1'b0;
    logic        mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic signed [15:0] pcm_left, pcm_right;
    logic        pcm_valid;

    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .reg_wr(reg_wr), .reg_rd(reg_rd),
        .cpu_mem_rd_data(cpu_mem_rd_data),
        .cpu_mem_busy(cpu_mem_busy),
        .reg02_readback(reg02_readback),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_wavetblhdr(), .dbg_hf_pending(),
        .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(),
        .dbg_slot0_pan(), .dbg_slot0_ar(), .dbg_slot0_d1r(),
        .dbg_slot5_wave(), .dbg_slot23_wave(),
        .dbg_slot0_hdr_start(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits()
    );

    // ── Fake SDRAM (4 KB) preloaded with yrw801-like first bytes ─────────────
    // Real yrw801.rom byte 0..11 = 40 18 00 00 00 FF D6 00 F0 00 0F 00
    logic [7:0] rom [0:4095];
    initial begin
        for (int i = 0; i < 4096; i++) rom[i] = 8'(i & 8'hFF);  // address-pattern
        rom[0]  = 8'h40; rom[1]  = 8'h18; rom[2]  = 8'h00;
        rom[3]  = 8'h00; rom[4]  = 8'h00; rom[5]  = 8'hFF;
        rom[6]  = 8'hD6; rom[7]  = 8'h00; rom[8]  = 8'hF0;
        rom[9]  = 8'h00; rom[10] = 8'h0F; rom[11] = 8'h00;
    end

    // Fake SDRAM model: 5-cycle read latency, 1-cycle write.  Writes update
    // the rom[] array so subsequent reads at the same address return the
    // updated byte — exactly the behaviour BASIC's write+readback test needs.
    logic [3:0]  fake_lat;
    logic [21:0] fake_addr;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fake_lat     <= '0;
            mem_rd_valid <= 1'b0;
            mem_rd_data  <= '0;
        end else begin
            mem_rd_valid <= 1'b0;
            if (mem_wr_en) begin
                // Capture write — emulates SDRAM latching ch4_din on req edge.
                rom[mem_addr[11:0]] <= mem_wr_data;
            end
            if (mem_rd_en) begin
                fake_lat  <= 4'd5;
                fake_addr <= mem_addr;
            end else if (fake_lat != 0) begin
                fake_lat <= fake_lat - 4'd1;
                if (fake_lat == 4'd1) begin
                    mem_rd_valid <= 1'b1;
                    mem_rd_data  <= rom[fake_addr[11:0]];
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

    task read_reg(input [7:0] a);
        @(negedge clk);
        reg_addr = a; reg_rd = 1'b1;
        @(negedge clk);
        reg_rd = 1'b0;
    endtask

    // Wait until cpu_mem_busy clears (prefetch complete + buf updated).
    // CPU mem ops only fire in HF idle window (frame_cycle >= 1728); idle
    // window is ~220 cycles out of 1948 per frame, so worst-case ~1730
    // cycles wait until next idle window opens.  Guard is 10× that.
    task wait_cpu_idle;
        int guard = 0;
        while (cpu_mem_busy && guard < 20000) begin
            @(posedge clk);
            guard++;
        end
        if (guard >= 20000) $display("  [warn] cpu_mem_busy stuck");
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // -- Test 1: reg 0x02 access mode latch + readback
        // Initial readback (before any write): D5=1 (ID), others 0 → 0x20
        check("reg02 readback after reset = 0x20", reg02_readback == 8'h20);

        write_reg(8'h02, 8'h01);     // bit0 = mem_access_mode = 1
        @(posedge clk);
        check("reg02_mem_access_mode latched", dut.reg02_mem_access_mode == 1'b1);
        check("reg02_mem_type stays 0",        dut.reg02_mem_type == 1'b0);
        check("reg02 readback = 0x21 (ID + access_mode)", reg02_readback == 8'h21);

        // Now write mem_type = 1 as well
        write_reg(8'h02, 8'h03);     // bit0=1, bit1=1
        @(posedge clk);
        check("reg02 readback = 0x23 (ID + type + access_mode)", reg02_readback == 8'h23);

        // Test reg 0x02 with mem_type only (no access mode)
        write_reg(8'h02, 8'h02);     // bit0=0, bit1=1
        @(posedge clk);
        check("reg02 readback = 0x22 (ID + type only)", reg02_readback == 8'h22);

        // Test wavetblhdr bits (D4-D2)
        write_reg(8'h02, 8'h0C);     // bits[4:2] = 011 = wavetblhdr=3
        @(posedge clk);
        check("reg02 readback = 0x2C (ID + wavetblhdr=3)", reg02_readback == 8'h2C);

        // Reset back to access_mode=1 for following tests
        write_reg(8'h02, 8'h01);
        @(posedge clk);

        // -- Test 2: address load 03/04/05 then 05 triggers prefetch
        write_reg(8'h03, 8'h00);     // adr[23:16] = 0
        write_reg(8'h04, 8'h00);     // adr[15:8]  = 0
        write_reg(8'h05, 8'h00);     // adr[7:0]   = 0  → cpu_rd_pend
        @(posedge clk);
        check("cpu_mem_adr == 0", dut.cpu_mem_adr == 24'h000000);

        // -- Test 3: wait for first prefetch to complete, expect rom[0] = 0x40
        wait_cpu_idle();
        check("first prefetch returns 0x40", cpu_mem_rd_buf_eq(8'h40));

        // -- Test 4: read 06H — returns cpu_mem_rd_buf (=0x40) AND advances adr
        read_reg(8'h06);
        @(posedge clk);
        check("cpu_mem_adr incremented to 1", dut.cpu_mem_adr == 24'h000001);
        wait_cpu_idle();
        check("second prefetch returns 0x18", cpu_mem_rd_buf_eq(8'h18));

        // -- Test 5: sequential read confirms 12 yrw801 bytes
        read_reg(8'h06); wait_cpu_idle();
        check("byte[2] = 0x00", cpu_mem_rd_buf_eq(8'h00));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[3] = 0x00", cpu_mem_rd_buf_eq(8'h00));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[4] = 0x00", cpu_mem_rd_buf_eq(8'h00));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[5] = 0xFF", cpu_mem_rd_buf_eq(8'hFF));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[6] = 0xD6", cpu_mem_rd_buf_eq(8'hD6));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[7] = 0x00", cpu_mem_rd_buf_eq(8'h00));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[8] = 0xF0", cpu_mem_rd_buf_eq(8'hF0));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[9] = 0x00", cpu_mem_rd_buf_eq(8'h00));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[10] = 0x0F", cpu_mem_rd_buf_eq(8'h0F));
        read_reg(8'h06); wait_cpu_idle();
        check("byte[11] = 0x00", cpu_mem_rd_buf_eq(8'h00));

        // -- Test 6: confirm adr is 0x0C (== 12) after 11 reads (initial 05 = 0,
        // then 11 reads of 06 increment to 11). Wait — 05 set to 0 didn't increment.
        // Each 06 read increments by 1.  We did 11 reads of 06 above, so adr = 11.
        // Next 06 read → returns rom[11] = 0x00 → adr = 12.
        check("cpu_mem_adr == 11 after 11 reads", dut.cpu_mem_adr == 24'h00000B);

        // -- Test 7: address re-load — overrides increment
        write_reg(8'h03, 8'h00);
        write_reg(8'h04, 8'h01);
        write_reg(8'h05, 8'h00);      // adr = 0x000100 → rom[256] = 0x00 (pattern)
        @(posedge clk);
        check("cpu_mem_adr == 0x000100", dut.cpu_mem_adr == 24'h000100);
        wait_cpu_idle();
        check("prefetch at 0x100 = 0x00", cpu_mem_rd_buf_eq(8'h00));

        // -- Test 8: WRITE path — write 0xAB at 0x000200, read it back.
        // This exercises the engine→bridge→SDRAM write timing that BASIC
        // showed broken (any byte→0x56 with stale-data bug).
        write_reg(8'h03, 8'h00);
        write_reg(8'h04, 8'h02);
        write_reg(8'h05, 8'h00);      // adr = 0x000200
        @(posedge clk);
        wait_cpu_idle();              // prefetch of original byte
        // Now write 0xAB to that address
        write_reg(8'h06, 8'hAB);
        @(posedge clk);
        wait_cpu_idle();              // wait for engine to issue write + auto-inc + next prefetch
        // adr has been incremented to 0x000201 after the write.
        // Re-set address back to 0x000200 to read it back
        write_reg(8'h03, 8'h00);
        write_reg(8'h04, 8'h02);
        write_reg(8'h05, 8'h00);
        @(posedge clk);
        wait_cpu_idle();
        check("write 0xAB → readback 0xAB", cpu_mem_rd_buf_eq(8'hAB));

        // -- Test 9: multiple sequential writes + auto-increment
        write_reg(8'h03, 8'h00);
        write_reg(8'h04, 8'h03);
        write_reg(8'h05, 8'h00);      // adr = 0x000300
        @(posedge clk);
        wait_cpu_idle();
        write_reg(8'h06, 8'h11); wait_cpu_idle();   // 0x300
        write_reg(8'h06, 8'h22); wait_cpu_idle();   // 0x301
        write_reg(8'h06, 8'h33); wait_cpu_idle();   // 0x302
        write_reg(8'h06, 8'h44); wait_cpu_idle();   // 0x303
        // Re-read from 0x300
        write_reg(8'h03, 8'h00);
        write_reg(8'h04, 8'h03);
        write_reg(8'h05, 8'h00);
        @(posedge clk);
        wait_cpu_idle();
        check("seq write[0x300] = 0x11", cpu_mem_rd_buf_eq(8'h11));
        read_reg(8'h06); wait_cpu_idle();
        check("seq write[0x301] = 0x22", cpu_mem_rd_buf_eq(8'h22));
        read_reg(8'h06); wait_cpu_idle();
        check("seq write[0x302] = 0x33", cpu_mem_rd_buf_eq(8'h33));
        read_reg(8'h06); wait_cpu_idle();
        check("seq write[0x303] = 0x44", cpu_mem_rd_buf_eq(8'h44));

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    // Helper: compare cpu_mem_rd_buf via the visible cpu_mem_rd_data port
    function automatic logic cpu_mem_rd_buf_eq(input [7:0] expected);
        if (cpu_mem_rd_data === expected) return 1'b1;
        $display("  [check] cpu_mem_rd_data = 0x%02h  expected 0x%02h",
                 cpu_mem_rd_data, expected);
        return 1'b0;
    endfunction

    initial begin
        #50ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
