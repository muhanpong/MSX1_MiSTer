`timescale 1ps/1ps
// SDRAM model + timing checker for the sdram128 TDM controller.
//
// One or two x16 chips on a shared bus (128 MB board: nCS low = chip 0, high =
// chip 1; 32 MB board: one chip, nCS high deselects).  DQM is A[12:11] (the
// MiSTer module ties them), so the model takes DQM from the address bus.  Every
// violation prints "SDCHK ERR <what>" and counts in errs.
//
// Read timing (CL3, BL2): READ at edge k -> word0 valid at edge k+3 (driven tAC
// after edge k+2, held tOH after k+3), word1 at k+4.  DQM latency 2: the DQM at
// edge e masks the word valid at e+2.  Write: words at edges w, w+1, DQM latency 0.
// Numbers: AS4C32M16SB-7 class, conservative.
module sdram_chk #(parameter int NCHIP = 1, parameter int COLS = 512, parameter int TCK = 7760)
(
    input        clk,          // SDRAM_CLK pin
    inout [15:0] dq,
    input [12:0] a,
    input  [1:0] ba,
    input        ncs, nras, ncas, nwe,
    input        fpga_oe       // the controller's DQ output enable (bus check)
);
    localparam int T_RCD = 21000, T_RP = 21000, T_RAS = 42000, T_RC = 63000,
                   T_RRD = 14000, T_RFC = 70000, T_AC = 5400, T_OH = 2500,
                   T_REFI = 7812500;
    int errs = 0, nact = 0, nrd = 0, nwr = 0, nref = 0, ras_lockout = 0;
    //  Refresh rule.  Default: every interval <= T_REFI (7.8125 us = 64 ms / 8192, the
    //  distributed figure -- stricter than the part).  +refdebt=N: the datasheet's
    //  "Refresh Period (8192 cycles) 64 ms" (AS4C32M16SA v2.0 table, item 22) as a
    //  running debt: elapsed/T_REFI - REFRESHes issued, error above N.  N = 8 keeps every
    //  row far inside 64 ms (8 postponed = 62.5 us late).  Max interval and max debt are
    //  printed either way (sdram_tdm's VRAM-chip refresh waits for V-idle frames).
    int refdebt = 0;
    real dbt [2] = '{0.0, 0.0}, dbt_max [2] = '{0.0, 0.0};
    realtime gap_max [2] = '{0, 0}, t_dbt [2] = '{-1, -1};
    initial void'($value$plusargs("refdebt=%d", refdebt));
    final for (int c = 0; c < NCHIP; c++)
        $display("  SDCHK refresh chip %0d: max interval %0.3f us, max debt %0.2f%s", c, gap_max[c] / 1e6, dbt_max[c],
                 refdebt ? $sformatf(" (rule: debt <= %0d)", refdebt) : " (rule: interval <= 7.8125 us)");
    task automatic err(input string s);
        errs++;
        if (errs <= 20) $display("SDCHK ERR t=%0t %s", $time, s);
    endtask

    logic [15:0] mem [longint];
    function automatic longint key(int c, int b, int r, int k);
        return ((longint'(c) * 4 + b) * 8192 + r) * 1024 + k;
    endfunction

    bit      open_  [2][4];
    int      row_   [2][4];
    realtime t_act  [2][4];
    realtime t_idle [2][4];
    realtime t_lastact [2];
    realtime t_refbusy [2];
    realtime t_lastref [2];
    bit      moded [2];
    initial for (int c = 0; c < 2; c++) begin
        t_lastact[c] = -1e12; t_refbusy[c] = -1e12; t_lastref[c] = -1; moded[c] = 0;
        for (int b = 0; b < 4; b++) begin open_[c][b] = 0; t_act[c][b] = -1e12; t_idle[c][b] = -1e12; end
    end

    // read words by the edge they are valid at
    typedef struct { int c, b, r, k; } rw_t;
    rw_t rdq [int];
    int  e = 0;                   // edge number
    int  rd_end = -100;           // last edge holding read data
    int  wr_end = -100;           // last edge of a write burst
    int  wr_c, wr_b, wr_r, wr_k;  // the write burst's next word
    logic [1:0] dqm_at [int];     // DQM sampled at each edge (kept for latency 2)

    logic [15:0] drv = 'z;
    assign dq = drv;
    rw_t         rd_w;
    longint      rd_kk;
    logic [15:0] nx_v;
    logic [1:0]  rd_m;
    bit          nx_ok = 1'b0;
    int          last_word = -100;   // last edge whose read word is on the bus
    always @(negedge clk) drv <= nx_ok ? nx_v : 16'hzzzz;   // = FPGA rising edge
    //  (assignments to drv from a forked task never reached the net in the
    //  timing simulator; the falling-edge process below does it without delays)

    //  (Verilator: no initialisers on declarations in procedural code -- an
    //  'automatic x = expr' inside an always block kept the previous edge's value
    //  and shifted every read word by one column.  Declare, then assign.)
    task automatic write_word(int c, int b, int r, int k, logic [1:0] m);
        longint kk;
        logic [15:0] old;
        kk  = key(c, b, r, k);
        if (mem.exists(kk)) old = mem[kk]; else old = 16'hxxxx;
        if (m != 2'b11) begin
            if (!fpga_oe) err("write word but the FPGA is not driving");
            if ((!m[0] && $isunknown(dq[7:0])) || (!m[1] && $isunknown(dq[15:8]))) err("write data X/Z");
        end
        if (!m[0]) old[7:0]  = dq[7:0];
        if (!m[1]) old[15:8] = dq[15:8];
        mem[kk] = old;
    endtask

    int c, k, k1;
    bit sel, isrd;
    logic [2:0] cmd;
    realtime ap;
    always @(posedge clk) begin
        c   = (NCHIP == 2) ? int'(ncs) : 0;
        sel = (NCHIP == 2) ? 1'b1 : !ncs;
        cmd = {nras, ncas, nwe};
        e++;
        dqm_at[e] = a[12:11];
        if (dqm_at.exists(e - 4)) dqm_at.delete(e - 4);

        // ── bus: the chip holds read data at this edge (tOH) -> FPGA must not drive
        if (fpga_oe && (rdq.exists(e) || last_word == e - 1))
            err("bus contention: FPGA drives while the chip has read data");

        // ── write burst word1 ──
        if (e == wr_end) write_word(wr_c, wr_b, wr_r, wr_k, a[12:11]);

        // ── read output.  Model clock = SDRAM_CLK = the FPGA clock inverted, so
        //    this edge is an FPGA falling edge.  Measured by STA (sdram_io.sdc on
        //    a253d77): the real pin clock lags 3.77 ns more, and the word valid at
        //    chip edge e is at the FPGA input register from +0.6 to +4.7 ns after
        //    the FPGA rising edge that follows this one -- i.e. around the NEXT
        //    falling edge.  So the word computed here goes onto the bus at the
        //    following FPGA rising edge (non-blocking, so an FPGA rising-edge
        //    register on that edge still sees the old word) and stays one clock.
        //    A rising-edge capture gets a wrong word; the falling edge in between
        //    gets the right one.  (Two earlier versions put the word earlier and
        //    passed designs the STA rejects.) ──
        if (rdq.exists(e)) begin
            rd_w  = rdq[e];
            rd_kk = key(rd_w.c, rd_w.b, rd_w.r, rd_w.k);
            if (mem.exists(rd_kk)) nx_v = mem[rd_kk]; else nx_v = 16'hxxxx;
            rd_m  = 2'b00;
            if (dqm_at.exists(e - 2)) rd_m = dqm_at[e - 2];     // DQM latency 2
            if (rd_m[0]) nx_v[7:0]  = 8'hzz;
            if (rd_m[1]) nx_v[15:8] = 8'hzz;
            if (rd_m != 2'b00) err($sformatf("read word masked by DQM=%b (row bits on A12:A11?)", rd_m));
            nx_ok = 1'b1;
            last_word = e;
        end else nx_ok = 1'b0;
        if (rdq.exists(e)) rdq.delete(e);

        // ── commands ──
        if (sel) case (cmd)
            3'b011: begin // ACT
                nact++;
                if (open_[c][ba]) err($sformatf("ACT to open bank c%0d b%0d", c, ba));
                if ($realtime - t_act[c][ba] < T_RC) err($sformatf("tRC c%0d b%0d (%0t)", c, ba, $realtime - t_act[c][ba]));
                if ($realtime < t_idle[c][ba]) err($sformatf("ACT before precharge done c%0d b%0d", c, ba));
                if ($realtime - t_lastact[c] < T_RRD) err("tRRD");
                if ($realtime < t_refbusy[c]) err("ACT during tRFC");
                if (!moded[c]) err("ACT before mode register");
                open_[c][ba] = 1; row_[c][ba] = a; t_act[c][ba] = $realtime; t_lastact[c] = $realtime;
            end
            3'b101, 3'b100: begin // READ / WRITE
                isrd = (cmd == 3'b101);
                k    = a[9:0];
                k1   = (k & ~1) | ((k + 1) & 1);
                if (COLS == 512 && a[9]) err("column bit 9 on a 512-column chip");
                if (!open_[c][ba]) err($sformatf("%s to closed bank c%0d b%0d", isrd ? "READ" : "WRITE", c, ba));
                if ($realtime - t_act[c][ba] < T_RCD) err("tRCD");
                if (!a[10]) err("access without auto precharge");
                if (e <= wr_end) err("READ/WRITE cuts a write burst");
                if (isrd) begin
                    nrd++;
                    if (e + 3 <= rd_end) err("READ overlaps the read data in flight");
                    rdq[e + 3] = '{c, ba, row_[c][ba], k};
                    rdq[e + 4] = '{c, ba, row_[c][ba], k1};
                    rd_end = e + 4;
                    ap = $realtime + 2 * TCK;                    // auto precharge after BL
                end else begin
                    nwr++;
                    if (e < rd_end + 2) err("WRITE without a bus-idle cycle after read data");
                    write_word(c, ba, row_[c][ba], k, a[12:11]);
                    wr_c = c; wr_b = ba; wr_r = row_[c][ba]; wr_k = k1; wr_end = e + 1;
                    ap = $realtime + 3 * TCK;                    // last word + tWR 2
                end
                if (ap < t_act[c][ba] + T_RAS) begin ras_lockout++; ap = t_act[c][ba] + T_RAS; end
                t_idle[c][ba] = ap + T_RP;
                open_[c][ba] = 0;
            end
            3'b001: begin // REFRESH
                nref++;
                for (int b = 0; b < 4; b++)
                    if (open_[c][b] || $realtime < t_idle[c][b]) err($sformatf("REFRESH with bank %0d busy (c%0d)", b, c));
                if ($realtime < t_refbusy[c]) err("REFRESH during tRFC");
                if (moded[c] && t_lastref[c] >= 0) begin
                    if ($realtime - t_lastref[c] > gap_max[c]) gap_max[c] = $realtime - t_lastref[c];
                    if (!refdebt && $realtime - t_lastref[c] > T_REFI)
                        err($sformatf("refresh interval %0t on chip %0d", $realtime - t_lastref[c], c));
                end
                if (moded[c] && t_dbt[c] >= 0) dbt[c] = dbt[c] - 1.0;
                t_refbusy[c] = $realtime + T_RFC;
                if (moded[c]) t_lastref[c] = $realtime;
            end
            3'b010: for (int b = 0; b < 4; b++) begin open_[c][b] = 0; t_idle[c][b] = $realtime + T_RP; end
            3'b000: begin // MODE
                if (a[6:4] != 3'd3) err("mode: CL is not 3");
                if (a[2:0] != 3'd1) err("mode: BL is not 2");
                if (a[9])           err("mode: write burst off");
                moded[c] = 1;
                //  the refresh watch starts here: a controller that never refreshes
                //  after init must still trip it (it did not, first version)
                if (t_lastref[c] < 0) t_lastref[c] = $realtime;
                if (t_dbt[c] < 0) t_dbt[c] = $realtime;
            end
            default: ;
        endcase

        for (int cc = 0; cc < NCHIP; cc++) if (moded[cc] && t_dbt[cc] >= 0) begin
            //  debt accrues one REFRESH every T_REFI; a debt below zero (refreshes ahead) is
            //  not banked beyond one, as a part's counter cannot be pre-paid for long
            dbt[cc] = dbt[cc] + ($realtime - t_dbt[cc]) / T_REFI; t_dbt[cc] = $realtime;
            if (dbt[cc] < -1.0) dbt[cc] = -1.0;
            if (dbt[cc] > dbt_max[cc]) dbt_max[cc] = dbt[cc];
            if (refdebt && dbt[cc] > refdebt) begin
                err($sformatf("chip %0d refresh debt %0.2f > %0d", cc, dbt[cc], refdebt));
                dbt[cc] = 0;
            end
        end
        for (int cc = 0; cc < NCHIP; cc++)
            if (!refdebt && moded[cc] && t_lastref[cc] >= 0 && $realtime - t_lastref[cc] > T_REFI + TCK) begin
                err($sformatf("chip %0d not refreshed for %0t", cc, $realtime - t_lastref[cc]));
                t_lastref[cc] = $realtime;
            end
    end
endmodule
