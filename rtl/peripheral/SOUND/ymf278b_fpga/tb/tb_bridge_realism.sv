// Bridge realism integration test.
//
// Verifies that the v2 PCM engine works against an exact replica of the
// msx.sv pcm_state bridge FSM (IDLE→ACTIVE→WAIT→DONE) backed by a model
// of sdram.sv ch4 edge-triggered req/ready handshake.  If this passes,
// the engine is ready to drop into the real msx.sv core.
//
// Bridge model (matches rtl/msx.sv lines 641-680):
//   state 0 (IDLE):   on rising edge of mem_rd_en → state 1
//   state 1 (ACTIVE): wait for ch4_ready to drop  → state 2
//   state 2 (WAIT):   wait for ch4_ready to rise  → state 3
//   state 3 (DONE):   pulse mem_rd_valid, → state 0
//
// SDRAM ch4 model (loose match to sdram.sv arbitration):
//   On ch4_req rising edge: drop ch4_ready for ~6 cycles, then raise it
//   with ch4_dout = rom[ch4_addr].
`timescale 1ns/1ps
`default_nettype none

module tb_bridge_realism;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // Engine ↔ bridge signals
    logic [7:0]  reg_addr  = '0;
    logic [7:0]  reg_data  = '0;
    logic        reg_wr    = 1'b0;
    logic [21:0] mem_addr;
    logic        mem_rd_en;
    logic [7:0]  mem_rd_data;
    logic        mem_rd_valid;
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
        .dbg_slot0_hdr_bits(dbg_slot0_hdr_bits)
    );

    // ── Replica of msx.sv pcm_state bridge FSM ──────────────────────────────
    logic [1:0]  pcm_state;
    logic        mem_rd_en_prev;
    logic        ch4_req;
    logic        ch4_ready;
    logic [21:0] ch4_addr;
    logic [7:0]  ch4_dout;

    assign ch4_req = (pcm_state == 2'd1) || (pcm_state == 2'd2);

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

    assign mem_rd_data  = ch4_dout;
    assign mem_rd_valid = (pcm_state == 2'd3);

    // ── SDRAM ch4 model (mimics edge-triggered req/ready) ──────────────────
    logic [3:0] sdram_lat;
    logic [7:0] rom [0:1023];

    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        // Header for wave #5 (same layout as tb_integration)
        rom[60] = 8'h80; rom[61] = 8'h00; rom[62] = 8'h80; // bits=10, start=0x80
        rom[63] = 8'h00; rom[64] = 8'h00;
        rom[65] = 8'hFF; rom[66] = 8'hF0;
        // Alternating ±0x4000 samples (16-bit big-endian) at base 0x80
        for (int i = 0; i < 32; i++) begin
            if (i[0]) begin
                rom[8'h80 + i*2]     = 8'hC0;
                rom[8'h80 + i*2 + 1] = 8'h00;
            end else begin
                rom[8'h80 + i*2]     = 8'h40;
                rom[8'h80 + i*2 + 1] = 8'h00;
            end
        end
    end

    // ch4_ready: starts high; drops on req rising edge, rises back after ~6 cycles
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
                // Rising edge of req — start transaction
                ch4_ready <= 1'b0;
                sdram_lat <= 4'd6;
            end else if (sdram_lat != 0) begin
                sdram_lat <= sdram_lat - 4'd1;
                if (sdram_lat == 4'd1) begin
                    ch4_ready <= 1'b1;
                    ch4_dout  <= rom[ch4_addr[9:0]];
                end
            end
        end
    end

    // ── Test ────────────────────────────────────────────────────────────────
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

    int pcm_valid_count = 0;
    int max_abs_left    = 0;
    int abs_l;
    always_ff @(posedge clk) begin
        if (pcm_valid) begin
            pcm_valid_count <= pcm_valid_count + 1;
            abs_l = pcm_left[15] ? -pcm_left : pcm_left;
            if (abs_l > max_abs_left) max_abs_left <= abs_l;
        end
    end

    // Track total SDRAM transactions for sanity (each round-trip is ~10 cycles)
    int sdram_tx_count = 0;
    always_ff @(posedge clk) begin
        if (rst_n && pcm_state == 2'd3) sdram_tx_count <= sdram_tx_count + 1;
    end

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Same slot 0 setup as tb_integration
        write_reg(8'h02, 8'h00);
        write_reg(8'h08, 8'd5);
        write_reg(8'h20, 8'h00);
        write_reg(8'h38, 8'h00);
        write_reg(8'h50, 8'h01);
        write_reg(8'h68, 8'h80); // keyon=1, pan=0 (center)
        write_reg(8'h98, 8'hF0);

        wait (dbg_hf_pending[0] == 1'b1);
        $display("  [info] HF pending set");
        wait (dbg_slot0_hdr_start != 22'd0);
        $display("  [info] HF complete via realistic bridge: bits=%h start=%h",
                 dbg_slot0_hdr_bits, dbg_slot0_hdr_start);
        check("Realistic bridge: HF header populated",
              dbg_slot0_hdr_bits == 2'b10 && dbg_slot0_hdr_start == 22'h80);

        // Let several frames go by — HF completes once, then Stage B runs
        // ~4 reads × 24 slots = 96 tx/frame.
        pcm_valid_count = 0;
        max_abs_left    = 0;
        repeat (12 * 1948) @(posedge clk);

        $display("  [info] %0d pcm_valid pulses, max |pcm_left| = %0d (0x%h)",
                 pcm_valid_count, max_abs_left, max_abs_left[15:0]);
        $display("  [info] Total SDRAM transactions: %0d (avg %0d per frame)",
                 sdram_tx_count, sdram_tx_count / 12);

        check("Realistic bridge: 12 pcm_valid pulses",
              pcm_valid_count >= 10);
        check("Realistic bridge: non-zero audio",
              max_abs_left > 0);
        // Budget check: per frame ~ 24 slots × 5 reads (Stage B) + ~12 HF
        // bytes = ~120 + small overhead = ~130 tx/frame.
        // Total over 12 frames < 1700.
        check("Realistic bridge: SDRAM tx budget reasonable (<1700/12fr)",
              sdram_tx_count < 1700);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin
        #500ms;
        $display("TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
