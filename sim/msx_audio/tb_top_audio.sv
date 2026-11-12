// ymf278b_top with audio_mode = 1 (MSX-AUDIO): detection, sample RAM, FM and ADPCM levels.
`timescale 1ns/1ps
module tb;
    localparam int CLK_HZ = 128863636;
    logic clk = 0; always #3.88 clk = ~clk;
    logic [3:0] dv = 0; logic clk_opl3 = 0;
    always @(posedge clk) begin dv <= (dv == 8) ? 4'd0 : dv + 4'd1; clk_opl3 <= (dv < 4); end
    logic rst_n = 0;
    logic [7:0] io_port = 0, io_din = 0; logic io_wr = 0, io_rd = 0;
    wire  [7:0] io_dout, status; wire io_ack, irq_n;
    wire signed [15:0] al, ar; wire av;
    logic adpcm_mute = 0, fm_mute = 0; logic [3:0] adpcm_vol = 4'd3, fm_vol = 4'd3;      // both rows at their 0dB entry

    ymf278b_top #(.CLK_HZ(CLK_HZ), .CLK_OPL3(14318182)) dut (
        .clk(clk), .clk_opl3(clk_opl3), .rst_n(rst_n),
        .io_port(io_port), .io_data_in(io_din), .io_wr(io_wr), .io_rd(io_rd),
        .io_data_out(io_dout), .io_ack(io_ack),
        .status_export(status), .status_rd_notify(1'b0),
        .mem_addr(), .mem_rd_req(), .mem_rd_data(8'h00), .mem_rd_data16(16'h0), .mem_rd_data16b(16'h0),
        .mem_rd_valid(1'b0), .mem_wr_req(), .mem_wr_data(), .mem_busy(1'b0),
        .audio_left(al), .audio_right(ar), .audio_valid(av), .irq_n(irq_n),
        .pcm_mute(1'b0), .fm_mute(fm_mute), .pcm_vol(4'd0), .fm_vol(fm_vol),
        .audio_mode(1'b1), .adpcm_mute(adpcm_mute), .adpcm_vol(adpcm_vol),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(), .dbg_keyon_count(),
        .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(), .dbg_pcm_base_set(), .dbg_slot_keyon(),
        .dbg_slot_active(), .dbg_slot_envlive(), .dbg_slot0_hdr_start(), .dbg_slot0_dyn_pos(),
        .dbg_slot0_dyn_env_vol(), .dbg_slot0_dyn_env_state(), .dbg_ack_stopped());

    logic [7:0] rv;
    task automatic iow(input [7:0] p, input [7:0] d);
        @(posedge clk); io_port <= p; io_din <= d; io_wr <= 1;
        @(posedge clk); io_wr <= 0;
        while (!io_ack) @(posedge clk);
        repeat (40) @(posedge clk);
    endtask
    task automatic ior(input [7:0] p);
        @(posedge clk); io_port <= p; io_rd <= 1;
        @(posedge clk); io_rd <= 0;
        while (!io_ack) @(posedge clk);
        @(posedge clk); rv = io_dout;
        repeat (40) @(posedge clk);
    endtask
    task automatic rw(input [7:0] a, input [7:0] d); iow(8'hC0, a); iow(8'hC1, d); endtask
    task automatic rr(input [7:0] a); iow(8'hC0, a); ior(8'hC1); endtask

    int pk, mn, mx, right_diff = 0;
    logic meas = 0;
    always @(posedge clk) if (av && meas) begin
        if (al > mx) mx = al; if (al < mn) mn = al;
        if (al != ar) right_diff++;
    end
    task automatic measure(input int ms);
        mn = 0; mx = 0; meas = 1; #(ms * 1ms); meas = 0; pk = (mx > -mn) ? mx : -mn;
    endtask

    int fails = 0, fm_pk, ad_pk, i;
    initial begin
        repeat (200) @(posedge clk); rst_n = 1; repeat (2000) @(posedge clk);

        // --- detection: status after reset, timer 1 flag and IRQ
        if ((status & 8'hF9) != 8'h00 && status != 8'h0E) begin $display("FAIL reset status %02x", status); fails++; end
        $display("status after reset %02x (io read:", status); ior(8'hC0); $display("  %02x)", rv);
        rw(8'h04, 8'h80); rw(8'h02, 8'hFF); rw(8'h04, 8'h01);   // T1 start, nothing masked
        #200us;
        $display("status with T1 expired %02x irq_n=%b", status, irq_n);
        if (!(status[7] && status[6]) || irq_n) begin $display("FAIL timer1"); fails++; end
        rw(8'h04, 8'h80); #1us;
        rw(8'h04, 8'h08);                       // timers stopped, only BUF RDY masked
        if (status[6] || !irq_n) begin $display("FAIL timer1 clear %02x", status); fails++; end

        // --- sample RAM write and read back (32 KB block RAM), and above 32 KB
        rw(8'h07, 8'h01); rw(8'h07, 8'h60);
        rw(8'h09, 8'h10); rw(8'h0A, 8'h00); rw(8'h0B, 8'h11); rw(8'h0C, 8'h00);
        for (i = 0; i < 8; i++) rw(8'h0F, 8'hA0 + i);
        if (!status[4]) begin $display("FAIL no EOS after RAM write %02x", status); fails++; end
        rw(8'h07, 8'h01); rw(8'h07, 8'h20);
        rw(8'h09, 8'h10); rw(8'h0A, 8'h00); rw(8'h0B, 8'h11); rw(8'h0C, 8'h00);
        rr(8'h0F); rr(8'h0F);
        for (i = 0; i < 8; i++) begin rr(8'h0F); if (rv != 8'hA0 + i) begin $display("FAIL RAM[%0d] = %02x", i, rv); fails++; end end
        rw(8'h07, 8'h01); rw(8'h07, 8'h60);
        rw(8'h09, 8'h00); rw(8'h0A, 8'h20); rw(8'h0B, 8'h00); rw(8'h0C, 8'h20);   // byte 0x8000: outside
        rw(8'h0F, 8'h55);
        rw(8'h07, 8'h01); rw(8'h07, 8'h20);
        rw(8'h09, 8'h00); rw(8'h0A, 8'h20); rw(8'h0B, 8'h00); rw(8'h0C, 8'h20);
        rr(8'h0F); rr(8'h0F); rr(8'h0F);
        if (rv != 8'h00) begin $display("FAIL read above 32 KB = %02x", rv); fails++; end
        rw(8'h07, 8'h01);

        // --- FM: one channel, carrier only, full level
        rw(8'h20, 8'h01); rw(8'h23, 8'h01); rw(8'h40, 8'h3F); rw(8'h43, 8'h00);
        rw(8'h60, 8'hF0); rw(8'h63, 8'hF0); rw(8'h80, 8'h00); rw(8'h83, 8'h00);
        rw(8'hE3, 8'h03);                       // waveform select: must be ignored
        rw(8'hC0, 8'h01); rw(8'hA0, 8'h98); rw(8'hB0, 8'h31);
        #5ms; measure(15); fm_pk = pk;
        $display("FM one channel peak %0d (min %0d max %0d) L!=R %0d", fm_pk, mn, mx, right_diff);
        if (fm_pk < 200) begin $display("FAIL FM silent"); fails++; end
        if (mx + mn > fm_pk / 8 || mx + mn < -fm_pk / 8) begin $display("FAIL FM not symmetric (waveform select leaked?)"); fails++; end
        if (right_diff != 0) begin $display("FAIL FM left != right"); fails++; end
        rw(8'hB0, 8'h11); rw(8'h43, 8'h3F); #20ms;

        // --- ADPCM from the CPU: 0x7 nibbles then 0xF nibbles = a ramp to both rails
        rw(8'h10, 8'h00); rw(8'h11, 8'h40); rw(8'h12, 8'hFF); rw(8'h07, 8'h80);
        meas = 1; mn = 0; mx = 0;
        for (i = 0; i < 60; i++) begin rw(8'h0F, (i % 20 < 10) ? 8'h77 : 8'hFF); #160us; end
        meas = 0; ad_pk = (mx > -mn) ? mx : -mn;
        $display("ADPCM full-scale peak %0d (min %0d max %0d)", ad_pk, mn, mx);
        if (ad_pk < 200) begin $display("FAIL ADPCM silent"); fails++; end
        adpcm_mute = 1; fm_mute = 1; #2ms; measure(3);
        if (pk > 8) begin $display("FAIL ADPCM mute leaves %0d", pk); fails++; end
        $display("RATIO adpcm/fm = %0d / %0d", ad_pk, fm_pk);
        //  openMSX: ADPCM full scale 2040, one FM channel 2047 -> equal within 1 dB at equal trims
        if (ad_pk * 10 < fm_pk * 9 || ad_pk * 10 > fm_pk * 11) begin $display("FAIL ADPCM / FM balance"); fails++; end
        if (fails == 0) $display("TOP PASS"); else $display("TOP FAIL");
        $finish;
    end
endmodule
