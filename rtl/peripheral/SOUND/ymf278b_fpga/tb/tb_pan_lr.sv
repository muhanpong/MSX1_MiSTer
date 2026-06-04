// Pan L/R unit test.
// Verifies pan_att_left/pan_att_right return correct values per
// YMF278B spec (matches openMSX YMF278.cc panning tables).
`timescale 1ns/1ps
`default_nettype none

import ymf278_pcm_alu_pkg::*;

module tb_pan_lr;
    int passes = 0, fails = 0;
    task check(string name, logic ok);
        if (ok) begin $display("PASS: %s", name); passes++; end
        else    begin $display("FAIL: %s", name); fails++;  end
    endtask

    initial begin
        // pan=0 (center): both channels full
        check("pan=0  L=0x20 (full)",  pan_att_left(4'd0)  == 6'h20);
        check("pan=0  R=0x20 (full)",  pan_att_right(4'd0) == 6'h20);

        // pan=1 (slight right): left -3dB attenuated
        check("pan=1  L=0x18 (atten 3dB)", pan_att_left(4'd1)  == 6'h18);
        check("pan=1  R=0x20 (full)",       pan_att_right(4'd1) == 6'h20);

        // pan=7 (full right): left silent
        check("pan=7  L=0 (silent)",     pan_att_left(4'd7)  == 6'd0);
        check("pan=7  R=0x20 (full)",    pan_att_right(4'd7) == 6'h20);

        // pan=8 (mute): both silent
        check("pan=8  L=0 (mute)",       pan_att_left(4'd8)  == 6'd0);
        check("pan=8  R=0 (mute)",       pan_att_right(4'd8) == 6'd0);

        // pan=9 (full left): right silent
        check("pan=9  L=0x20 (full)",    pan_att_left(4'd9)  == 6'h20);
        check("pan=9  R=0 (silent)",     pan_att_right(4'd9) == 6'd0);

        // pan=15 (slight left): right -3dB attenuated
        check("pan=15 L=0x20 (full)",    pan_att_left(4'd15)  == 6'h20);
        check("pan=15 R=0x18 (atten 3dB)", pan_att_right(4'd15) == 6'h18);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end
endmodule

`default_nettype wire
