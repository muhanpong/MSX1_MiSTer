// Testbench: PCM Integration — ymf278_pcm_top + ymf278_pcm_memory
// Drives PCM register writes the way ymf278b_regs would, provides a synthetic
// sample memory, and verifies that KEY_ON eventually produces audio output.
// Bypasses OPL3 (which uses SV constructs iverilog doesn't support).
`timescale 1ns/1ps
`default_nettype none

module tb_pcm_integration;

localparam real CLK_PERIOD = 1e9 / 33868800.0;

logic clk, rst_n;

// ── PCM top ↔ memory interface ──────────────────────────────────────────
logic [21:0] mem_addr;
logic        mem_rd_req;
logic [7:0]  mem_rd_data;
logic        mem_rd_valid;

logic [7:0]  cpu_mem_reg, cpu_mem_data;
logic        cpu_mem_wr, cpu_mem_rd;
logic [7:0]  cpu_mem_rd_data;
logic        cpu_mem_ack;

// External memory bus (memory module ↔ stub)
logic [21:0] ext_addr;
logic        ext_rd_en, ext_wr_en;
logic [7:0]  ext_wr_data;
logic [7:0]  ext_rd_data;
logic        ext_rd_valid;
logic        ext_busy;
logic        mem_busy_int;

// PCM register interface
logic [7:0]  pcm_reg_addr, pcm_reg_data;
logic        pcm_reg_wr, pcm_reg_rd;
logic [7:0]  pcm_reg_dout;

// Audio output
logic signed [15:0] pcm_left, pcm_right;
logic               pcm_valid;
logic [4:0]         dbg_keyon_count;
logic [4:0]         dbg_accum_cnt;
logic [9:0]         dbg_env_min;

// ── Synthetic sample memory (4KB) ───────────────────────────────────────
// Layout:
//   addr 0..11:    Sample 0 header (wave_num = 0)
//   addr 12..23:   Sample 1 header (wave_num = 1)
//   ...
//   addr 256..1023: Sample audio data for wave 0 (startAddr = 256)
logic [7:0] mem [0:4095];
initial begin
    for (int i = 0; i < 4096; i++) mem[i] = 8'd0;

    // Sample 0 header (12 bytes), wave_num=0 → base = 0
    //   byte 0: bits[7:6] = format (0 = 8-bit), bits[5:0] = startAddr[21:16]
    //   byte 1: startAddr[15:8]
    //   byte 2: startAddr[7:0]
    //   byte 3-4: loopAddr (16-bit, big-endian)
    //   byte 5-6: endAddr  (16-bit, 2's complement big-endian)
    //   byte 7:  bits[5:3]=lfo_speed, bits[2:0]=vib  (use 0 = no LFO)
    //   byte 8:  bits[7:4]=AR, bits[3:0]=D1R         (AR=15 → instant attack)
    //   byte 9:  bits[7:4]=DL_idx, bits[3:0]=D2R     (DL=0, D2R=0 → no decay)
    //   byte 10: bits[7:4]=RC, bits[3:0]=RR          (RC=15 → no rate scaling)
    //   byte 11: bits[2:0]=AM                        (0 = no AM)
    //
    // startAddr = 0x000100 (=256)
    mem[0]  = 8'h00;       // format=0 (8-bit), startAddr[21:16] = 0
    mem[1]  = 8'h01;       // startAddr[15:8] = 1 → startAddr = 0x0100
    mem[2]  = 8'h00;       // startAddr[7:0]  = 0
    mem[3]  = 8'h00;       // loopAddr[15:8] = 0
    mem[4]  = 8'h00;       // loopAddr[7:0]  = 0 → loopAddr = 0x0000
    mem[5]  = 8'hFF;       // endAddr[15:8]  = 0xFF
    mem[6]  = 8'h00;       // endAddr[7:0]   = 0x00 → endAddr = 0xFF00 (= -256, ~256 samples)
    mem[7]  = 8'h00;       // lfo_speed=0, vib=0
    mem[8]  = 8'hF0;       // AR=15, D1R=0  (instant attack to min attenuation)
    mem[9]  = 8'h00;       // DL_idx=0, D2R=0
    mem[10] = 8'hF0;       // RC=15, RR=0   (no rate scaling, no release)
    mem[11] = 8'h00;       // AM=0

    // Sample audio data at startAddr = 0x100..0x1FF (256 samples)
    // Use a sawtooth: 0x80, 0x81, 0x82, ... 0xFF, 0x00, 0x01, ...
    for (int i = 0; i < 256; i++)
        mem[256 + i] = 8'h80 + 8'(i);
end

// External memory model: handles read/write requests from memory module.
// Read: 1-cycle latency (request → valid). Write: 1-cycle complete.
assign ext_busy = 1'b0;
always_ff @(posedge clk) begin
    ext_rd_valid <= 1'b0;
    if (ext_rd_en) begin
        ext_rd_data  <= mem[ext_addr[11:0]];
        ext_rd_valid <= 1'b1;
    end
    if (ext_wr_en) begin
        mem[ext_addr[11:0]] <= ext_wr_data;
    end
end

// ── DUT instantiations ──────────────────────────────────────────────────
ymf278_pcm_top #(
    .CLK_HZ (33868800)
) u_pcm (
    .clk             (clk),
    .rst_n           (rst_n),
    .reg_addr        (pcm_reg_addr),
    .reg_data        (pcm_reg_data),
    .reg_wr          (pcm_reg_wr),
    .reg_rd          (pcm_reg_rd),
    .reg_dout        (pcm_reg_dout),
    .mem_addr        (mem_addr),
    .mem_rd_req      (mem_rd_req),
    .mem_rd_data     (mem_rd_data),
    .mem_rd_valid    (mem_rd_valid),
    .cpu_mem_reg     (cpu_mem_reg),
    .cpu_mem_data    (cpu_mem_data),
    .cpu_mem_wr      (cpu_mem_wr),
    .cpu_mem_rd      (cpu_mem_rd),
    .cpu_mem_rd_data (cpu_mem_rd_data),
    .cpu_mem_ack     (cpu_mem_ack),
    .pcm_left        (pcm_left),
    .pcm_right       (pcm_right),
    .pcm_valid       (pcm_valid),
    .keyon_count     (dbg_keyon_count),
    .dbg_accum_cnt   (dbg_accum_cnt),
    .dbg_env_min     (dbg_env_min)
);

ymf278_pcm_memory u_mem (
    .clk            (clk),
    .rst_n          (rst_n),
    .reg2_ram_wr_en (1'b1),
    .reg2_mode      (1'b0),
    .cpu_reg        (cpu_mem_reg),
    .cpu_data_in    (cpu_mem_data),
    .cpu_wr         (cpu_mem_wr),
    .cpu_rd         (cpu_mem_rd),
    .cpu_data_out   (cpu_mem_rd_data),
    .cpu_ack        (cpu_mem_ack),
    .pcm_addr       (mem_addr),
    .pcm_rd_req     (mem_rd_req),
    .pcm_rd_data    (mem_rd_data),
    .pcm_rd_valid   (mem_rd_valid),
    .ext_addr       (ext_addr),
    .ext_rd_en      (ext_rd_en),
    .ext_wr_en      (ext_wr_en),
    .ext_wr_data    (ext_wr_data),
    .ext_rd_data    (ext_rd_data),
    .ext_rd_valid   (ext_rd_valid),
    .ext_busy       (ext_busy),
    .busy           (mem_busy_int)
);

// Clock
initial clk = 0;
always #(CLK_PERIOD/2.0) clk = ~clk;

// ── PCM register-write task ─────────────────────────────────────────────
task pcm_write(input [7:0] addr, input [7:0] data);
    @(posedge clk);
    pcm_reg_addr <= addr;
    pcm_reg_data <= data;
    pcm_reg_wr   <= 1'b1;
    @(posedge clk);
    pcm_reg_wr   <= 1'b0;
    @(posedge clk);
    @(posedge clk);
endtask

// Test stats
int test_passes = 0;
int test_fails  = 0;
task check(input string name, input bit ok);
    if (ok) begin $display("PASS: %s", name); test_passes++; end
    else    begin $display("FAIL: %s", name); test_fails++;  end
endtask

// Track outputs
bit got_pcm_valid;
bit got_nonzero_audio;
int hf_addr_observed;
logic [21:0] last_mem_addr;
always_ff @(posedge clk) begin
    if (pcm_valid) begin
        got_pcm_valid <= 1'b1;
        if (pcm_left != 16'sd0 || pcm_right != 16'sd0)
            got_nonzero_audio <= 1'b1;
    end
    if (mem_rd_req) last_mem_addr <= mem_addr;
end

initial begin
    $dumpfile("tb_pcm_integration.vcd");
    $dumpvars(0, tb_pcm_integration);

    rst_n             = 0;
    pcm_reg_addr      = 8'd0;
    pcm_reg_data      = 8'd0;
    pcm_reg_wr        = 1'b0;
    pcm_reg_rd        = 1'b0;
    got_pcm_valid     = 1'b0;
    got_nonzero_audio = 1'b0;
    last_mem_addr     = 22'd0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (10) @(posedge clk);

    // ── Step 1: Confirm slot 0 is idle (no KEY_ON) ───────────────────────
    $display("\n=== Step 1: Initial state ===");
    repeat (200) @(posedge clk);
    check("Step 1.a: No pcm_valid before any setup",  !got_pcm_valid);
    check("Step 1.b: keyon_count == 0",                dbg_keyon_count == 5'd0);

    // ── Step 2: Configure slot 0 wave (triggers header fetch) ────────────
    // Write wave LSB to reg 0x08 (slot 0, field 0).  This triggers HF FSM
    // to read 12 bytes from mem[wave * 12] = mem[0..11] and populate slot 0.
    $display("\n=== Step 2: Write wave LSB → triggers HF ===");
    pcm_write(8'h08, 8'h00);                 // wave LSB = 0
    // Give HF FSM time to fetch 12 bytes (~30 cycles, plenty)
    repeat (200) @(posedge clk);
    check("Step 2.a: HF completed (mem_addr last seen in header range)",
          last_mem_addr <= 22'd11);

    // Dump slot 0 register state after HF
    $display("  After HF: sr_AR[0]=%0d (expect 15), sr_D1R[0]=%0d, sr_RC[0]=%0d (expect 15)",
             u_pcm.sr_AR[0], u_pcm.sr_D1R[0], u_pcm.sr_RC[0]);
    $display("  sr_DL_idx[0]=%0d, sr_D2R[0]=%0d, sr_RR[0]=%0d",
             u_pcm.sr_DL_idx[0], u_pcm.sr_D2R[0], u_pcm.sr_RR[0]);
    $display("  sr_startAddr[0]=0x%06h (expect 0x000100)",
             u_pcm.sr_startAddr[0]);
    $display("  sr_endAddr[0]=0x%04h (expect 0xFF00)",
             u_pcm.sr_endAddr[0]);
    $display("  sr_bits[0]=%0d, sr_AM[0]=%0d, sr_wave[0]=%0d",
             u_pcm.sr_bits[0], u_pcm.sr_AM[0], u_pcm.sr_wave[0]);
    $display("  sr_keyon[0]=%0d (expect 0 before KEY_ON)",
             u_pcm.sr_keyon[0]);

    // ── Step 3: KEY_ON slot 0 (reg 0x68, field 4, bit 7 = key-on) ────────
    $display("\n=== Step 3: KEY_ON slot 0 ===");
    // Reg index for field 4, slot 0: 0x08 + 4*24 = 0x68
    pcm_write(8'h68, 8'h80);                 // bit 7 = key-on, pan=0
    repeat (20) @(posedge clk);
    check("Step 3.a: keyon_count == 1 after KEY_ON",
          dbg_keyon_count == 5'd1);
    $display("  After KEY_ON: sr_keyon[0]=%0d, sr_pan[0]=%0d",
             u_pcm.sr_keyon[0], u_pcm.sr_pan[0]);

    // ── Step 4: Wait for first PCM sample output ────────────────────────
    // pcm_top runs at 44.1kHz with CLK_HZ=33868800 → SAMPLE_DIV ≈ 768.
    // After KEY_ON, envelope is AR=15 (instant attack), so first sample
    // should produce non-zero audio within a couple of sample periods.
    $display("\n=== Step 4: Waiting for PCM audio output ===");
    begin
        int wait_cnt = 0;
        while (!got_pcm_valid && wait_cnt < 10000) begin
            @(posedge clk);
            wait_cnt++;
        end
        check("Step 4.a: pcm_valid asserted within 10000 cycles",
              got_pcm_valid);
    end

    // Wait a few more sample periods for envelope to open up
    repeat (10000) @(posedge clk);
    check("Step 4.b: Non-zero PCM audio output observed",
          got_nonzero_audio);
    $display("  Last pcm_left=%0d pcm_right=%0d",
             $signed(pcm_left), $signed(pcm_right));
    $display("  dbg_env_min=0x%03x (0 = max volume, 0x280 = silence)",
             dbg_env_min);
    $display("  sr_TL[0]=%0d, sr_pan[0]=%0d, sr_pos[0]=%0d, sr_stepPtr[0]=0x%04h",
             u_pcm.sr_TL[0], u_pcm.sr_pan[0], u_pcm.sr_pos[0], u_pcm.sr_stepPtr[0]);
    $display("  vol u_vol: env_vol_r=%0d tl_vol_r=%0d pan_r=%0d sample_r=%0d",
             u_pcm.u_vol.env_vol_r, u_pcm.u_vol.tl_vol_r,
             u_pcm.u_vol.pan_r, $signed(u_pcm.u_vol.sample_r));
    $display("  vol u_vol: left_out=%0d right_out=%0d",
             $signed(u_pcm.u_vol.left_out), $signed(u_pcm.u_vol.right_out));

    // ── Step 5: KEY_OFF and verify silence ──────────────────────────────
    $display("\n=== Step 5: KEY_OFF ===");
    pcm_write(8'h68, 8'h00);                 // clear bit 7
    repeat (20) @(posedge clk);
    check("Step 5.a: keyon_count == 0 after KEY_OFF",
          dbg_keyon_count == 5'd0);

    // ── Step 6: CPU memory read path (the user's BASIC test scenario) ────
    // Set mem_adr = 0x000200 (start of sample data, mem[0x200] = 0x80).
    // Then issue a CPU read of reg 6 and verify cpu_mem_rd_data has the
    // correct value AND cpu_mem_ack pulses.
    $display("\n=== Step 6: CPU memory read path ===");
    pcm_write(8'h03, 8'h00);   // addr[21:16] = 0
    pcm_write(8'h04, 8'h01);   // addr[15:8]  = 1
    pcm_write(8'h05, 8'h00);   // addr[7:0]   = 0 → mem_adr = 0x000100
    repeat (20) @(posedge clk);
    // Issue CPU read of reg 6
    @(posedge clk);
    pcm_reg_addr <= 8'h06;
    pcm_reg_rd   <= 1'b1;
    @(posedge clk);
    pcm_reg_rd   <= 1'b0;
    // Wait up to 200 cycles for cpu_mem_ack
    begin
        int wait_cnt = 0;
        bit got_ack = 0;
        logic [7:0] read_data;
        while (!got_ack && wait_cnt < 200) begin
            @(posedge clk);
            if (u_pcm.cpu_mem_ack) begin
                got_ack   = 1;
                read_data = u_pcm.cpu_mem_rd_data;
            end
            wait_cnt++;
        end
        check("Step 6.a: cpu_mem_ack pulsed", got_ack);
        $display("  Read data = 0x%02h (expected 0x80 = mem[0x100])", read_data);
        check("Step 6.b: read data matches mem[0x100] = 0x80",
              got_ack && (read_data == 8'h80));
    end
    // Wait one more cycle for reg_rd_done to update pcm_reg_dout
    repeat (3) @(posedge clk);
    $display("  pcm_reg_dout (after ack) = 0x%02h", u_pcm.reg_dout);
    check("Step 6.c: pcm_reg_dout holds 0x80 after ack",
          u_pcm.reg_dout == 8'h80);

    // ── Step 7: User BASIC scenario — manual AR=15 then KEY_ON (no HF) ───
    // This mimics the user's failing BASIC test exactly.
    $display("\n=== Step 7: Manual AR=15 + KEY_ON without HF ===");
    // First reset slot 0 state by KEY_OFF
    pcm_write(8'h68, 8'h00);
    repeat (50) @(posedge clk);
    // Manually set AR=15, D1R=0 via reg 0x98
    pcm_write(8'h98, 8'hF0);
    // Manually set RC=0, RR=15 via reg 0xC8
    pcm_write(8'hC8, 8'h0F);
    repeat (20) @(posedge clk);
    $display("  sr_AR[0]=%0d (expect 15), sr_D1R[0]=%0d, sr_RC[0]=%0d, sr_RR[0]=%0d",
             u_pcm.sr_AR[0], u_pcm.sr_D1R[0], u_pcm.sr_RC[0], u_pcm.sr_RR[0]);
    check("Step 7.a: sr_AR[0] == 15 after reg 0x98 write",
          u_pcm.sr_AR[0] == 4'd15);
    // KEY_ON
    pcm_write(8'h68, 8'h80);
    repeat (5000) @(posedge clk);
    $display("  After KEY_ON: sr_keyon[0]=%0d, env_vol_out=0x%03h, dbg_env_min=0x%03h",
             u_pcm.sr_keyon[0], u_pcm.env_vol_out, dbg_env_min);
    check("Step 7.b: sr_keyon[0] = 1", u_pcm.sr_keyon[0]);
    check("Step 7.c: dbg_env_min reached 0 (envelope opened at some point)",
          dbg_env_min == 10'd0);

    // ── Step 8: Verify pcm_left actually produces non-zero amplitude ──────
    $display("\n=== Step 8: pcm_left amplitude check ===");
    begin
        int peak_abs = 0;
        int curr_abs;
        int run_cnt = 0;
        // Run long enough for many samples; track peak |pcm_left|
        for (int n = 0; n < 30000; n++) begin
            @(posedge clk);
            curr_abs = ($signed(pcm_left) < 0) ?
                       -int'($signed(pcm_left)) : int'($signed(pcm_left));
            if (curr_abs > peak_abs) peak_abs = curr_abs;
            if ($signed(pcm_left) != 16'sd0) run_cnt++;
        end
        $display("  pcm_left peak abs over 30k cycles: %0d (0x%04h)",
                 peak_abs, peak_abs);
        $display("  pcm_left non-zero cycles: %0d / 30000", run_cnt);
        // Dump intermediate signal peaks
        begin
            int interp_peak = 0, vol_peak = 0, accum_peak = 0;
            int curr;
            int vol_valid_cnt = 0, interp_valid_cnt = 0;
            for (int n = 0; n < 10000; n++) begin
                @(posedge clk);
                curr = ($signed(u_pcm.interp_out) < 0) ?
                       -int'($signed(u_pcm.interp_out)) : int'($signed(u_pcm.interp_out));
                if (curr > interp_peak) interp_peak = curr;
                curr = ($signed(u_pcm.vol_left) < 0) ?
                       -int'($signed(u_pcm.vol_left)) : int'($signed(u_pcm.vol_left));
                if (curr > vol_peak) vol_peak = curr;
                curr = ($signed(u_pcm.accum_left) < 0) ?
                       -int'($signed(u_pcm.accum_left)) : int'($signed(u_pcm.accum_left));
                if (curr > accum_peak) accum_peak = curr;
                if (u_pcm.vol_valid) vol_valid_cnt++;
                if (u_pcm.interp_valid) interp_valid_cnt++;
            end
            $display("  interp_out peak: %0d (0x%h)", interp_peak, interp_peak);
            $display("  vol_left peak:   %0d (0x%h)", vol_peak, vol_peak);
            $display("  accum_left peak: %0d (0x%h)", accum_peak, accum_peak);
            $display("  interp_valid count: %0d / 10000", interp_valid_cnt);
            $display("  vol_valid count:    %0d / 10000", vol_valid_cnt);
            $display("  sr_startAddr[0]=0x%06h, sr_endAddr[0]=0x%04h, sr_bits[0]=%0d",
                     u_pcm.sr_startAddr[0], u_pcm.sr_endAddr[0], u_pcm.sr_bits[0]);
            $display("  sr_FN[0]=%0d, sr_OCT[0]=%0d, sr_TL[0]=%0d, sr_pan[0]=%0d",
                     u_pcm.sr_FN[0], u_pcm.sr_OCT[0], u_pcm.sr_TL[0], u_pcm.sr_pan[0]);
            $display("  env_for_vol=0x%h env_vol_out=0x%h slot_mem[0][9:0]=0x%h",
                     u_pcm.env_for_vol, u_pcm.env_vol_out,
                     u_pcm.u_eg.slot_mem[0][9:0]);
            $display("  pipe_env[1]=0x%h ev_with_am(reg)=0x%h",
                     u_pcm.pipe_env[1], u_pcm.ev_with_am);
        end
        // env_for_vol min/max tracking over more cycles
        begin
            int env_min_seen = 1024, env_max_seen = 0;
            int env_at_interp = 1024;  // env_for_vol when interp_valid fires
            int sample_at_volstart = 0;
            for (int n = 0; n < 20000; n++) begin
                @(posedge clk);
                if (int'(u_pcm.env_for_vol) < env_min_seen)
                    env_min_seen = int'(u_pcm.env_for_vol);
                if (int'(u_pcm.env_for_vol) > env_max_seen)
                    env_max_seen = int'(u_pcm.env_for_vol);
                if (u_pcm.interp_valid) begin
                    env_at_interp = int'(u_pcm.env_for_vol);
                    sample_at_volstart = int'($signed(u_pcm.interp_out));
                    $display("    [interp_valid] env_for_vol=0x%03h sample=%d",
                             u_pcm.env_for_vol, $signed(u_pcm.interp_out));
                end
                if (u_pcm.u_vol.valid_r) begin
                    $display("    [u_vol compute] sample_r=%d env_vol_r=0x%h tl_vol_r=%0d pan_r=%0d left_out_next=?",
                             $signed(u_pcm.u_vol.sample_r),
                             u_pcm.u_vol.env_vol_r,
                             u_pcm.u_vol.tl_vol_r,
                             u_pcm.u_vol.pan_r);
                end
            end
            $display("  env_for_vol seen: min=0x%h, max=0x%h",
                     env_min_seen, env_max_seen);
        end
        check("Step 8.a: pcm_left peak >= 256 (audible threshold)",
              peak_abs >= 256);
        check("Step 8.b: pcm_left non-zero for > 100 cycles (sustained)",
              run_cnt > 100);
    end

    // ── Summary ─────────────────────────────────────────────────────────
    $display("\n=== Results: %0d PASS, %0d FAIL ===", test_passes, test_fails);
    if (test_fails == 0) $display("*** ALL TESTS PASSED ***");
    else                 $display("*** %0d FAILURE(S) ***", test_fails);
    $finish;
end

initial begin
    #500ms;
    $display("TIMEOUT");
    $finish;
end

endmodule
`default_nettype wire
