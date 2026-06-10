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

module tb_loopseam;
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

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data), .mem_busy(mem_busy),
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

    // Latency model.  Three modes (plusargs):
    //   default     : fixed `maxlat` cycles per read (original; maxlat=6).
    //   +varlat     : jitter [4..maxlat] per read.
    //   +contention : arbiter model — ch2 (Z80) competes for the bus and ch4
    //                 is lowest priority, EXCEPT during a burst-priority hold
    //                 (+hold=N, mirrors sdram.sv CH4_HOLD).  This reproduces
    //                 the real "first read of a slot pays the queue, rest are
    //                 cheap when hold>0" behavior, so it tests the actual fix
    //                 end-to-end through the engine.  +ch2load=P sets ch2's
    //                 per-cycle bus-demand probability in percent.
    localparam int TXN = 7;          // single SDRAM transaction length (cycles)
    logic [7:0] sdram_lat;
    int         MAXLAT = 6;
    logic       VARLAT = 1'b0;
    logic       CONTEND = 1'b0;
    int         CH2LOAD = 70;        // percent
    int         HOLD = 0;            // ch4 burst-priority hold (0 = off/original)
    logic [7:0] rnd_lat;
    initial begin
        if ($value$plusargs("maxlat=%d", MAXLAT)) ;
        if ($value$plusargs("ch2load=%d", CH2LOAD)) ;
        if ($value$plusargs("hold=%d", HOLD)) ;
        if ($test$plusargs("varlat"))  VARLAT = 1'b1;
        if ($test$plusargs("contention")) CONTEND = 1'b1;
    end

    // ── Contention arbiter model state ──
    int   bus_txn   = 0;   // cycles left in current bus transaction (any channel)
    int   bus_owner = 0;   // 4=ch4, 2=ch2
    logic ch4_pending = 0; // ch4 read requested, not yet delivered
    int   ch4_hold   = 0;  // mirrors sdram.sv ch4_hold_cnt
    int   ch4_wait   = 0;  // measured queue wait for current ch4 read (debug)
    int   ch4_lat_sum=0, ch4_lat_n=0, ch4_lat_max=0;
    logic ch4_req_prev;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ch4_ready<=1; sdram_lat<=0; ch4_req_prev<=0; ch4_dout<=0; ch4_dout16<=0;
            bus_txn<=0; bus_owner<=0; ch4_pending<=0; ch4_hold<=0; ch4_wait<=0;
            ch4_lat_sum<=0; ch4_lat_n<=0; ch4_lat_max<=0;
        end else if (!CONTEND) begin
            // ── original simple/varlat model ──
            ch4_req_prev<=ch4_req;
            if (ch4_req && !ch4_req_prev) begin
                rnd_lat = VARLAT ? 8'(4 + ($unsigned($random) % (MAXLAT-3))) : 8'(MAXLAT);
                ch4_ready<=0; sdram_lat<=rnd_lat;
            end
            else if (sdram_lat!=0) begin
                sdram_lat<=sdram_lat-8'd1;
                if (sdram_lat==8'd1) begin
                    ch4_ready<=1;
                    ch4_dout  <= rom[ch4_addr];
                    ch4_dout16 <= {rom[{ch4_addr[21:1],1'b1}], rom[{ch4_addr[21:1],1'b0}]};
                end
            end
        end else begin
            // ── contention arbiter model ──
            ch4_req_prev<=ch4_req;
            if (ch4_hold != 0) ch4_hold <= ch4_hold - 1;
            // latch a new ch4 read request
            if (ch4_req && !ch4_req_prev) begin
                ch4_pending<=1; ch4_ready<=0; ch4_wait<=0;
            end
            if (ch4_pending && bus_owner!=4) ch4_wait <= ch4_wait + 1;

            if (bus_txn > 1) begin
                bus_txn <= bus_txn - 1;
            end else if (bus_txn == 1) begin
                bus_txn <= 0;
                if (bus_owner==4) begin
                    ch4_ready<=1; ch4_pending<=0;
                    ch4_dout  <= rom[ch4_addr];
                    ch4_dout16 <= {rom[{ch4_addr[21:1],1'b1}], rom[{ch4_addr[21:1],1'b0}]};
                    ch4_lat_sum<=ch4_lat_sum+ch4_wait+TXN; ch4_lat_n<=ch4_lat_n+1;
                    if (ch4_wait+TXN>ch4_lat_max) ch4_lat_max<=ch4_wait+TXN;
                end
                bus_owner<=0;
            end else begin
                // bus free → arbitrate this cycle
                logic ch2_demand; logic ch4_pri;
                ch2_demand = ($unsigned($random)%100) < CH2LOAD;
                ch4_pri    = (ch4_hold != 0) && ch4_pending;
                if (ch4_pending && (ch4_pri || !ch2_demand)) begin
                    bus_txn<=TXN; bus_owner<=4; ch4_hold<=HOLD;   // grant ch4
                end else if (ch2_demand) begin
                    bus_txn<=TXN; bus_owner<=2;                   // grant ch2
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
        if (rst_n && dbg_stage_advance && dut.w_slot==5'd0) begin
            slot0_c_total <= slot0_c_total + 1;
            if (dut.win_had_slot && dut.win_done) slot0_c_valid <= slot0_c_valid + 1;
            slot0_interp <= dut.w_interp;
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

    // ── Loop-seam capture (the [19] fix) ──────────────────────────────────────
    // When slot 0 leaves Stage B with sb_split asserted (loop wrap), sample B is
    // the loop-start chunk in the B-window.  Capture the engine's samp_b and
    // compare to the loop-start sample decoded straight from ROM, and to the OLD
    // buggy value (decode from A's own window) to prove the fix actually moved it.
    int   seam_n=0, seam_ok=0, seam_oldbug=0;
    logic signed [15:0] seam_dut, seam_exp, seam_old;

    // 12-bit decode straight from ROM at byte-start `start`, sample index `pos`.
    function automatic signed [15:0] dec12(input [21:0] start, input [15:0] pos);
        logic [21:0] base; logic [7:0] b0,b1,b2;
        base = start + (22'(pos>>1))*22'd3;
        b0=rom[base]; b1=rom[base+22'd1]; b2=rom[base+22'd2];
        if (pos[0]) dec12 = $signed({b2, b1 & 8'hF0});
        else        dec12 = $signed({b0, 8'((b1<<4) & 16'h00F0)});
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && dbg_stage_advance && dut.w_slot==5'd0
                  && dut.w_need_b && dut.w_hdr.bits==2'd1) begin
            logic signed [15:0] e, o;
            e = dec12(dut.w_hdr.startAddr, dut.w_posb);
            // OLD buggy (A-even ELSE branch): decode from A's window at a pos with
            // A's chunk but B's parity → wrong loop-seam bytes.
            o = dec12(dut.w_hdr.startAddr,
                      (dut.w_pos2 & ~16'd1) | (dut.w_posb & 16'd1));
            seam_n   <= seam_n + 1;
            seam_dut <= dut.w_sb;
            seam_exp <= e;
            seam_old <= o;
            if (dut.w_sb === e)            seam_ok     <= seam_ok + 1;
            if (e !== o && dut.w_sb === o) seam_oldbug <= seam_oldbug + 1;
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
        if (CONTEND) $display("  [%s wv=%0d] CONTEND ch2load=%0d hold=%0d  ch4 read lat avg/max=%0.1f/%0d (n=%0d)",
                 label, wv, CH2LOAD, HOLD, ch4_lat_n?1.0*ch4_lat_sum/ch4_lat_n:0.0, ch4_lat_max, ch4_lat_n);
        // Sustain criteria: still producing nonzero audio late in the window,
        // and the position is looping (wrapped at least once).
        check($sformatf("%s: audio still alive (nonzero late)", label), pcm_nz_recent > 0);
        check($sformatf("%s: position loops (wraps>0)", label), loop_wraps > 0);
        check($sformatf("%s: env not OFF", label), dbg_slot0_dyn_env_state != EG_OFF);
    endtask

    initial begin
        // wave3: 12-bit, ODD loop length 301 → wraps with A on an even pos, the
        // exact case the old code mis-decoded.  Drive a higher octave so it
        // reaches the loop point and wraps many times within the window.
        play_wave(8'd3, 900, "WAVE3");
        $display("\n  [SEAM] slot0 sb_split 12-bit events=%0d  matched-loopstart=%0d  matched-OLDBUG=%0d",
                 seam_n, seam_ok, seam_oldbug);
        $display("  [SEAM] last: dut=%h exp(loopstart)=%h old(buggy)=%h", seam_dut, seam_exp, seam_old);
        check("seam events observed (wave3 wrapped at a 12-bit seam)", seam_n > 0);
        check("samp_b == loop-start chunk (fix correct) on ALL seam events", seam_n > 0 && seam_ok == seam_n);
        check("samp_b never equals OLD buggy value", seam_oldbug == 0);
        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails==0) $display("*** ALL TESTS PASSED ***");
        else          $display("!!! %0d FAILS !!!", fails);
        $finish;
    end
    initial begin #200ms; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
