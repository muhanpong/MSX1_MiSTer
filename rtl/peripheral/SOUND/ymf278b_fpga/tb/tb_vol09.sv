// [09] volume math check: engine's two-stage (env then TL) vol_factor must match
// the openMSX reference  smplOut = vol_factor(vol_factor(sample, env), TL<<2),
// and must NOT silence "layered" voices (env<0x280 && TL<<2<0x280 but sum>=0x280)
// that the OLD single-combined-clip engine wrongly muted.
`timescale 1ns/1ps
module tb_vol09;
    // reference vol_factor: x attenuated by att-index (0=full, >=0x280 = silence)
    function automatic integer vf(input integer x, input integer att);
        integer vol_mul, vol_shift;
        begin
            if (att >= 'h280) vf = 0;
            else begin
                vol_mul   = 'h80 - (att & 'h3F);
                vol_shift = 7 + (att >> 6);
                vf = (x * (('h8000 * vol_mul) >> vol_shift)) >>> 15;
            end
        end
    endfunction
    // OLD engine: single clip on summed index
    function automatic integer old_vol(input integer x, input integer env, input integer tl2);
        integer t, vol_mul, vol_shift;
        begin
            t = env + tl2;
            if (t >= 'h280) old_vol = 0;
            else begin
                vol_mul = 'h80 - (t & 'h3F); vol_shift = 7 + (t >> 6);
                old_vol = (x * (('h8000 * vol_mul) >> vol_shift)) >>> 15;
            end
        end
    endfunction
    // NEW engine: cascade (matches RTL D2b/D2c)
    function automatic integer new_vol(input integer x, input integer env, input integer tl2);
        integer ge, gt, inner;
        begin
            ge = (env >= 'h280) ? 0 : (('h8000 * ('h80 - (env & 'h3F))) >> (7 + (env >> 6)));
            gt = (tl2 >= 'h280) ? 0 : (('h8000 * ('h80 - (tl2 & 'h3F))) >> (7 + (tl2 >> 6)));
            inner   = (x * ge) >>> 15;
            new_vol = (inner * gt) >>> 15;
        end
    endfunction

    integer envs [0:5]; integer tls [0:3];
    integer i, j, env, tl2, sample, r, n, mism, layered, old_killed;
    initial begin
        envs[0]=0; envs[1]='h40; envs[2]='h100; envs[3]='h180; envs[4]='h200; envs[5]='h27f;
        tls[0]=0; tls[1]='h20; tls[2]='h40; tls[3]='h60;   // tl register; tl2 = tl<<2
        sample = 'h4000;
        mism=0; layered=0; old_killed=0;
        for (i=0;i<6;i=i+1) for (j=0;j<4;j=j+1) begin
            env = envs[i]; tl2 = tls[j] << 2;
            r = vf(vf(sample, env), tl2);
            n = new_vol(sample, env, tl2);
            if (n !== r) begin mism=mism+1; $display("MISMATCH env=%h tl2=%h ref=%0d new=%0d", env, tl2, r, n); end
            if (env < 'h280 && tl2 < 'h280 && (env+tl2) >= 'h280) begin
                layered = layered + 1;
                if (old_vol(sample,env,tl2)==0 && n!=0)
                    old_killed = old_killed + 1;  // old wrongly silenced, new audible
            end
        end
        $display("[vol09] new==ref mismatches=%0d  layered cases=%0d  (old silenced but new audible)=%0d",
                 mism, layered, old_killed);
        if (mism==0 && old_killed>0) $display("=== PASS: new matches reference AND revives layered voices ===");
        else $display("=== FAIL ===");
        $finish;
    end
endmodule
