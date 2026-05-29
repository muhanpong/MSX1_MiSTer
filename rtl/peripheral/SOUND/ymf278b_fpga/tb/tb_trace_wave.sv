// Track B — reproduce per-instrument sustain bug with REAL yrw801 data.
//
// openMSX trace (/tmp/openmsx.trace.txt) of a BASIC player shows it sets up a
// note with only:  reg 0x68=0x00 (key off) ; 0x20=0x00 (fn lo/wave8) ;
// 0x08=wave# ; 0x68=0x80 (key on).  Everything else (oct, TL, AR/D1R/DL/D2R/
// RR, loop) comes from the HF header backfill.  On hardware wave 0 sustains
// but wave 3 does not — yet both headers carry the SAME envelope
// (AR=15,D1R=0,D2R=0,RR=15 → attack-and-hold).  Only startAddr / loop length
// differ (w0: start 0x1800, loop 42; w3: start 0x11123E, loop 301).
//
// This TB loads the real headers + sample regions, replays the exact register
// sequence for a chosen wave, and reports whether pos loops and whether audio
// stays alive over many frames.
//
`timescale 1ns/1ps
`default_nettype none

module tb_trace_wave;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0; logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    localparam logic [2:0] EG_OFF=0, EG_REL=1, EG_SUS=2, EG_DEC=3, EG_ATT=4;

    logic [7:0]  reg_addr='0, reg_data='0; logic reg_wr=0;
    logic [21:0] mem_addr; logic mem_rd_en;
    logic [7:0]  mem_rd_data; logic [15:0] mem_rd_data16; logic mem_rd_valid;
    logic        mem_wr_en; logic [7:0] mem_wr_data; logic mem_busy;
    logic signed [15:0] pcm_left, pcm_right; logic pcm_valid;

    logic [2:0]  dbg_wavetblhdr; logic [23:0] dbg_hf_pending;
    logic [8:0]  dbg_slot0_wave; logic [9:0] dbg_slot0_fn;
    logic signed [3:0] dbg_slot0_oct;
    logic dbg_slot0_prvb, dbg_slot0_keyon, dbg_slot0_damp;
    logic [3:0] dbg_slot0_pan, dbg_slot0_ar, dbg_slot0_d1r;
    logic [8:0] dbg_slot5_wave, dbg_slot23_wave;
    logic [21:0] dbg_slot0_hdr_start; logic [15:0] dbg_slot0_hdr_loop, dbg_slot0_hdr_end;
    logic [1:0] dbg_slot0_hdr_bits;
    logic [15:0] dbg_slot0_dyn_pos, dbg_slot0_dyn_stepPtr;
    logic [9:0] dbg_slot0_dyn_env_vol; logic [2:0] dbg_slot0_dyn_env_state;
    logic dbg_stage_b_bytes_done, dbg_stage_advance, dbg_stage_b_valid;

    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data), .mem_busy(mem_busy),
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
    logic [1:0] pcm_state; logic mem_rd_en_prev;
    logic ch4_req, ch4_ready; logic [21:0] ch4_addr; logic [7:0] ch4_dout;
    logic [15:0] ch4_dout16;
    assign ch4_req  = (pcm_state==2'd1)||(pcm_state==2'd2);
    assign mem_busy = (pcm_state!=2'd0);
    always_ff @(posedge clk) begin
        if (!rst_n) begin pcm_state<=0; mem_rd_en_prev<=0; ch4_addr<=0; end
        else begin
            mem_rd_en_prev<=mem_rd_en;
            case (pcm_state)
                2'd0: if (mem_rd_en && !mem_rd_en_prev) begin pcm_state<=1; ch4_addr<=mem_addr; end
                2'd1: if (!ch4_ready) pcm_state<=2;
                2'd2: if (ch4_ready)  pcm_state<=3;
                2'd3: pcm_state<=0;
            endcase
        end
    end
    assign mem_rd_data  = ch4_dout;
    assign mem_rd_data16 = ch4_dout16;
    assign mem_rd_valid = (pcm_state==2'd3);

    // ── SDRAM model with REAL yrw801 windows ───────────────────────────────
    // rom must span up to ~0x111630.  Loaded sparsely via @-addressed hex.
    logic [7:0] rom [0:22'h11_2000];
    initial $readmemh("/tmp/yrw801_win.hex", rom);

    logic [3:0] sdram_lat;
    logic ch4_req_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin ch4_ready<=1; sdram_lat<=0; ch4_req_prev<=0; ch4_dout<=0; ch4_dout16<=0; end
        else begin
            ch4_req_prev<=ch4_req;
            if (ch4_req && !ch4_req_prev) begin ch4_ready<=0; sdram_lat<=4'd6; end
            else if (sdram_lat!=0) begin
                sdram_lat<=sdram_lat-4'd1;
                if (sdram_lat==4'd1) begin
                    ch4_ready<=1;
                    ch4_dout  <= rom[ch4_addr];
                    ch4_dout16 <= {rom[{ch4_addr[21:1],1'b1}], rom[{ch4_addr[21:1],1'b0}]};
                end
            end
        end
    end

    // ── Monitors ────────────────────────────────────────────────────────────
    logic [15:0] pos_min, pos_max; int loop_wraps; logic [15:0] prev_pos;
    int    pcm_nz_recent;  // nonzero pcm samples in the current measurement window
    int    pcm_cnt; int frame_ticks; int pcm_x;
    logic [21:0] max_mem_addr, min_mem_addr;
    int slot0_c_valid, slot0_c_total; logic signed [15:0] slot0_interp;
    always_ff @(posedge clk) begin
        // Count slot-0 outcomes as it leaves Stage B → Stage C at stage_advance.
        if (rst_n && dbg_stage_advance && dut.stage_b_reg.slot==5'd0) begin
            slot0_c_total <= slot0_c_total + 1;
            if (dut.stage_b_reg.valid && dut.stage_b_bytes_done) slot0_c_valid <= slot0_c_valid + 1;
            slot0_interp <= dut.interp_val;
        end
        if (mem_rd_en) begin
            if (mem_addr > max_mem_addr) max_mem_addr <= mem_addr;
            if (mem_addr < min_mem_addr) min_mem_addr <= mem_addr;
        end
        if (!rst_n) begin pos_min<=16'hFFFF; pos_max<=0; loop_wraps<=0; prev_pos<=0; pcm_nz_recent<=0; pcm_cnt<=0; end
        else begin
            if (dbg_slot0_dyn_pos < pos_min) pos_min<=dbg_slot0_dyn_pos;
            if (dbg_slot0_dyn_pos > pos_max) pos_max<=dbg_slot0_dyn_pos;
            // a wrap = pos decreased significantly (loop back)
            if (prev_pos > 16'd8 && dbg_slot0_dyn_pos < (prev_pos - 16'd4)) loop_wraps<=loop_wraps+1;
            prev_pos<=dbg_slot0_dyn_pos;
            if (dut.frame_cycle==11'd1947) frame_ticks<=frame_ticks+1;
            if (pcm_valid===1'bx) pcm_x<=pcm_x+1;
            if (pcm_valid===1'b1) begin
                pcm_cnt<=pcm_cnt+1;
                if (pcm_left!=0 || pcm_right!=0) pcm_nz_recent<=pcm_nz_recent+1;
            end
        end
    end

    int passes=0, fails=0;
    task check(string n, logic ok); if(ok)begin $display("PASS: %s",n);passes++;end else begin $display("FAIL: %s",n);fails++;end endtask
    task write_reg(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1; @(negedge clk); reg_wr=0;
    endtask
    task frames(input int n); repeat (n*1948) @(posedge clk); endtask
    task reset_mon(); pos_min=16'hFFFF; pos_max=0; loop_wraps=0; pcm_nz_recent=0; pcm_cnt=0; max_mem_addr=0; min_mem_addr=22'h3FFFFF; slot0_c_valid=0; slot0_c_total=0; frame_ticks=0; pcm_x=0; endtask

    task play_wave(input [7:0] wv, input int nframes, input string label);
        // Full reset so each wave starts clean.
        rst_n=0; repeat(8) @(posedge clk); rst_n=1; repeat(4) @(posedge clk);
        // Trace sequence: key off, fn lo / wave8 = 0, wave = wv, key on.
        write_reg(8'h68, 8'h00);
        write_reg(8'h20, 8'h00);
        write_reg(8'h08, wv);
        write_reg(8'h68, 8'h80);
        // wait for HF header load
        wait (dbg_slot0_hdr_bits != 2'b00 || dbg_slot0_hdr_start != 22'd0);
        repeat (2000) @(posedge clk);
        $display("  [%s wv=%0d] hdr bits=%b start=%h loop=%h end=%h  AR=%0d",
                 label, wv, dbg_slot0_hdr_bits, dbg_slot0_hdr_start,
                 dbg_slot0_hdr_loop, dbg_slot0_hdr_end, dbg_slot0_ar);
        // settle, then measure over a long window (must reach loop point!)
        frames(10);
        reset_mon();
        // periodic progression trace
        for (int k=0; k<6; k++) begin
            frames(nframes/6);
            $display("    .. [%s] t=%0d/6  pos=%0d stepPtr=%h env=%0d hf_pend0=%b pcm_cnt=%0d",
                     label, k+1, dbg_slot0_dyn_pos, dbg_slot0_dyn_stepPtr,
                     dbg_slot0_dyn_env_state, dbg_hf_pending[0], pcm_cnt);
        end
        $display("  [%s wv=%0d] pos[min..max]=%0d..%0d wraps=%0d  env_state=%0d env_vol=%h  pcm nz=%0d/%0d",
                 label, wv, pos_min, pos_max, loop_wraps,
                 dbg_slot0_dyn_env_state, dbg_slot0_dyn_env_vol, pcm_nz_recent, pcm_cnt);
        $display("  [%s wv=%0d] mem_addr[min..max]=%h..%h  slot0 stageC valid=%0d/%0d  last_interp=%h",
                 label, wv, min_mem_addr, max_mem_addr,
                 slot0_c_valid, slot0_c_total, slot0_interp); $display("  [%s wv=%0d] frame_ticks=%0d pcm_valid_ones=%0d pcm_valid_X=%0d", label, wv, frame_ticks, pcm_cnt, pcm_x);
        // Sustain criteria: still producing nonzero audio late in the window,
        // and the position is looping (wrapped at least once).
        check($sformatf("%s: audio still alive (nonzero late)", label), pcm_nz_recent > 0);
        check($sformatf("%s: position loops (wraps>0)", label), loop_wraps > 0);
        check($sformatf("%s: env not OFF", label), dbg_slot0_dyn_env_state != EG_OFF);
    endtask

    initial begin
        // oct=0 → pos advances ~0.5 sample/frame.  wave0 loop=42 (wraps in
        // ~84 frames); wave3 loop=301 (needs ~620 frames to reach + wrap).
        play_wave(8'd0, 200, "WAVE0");
        play_wave(8'd3, 900, "WAVE3");
        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails==0) $display("*** ALL TESTS PASSED ***");
        else          $display("!!! %0d FAILS (sustain bug reproduced) !!!", fails);
        $finish;
    end
    initial begin #200ms; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
