// Verify ROM-function values exactly match the original openMSX tables.
// Caught a bug where dl_tab_rom returned idx*8 instead of idx*32.
`timescale 1ns/1ps
`default_nettype none

import ymf278_pcm_eg_pkg::*;

module tb_eg_roms;
    int passes = 0, fails = 0;
    task check_v(string name, logic [15:0] got, logic [15:0] exp);
        if (got == exp) begin $display("PASS: %s  got=%h exp=%h", name, got, exp); passes++; end
        else            begin $display("FAIL: %s  got=%h exp=%h", name, got, exp); fails++;  end
    endtask

    // Reference tables (golden values from openMSX YMF278.cc)
    logic [7:0] ref_eg_inc [0:119];
    logic [7:0] ref_eg_sel [0:63];
    logic [7:0] ref_eg_shft [0:63];
    logic [9:0] ref_dl_tab [0:15];

    initial begin
        // eg_inc_rom
        ref_eg_inc  = '{
            8'd0, 8'd1, 8'd0, 8'd1, 8'd0, 8'd1, 8'd0, 8'd1,
            8'd0, 8'd1, 8'd0, 8'd1, 8'd1, 8'd1, 8'd0, 8'd1,
            8'd0, 8'd1, 8'd1, 8'd1, 8'd0, 8'd1, 8'd1, 8'd1,
            8'd0, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1,
            8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1, 8'd1,
            8'd1, 8'd1, 8'd1, 8'd2, 8'd1, 8'd1, 8'd1, 8'd2,
            8'd1, 8'd2, 8'd1, 8'd2, 8'd1, 8'd2, 8'd1, 8'd2,
            8'd1, 8'd2, 8'd2, 8'd2, 8'd1, 8'd2, 8'd2, 8'd2,
            8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2, 8'd2,
            8'd2, 8'd2, 8'd2, 8'd4, 8'd2, 8'd2, 8'd2, 8'd4,
            8'd2, 8'd4, 8'd2, 8'd4, 8'd2, 8'd4, 8'd2, 8'd4,
            8'd2, 8'd4, 8'd4, 8'd4, 8'd2, 8'd4, 8'd4, 8'd4,
            8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4, 8'd4,
            8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8, 8'd8,
            8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0
        };

        // 4 (row 0=112) + 48 (rows 1..12 = {0,8,16,24}×12) + 4×3 (rows 13,14,15) = 64
        ref_eg_sel = '{
            8'd112, 8'd112, 8'd112, 8'd112,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd0, 8'd8, 8'd16, 8'd24, 8'd0, 8'd8, 8'd16, 8'd24,
            8'd32, 8'd40, 8'd48, 8'd56,
            8'd64, 8'd72, 8'd80, 8'd88,
            8'd96, 8'd96, 8'd96, 8'd96
        };

        ref_eg_shft = '{
            8'd12, 8'd12, 8'd12, 8'd12, 8'd11, 8'd11, 8'd11, 8'd11,
            8'd10, 8'd10, 8'd10, 8'd10, 8'd9,  8'd9,  8'd9,  8'd9,
            8'd8,  8'd8,  8'd8,  8'd8,  8'd7,  8'd7,  8'd7,  8'd7,
            8'd6,  8'd6,  8'd6,  8'd6,  8'd5,  8'd5,  8'd5,  8'd5,
            8'd4,  8'd4,  8'd4,  8'd4,  8'd3,  8'd3,  8'd3,  8'd3,
            8'd2,  8'd2,  8'd2,  8'd2,  8'd1,  8'd1,  8'd1,  8'd1,
            8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0,
            8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0,  8'd0
        };

        ref_dl_tab = '{
            10'h000, 10'h020, 10'h040, 10'h060,
            10'h080, 10'h0A0, 10'h0C0, 10'h0E0,
            10'h100, 10'h120, 10'h140, 10'h160,
            10'h180, 10'h1A0, 10'h1C0, 10'h3E0
        };

        // Verify each entry
        for (int i = 0; i < 120; i++) begin
            check_v($sformatf("eg_inc_rom[%0d]", i),
                    {8'd0, eg_inc_rom(7'(i))}, {8'd0, ref_eg_inc[i]});
        end
        for (int i = 0; i < 64; i++) begin
            check_v($sformatf("eg_rate_select_rom[%0d]", i),
                    {8'd0, eg_rate_select_rom(6'(i))}, {8'd0, ref_eg_sel[i]});
        end
        for (int i = 0; i < 64; i++) begin
            check_v($sformatf("eg_rate_shift_rom[%0d]", i),
                    {8'd0, eg_rate_shift_rom(6'(i))}, {8'd0, ref_eg_shft[i]});
        end
        for (int i = 0; i < 16; i++) begin
            check_v($sformatf("dl_tab_rom[%0d]", i),
                    {6'd0, dl_tab_rom(4'(i))}, {6'd0, ref_dl_tab[i]});
        end

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails == 0) $display("*** ALL ROM TABLES MATCH ***");
        $finish;
    end
endmodule

`default_nettype wire
