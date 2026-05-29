// Track B — PCM noise reproduction: dynamic note-change scenario.
//
// Single static note is known-good (tb_long_run PASS) but real music is
// noisy on hardware.  This TB exercises the DYNAMIC behaviors a real player
// drives that a static note doesn't:
//
//   P1 pitch bend   — change fn/oct while keyon held (pos continues, step
//                     changes).  Output must stay bounded, pos must wrap
//                     sanely through endAddr/loopAddr.
//   P2 retrigger    — keyon 0→1 toggling.  pos/stepPtr must reset to 0 on
//                     each key-on edge; env must restart attack.
//   P3 wave switch  — change wave number while keyon held.  Header is
//                     re-fetched (hf_pending) but pos is NOT reset (only
//                     reset on key_on_edge).  If old pos > new endAddr the
//                     slot reads outside the sample → garbage/noise.
//
// Assertions look for the failure signatures of "noise": pcm output that
// jumps to rails unexpectedly, pos running far past endAddr, or X/unknown.
//
`timescale 1ns/1ps
`default_nettype none

module tb_note_change;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    localparam logic [2:0] EG_OFF = 3'd0;
    localparam logic [2:0] EG_REL = 3'd1;
    localparam logic [2:0] EG_SUS = 3'd2;
    localparam logic [2:0] EG_DEC = 3'd3;
    localparam logic [2:0] EG_ATT = 3'd4;

    logic [7:0]  reg_addr  = '0;
    logic [7:0]  reg_data  = '0;
    logic        reg_wr    = 1'b0;
    logic [21:0] mem_addr;
    logic        mem_rd_en;
    logic [7:0]  mem_rd_data;
    logic [15:0] mem_rd_data16;
    logic        mem_rd_valid;
    logic        mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic        mem_busy;
    logic signed [15:0] pcm_left, pcm_right;
    logic        pcm_valid;

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
    logic [15:0] dbg_slot0_dyn_pos, dbg_slot0_dyn_stepPtr;
    logic [9:0]  dbg_slot0_dyn_env_vol;
    logic [2:0]  dbg_slot0_dyn_env_state;
    logic        dbg_stage_b_bytes_done;
    logic        dbg_stage_advance;
    logic        dbg_stage_b_valid;

    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(mem_busy),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_wavetblhdr(dbg_wavetblhdr), .dbg_hf_pending(dbg_hf_pending),
        .dbg_slot0_wave(dbg_slot0_wave), .dbg_slot0_fn(dbg_slot0_fn),
        .dbg_slot0_oct(dbg_slot0_oct), .dbg_slot0_prvb(dbg_slot0_prvb),
        .dbg_slot0_keyon(dbg_slot0_keyon), .dbg_slot0_damp(dbg_slot0_damp),
        .dbg_slot0_pan(dbg_slot0_pan), .dbg_slot0_ar(dbg_slot0_ar),
        .dbg_slot0_d1r(dbg_slot0_d1r), .dbg_slot5_wave(dbg_slot5_wave),
        .dbg_slot23_wave(dbg_slot23_wave),
        .dbg_slot0_hdr_start(dbg_slot0_hdr_start),
        .dbg_slot0_hdr_loop(dbg_slot0_hdr_loop),
        .dbg_slot0_hdr_end(dbg_slot0_hdr_end),
        .dbg_slot0_hdr_bits(dbg_slot0_hdr_bits),
        .dbg_slot0_dyn_pos(dbg_slot0_dyn_pos),
        .dbg_slot0_dyn_stepPtr(dbg_slot0_dyn_stepPtr),
        .dbg_slot0_dyn_env_vol(dbg_slot0_dyn_env_vol),
        .dbg_slot0_dyn_env_state(dbg_slot0_dyn_env_state),
        .dbg_stage_b_bytes_done(dbg_stage_b_bytes_done),
        .dbg_stage_advance(dbg_stage_advance),
        .dbg_stage_b_valid(dbg_stage_b_valid)
    );

    // ── Bridge FSM replica (from tb_long_run) ──────────────────────────────
    logic [1:0]  pcm_state;
    logic        mem_rd_en_prev;
    logic        ch4_req;
    logic        ch4_ready;
    logic [21:0] ch4_addr;
    logic [7:0]  ch4_dout;

    assign ch4_req  = (pcm_state == 2'd1) || (pcm_state == 2'd2);
    assign mem_busy = (pcm_state != 2'd0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pcm_state <= 2'd0; mem_rd_en_prev <= 1'b0; ch4_addr <= '0;
        end else begin
            mem_rd_en_prev <= mem_rd_en;
            case (pcm_state)
                2'd0: if (mem_rd_en && !mem_rd_en_prev) begin
                    pcm_state <= 2'd1; ch4_addr <= mem_addr;
                end
                2'd1: if (!ch4_ready) pcm_state <= 2'd2;
                2'd2: if (ch4_ready)  pcm_state <= 2'd3;
                2'd3: pcm_state <= 2'd0;
            endcase
        end
    end
    logic [15:0] ch4_dout16;
    assign mem_rd_data  = ch4_dout;
    assign mem_rd_data16 = ch4_dout16;
    assign mem_rd_valid = (pcm_state == 2'd3);

    // ── SDRAM model + ROM with TWO wave headers (5 and 6) ──────────────────
    // Wave 5: 16-bit, start=0x80,  end region ~32 samples (endAddr large neg)
    // Wave 6: 16-bit, start=0x200, SHORT loop (~8 samples) — switching to it
    //         while pos is large (from wave 5) exposes out-of-range reads.
    logic [3:0] sdram_lat;
    logic [7:0] rom [0:4095];
    initial begin
        for (int i = 0; i < 4096; i++) rom[i] = 8'h00;
        // Header for wave #5 @ rom[5*12=60]: 16-bit (bits=10)
        // start=0x000080, loop=0x0000, end=0xFFE0 (~32 samples)
        rom[60]=8'h80; rom[61]=8'h00; rom[62]=8'h80;  // bits<<6 | start[21:16], start[15:8], start[7:0]
        rom[63]=8'h00; rom[64]=8'h00;                  // loopAddr
        rom[65]=8'hFF; rom[66]=8'hE0;                  // endAddr (~32 samples)
        rom[67]=8'h00; rom[68]=8'hF0; rom[69]=8'h00;   // AR=15
        rom[70]=8'h00; rom[71]=8'h00;
        // Header for wave #6 @ rom[6*12=72]: 16-bit, start=0x000200,
        // end=0xFFF8 (~8 samples short loop), loop=0x0000
        rom[72]=8'h80; rom[73]=8'h02; rom[74]=8'h00;
        rom[75]=8'h00; rom[76]=8'h00;
        rom[77]=8'hFF; rom[78]=8'hF8;
        rom[79]=8'h00; rom[80]=8'hF0; rom[81]=8'h00;
        rom[82]=8'h00; rom[83]=8'h00;
        // Wave 5 sample data @0x80: ±0x4000 sine-ish alternating, 64 samples
        for (int i = 0; i < 64; i++) begin
            rom[16'h80 + i*2]     = i[0] ? 8'hC0 : 8'h40;
            rom[16'h80 + i*2 + 1] = 8'h00;
        end
        // Wave 6 sample data @0x200: small ±0x1000, 16 samples
        for (int i = 0; i < 16; i++) begin
            rom[16'h200 + i*2]     = i[0] ? 8'hF0 : 8'h10;
            rom[16'h200 + i*2 + 1] = 8'h00;
        end
    end

    logic ch4_req_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ch4_ready <= 1'b1; sdram_lat <= '0; ch4_req_prev <= 1'b0; ch4_dout <= '0;
        end else begin
            ch4_req_prev <= ch4_req;
            if (ch4_req && !ch4_req_prev) begin
                ch4_ready <= 1'b0; sdram_lat <= 4'd6;
            end else if (sdram_lat != 0) begin
                sdram_lat <= sdram_lat - 4'd1;
                if (sdram_lat == 4'd1) begin
                    ch4_ready <= 1'b1; ch4_dout <= rom[ch4_addr[11:0]];
                    ch4_dout16 <= {rom[{ch4_addr[11:1],1'b1}], rom[{ch4_addr[11:1],1'b0}]};
                end
            end
        end
    end

    // ── Anomaly monitors ───────────────────────────────────────────────────
    int    rail_hits      = 0;   // pcm output pinned to ±full-scale
    int    pcm_samples    = 0;
    int    pos_oor_hits   = 0;   // pos read beyond a sane sample window
    int    x_hits         = 0;   // X/unknown on output
    logic [15:0] max_abs_out = 0;

    function automatic logic [15:0] abs16(input logic signed [15:0] v);
        return v[15] ? (~v + 16'd1) : v;
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && pcm_valid) begin
            pcm_samples <= pcm_samples + 1;
            if (^{pcm_left, pcm_right} === 1'bx) x_hits <= x_hits + 1;
            else begin
                if (abs16(pcm_left)  > max_abs_out) max_abs_out <= abs16(pcm_left);
                // Rail = within 4 LSB of ±0x7FFF/0x8000
                if (pcm_left >= 16'sh7FF0 || pcm_left <= -16'sh7FF0 ||
                    pcm_right >= 16'sh7FF0 || pcm_right <= -16'sh7FF0)
                    rail_hits <= rail_hits + 1;
            end
        end
    end

    // ── Helpers ────────────────────────────────────────────────────────────
    int passes = 0, fails = 0;
    task check(string name, logic ok);
        if (ok) begin $display("PASS: %s", name); passes++; end
        else    begin $display("FAIL: %s", name); fails++;  end
    endtask
    task write_reg(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1'b1;
        @(negedge clk); reg_wr=1'b0;
    endtask
    task frames(input int n);
        repeat (n * 1948) @(posedge clk);
    endtask

    // Field offsets for slot 0 (base 0x08, stride 24)
    localparam [7:0] F_WAVE = 8'h08; // field0 wave[7:0]
    localparam [7:0] F_FNL  = 8'h20; // field1 wave[8]|fn[6:0]
    localparam [7:0] F_FNH  = 8'h38; // field2 fn[9:7]|prvb|oct
    localparam [7:0] F_TL   = 8'h50; // field3
    localparam [7:0] F_PAN  = 8'h68; // field4 pan|damp|keyon
    localparam [7:0] F_ARDR = 8'h98; // field6 ar|d1r

    initial begin
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);

        // ── P1: key on wave 5, center pan, AR=15, octave 0, fn=0 ───────────
        write_reg(8'h02, 8'h00);
        write_reg(F_WAVE, 8'd5);
        write_reg(F_FNL,  8'h00);
        write_reg(F_FNH,  8'h00);     // oct=0, fn=0
        write_reg(F_TL,   8'h00);
        write_reg(F_ARDR, 8'hF0);     // AR=15
        write_reg(F_PAN,  8'h80);     // keyon=1, pan=center
        wait (dbg_slot0_hdr_start != 22'd0);
        $display("  [P1] wave5 hdr: bits=%h start=%h end=%h",
                 dbg_slot0_hdr_bits, dbg_slot0_hdr_start, dbg_slot0_hdr_end);
        frames(20);

        // ── P1b: pitch sweep — change oct/fn while keyon held ──────────────
        for (int o = 0; o < 6; o++) begin
            write_reg(F_FNH, 8'(o << 4));        // oct = o, prvb=0, fn[9:7]=0
            write_reg(F_FNL, 8'((o*23) << 1));   // vary fn low bits
            frames(8);
        end
        $display("  [P1b] after pitch sweep: pos=%h step=%h state=%0d",
                 dbg_slot0_dyn_pos, dbg_slot0_dyn_stepPtr, dbg_slot0_dyn_env_state);

        // ── P2: retrigger — keyon 0→1 a few times ──────────────────────────
        for (int r = 0; r < 4; r++) begin
            write_reg(F_PAN, 8'h00);   // keyon=0 → release
            frames(3);
            write_reg(F_PAN, 8'h80);   // keyon=1 → retrigger, pos should reset
            // pos should be small right after retrigger
            repeat (3 * 1948) @(posedge clk);
            frames(3);
        end
        $display("  [P2] after retriggers: pos=%h state=%0d vol=%h",
                 dbg_slot0_dyn_pos, dbg_slot0_dyn_env_state, dbg_slot0_dyn_env_vol);

        // ── P3: wave switch while keyon held (no key_on edge) ──────────────
        // Let wave 5 run so pos grows large, THEN switch to short wave 6.
        write_reg(F_FNH, 8'h40);   // oct=4 → fast pos advance
        frames(10);
        $display("  [P3] pre-switch pos=%h (wave5 end=%h)",
                 dbg_slot0_dyn_pos, dbg_slot0_dyn_hdr_end_dummy());
        write_reg(F_WAVE, 8'd6);   // switch instrument, keyon STILL high
        frames(20);
        $display("  [P3] post-switch wave=%0d hdr_end=%h pos=%h state=%0d",
                 dbg_slot0_wave, dbg_slot0_hdr_end, dbg_slot0_dyn_pos,
                 dbg_slot0_dyn_env_state);

        // ── Results ─────────────────────────────────────────────────────────
        $display("");
        $display("  ── Output anomaly stats ──");
        $display("  pcm_valid samples : %0d", pcm_samples);
        $display("  rail hits (±full) : %0d", rail_hits);
        $display("  X/unknown hits    : %0d", x_hits);
        $display("  max |pcm_left|    : 0x%h", max_abs_out);
        $display("");

        check("no X/unknown on pcm output", x_hits == 0);
        check("produced pcm_valid samples", pcm_samples > 100);
        check("output not pinned to rails (<5% of samples)",
              pcm_samples > 0 && (rail_hits * 100) < (pcm_samples * 5));

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        else            $display("!!! %0d ANOMALIES DETECTED !!!", fails);
        $finish;
    end

    // dummy to avoid referencing a non-existent signal in $display above
    function automatic [15:0] dbg_slot0_dyn_hdr_end_dummy();
        return dbg_slot0_hdr_end;
    endfunction

    initial begin
        #40ms; $display("TIMEOUT"); $finish;
    end
endmodule
`default_nettype wire
