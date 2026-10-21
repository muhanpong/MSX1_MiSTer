//  v9968_cmdwait -- the V9968 command engine's per-command waits (MSX1 core, 2026-10-22).
//
//  rtl/video/v9968/vdp_command.v waits `{wait, 2'b11}` clk_vdp per access step in the
//  normal-speed mode (HS=0); upstream fixes every wait at 40, which makes its commands
//  0.39-0.88 x the V9938's time (sim/v9968_vram +wl=K against openMSX 21.0-245, SCREEN5,
//  display and sprites on).  Software that times the VDP refuses it: Go Figure's boot
//  check ("Abnormal fast VDP") wants its HMMM still running at line 188.
//
//  v9938 = 0: 40 everywhere (bit-identical to upstream).  v9938 = 1: the table below,
//  calibrated per command to the openMSX V9938 references in sim/v9968_vram (+wl=0..6
//  and the Go Figure workload +cmd=4).  HS=1 (high-speed mode) is not affected.
//  Order: hmmc ymmm hmmm hmmv lmmc lmcm lmmm lmmv line srch pset point.
module v9968_cmdwait (
    input  wire        v9938,
    output wire [95:0] cmd_wait
);
    //  Calibration (2026-10-22, sim/v9968_vram, the duration is linear in the wait:
    //  T(w) = T40 + (w - 40) * (T80 - T40) / 40, both measured):
    //    HMMV 59, LMMV 59, YMMM 48, LMMM 46, LINE 72, SRCH 108: each within 1 % of openMSX.
    //    HMMM 57, not the 59 its 256x128 row alone asks for: Go Figure's short-row HMMM
    //    (NX 28) costs relatively more here than on the V9938, and the hardware-found pass
    //    boundary of its check is 259.5 lines -- 57 puts it at ~269 lines, the 256x128 copy
    //    at 0.97 x openMSX (inside the 5 % gate of sim/check_vdpcmd.sh).
    //    HMMC, LMMC, LMCM, PSET, POINT: no reference workload; 59 like the other block
    //    commands (the CPU paces HMMC/LMMC/LMCM anyway).
    localparam [95:0] W_V9968 = {12{8'd40}};
    localparam [95:0] W_V9938 = {
        8'd59,      // hmmc
        8'd48,      // ymmm
        8'd57,      // hmmm
        8'd59,      // hmmv
        8'd59,      // lmmc
        8'd59,      // lmcm
        8'd46,      // lmmm
        8'd59,      // lmmv
        8'd72,      // line
        8'd108,     // srch
        8'd59,      // pset
        8'd59       // point
    };
    assign cmd_wait = v9938 ? W_V9938 : W_V9968;
endmodule
