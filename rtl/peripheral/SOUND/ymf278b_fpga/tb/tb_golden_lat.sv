// PCM golden-comparison TB: drives ymf278_pcm_engine2 from a register script
// and dumps one "<L> <R>" line per audio frame.  The same script + memory go
// through sim/golden/golden_pcm.py (YMF278.cc-derived model with RTL frame
// semantics); compare_pcm.py diffs the streams.
//
// plusargs:
//   +script=<file>   lines: <frame> <addr_hex> <data_hex> [<apply_cycle>]
//   +mem=<file>      $readmemh byte file (one hex byte per line)
//   +frames=<n>
//   +out=<file>
//
// Writes for frame N are applied during frame N-1, each at its apply_cycle
// (default 1000, mid service window), so they are in force when frame N's
// slots dispatch — the golden model's "apply before frame" semantics.
// apply_cycle 1780 lands past the header-fetch start deadline and models the
// worst-case real write timing (any hf_pending starves into frame N).
`timescale 1ns/1ps

module tb_golden_lat;
    logic clk = 0;
    always #5.82 clk = ~clk;          // 85.909 MHz
    logic rst_n = 0;

    logic [7:0] reg_addr = 0, reg_data = 0;
    logic       reg_wr = 0;
    logic [21:0] mem_addr;
    logic        mem_rd_en, mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic [7:0]  mem_rd_data;
    logic [15:0] mem_rd_data16;
    logic        mem_rd_valid;
    logic signed [15:0] pcm_l, pcm_r;
    logic        pcm_v;

    // Latency memory model: replicates msx.sv's pcm_state bridge FSM + the
    // SDRAM ch4 round-trip latency that the instant model hides.  +lat=N sets
    // the ch4 ready latency (cycles); +cpu=M holds ch4 busy M of every 64
    // cycles (models the CPU's absolute SDRAM priority starving PCM).  This is
    // the dimension the bit-exact golden harness structurally cannot see.
    logic        mem_busy;
    int LAT = 0, CPU = 0;
    initial begin
        void'($value$plusargs("lat=%d", LAT));
        void'($value$plusargs("cpu=%d", CPU));
    end

    logic [7:0]  mem [0:4194303];
    logic [21:0] lat_addr;
    logic [15:0] lat_dout16;
    logic [7:0]  lat_dout;
    logic        ch4_req, ch4_ready, ch4_req_prev;
    logic [1:0]  pcm_state;
    logic        mem_rd_en_prev;
    int          sdram_lat, cpu_ctr;
    logic        cpu_hold;

    assign ch4_req = (pcm_state == 2'd1) || (pcm_state == 2'd2);

    always_ff @(posedge clk) begin               // bridge FSM (verbatim msx.sv)
        if (!rst_n) begin
            pcm_state <= 0; mem_rd_en_prev <= 0; lat_addr <= 0;
        end else begin
            mem_rd_en_prev <= mem_rd_en;
            case (pcm_state)
                2'd0: if (mem_rd_en && !mem_rd_en_prev) begin pcm_state <= 1; lat_addr <= mem_addr; end
                2'd1: if (!ch4_ready) pcm_state <= 2;
                2'd2: if (ch4_ready)  pcm_state <= 3;
                2'd3: pcm_state <= 0;
            endcase
        end
    end
    assign mem_rd_valid  = (pcm_state == 2'd3);
    assign mem_busy      = (pcm_state != 2'd0) || cpu_hold;
    assign mem_rd_data   = lat_dout;
    assign mem_rd_data16 = lat_dout16;

    always_ff @(posedge clk) begin               // periodic CPU contention
        if (!rst_n) begin cpu_ctr <= 0; cpu_hold <= 0; end
        else begin
            cpu_ctr <= (cpu_ctr == 63) ? 0 : cpu_ctr + 1;
            if (CPU > 0 && cpu_ctr == 0) cpu_hold <= 1;
            else if (cpu_ctr >= CPU)     cpu_hold <= 0;
        end
    end

    always_ff @(posedge clk) begin               // ch4 ready/latency (verbatim msx.sv)
        if (!rst_n) begin
            ch4_ready <= 1; sdram_lat <= 0; ch4_req_prev <= 0;
            lat_dout <= 0; lat_dout16 <= 0;
        end else begin
            ch4_req_prev <= ch4_req;
            if (ch4_req && !ch4_req_prev) begin
                ch4_ready <= 0;
                sdram_lat <= (LAT < 1) ? 1 : LAT;
            end else if (sdram_lat != 0) begin
                sdram_lat <= sdram_lat - 1;
                if (sdram_lat == 1) begin
                    ch4_ready  <= 1;
                    lat_dout   <= mem[lat_addr[21:0]];
                    lat_dout16 <= {mem[{lat_addr[21:1],1'b1}], mem[{lat_addr[21:1],1'b0}]};
                end
            end
        end
        if (mem_wr_en) mem[mem_addr[21:0]] <= mem_wr_data;
    end

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(1'b0),
        .cpu_mem_rd_data(), .cpu_mem_busy(), .reg02_readback(),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(mem_busy),
        .pcm_vol(2'd3),                          // shift 0 → raw saturated sum
        .pcm_left(pcm_l), .pcm_right(pcm_r), .pcm_valid(pcm_v),
        .dbg_wavetblhdr(), .dbg_hf_pending(),
        .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(),
        .dbg_slot0_pan(), .dbg_slot0_ar(), .dbg_slot0_d1r(),
        .dbg_slot5_wave(), .dbg_slot23_wave(),
        .dbg_slot0_hdr_start(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits()
    );

    // script storage
    int s_frame [0:16383];
    int s_addr  [0:16383];
    int s_data  [0:16383];
    int s_wcyc  [0:16383];     // apply cycle within the previous frame
    int n_writes = 0;
    int frames = 100;
    int fd_out;

    initial begin
        string script_f, mem_f, out_f;
        int fd, fr, ad, da, wc, code;
        if (!$value$plusargs("script=%s", script_f)) script_f = "script.txt";
        if (!$value$plusargs("mem=%s", mem_f))       mem_f    = "mem.hex";
        if (!$value$plusargs("out=%s", out_f))       out_f    = "out_rtl.txt";
        void'($value$plusargs("frames=%d", frames));

        $readmemh(mem_f, mem);

        fd = $fopen(script_f, "r");
        if (fd == 0) begin $display("FATAL: no script"); $finish; end
        begin
            string ln;
            while ($fgets(ln, fd)) begin     // line-at-a-time: a malformed or
                code = $sscanf(ln, "%d %h %h %d", fr, ad, da, wc);   // 3-column
                if (code >= 3) begin         // line can't desync/hang the parse
                    s_frame[n_writes] = fr; s_addr[n_writes] = ad; s_data[n_writes] = da;
                    s_wcyc[n_writes]  = (code == 4) ? wc : 1000;
                    n_writes++;
                end
            end
        end
        $fclose(fd);
        $display("script: %0d writes, %0d frames", n_writes, frames);

        fd_out = $fopen(out_f, "w");

        repeat (8) @(negedge clk);
        rst_n = 1;
        repeat (8) @(negedge clk);
    end

    // frame counter + write applier + dumper
    int cur_frame = 0;     // frame currently being generated
    int wi = 0;
    logic running = 0;
    always @(posedge clk) if (rst_n) running <= 1;

    // apply frame (cur_frame+1)'s writes during cur_frame, each at its own
    // s_wcyc cycle (scripts are sorted by frame then cycle)
    always @(posedge clk) begin
        if (running) begin
            while (wi < n_writes && s_frame[wi] == cur_frame + 1
                   && s_wcyc[wi] <= int'(dut.frame_cycle)) begin
                do_write(s_addr[wi][7:0], s_data[wi][7:0]);
                wi++;
            end
        end
    end

    task automatic do_write(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr = a; reg_data = d; reg_wr = 1;
        @(negedge clk); reg_wr = 0;
        @(negedge clk);
    endtask

    // frame-0 writes: apply before the engine leaves reset-adjacent frame 0
    initial begin
        wait (rst_n);
        @(negedge clk);
        while (wi < n_writes && s_frame[wi] == 0) begin
            do_write(s_addr[wi][7:0], s_data[wi][7:0]);
            wi++;
        end
    end

    // slot census: per frame count run-dispatches (slots that entered the
    // pipeline) vs SL_ACC completions (slots that produced output).  A gap =
    // slots abandoned mid-flight at frame end (the latency-induced drop).
    int frames_seen = 0, run_total = 0, acc_total = 0;
    int run_this = 0, acc_this = 0, frames_short = 0;
    logic acc_d, idle_run_d;
    always @(posedge clk) begin
        acc_d <= (dut.sl_state == dut.SL_ACC);
        idle_run_d <= dut.dispatch_now && dut.ld_run;
        if (running) begin
            if (dut.dispatch_now && dut.ld_run) run_this <= run_this + 1;
            if (dut.sl_state == dut.SL_ACC && !acc_d) acc_this <= acc_this + 1;
            if (dut.frame_cycle == 11'd1947) begin
                frames_seen <= frames_seen + 1;
                run_total <= run_total + run_this;
                acc_total <= acc_total + acc_this;
                if (acc_this < run_this) frames_short <= frames_short + 1;
                run_this <= 0; acc_this <= 0;
            end
        end
    end
    final $display("SLOTCENSUS frames=%0d dispatched=%0d completed=%0d dropped=%0d frames_short=%0d",
                   frames_seen, run_total, acc_total, run_total-acc_total, frames_short);

`ifdef DBG_XTRACE
    // X-origin tracer: dump slot pipeline values while the accumulator is X
    always @(posedge clk) begin
        if (cur_frame >= 38 && cur_frame <= 41) begin
            if (dut.sl_state == dut.SL_DECODE)
                $display("XT f=%0d slot=%0d bits=%b start=%h pos2=%h a0=%h b0=%h needb=%b w0=%h w1=%h w2=%h w3=%h",
                         cur_frame, dut.w_slot, dut.w_hdr.bits, dut.w_hdr.startAddr,
                         dut.w_pos2, dut.w_a0, dut.w_b0, dut.w_need_b,
                         dut.w_word[0], dut.w_word[1], dut.w_word[2], dut.w_word[3]);
            if (dut.sl_state == dut.SL_INTERP)
                $display("XT f=%0d slot=%0d sa=%h sb=%h", cur_frame, dut.w_slot, dut.w_sa, dut.w_sb);
            if (dut.sl_state == dut.SL_ACC)
                $display("XT f=%0d slot=%0d ACC l=%h r=%h", cur_frame, dut.w_slot, dut.accum_l, dut.accum_r);
        end
    end
`endif
`ifdef DBG_GOLDEN
    always @(posedge clk) begin
        if (dut.dispatch_now && dut.ld_slot == 0 && cur_frame < 4)
            $display("DBG f=%0d cyc=%0d slot0 ld_run=%b retrig=%b hfpend=%b env=%0d",
                     cur_frame, dut.frame_cycle, dut.ld_run, dut.key_retrig[0],
                     dut.hf_pending[0], dut.ld_dyn_c.env_state);
        if (reg_wr && cur_frame < 4)
            $display("DBG f=%0d cyc=%0d WRITE %02x=%02x", cur_frame, dut.frame_cycle, reg_addr, reg_data);
        if (cur_frame == 0 && dut.frame_cycle >= 11'd1000 && dut.frame_cycle < 11'd1100 && (dut.frame_cycle % 11'd8) == 0)
            $display("DBG cyc=%0d sv=%0d hfp=%b found=%b slots_done=%b cur_slot=%0d",
                     dut.frame_cycle, dut.sv_state, dut.hf_pending[0], dut.hf_found, dut.slots_done, dut.cur_slot);
    end
`endif
    always @(posedge clk) begin
        if (pcm_v && running) begin
            $fdisplay(fd_out, "%0d %0d", $signed(pcm_l), $signed(pcm_r));
            cur_frame <= cur_frame + 1;
            if (cur_frame + 1 >= frames) begin
                $fclose(fd_out);
                $display("RTL: %0d frames done", frames);
                $finish;
            end
        end
    end

    initial begin
        #800ms;
        $display("FATAL: timeout");
        $finish;
    end
endmodule
