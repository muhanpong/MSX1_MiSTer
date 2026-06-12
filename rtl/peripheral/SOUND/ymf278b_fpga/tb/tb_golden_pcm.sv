// PCM golden-comparison TB: drives ymf278_pcm_engine2 from a register script
// and dumps one "<L> <R>" line per audio frame.  The same script + memory go
// through sim/golden/golden_pcm.py (YMF278.cc-derived model with RTL frame
// semantics); compare_pcm.py diffs the streams.
//
// plusargs:
//   +script=<file>   lines: <frame> <addr_hex> <data_hex>
//   +mem=<file>      $readmemh byte file (one hex byte per line)
//   +frames=<n>
//   +out=<file>
//
// Writes for frame N are applied during frame N-1's service window
// (frame_cycle == 1800), so they are in force when frame N's slots dispatch —
// identical to the golden model's "apply before frame" semantics.
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

    // instant, deterministic memory (2MB)
    logic [7:0] mem [0:2097151];
    always_ff @(posedge clk) begin
        mem_rd_valid <= 1'b0;
        if (mem_rd_en) begin
            mem_rd_data   <= mem[mem_addr[20:0]];
            mem_rd_data16 <= {mem[{mem_addr[20:1], 1'b1}], mem[{mem_addr[20:1], 1'b0}]};
            mem_rd_valid  <= 1'b1;
        end
        if (mem_wr_en) mem[mem_addr[20:0]] <= mem_wr_data;
    end

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(1'b0),
        .cpu_mem_rd_data(), .cpu_mem_busy(), .reg02_readback(),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(1'b0),
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
    int s_frame [0:4095];
    int s_addr  [0:4095];
    int s_data  [0:4095];
    int n_writes = 0;
    int frames = 100;
    int fd_out;

    initial begin
        string script_f, mem_f, out_f;
        int fd, fr, ad, da, code;
        if (!$value$plusargs("script=%s", script_f)) script_f = "script.txt";
        if (!$value$plusargs("mem=%s", mem_f))       mem_f    = "mem.hex";
        if (!$value$plusargs("out=%s", out_f))       out_f    = "out_rtl.txt";
        void'($value$plusargs("frames=%d", frames));

        $readmemh(mem_f, mem);

        fd = $fopen(script_f, "r");
        if (fd == 0) begin $display("FATAL: no script"); $finish; end
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%d %h %h\n", fr, ad, da);
            if (code == 3) begin
                s_frame[n_writes] = fr; s_addr[n_writes] = ad; s_data[n_writes] = da;
                n_writes++;
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

    // apply frame (cur_frame+1)'s writes late in cur_frame's service window
    always @(posedge clk) begin
        if (running && dut.frame_cycle == 11'd1000) begin
            while (wi < n_writes && s_frame[wi] == cur_frame + 1) begin
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
        #400ms;
        $display("FATAL: timeout");
        $finish;
    end
endmodule
