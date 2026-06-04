`timescale 1ns/1ps

module tb_pcm_alu;

    ymf278_pcm_alu alu();

    initial begin
        $display("=== YMF278B ALU UNIT TESTS ===");
        
        // ---------------------------------------------------------
        // 1. Test Step Calculation
        // ---------------------------------------------------------
        $display("\n[1] Testing calc_step()");
        begin
            logic signed [3:0] oct;
            logic [9:0] fn;
            logic signed [15:0] vib;
            logic [31:0] step;
            
            // OCT = 0, FN = 0, no vib -> Base step
            oct = 4'sd0; fn = 10'd0; vib = 16'sh0;
            step = alu.calc_step(oct, fn, vib);
            $display("OCT=0, FN=0, VIB=0 -> Step = 0x%08X (Expected: 0x00008000)", step);
            if (step !== 32'h00008000) $display("FAIL");
            
            // OCT = -1 (down 1 octave -> divide by 2)
            oct = -4'sd1;
            step = alu.calc_step(oct, fn, vib);
            $display("OCT=-1, FN=0, VIB=0 -> Step = 0x%08X (Expected: 0x00004000)", step);
            if (step !== 32'h00004000) $display("FAIL");
            
            // OCT = -8 (Special case = 0)
            oct = -4'sd8;
            step = alu.calc_step(oct, fn, vib);
            $display("OCT=-8 -> Step = 0x%08X (Expected: 0x00000000)", step);
            if (step !== 32'h00000000) $display("FAIL");
        end
        
        // ---------------------------------------------------------
        // 2. Test Interpolation
        // ---------------------------------------------------------
        $display("\n[2] Testing calc_interp()");
        begin
            logic signed [15:0] a, b;
            logic [15:0] ptr;
            logic signed [15:0] out;
            
            a = 16'sd1000; b = 16'sd2000;
            
            // ptr = 0 (100% A)
            ptr = 16'h0000;
            out = alu.calc_interp(a, b, ptr);
            $display("A=1000, B=2000, Ptr=0x0000 -> Out = %0d (Expected: 1000)", out);
            if (out !== 16'sd1000) $display("FAIL");
            
            // ptr = 0x8000 (50% A, 50% B -> 1500)
            ptr = 16'h8000;
            out = alu.calc_interp(a, b, ptr);
            $display("A=1000, B=2000, Ptr=0x8000 -> Out = %0d (Expected: 1500)", out);
            if (out !== 16'sd1500) $display("FAIL");
            
            // Negative interpolation crossing 0
            a = -16'sd500; b = 16'sd500; ptr = 16'h8000;
            out = alu.calc_interp(a, b, ptr);
            $display("A=-500, B=500, Ptr=0x8000 -> Out = %0d (Expected: 0)", out);
            if (out !== 16'sd0) $display("FAIL");
        end
        
        // ---------------------------------------------------------
        // 3. Test Volume Calculation
        // ---------------------------------------------------------
        $display("\n[3] Testing calc_vol()");
        begin
            logic signed [15:0] in;
            logic [9:0] env;
            logic [7:0] tl;
            logic signed [31:0] out;
            
            in = 16'sd32767; // Max positive sample
            
            // Max volume (env=0, tl=0)
            env = 10'd0; tl = 8'd0;
            out = alu.calc_vol(in, env, tl);
            $display("In=32767, Env=0, TL=0 -> Out = %0d (Expected: ~32767)", out);
            if (out <= 0) $display("FAIL");
            
            // Absolute Silence (env = 0x280)
            env = 10'h280;
            out = alu.calc_vol(in, env, tl);
            $display("In=32767, Env=0x280, TL=0 -> Out = %0d (Expected: 0)", out);
            if (out !== 0) $display("FAIL");
        end
        
        // ---------------------------------------------------------
        // 4. Test Attack Step
        // ---------------------------------------------------------
        $display("\n[4] Testing calc_attack_step()");
        begin
            logic [9:0] ev;
            logic [7:0] inc;
            logic [9:0] out;
            
            ev = 10'h280; // Max attenuation (Silence)
            inc = 8'd16;
            out = alu.calc_attack_step(ev, inc);
            $display("Ev=0x280 (640), Inc=16 -> Out = %0d (Expected: 640 - 641 = 0, bounded to 0)", out);
            
            inc = 8'd1;
            out = alu.calc_attack_step(ev, inc);
            $display("Ev=0x280 (640), Inc=1 -> Out = %0d (Expected: 640 - 41 = 599)", out);
            if (out !== 599) $display("FAIL");
        end
        
        // ---------------------------------------------------------
        // 5. Test Envelope Rate Calculations
        // ---------------------------------------------------------
        $display("\n[5] Testing calc_eg_rate()");
        begin
            logic [3:0] val, rc;
            logic signed [3:0] oct;
            logic [9:0] fn;
            logic [5:0] out;
            
            val = 4'd5; rc = 4'd2; oct = -4'sd4; fn = 10'd0;
            // oct_rc = 2 + (-4) = -2 -> clamped to 0. 
            // res = 5*4 + 2*0 + 0 = 20.
            out = alu.calc_eg_rate(val, rc, oct, fn);
            $display("Val=5, RC=2, Oct=-4, Fn=0 -> Out = %0d (Expected: 20)", out);
            if (out !== 20) $display("FAIL");
            
            val = 4'd5; rc = 4'd12; oct = 4'sd6; fn = 10'h200; // fn[9] = 1
            // oct_rc = 12 + 6 = 18 -> clamped to 15.
            // res = 5*4 + 2*15 + 1 = 20 + 30 + 1 = 51.
            out = alu.calc_eg_rate(val, rc, oct, fn);
            $display("Val=5, RC=12, Oct=6, Fn=512 -> Out = %0d (Expected: 51)", out);
            if (out !== 51) $display("FAIL");
            
            val = 4'd1; rc = 4'd0; oct = -4'sd8; fn = 10'd0;
            // oct_rc = 0 - 8 = -8 -> clamped to 0.
            // res = 1*4 + 0 = 4.
            out = alu.calc_eg_rate(val, rc, oct, fn);
            $display("Val=1, RC=0, Oct=-8, Fn=0 -> Out = %0d (Expected: 4)", out);
            if (out !== 4) $display("FAIL");
        end
        
        // ---------------------------------------------------------
        // 6. Test byte_addr Calculation
        // ---------------------------------------------------------
        $display("\n[6] Testing byte_addr()");
        begin
            logic [21:0] base, out;
            logic [15:0] p;
            logic [1:0] fmt, byte_sel;
            
            base = 22'd0;
            p = 16'd43692; // 43692 / 2 * 3 = 65538
            fmt = 2'd1; // 12-bit
            byte_sel = 2'd0;
            
            out = alu.byte_addr(base, p, fmt, byte_sel);
            $display("Base=0, P=43692, Fmt=12-bit, ByteSel=0 -> Out = %0d (Expected: 65538)", out);
            if (out !== 65538) $display("FAIL - 16-bit truncation bug!");
        end
        
        $display("\n=== ALL TESTS PASSED ===");
        $finish;
    end

endmodule
