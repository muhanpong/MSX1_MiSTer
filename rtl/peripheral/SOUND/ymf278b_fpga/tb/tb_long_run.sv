// H3/H6/H8 combined diagnostic testbench.
//
// Replicates tb_bridge_realism setup (realistic msx.sv bridge FSM + ch4
// SDRAM model) but runs for 100 audio frames so we can observe steady-state
// behavior of slot 0 across many stage_advance cycles.
//
// Three hypotheses checked simultaneously:
//
//   H3 (pos accumulation): ram_dyn[0].pos must advance from 0 after the slot
//      has been keyed on for many frames.  If pos stays at 0, ram_dyn
//      writeback is dropping or the d2_pkt.key_on_edge keeps firing
//      spuriously.
//
//   H6 (Stage B 64-cycle window): under realistic SDRAM latency (~10
//      cycles per byte × 5 bytes = 50 cycles) AND HF FSM contention, every
//      slot's Stage B should still finish before stage_advance fires.
//      Measure stage_b_bytes_done success rate across all stage_advance
//      events.  Anything below ~95% means the slot is silenced for that
//      window (which would sound like jittery noise on hw).
//
//   H8 (EG stuck in attack): after key_on with AR=15 (instant attack via HF
//      backfill), env_state should transition out of EG_ATT within a few
//      frames.  If env_state stays at EG_ATT, the slot never produces sound;
//      if it bounces back due to spurious key_on_edge resets, the envelope
//      oscillates and produces clicks.
//
`timescale 1ns/1ps
`default_nettype none

module tb_long_run;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // EG state encoding (matches ymf278_pcm_eg_pkg)
    localparam logic [2:0] EG_OFF = 3'd0;
    localparam logic [2:0] EG_REL = 3'd1;
    localparam logic [2:0] EG_SUS = 3'd2;
    localparam logic [2:0] EG_DEC = 3'd3;
    localparam logic [2:0] EG_ATT = 3'd4;

    // ── Engine ↔ bridge signals ────────────────────────────────────────────
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
    logic [15:0] dbg_slot0_dyn_pos, dbg_slot0_dyn_stepPtr;
    logic [9:0]  dbg_slot0_dyn_env_vol;
    logic [2:0]  dbg_slot0_dyn_env_state;
    logic        dbg_stage_b_bytes_done;
    logic        dbg_stage_advance;
    logic        dbg_stage_b_valid;

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(1'b0), .pcm_vol(2'd3),
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

    // ── Replica of msx.sv pcm_state bridge FSM ──────────────────────────────
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
            pcm_state      <= 2'd0;
            mem_rd_en_prev <= 1'b0;
            ch4_addr       <= '0;
        end else begin
            mem_rd_en_prev <= mem_rd_en;
            case (pcm_state)
                2'd0: if (mem_rd_en && !mem_rd_en_prev) begin
                    pcm_state <= 2'd1;
                    ch4_addr  <= mem_addr;
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

    // ── SDRAM ch4 model + wave 5 header ────────────────────────────────────
    logic [3:0] sdram_lat;
    logic [7:0] rom [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        // Header for wave #5: 16-bit (bits=10), start=0x80, end=0xFFF0 (~16 samples)
        rom[60] = 8'h80; rom[61] = 8'h00; rom[62] = 8'h80;
        rom[63] = 8'h00; rom[64] = 8'h00;
        rom[65] = 8'hFF; rom[66] = 8'hF0;
        rom[67] = 8'h00;
        rom[68] = 8'hF0;   // AR=15 instant attack
        rom[69] = 8'h00;
        rom[70] = 8'h00;
        rom[71] = 8'h00;
        // ±0x4000 alternating 16-bit samples
        for (int i = 0; i < 32; i++) begin
            rom[8'h80 + i*2]     = i[0] ? 8'hC0 : 8'h40;
            rom[8'h80 + i*2 + 1] = 8'h00;
        end
    end

    logic ch4_req_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ch4_ready    <= 1'b1;
            sdram_lat    <= '0;
            ch4_req_prev <= 1'b0;
            ch4_dout     <= '0;
        end else begin
            ch4_req_prev <= ch4_req;
            if (ch4_req && !ch4_req_prev) begin
                ch4_ready <= 1'b0;
                sdram_lat <= 4'd6;
            end else if (sdram_lat != 0) begin
                sdram_lat <= sdram_lat - 4'd1;
                if (sdram_lat == 4'd1) begin
                    ch4_ready <= 1'b1;
                    ch4_dout  <= rom[ch4_addr[9:0]];
                    ch4_dout16 <= {rom[{ch4_addr[9:1],1'b1}], rom[{ch4_addr[9:1],1'b0}]};
                end
            end
        end
    end

    // ── Monitors (use hierarchical refs into dut) ──────────────────────────
    int b_done_true   = 0;
    int b_done_false  = 0;
    int b_advance_count = 0;
    int eg_att_cycles = 0;
    int eg_non_att_cycles = 0;
    logic prev_stage_advance;
    logic [15:0] max_pos_seen = 16'd0;

    // Use the new dbg outputs (avoids hierarchical struct-array refs that
    // crash iverilog).
    wire dut_stage_advance = dbg_stage_advance;
    wire dut_b_done        = dbg_stage_b_bytes_done;
    wire dut_stage_b_valid = dbg_stage_b_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            b_done_true       <= 0;
            b_done_false      <= 0;
            b_advance_count   <= 0;
            eg_att_cycles     <= 0;
            eg_non_att_cycles <= 0;
            max_pos_seen      <= 16'd0;
            prev_stage_advance <= 1'b0;
        end else begin
            prev_stage_advance <= dut_stage_advance;
            // Count stage_b_bytes_done outcome at each stage_advance edge,
            // only for slots that had a valid stage_b_reg entering.
            if (dut_stage_advance && !prev_stage_advance) begin
                if (dut_stage_b_valid) begin
                    b_advance_count <= b_advance_count + 1;
                    if (dut_b_done) b_done_true  <= b_done_true  + 1;
                    else            b_done_false <= b_done_false + 1;
                end
            end
            // Sample slot 0's env_state — count cycles in EG_ATT
            // vs cycles in any non-OFF non-ATT state, after rst.
            if (dbg_slot0_dyn_env_state == EG_ATT) eg_att_cycles     <= eg_att_cycles + 1;
            else if (dbg_slot0_dyn_env_state != EG_OFF)
                                                    eg_non_att_cycles <= eg_non_att_cycles + 1;
            // Track max pos slot 0 ever reached.
            if (dbg_slot0_dyn_pos > max_pos_seen)
                max_pos_seen <= dbg_slot0_dyn_pos;
        end
    end

    // ── Helpers ────────────────────────────────────────────────────────────
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

    // ── Test ────────────────────────────────────────────────────────────────
    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Slot 0: wave 5, fn=0, oct=0, TL=0, pan=center, keyon=1, AR=15
        write_reg(8'h02, 8'h00);
        write_reg(8'h08, 8'd5);
        write_reg(8'h20, 8'h00);
        write_reg(8'h38, 8'h00);
        write_reg(8'h50, 8'h01);
        write_reg(8'h68, 8'h80); // keyon=1, pan=0
        write_reg(8'h98, 8'hF0); // AR=15

        wait (dbg_slot0_hdr_start != 22'd0);
        $display("  [info] HF complete: bits=%h start=%h", dbg_slot0_hdr_bits, dbg_slot0_hdr_start);

        // Reset monitor counters AFTER HF completes so we don't count startup
        b_done_true       = 0;
        b_done_false      = 0;
        b_advance_count   = 0;
        eg_att_cycles     = 0;
        eg_non_att_cycles = 0;
        max_pos_seen      = 16'd0;

        // Run 100 audio frames (100 × 1948 = 194800 cycles)
        $display("  [info] Running 100 frames...");
        repeat (100 * 1948) @(posedge clk);

        $display("");
        $display("  ── Slot 0 final state ──");
        $display("  ram_dyn[0].pos       = 0x%h  (max seen 0x%h)", dbg_slot0_dyn_pos, max_pos_seen);
        $display("  ram_dyn[0].stepPtr   = 0x%h", dbg_slot0_dyn_stepPtr);
        $display("  ram_dyn[0].env_state = %0d (0=OFF 1=REL 2=SUS 3=DEC 4=ATT)", dbg_slot0_dyn_env_state);
        $display("  ram_dyn[0].env_vol   = 0x%h", dbg_slot0_dyn_env_vol);
        $display("");
        $display("  ── H6 stage_b_bytes_done stats ──");
        $display("  total stage_b advances with valid: %0d", b_advance_count);
        $display("  done=true: %0d  done=false: %0d", b_done_true, b_done_false);
        $display("");
        $display("  ── H8 EG state cycles (slot 0) ──");
        $display("  ATT cycles: %0d  non-ATT non-OFF cycles: %0d", eg_att_cycles, eg_non_att_cycles);
        $display("");

        // ── Assertions ──────────────────────────────────────────────────────
        check("H3: ram_dyn[0].pos accumulated past 0",
              max_pos_seen > 16'd0);

        check("H6: stage_b_bytes_done success >= 95%",
              b_advance_count > 0
              && (b_done_true * 100) >= (b_advance_count * 95));

        check("H8: env_state left EG_ATT (transitioned to DEC/SUS)",
              dbg_slot0_dyn_env_state != EG_ATT
              && dbg_slot0_dyn_env_state != EG_OFF);

        check("H8: more cycles in non-ATT state than ATT (envelope progressed)",
              eg_non_att_cycles > eg_att_cycles);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        else            $display("!!! %0d HYPOTHESES NOT YET REFUTED !!!", fails);
        $finish;
    end

    initial begin
        #20ms;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire
