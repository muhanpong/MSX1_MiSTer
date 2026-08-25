// Integration TB: drives the FULL ymf278b_top through the real I/O-port path
// (OUT 0x7E select / 0x7F data, with the io_ack handshake = CPU WAIT_n), the
// same path vgmplay uses on hardware — which the engine-direct golden harness
// bypasses.  Replays the ST04O register stream and dumps audio per audio_valid
// so it can be diffed against ref278 (the real-chip reference).
//
//   plusargs: +script=<f> (frame regHex dataHex [cyc]), +mem=<hex>, +frames=N,
//             +out=<f>, +lat=N (ch4 latency cycles)
`timescale 1ns/1ps
module tb_integration_io;
    localparam real CLK_PERIOD      = 1e9 / 85909090.0;   // master = clk_sdram
    localparam real CLK_OPL3_PERIOD = 1e9 / 14318180.0;

    logic clk = 0, clk_opl3 = 0, rst_n = 0;
    always #(CLK_PERIOD/2.0)      clk      = ~clk;
    always #(CLK_OPL3_PERIOD/2.0) clk_opl3 = ~clk_opl3;

    logic [7:0]  io_port = 0, io_data_in = 0;
    logic        io_wr = 0, io_rd = 0;
    logic [7:0]  io_data_out;
    logic        io_ack;
    logic [21:0] mem_addr;
    logic        mem_rd_req;
    logic [7:0]  mem_rd_data;
    logic [15:0] mem_rd_data16;
    logic        mem_rd_valid;
    logic        mem_wr_req;
    logic [7:0]  mem_wr_data;
    logic        mem_busy;
    logic signed [15:0] audio_left, audio_right;
    logic        audio_valid, irq_n;
    wire  [7:0]  status_export;
    wire         status_rd_notify = 1'b0;
    wire         pcm_mute = 1'b0, fm_mute = 1'b0;
    wire  [1:0]  pcm_vol  = 2'd3;          // shift 0 → raw mix (match ref278)

    // ── latency memory model (verbatim msx.sv bridge + ch4 latency) ──────────
    int LAT = 6;
    initial void'($value$plusargs("lat=%d", LAT));
    logic [7:0]  mem [0:4194303];
    logic [21:0] lat_addr;
    logic        ch4_req, ch4_ready = 1, ch4_req_prev;
    logic [1:0]  pcm_state;
    logic        mrr_prev;
    int          sdram_lat;
    assign ch4_req = (pcm_state == 2'd1) || (pcm_state == 2'd2);
    always_ff @(posedge clk) begin
        if (!rst_n) begin pcm_state<=0; mrr_prev<=0; lat_addr<=0; end
        else begin
            mrr_prev <= mem_rd_req;
            case (pcm_state)
                2'd0: if (mem_rd_req && !mrr_prev) begin pcm_state<=1; lat_addr<=mem_addr; end
                2'd1: if (!ch4_ready) pcm_state<=2;
                2'd2: if (ch4_ready)  pcm_state<=3;
                2'd3: pcm_state<=0;
            endcase
        end
    end
    assign mem_rd_valid = (pcm_state == 2'd3);
    assign mem_busy     = (pcm_state != 2'd0);
    always_ff @(posedge clk) begin
        if (!rst_n) begin ch4_ready<=1; sdram_lat<=0; ch4_req_prev<=0; mem_rd_data<=0; mem_rd_data16<=0; end
        else begin
            ch4_req_prev <= ch4_req;
            if (ch4_req && !ch4_req_prev) begin ch4_ready<=0; sdram_lat<=(LAT<1)?1:LAT; end
            else if (sdram_lat!=0) begin
                sdram_lat<=sdram_lat-1;
                if (sdram_lat==1) begin
                    ch4_ready<=1;
                    mem_rd_data  <= mem[lat_addr[21:0]];
                    mem_rd_data16<= {mem[{lat_addr[21:1],1'b1}], mem[{lat_addr[21:1],1'b0}]};
                end
            end
        end
        if (mem_wr_req) mem[mem_addr[21:0]] <= mem_wr_data;
    end

    ymf278b_top #(.CLK_HZ(85909090), .CLK_OPL3(14318180)) dut (
        .clk(clk), .clk_opl3(clk_opl3), .rst_n(rst_n),
        .io_port(io_port), .io_data_in(io_data_in), .io_wr(io_wr), .io_rd(io_rd),
        .io_data_out(io_data_out), .io_ack(io_ack),
        .status_export(status_export), .status_rd_notify(status_rd_notify),
        .mem_addr(mem_addr), .mem_rd_req(mem_rd_req), .mem_rd_data(mem_rd_data),
        .mem_rd_data16(mem_rd_data16), .mem_rd_valid(mem_rd_valid),
        .mem_wr_req(mem_wr_req), .mem_wr_data(mem_wr_data), .mem_busy(mem_busy),
        .audio_left(audio_left), .audio_right(audio_right), .audio_valid(audio_valid),
        .irq_n(irq_n), .pcm_mute(pcm_mute), .fm_mute(fm_mute), .pcm_vol(pcm_vol),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(),
        .dbg_keyon_count(), .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(),
        .dbg_pcm_base_set(), .dbg_slot_keyon(), .dbg_slot_active(), .dbg_slot_envlive(),
        .dbg_ack_stopped()
    );

    // ── I/O write with the real ack handshake (CPU held until io_ack) ────────
    task automatic io_w(input [7:0] port, input [7:0] data);
        int guard;
        @(posedge clk); io_port <= port; io_data_in <= data; io_wr <= 1'b1;
        @(posedge clk); io_wr <= 1'b0;
        guard = 0;
        while (!io_ack && guard < 5000) begin @(posedge clk); guard++; end
        @(posedge clk);
    endtask
    // a WAVE register write = select 0x7E then data 0x7F
    task automatic wave_w(input [7:0] reg_n, input [7:0] data);
        io_w(8'h7E, reg_n); io_w(8'h7F, data);
    endtask

    // probe: count + log wave-register writes that actually reach the PCM engine
    int eng_wr_cnt = 0;
    always @(posedge clk) if (dut.u_pcm.reg_wr) begin
        eng_wr_cnt <= eng_wr_cnt + 1;
        if (eng_wr_cnt < 60)
            $display("ENGW #%0d addr=%02h data=%02h", eng_wr_cnt, dut.u_pcm.reg_addr, dut.u_pcm.reg_data);
    end
    int ioack_cnt = 0;
    always @(posedge clk) if (io_ack) ioack_cnt <= ioack_cnt + 1;

    // ── script storage ───────────────────────────────────────────────────────
    int s_frame[0:16383], s_addr[0:16383], s_data[0:16383], n_writes=0, frames=2000;
    int fd_out, wi=0, cur_frame=0;
    string script_f, mem_f, out_f;

    initial begin
        int fd, code; string ln; int fr, ad, da, wc;
        if (!$value$plusargs("script=%s", script_f)) script_f="sc_st04.txt";
        if (!$value$plusargs("mem=%s", mem_f))       mem_f="mem4.hex";
        if (!$value$plusargs("out=%s", out_f))       out_f="out/st04_io.txt";
        void'($value$plusargs("frames=%d", frames));
        $readmemh(mem_f, mem);
        fd = $fopen(script_f, "r");
        while ($fgets(ln, fd)) begin
            code = $sscanf(ln, "%d %h %h %d", fr, ad, da, wc);
            if (code >= 3) begin s_frame[n_writes]=fr; s_addr[n_writes]=ad; s_data[n_writes]=da; n_writes++; end
        end
        $fclose(fd);
        fd_out = $fopen(out_f, "w");
        $display("io-int: %0d writes, %0d frames, lat=%0d", n_writes, frames, LAT);
        repeat (16) @(negedge clk); rst_n = 1;
    end

    // deliver each frame's writes right after the previous frame's sample, paced
    // by the ack handshake (back-to-back = the vgmplay worst case for the path)
    logic running = 0;
    always_ff @(posedge clk) if (rst_n) running <= 1;

    // Tap the PCM engine's 44.1kHz output directly (after the real register
    // path), so it diffs bit-for-bit against ref278 without the OPL3-rate
    // resample the final ymf278b_top mix applies.
    wire        eng_valid = dut.u_pcm.pcm_valid;
    wire signed [15:0] eng_l = dut.u_pcm.pcm_left;
    wire signed [15:0] eng_r = dut.u_pcm.pcm_right;

    int sample_cnt = 0;
    always @(posedge clk) begin
        if (running && eng_valid) begin
            $fdisplay(fd_out, "%0d %0d", eng_l, eng_r);
            sample_cnt <= sample_cnt + 1;
            if (sample_cnt + 1 >= frames) begin $fclose(fd_out); $display("io-int done %0d frames | eng_wr=%0d io_ack=%0d delivered_wi=%0d new2=%b", frames, eng_wr_cnt, ioack_cnt, wi, dut.new2); $finish; end
        end
    end

    // ALSO tap the FINAL ymf278b_top audio output (49.7kHz, after the PCM→OPL3-
    // rate zero-order-hold resample) — the one path never tested before.
    int fd_aud; logic aud_open = 0;
    always @(posedge clk) begin
        if (running && !aud_open) begin fd_aud <= $fopen("out/st04_audio.txt","w"); aud_open <= 1; end
        if (running && aud_open && audio_valid) $fdisplay(fd_aud, "%0d %0d", $signed(audio_left), $signed(audio_right));
    end

    // write-delivery process: NEW2 first (vgmplay OPL4_Reset order), THEN the
    // frame writes — single process so reg 0x02 can never race ahead of NEW2.
    initial begin
        wait (rst_n); repeat (8) @(negedge clk);
        io_w(8'hC6, 8'h05); io_w(8'hC7, 8'h03);   // NEW + NEW2
        repeat (8) @(posedge clk);
        $display("PROBE: new2=%b", dut.new2);
        while (wi < n_writes && s_frame[wi] <= 1) begin
            wave_w(s_addr[wi][7:0], s_data[wi][7:0]); wi++;
        end
        forever begin
            @(posedge eng_valid);
            cur_frame = cur_frame + 1;
            // +2 lead so a key-on's header fetch lands a full frame ahead, matching
            // the golden TB's "apply during the previous frame's service window".
            while (wi < n_writes && s_frame[wi] <= cur_frame + 2) begin
                wave_w(s_addr[wi][7:0], s_data[wi][7:0]); wi++;
            end
        end
    end

    initial begin #2000ms; $display("FATAL timeout"); $fclose(fd_out); $finish; end
endmodule
