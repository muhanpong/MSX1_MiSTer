// ymf278b_top with audio_mode = 1 playing an openMSX port log: FM (the OPL3) and ADPCM
// together, as the core mixes them.  +script=<file> lines: "<time ns> W|R <port hex> <data hex>"
// (omsx2script.py top); +pcm=<file> gets the output, s16le stereo, one frame per audio_valid.
`timescale 1ns/1ps
`ifndef DIV
 `define DIV 9
`endif
`ifndef RAM_AW
 `define RAM_AW 15
`endif
module tb;
    localparam int CLK_HZ = 128863636;
    logic clk = 0; always #(3.88 * 9 / `DIV) clk = ~clk;
    logic [3:0] dv = 0; logic clk_opl3 = 0;
    //  clk : clk_opl3 is 9 in the core.  -DDIV=3 runs three times faster; the samples do not
    //  depend on it, but an FM write can land one sample apart (file 14: 4217 of 395466
    //  samples differ, one 85 ms stretch).  Use 9 for anything that is compared.
    always @(posedge clk) begin dv <= (dv == `DIV - 1) ? 4'd0 : dv + 4'd1; clk_opl3 <= (dv < `DIV / 2); end
    //  +sdram: the sample RAM through a model of msx.sv's ch4 bridge (read on a rising
    //  request, write on a level, about 20 clocks each) into a 4 MB memory
    logic use_sdram; initial use_sdram = $test$plusargs("sdram");
    wire [21:0] m_addr; wire m_rd, m_wr; wire [7:0] m_d;
    logic [7:0] m_mem [0:(1 << 22) - 1]; logic [7:0] m_q; logic m_valid = 0, m_rd_q = 0, m_w = 0;
    int m_st = 0;
    always @(posedge clk) begin
        m_valid <= 0; m_rd_q <= m_rd;
        if (m_st == 0) begin
            if (m_rd & ~m_rd_q) begin m_w <= 0; m_st <= 1; end
            else if (m_wr)      begin m_w <= 1; m_st <= 1; end
        end
        else if (m_st == 20) begin
            if (m_w) m_mem[m_addr] <= m_d; else begin m_q <= m_mem[m_addr]; m_valid <= 1; end
            m_st <= 0;
        end
        else m_st <= m_st + 1;
    end
    logic rst_n = 0; logic fm_mute;
    logic [7:0] io_port = 0, io_din = 0; logic io_wr = 0, io_rd = 0;
    wire  [7:0] io_dout, status; wire io_ack, irq_n;
    wire signed [15:0] al, ar; wire av;

    ymf278b_top #(.CLK_HZ(CLK_HZ), .CLK_OPL3(14318182), .YA_RAM_AW(`RAM_AW)) dut (
        .clk(clk), .clk_opl3(clk_opl3), .rst_n(rst_n),
        .io_port(io_port), .io_data_in(io_din), .io_wr(io_wr), .io_rd(io_rd),
        .io_data_out(io_dout), .io_ack(io_ack),
        .status_export(status), .status_rd_notify(1'b0),
        .mem_addr(m_addr), .mem_rd_req(m_rd), .mem_rd_data(m_q), .mem_rd_data16(16'h0), .mem_rd_data16b(16'h0),
        .mem_rd_valid(m_valid), .mem_wr_req(m_wr), .mem_wr_data(m_d), .mem_busy(m_st != 0),
        .audio_left(al), .audio_right(ar), .audio_valid(av), .irq_n(irq_n),
        .pcm_mute(1'b0), .fm_mute(fm_mute), .pcm_vol(4'd0), .fm_vol(4'd0),      // the OSD defaults
        .audio_mode_i(1'b1), .ya_sdram_i(use_sdram), .adpcm_mute(1'b0), .adpcm_vol(4'd0),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(), .dbg_keyon_count(),
        .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(), .dbg_pcm_base_set(), .dbg_slot_keyon(),
        .dbg_slot_active(), .dbg_slot_envlive(), .dbg_slot0_hdr_start(), .dbg_slot0_dyn_pos(),
        .dbg_slot0_dyn_env_vol(), .dbg_slot0_dyn_env_state(), .dbg_ack_stopped());

    initial fm_mute = $test$plusargs("fmmute");   // ADPCM alone
    int fo, frames = 0, late = 0;
    //  audio_valid stays up for the nine clocks of one clk_opl3 period: one frame per burst
    logic av_q = 0;
    always @(posedge clk) begin
        av_q <= av;
        if (av_q & ~av) begin $fwrite(fo, "%c%c%c%c", al[7:0], al[15:8], ar[7:0], ar[15:8]); frames++; end
    end
    string script, pcm, cmd; int fi, r, p, d; longint t;
    initial begin
        if (!$value$plusargs("script=%s", script)) $fatal(1, "no +script");
        if (!$value$plusargs("pcm=%s", pcm)) $fatal(1, "no +pcm");
        fi = $fopen(script, "r"); fo = $fopen(pcm, "wb");
        repeat (200) @(posedge clk); rst_n = 1; repeat (4000) @(posedge clk);
        while (!$feof(fi)) begin
            r = $fscanf(fi, "%d %s %h %h", t, cmd, p, d);
            if (r != 4) break;
            if ($time > t + 100000) late++;                 // more than 100 us behind the log
            while ($time < t) @(posedge clk);
            @(posedge clk); io_port <= p[7:0]; io_din <= d[7:0]; io_wr <= (cmd == "W"); io_rd <= (cmd == "R");
            @(posedge clk); io_wr <= 0; io_rd <= 0;
            while (!io_ack) @(posedge clk);
        end
        $fclose(fo);
        $display("REPLAY frames %0d, accesses later than 100 us: %0d", frames, late);
        $finish;
    end
endmodule
