//  Per-RUN breakdown of a geo3d frame (clk_vdp clocks), for tb_geo3d_brk.sv (this core) and
//  tb_system_brk.v (upstream's ideal-memory bench).  Prints one "BRK" line when in_run falls.
//  Engine side (both benches):
//    ce1 by command type (0 LINE, 1 LRMM, 2 other): req = engine's cache request not accepted,
//    rd = waiting for read data, cnt = c_state_wait_counter, fin = c_state_finish (flush),
//    oth = the rest (the command engine's own steps)
//    ce0: hold = a command is ready in geo3d (issuing R#36.., guard, CE sync), pre = before the
//    first command of the RUN (transform, sort), mid = between commands with nothing ready
//    (engine producing), tail = after the last command until run_busy falls, idle = run_busy 0
//  VRAM side (HAVE_VRAM, this core only): cache -> vdp_vram_interface
//    vw = valid & !ready, split: ns = not on a slot clock (h 1/9), ref = slot taken by refresh,
//    dsp = slot a taken by screen/sprite, cpu = slot b taken by the CPU, oth = other;
//    rd/wr = granted reads/writes, lat = sum of grant -> rdata_en clocks over reads
module brk_probe #(parameter HAVE_VRAM = 1) (
    input clk, input in_run, input ce, input geo_busy, input hold_valid,
    input [5:0] st, input [3:0] cmd, input eng_req, input eng_ready,
    input cv, input cr, input cw, input crde, input [3:0] hcnt,
    input refresh, input disp_req, input cpu_req);
    reg [63:0] ce1 [0:2], req [0:2], rd [0:2], cnt [0:2], fin [0:2], ncmd [0:2];
    reg [63:0] hold, pre, mid, tail, idle, tmp, tot;
    reg [63:0] vw, vns, vref, vdsp, vcpu, voth, nrd, nwr, lat;
    reg [63:0] q [0:15]; reg [3:0] qh, qt; reg [63:0] now;
    reg prev_run, prev_ce, seen_ce; integer k, fr, t;
    initial begin fr = 0; prev_run = 0; prev_ce = 0; now = 0; qh = 0; qt = 0; end
    task clr; begin
        for (k = 0; k < 3; k = k + 1) begin ce1[k] = 0; req[k] = 0; rd[k] = 0; cnt[k] = 0; fin[k] = 0; ncmd[k] = 0; end
        hold = 0; pre = 0; mid = 0; tail = 0; idle = 0; tmp = 0; tot = 0; seen_ce = 0;
        vw = 0; vns = 0; vref = 0; vdsp = 0; vcpu = 0; voth = 0; nrd = 0; nwr = 0; lat = 0;
    end endtask
    initial clr;
    always @(posedge clk) begin
        now = now + 1;
        if (HAVE_VRAM) begin
            if (cv && cr && !cw) begin q[qh] = now; qh = qh + 1; end
            if (crde && qh != qt) begin if (in_run) lat = lat + (now - q[qt]); qt = qt + 1; end
        end
        if (in_run) begin
            tot = tot + 1;
            t = (cmd == 4'b0111) ? 0 : (cmd == 4'b0011) ? 1 : 2;
            if (ce && !prev_ce) begin ncmd[t] = ncmd[t] + 1; mid = mid + tmp; tmp = 0; seen_ce = 1; end
            if (ce) begin
                ce1[t] = ce1[t] + 1;
                if (eng_req && !eng_ready) req[t] = req[t] + 1;
                else if (st == 6'd39) rd[t] = rd[t] + 1;
                else if (st == 6'd40) cnt[t] = cnt[t] + 1;
                else if (st == 6'd42) fin[t] = fin[t] + 1;
            end else if (!geo_busy) idle = idle + 1;
            else if (hold_valid) hold = hold + 1;
            else if (!seen_ce) pre = pre + 1;
            else tmp = tmp + 1;
            if (HAVE_VRAM) begin
                if (cv && cr) begin if (cw) nwr = nwr + 1; else nrd = nrd + 1; end
                if (cv && !cr) begin
                    vw = vw + 1;
                    if (hcnt != 4'd1 && hcnt != 4'd9) vns = vns + 1;
                    else if (refresh) vref = vref + 1;
                    else if (hcnt == 4'd1 && disp_req) vdsp = vdsp + 1;
                    else if (hcnt == 4'd9 && cpu_req) vcpu = vcpu + 1;
                    else voth = voth + 1;
                end
            end
        end
        if (prev_run && !in_run) begin
            tail = tmp;
            $display("BRK %0d tot %0d | LINE n %0d ce %0d req %0d rd %0d cnt %0d fin %0d | LRMM n %0d ce %0d req %0d rd %0d cnt %0d fin %0d | OTH n %0d ce %0d req %0d rd %0d | hold %0d pre %0d mid %0d tail %0d idle %0d | vw %0d ns %0d ref %0d dsp %0d cpu %0d oth %0d rd %0d wr %0d lat %0d",
                fr, tot, ncmd[0], ce1[0], req[0], rd[0], cnt[0], fin[0], ncmd[1], ce1[1], req[1], rd[1], cnt[1], fin[1],
                ncmd[2], ce1[2], req[2], rd[2], hold, pre, mid, tail, idle, vw, vns, vref, vdsp, vcpu, voth, nrd, nwr, lat);
            fr = fr + 1;
            clr;
        end
        prev_run = in_run; prev_ce = ce;
    end
endmodule
