// Unit check of YMF278B_pkg functions: three whose multiplications mix a
// $signed() operand with an unsigned one (IEEE 1800 11.8.1: the operation is
// then unsigned and the signed operand is zero-extended), and LevelAddPanR,
// whose ~PAN[2:0] is evaluated at the 10-bit context width (11.6.1), i.e.
// widened first and inverted after.  Prints the package result next to the
// arithmetic the code evidently intends.
//   (Verilator) built against YMF278B_pkg.sv itself (import)
//   iverilog : cannot parse the package (unpacked array parameter), so
//              -DCOPY uses verbatim copies of the three function bodies
module tb_signedness;
`ifdef COPY
    function bit signed [15:0] VolCalc(bit signed [15:0] WAVE, bit [9:0] LEVEL);
        bit [22:0] MULT; bit [15:0] RES;
        MULT = $signed(WAVE) * ({2'b01,~LEVEL[5:0]});
        RES = $signed($signed(MULT[22:7])>>>LEVEL[9:6]);
        return RES;
    endfunction
    function bit [15:0] Interpolate(input bit [15:0] WAVE0, input bit [15:0] WAVE1, bit [5:0] PHASE);
        bit [ 6:0] PHASE_NEG; bit [21:0] TEMP0,TEMP1; bit [21:0] SUM;
        PHASE_NEG = 7'h40 - PHASE;
        TEMP0 = $signed(WAVE0) * PHASE_NEG;
        TEMP1 = $signed(WAVE1) * PHASE;
        SUM = $signed(TEMP0) + $signed(TEMP1);
        return SUM[21:6];
    endfunction
    function bit [22:0] PhaseCalc(bit [9:0] FNUM, bit [3:0] OCT, bit signed [7:0] PLFO_WAVE);
        bit [26:0] P; bit [3:0] S; bit [10:0] F; bit [14:0] TEMP; bit [11:0] FM;
        S = OCT^4'h8; F = 11'h400 + FNUM;
        TEMP = $signed(PLFO_WAVE) * F[10:4];
        FM = {{3{TEMP[14]}},TEMP[14:6]};
        P = {15'b000000000000000,{1'b0,F}+FM}<<(S-1);
        return P[26:4];
    endfunction
    function bit [9:0] LevelAddPanR(bit [9:0] LEVEL, bit [3:0] PAN);
        bit [9:0] PAN_LEVEL; bit [10:0] SUM;
        PAN_LEVEL = PAN == 4'h9 || PAN == 4'h8 ? 10'h3FF : PAN < 4'h8 || PAN == 4'h0 ? 10'h000 : (10'h020 * ~PAN[2:0]);
        SUM = {1'b0,LEVEL} + {1'b0,PAN_LEVEL};
        return !SUM[10] ? SUM[9:0] : 10'h3FF;
    endfunction
`else
    import YMF278B_PKG::*;
`endif
    initial begin
        $display("VolCalc(+16384, lvl 0)   = %0d   (intended %0d)", $signed(VolCalc(16'sd16384, 10'd0)), (16384*127)>>>7);
        $display("VolCalc(-16384, lvl 0)   = %0d   (intended %0d)", $signed(VolCalc(-16'sd16384, 10'd0)), (-16384*127)>>>7);
        $display("VolCalc(-16384, lvl 0x3F)= %0d   (intended %0d)", $signed(VolCalc(-16'sd16384, 10'h3F)), (-16384*64)>>>7);
        $display("VolCalc(-16384, lvl 0x7F)= %0d   (intended %0d)", $signed(VolCalc(-16'sd16384, 10'h7F)), ((-16384*64)>>>7)>>>1);
        $display("Interp(-1024,-1024,ph32) = %0d   (intended %0d)", $signed(Interpolate(-16'sd1024, -16'sd1024, 6'd32)), -1024);
        $display("Interp(-1024,    0,ph32) = %0d   (intended %0d)", $signed(Interpolate(-16'sd1024, 16'sd0, 6'd32)), -512);
        $display("Interp(    0,-1024,ph16) = %0d   (intended %0d)", $signed(Interpolate(16'sd0, -16'sd1024, 6'd16)), -256);
        $display("PhaseCalc(fn0,oct0,lfo+8)= %0d   PhaseCalc(fn0,oct0,lfo-8)= %0d   lfo0= %0d",
                 PhaseCalc(10'd0, 4'd0, 8'sd8), PhaseCalc(10'd0, 4'd0, -8'sd8), PhaseCalc(10'd0, 4'd0, 8'sd0));
        for (int p = 10; p <= 15; p++)
            $display("LevelAddPanR(0, pan %0d) = 0x%03h   (intended 0x%03h)", p, LevelAddPanR(10'd0, p[3:0]), 10'h020 * (7 - (p & 7)));
        $finish;
    end
endmodule
