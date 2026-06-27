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

module tb_golden_pcm;
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

    // deterministic memory (4MB — full YMF278 map: ROM low, SRAM at 0x200000).
    // +lat=N models SDRAM ch4 read latency (cycles from mem_rd_en pulse to
    // mem_rd_valid).  LAT=1 (default) == the original instant model (no
    // regression); LAT>1 holds mem_busy during the wait, like the real bridge.
    logic [7:0] mem [0:4194303];
    int          LAT = 1;
    logic        rd_pend = 1'b0;
    int          rd_cnt  = 0;
    logic [21:0] rd_addr;
    initial void'($value$plusargs("lat=%d", LAT));
    wire mem_busy_w = rd_pend;
    always_ff @(posedge clk) begin
        mem_rd_valid <= 1'b0;
        if (mem_rd_en && !rd_pend) begin
            if (LAT <= 1) begin
                mem_rd_data   <= mem[mem_addr[21:0]];
                mem_rd_data16 <= {mem[{mem_addr[21:1], 1'b1}], mem[{mem_addr[21:1], 1'b0}]};
                mem_rd_valid  <= 1'b1;
            end else begin
                rd_pend <= 1'b1;
                rd_cnt  <= LAT - 1;
                rd_addr <= mem_addr[21:0];
            end
        end else if (rd_pend) begin
            if (rd_cnt <= 1) begin
                mem_rd_data   <= mem[rd_addr];
                mem_rd_data16 <= {mem[{rd_addr[21:1], 1'b1}], mem[{rd_addr[21:1], 1'b0}]};
                mem_rd_valid  <= 1'b1;
                rd_pend       <= 1'b0;
            end else rd_cnt <= rd_cnt - 1;
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
        .mem_busy(mem_busy_w),
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
`ifdef DBG_DIRDEP
    always @(posedge clk) begin
        if (cur_frame >= 30 && cur_frame <= 50) begin
            if (dut.frame_cycle == 11'd2)
                $display("DD f=%0d START hfpend0=%b slstate=%0d cur=%0d",
                    cur_frame, dut.hf_pending[0], dut.sl_state, dut.cur_slot);
            if (dut.dispatch_now && dut.ld_slot==0)
                $display("DD f=%0d cyc=%0d DISP ld_run=%b want_hdr=%b retrig=%b hfpend=%b env=%0d",
                    cur_frame, dut.frame_cycle, dut.ld_run, dut.ld_want_hdr,
                    dut.key_retrig[0], dut.hf_pending[0], dut.ld_dyn_c.env_state);
            if (dut.sl_state==dut.SL_STALL_HDR && dut.frame_cycle[4:0]==0)
                $display("DD f=%0d cyc=%0d STALL hfpend0=%b svstate=%0d",
                    cur_frame, dut.frame_cycle, dut.hf_pending[0], dut.sv_state);
            if (dut.wr_sets_hf)
                $display("DD f=%0d cyc=%0d WRSETHF snum=%0d", cur_frame, dut.frame_cycle, dut.wr_snum);
            if (dut.mem_rd_en && (dut.sl_state==dut.SL_F_ISSUE || dut.sv_state==dut.SV_HDR_ISSUE))
                $display("DD f=%0d cyc=%0d RDEN sl_state=%0d sv_state=%0d", cur_frame, dut.frame_cycle, dut.sl_state, dut.sv_state);
            if (dut.hf_store_now)
                $display("DD f=%0d cyc=%0d HFSTORE slot=%0d wave=%0d base=%h buf5=%h buf6=%h end_built=%h",
                    cur_frame, dut.frame_cycle, dut.hf_cur_slot, dut.hf_cur_wave, dut.hf_base,
                    dut.hf_buf[5], dut.hf_buf[6], dut.hf_hdr_built.endAddr);
            if (dut.sv_state==dut.SV_HDR_ISSUE)
                $display("DD f=%0d cyc=%0d HFISSUE widx=%0d rdaddr=%h base=%h",
                    cur_frame, dut.frame_cycle, dut.hf_widx, dut.sv_rd_addr, dut.hf_base);
            if (dut.sl_state==dut.SL_VIB && dut.w_slot==0)
                $display("DD f=%0d VIB pos=%h step=%h env_vol=%0d env_st=%0d hdr_start=%h end=%h",
                    cur_frame, dut.w_dyn.pos, dut.w_dyn.stepPtr, dut.w_dyn.env_vol,
                    dut.w_dyn.env_state, dut.w_hdr.startAddr, dut.w_hdr.endAddr);
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
        #7000ms;
        $display("FATAL: timeout");
        $finish;
    end
endmodule
