`timescale 1ns/1ps
// Fade-out smoke test: alpha steps at hold 36..8=3, 7..6=2, 5..4=1, 3..0=0,
// and blended pixel values for white bar over a mid-gray background.
module tb_fade_smoke;
    reg clk=0; always #23 clk=~clk;
    reg ce=1, hbl=0, vbl=0, pause=0, osd=0, key=0, mouse=0;
    reg [5:0] j0=0, j1=0;
    wire [7:0] Ro,Go,Bo;
    debug_overlay dut(.CLK_VIDEO(clk), .ce_pix(ce), .hblank(hbl), .vblank(vbl),
        .R_in(8'h80), .G_in(8'h80), .B_in(8'h80), .R_out(Ro), .G_out(Go), .B_out(Bo),
        .en(1'b0), .dbg_pcm_valid(1'b0), .dbg_opl3_valid(1'b0), .dbg_mem_nonzero(1'b0),
        .dbg_interp_nonzero(1'b0), .dbg_pcm_level(16'd0), .dbg_new2(1'b0),
        .dbg_keyon_count(5'd0), .dbg_accum_cnt(5'd0), .dbg_env_min(10'd0),
        .dbg_slot_keyon(24'd0), .dbg_slot_active(24'd0), .dbg_slot_envlive(24'd0),
        .dbg_wait_stuck(1'b0), .dbg_irq_stuck(1'b0), .dbg_cpu_nom1(1'b0),
        .dbg_ack_stopped(1'b0), .dbg_intack_stop(1'b0), .dbg_iff_stuck_off(1'b0),
        .dbg_int_refused(1'b0), .dbg_pc_snap(16'd0), .dbg_pc_vec(16'd0),
        .dbg_pc_now(16'd0), .dbg_im_i(16'd0), .dbg_watch_pc(16'd0), .dbg_watch_dc(16'd0),
        .dbg_int_ghost(1'b0),
        .pause_in(pause), .osd_in(osd), .key_tgl_in(key), .mouse_tgl_in(mouse),
        .joy0_in(j0), .joy1_in(j1));
    integer errs=0;
    task chk(input c, input [255:0] m);
        if (!c) begin errs=errs+1; $display("FAIL: %0s", m); end
        else $display("PASS: %0s", m);
    endtask
    initial begin
        repeat(8) @(posedge clk);
        pause=1; osd=1; repeat(8) @(posedge clk);
        chk(dut.sym_alpha==2'd3, "osd open: alpha=3 (opaque)");
        // force hold values and read alpha
        osd=0; repeat(8) @(posedge clk);
        force dut.sym_hold=6'd8;  #1 chk(dut.sym_alpha==2'd3, "hold=8: alpha=3");
        force dut.sym_hold=6'd7;  #1 chk(dut.sym_alpha==2'd2, "hold=7: alpha=2");
        force dut.sym_hold=6'd4;  #1 chk(dut.sym_alpha==2'd1, "hold=4: alpha=1");
        force dut.sym_hold=6'd1;  #1 chk(dut.sym_alpha==2'd0, "hold=1: alpha=0(1/4)");
        // blend values: fg=FF, bg=80 → d=127: a3→FF? 80+127=FF; a2→80+95=DF; a1→80+63=BF; a0→80+31=9F
        chk(dut.sym_blend(8'hFF,8'h80,2'd3)==8'hFF, "blend a3 = FF");
        chk(dut.sym_blend(8'hFF,8'h80,2'd2)==8'hDE || dut.sym_blend(8'hFF,8'h80,2'd2)==8'hDF, "blend a2 ~ DF");
        chk(dut.sym_blend(8'hFF,8'h80,2'd1)==8'hBF, "blend a1 = BF");
        chk(dut.sym_blend(8'hFF,8'h80,2'd0)==8'h9F, "blend a0 = 9F");
        chk(dut.sym_blend(8'h00,8'h80,2'd3)==8'h00, "blend black a3 = 00");
        chk(dut.sym_blend(8'h00,8'h80,2'd0)==8'h60, "blend black a0 = 60");
        release dut.sym_hold;
        if (errs==0) $display("ALL FADE CHECKS PASSED"); else $display("%0d FAILS", errs);
        $finish;
    end
endmodule
