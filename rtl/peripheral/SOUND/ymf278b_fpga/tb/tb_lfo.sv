// Unit TB for [14] LFO: validates ymf278_pcm_alu_pkg::compute_vib /
// compute_am / lfo_period_rom against openMSX YMF278.cc reference values.
//
//   compute_vib(lfo_cnt, vib) — triangle in [-0xF..+0xF] * vib_depth / 12
//   compute_am (lfo_cnt, am)  — triangle in [0..0x7F]   * am_depth >> 7
//   lfo_period_rom(s)         — increments per sample (LFO_PERIOD = 1<<18)
//
// Golden values hand-computed from the C++ in reference/YMF278.cc.
`timescale 1ns/1ps
`default_nettype none

module tb_lfo;
    import ymf278_pcm_alu_pkg::*;

    int errors = 0;
    int checks = 0;

    // lfo_cnt for a given quarter-phase index lfo_fm (vib) = lfo_fm << 12.
    function automatic [17:0] cnt_vib(input int lfo_fm);
        return 18'(lfo_fm << 12);
    endfunction
    // lfo_cnt for a given am index lfo_am = lfo_am << 10.
    function automatic [17:0] cnt_am(input int lfo_am);
        return 18'(lfo_am << 10);
    endfunction

    task automatic chk_vib(input int lfo_fm, input [2:0] vib, input int exp);
        logic signed [15:0] got;
        got = compute_vib(cnt_vib(lfo_fm), vib);
        checks++;
        if (got !== 16'(exp)) begin
            $display("FAIL vib: lfo_fm=%0d vib=%0d got=%0d exp=%0d", lfo_fm, vib, got, exp);
            errors++;
        end
    endtask

    task automatic chk_am(input int lfo_am, input [2:0] am, input int exp);
        logic [8:0] got;
        got = compute_am(cnt_am(lfo_am), am);
        checks++;
        if (got !== 9'(exp)) begin
            $display("FAIL am: lfo_am=%0d am=%0d got=%0d exp=%0d", lfo_am, am, got, exp);
            errors++;
        end
    endtask

    initial begin
        // ── compute_vib, vib=7 (depth 48 → 4 per unit), full triangle ──────────
        chk_vib(0,  3'd7, 0);    chk_vib(8,  3'd7, 32);   chk_vib(15, 3'd7, 60);
        chk_vib(16, 3'd7, 60);   chk_vib(24, 3'd7, 28);   chk_vib(31, 3'd7, 0);
        chk_vib(32, 3'd7, 0);    chk_vib(40, 3'd7, -32);  chk_vib(47, 3'd7, -60);
        chk_vib(48, 3'd7, -60);  chk_vib(56, 3'd7, -28);  chk_vib(63, 3'd7, 0);

        // vib=1 (depth 2) — truncation toward zero on positive and negative
        chk_vib(15, 3'd1, 2);    chk_vib(8,  3'd1, 1);    chk_vib(40, 3'd1, -1);
        // vib=0 → always 0
        chk_vib(15, 3'd0, 0);    chk_vib(40, 3'd0, 0);

        // ── compute_am, am=7 (depth 0x80 → identity) ───────────────────────────
        chk_am(0,   3'd7, 0);    chk_am(64,  3'd7, 64);   chk_am(127, 3'd7, 127);
        chk_am(128, 3'd7, 127);  chk_am(200, 3'd7, 55);   chk_am(255, 3'd7, 0);
        // am=1 (depth 0x14=20)
        chk_am(127, 3'd1, 19);   chk_am(64,  3'd1, 10);
        // am=0 → always 0
        chk_am(127, 3'd0, 0);    chk_am(200, 3'd0, 0);

        // ── lfo_period_rom table ───────────────────────────────────────────────
        begin
            int exp_p [0:7];
            exp_p = '{1,12,19,25,31,35,37,42};
            for (int s = 0; s < 8; s++) begin
                checks++;
                if (lfo_period_rom(3'(s)) !== 6'(exp_p[s])) begin
                    $display("FAIL period: s=%0d got=%0d exp=%0d", s,
                             lfo_period_rom(3'(s)), exp_p[s]);
                    errors++;
                end
            end
        end

        // ── accumulation sanity: speed 0 advances +1/sample, speed 7 +42 ───────
        begin
            logic [17:0] cnt; int n;
            cnt = 18'd0;
            for (n = 0; n < 100; n++) cnt = (cnt + {12'd0, lfo_period_rom(3'd0)}) & 18'h3FFFF;
            checks++;
            if (cnt !== 18'd100) begin
                $display("FAIL accum speed0: got=%0d exp=100", cnt); errors++;
            end
            cnt = 18'd0;
            for (n = 0; n < 10; n++) cnt = (cnt + {12'd0, lfo_period_rom(3'd7)}) & 18'h3FFFF;
            checks++;
            if (cnt !== 18'd420) begin
                $display("FAIL accum speed7: got=%0d exp=420", cnt); errors++;
            end
        end

        $display("tb_lfo: %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end
endmodule
