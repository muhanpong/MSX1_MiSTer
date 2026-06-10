// Track B — PCM noise reproduction: multi-slot simultaneous playback.
//
// Single slot (static + dynamic) is known-good.  Real MoonSound music drives
// up to 24 PCM channels at once.  All slots share ONE Stage B SDRAM bridge
// (5 byte-reads per slot per frame, serialized) plus the HF header fetcher.
// If aggregate bandwidth can't service every active slot within its
// 64-cycle stage window, slots get silenced intermittently → crackle/noise.
//
// This TB activates N slots and measures the stage_b_bytes_done success rate
// (the H6 metric) under multi-slot load, plus output sanity.  A success rate
// that degrades as N grows is the noise mechanism.
//
`timescale 1ns/1ps
`default_nettype none

module tb_multi_slot;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

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

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(mem_busy),
        .pcm_vol(2'd1),
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

    // ── Bridge FSM replica ─────────────────────────────────────────────────
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
    // 16-bit word for the held (word-aligned) address: {odd byte, even byte}.
    assign mem_rd_data16 = ch4_dout16;
    assign mem_rd_valid = (pcm_state == 2'd3);

    // SDRAM model — latency parameterizable to emulate ch2 contention.
    logic [7:0] sdram_lat;
    logic [7:0] LATENCY = 8'd6;
    logic [7:0] rom [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        // wave 5 header (16-bit, start 0x80, ~32 samples), AR=15
        rom[60]=8'h80; rom[61]=8'h00; rom[62]=8'h80;
        rom[63]=8'h00; rom[64]=8'h00; rom[65]=8'hFF; rom[66]=8'hE0;
        rom[67]=8'h00; rom[68]=8'hF0; rom[69]=8'h00; rom[70]=8'h00; rom[71]=8'h00;
        for (int i = 0; i < 64; i++) begin
            rom[16'h80 + i*2]     = i[0] ? 8'hC0 : 8'h40;
            rom[16'h80 + i*2 + 1] = 8'h00;
        end
    end
    logic        VARLAT = 1'b0;   // when set, latency varies per read
    logic [7:0]  rnd_lat;
    logic ch4_req_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ch4_ready <= 1'b1; sdram_lat <= '0; ch4_req_prev <= 1'b0; ch4_dout <= '0;
        end else begin
            ch4_req_prev <= ch4_req;
            if (ch4_req && !ch4_req_prev) begin
                // VARLAT: latency in [4 .. LATENCY] emulating ch2 contention jitter
                rnd_lat = VARLAT ? (8'd4 + ($random % (LATENCY - 8'd3))) : LATENCY;
                ch4_ready <= 1'b0; sdram_lat <= rnd_lat;
            end else if (sdram_lat != 0) begin
                sdram_lat <= sdram_lat - 8'd1;
                if (sdram_lat == 8'd1) begin
                    ch4_ready <= 1'b1; ch4_dout <= rom[ch4_addr[9:0]];
                    ch4_dout16 <= {rom[{ch4_addr[9:1],1'b1}], rom[{ch4_addr[9:1],1'b0}]};
                end
            end
        end
    end

    // ── Monitors ────────────────────────────────────────────────────────────
    int b_done_true = 0, b_done_false = 0, b_advance = 0;
    int pcm_samples = 0, x_hits = 0, rail_hits = 0;
    logic [15:0] max_abs_out = 0;
    logic prev_sa;
    function automatic logic [15:0] abs16(input logic signed [15:0] v);
        return v[15] ? (~v + 16'd1) : v;
    endfunction
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            b_done_true<=0; b_done_false<=0; b_advance<=0; prev_sa<=1'b0;
            pcm_samples<=0; x_hits<=0; rail_hits<=0; max_abs_out<=0;
        end else begin
            prev_sa <= dbg_stage_advance;
            if (dbg_stage_advance && !prev_sa && dbg_stage_b_valid) begin
                b_advance <= b_advance + 1;
                if (dbg_stage_b_bytes_done) b_done_true  <= b_done_true + 1;
                else                        b_done_false <= b_done_false + 1;
            end
            if (pcm_valid) begin
                pcm_samples <= pcm_samples + 1;
                if (^{pcm_left,pcm_right} === 1'bx) x_hits <= x_hits + 1;
                else begin
                    if (abs16(pcm_left) > max_abs_out) max_abs_out <= abs16(pcm_left);
                    if (pcm_left>=16'sh7FF0 || pcm_left<=-16'sh7FF0) rail_hits<=rail_hits+1;
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
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1'b1;
        @(negedge clk); reg_wr=1'b0;
    endtask
    // Configure slot s: wave 5, oct, fn=0, TL=0, pan=center, keyon, AR=15
    task setup_slot(input int s, input [3:0] oct);
        write_reg(8'(8'h08 + 0*24 + s), 8'd5);            // wave
        write_reg(8'(8'h08 + 1*24 + s), 8'h00);           // fn low / wave[8]
        write_reg(8'(8'h08 + 2*24 + s), 8'(oct << 4));    // oct, fn[9:7]
        write_reg(8'(8'h08 + 3*24 + s), 8'h00);           // TL
        write_reg(8'(8'h08 + 6*24 + s), 8'hF0);           // AR=15
        write_reg(8'(8'h08 + 4*24 + s), 8'h80);           // keyon, pan center
    endtask
    task frames(input int n);
        repeat (n * 1948) @(posedge clk);
    endtask
    task reset_counts();
        b_done_true=0; b_done_false=0; b_advance=0;
        pcm_samples=0; x_hits=0; rail_hits=0; max_abs_out=0;
    endtask

    task run_n_slots(input int n, input [7:0] lat, input logic varlat, input string label);
        real rate;
        // full reset between sub-tests
        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);
        LATENCY = lat; VARLAT = varlat;
        write_reg(8'h02, 8'h00);
        for (int s = 0; s < n; s++) setup_slot(s, 4'(s % 6));  // varied octaves
        // let HF settle for all slots
        frames(8);
        reset_counts();
        frames(40);
        rate = (b_advance > 0) ? (100.0 * b_done_true / b_advance) : 0.0;
        $display("  [%s] N=%0d lat=%0d: advances=%0d done=%0d fail=%0d rate=%0.1f%%  pcm=%0d rail=%0d x=%0d maxout=0x%h",
                 label, n, lat, b_advance, b_done_true, b_done_false, rate,
                 pcm_samples, rail_hits, x_hits, max_abs_out);
        check($sformatf("%s: stage_b bytes_done >= 95%%", label),
              b_advance > 0 && (b_done_true*100) >= (b_advance*95));
        check($sformatf("%s: no X on output", label), x_hits == 0);
    endtask

    initial begin
        // Fixed-latency sweep at 24 slots — find the window-miss threshold.
        run_n_slots(3,  8'd6,  1'b0, "3slot/lat6");
        run_n_slots(24, 8'd6,  1'b0, "24slot/lat6");
        run_n_slots(24, 8'd7,  1'b0, "24slot/lat7");
        run_n_slots(24, 8'd8,  1'b0, "24slot/lat8");
        // Variable latency [4..max] — emulates real ch2 contention jitter.
        // Expect PARTIAL bytes_done (some slots ok, some fail) → garbage
        // samples in the half-filled buffers = the "noise" signature.
        run_n_slots(24, 8'd10, 1'b1, "24slot/var4-10");
        run_n_slots(24, 8'd14, 1'b1, "24slot/var4-14");

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        $display("(NOTE: failures here are the bandwidth-starvation finding, expected)");
        $finish;
    end
    initial begin #80ms; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
