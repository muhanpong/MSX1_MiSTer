// tb_pcm_regread -- OPL4 wave register readback (ymf278_pcm_engine2 reg_rd_data),
// against openMSX YMF278::peekReg (default -> regs[reg]).
//
// R1  a slot register reads back what was written (fields 0..9), field 4 with
//     bit 5 (LFO reset) intact although it is stored inverted
// R2  Neon Horizon's stop routine (ROM 0x50D8): for 68h..7Fh read, AND 3Fh,
//     OR 40h, write back -> pan / CH / LFO-reset bits survive, key off + damp
//     set; slot 0's decoded pan is still the written one
// R3  a header load backfills fields 5..9 and they read back (openMSX: "Verified
//     on real YMF278: after tone loading ... their value actually has changed")
// R4  a CPU write made after the wave write but before the header arrives wins
//     over the backfill (bf_dirty), and the other fields take the header
// R5  non-slot registers: 00h, 01h, 07h, F8h, F9h, FFh store what was written,
//     reg 3 keeps 6 bits
`timescale 1ns/1ps
`default_nettype none
module tb_pcm_regread;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0;
    logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    logic [7:0]  reg_addr = '0, reg_data = '0;
    logic        reg_wr = 1'b0;
    logic [21:0] mem_addr;
    logic        mem_rd_en, mem_wr_en;
    logic [7:0]  mem_rd_data = '0, mem_wr_data;
    logic [15:0] mem_rd_data16 = '0;
    logic        mem_rd_valid = 1'b0;
    logic signed [15:0] pcm_left, pcm_right;
    logic        pcm_valid;
    logic [7:0]  reg_rd_data, reg02;
    logic [3:0]  dbg_slot0_pan;
    logic [23:0] dbg_hf_pending;

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(1'b0), .pcm_vol(2'd3),
        .reg02_readback(reg02), .reg_rd_data(reg_rd_data),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16), .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data), .mem_busy(1'b0),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_slot0_pan(dbg_slot0_pan), .dbg_hf_pending(dbg_hf_pending));

    //  Fake SDRAM: wave n's 12-byte header at n*12.  Wave 7 (slot 0): bytes 7..11
    //  = 11 22 33 44 55.  Wave 9 (slot 1): bytes 7..11 = A1 B2 C3 D4 E5.
    logic [7:0] rom [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) rom[i] = 8'h00;
        for (int i = 0; i < 5; i++) rom[7*12 + 7 + i] = 8'h11 * (i + 1);
        rom[9*12+7] = 8'hA1; rom[9*12+8] = 8'hB2; rom[9*12+9] = 8'hC3; rom[9*12+10] = 8'hD4; rom[9*12+11] = 8'hE5;
    end
    logic [3:0]  fake_lat;
    logic [21:0] fake_addr;
    always_ff @(posedge clk) begin
        if (!rst_n) begin fake_lat <= '0; mem_rd_valid <= 1'b0; end
        else begin
            mem_rd_valid <= 1'b0;
            if (mem_rd_en) begin fake_lat <= 4'd5; fake_addr <= mem_addr; end
            else if (fake_lat != 0) begin
                fake_lat <= fake_lat - 4'd1;
                if (fake_lat == 4'd1) begin
                    mem_rd_valid  <= 1'b1;
                    mem_rd_data   <= rom[fake_addr[9:0]];
                    mem_rd_data16 <= {rom[{fake_addr[9:1],1'b1}], rom[{fake_addr[9:1],1'b0}]};
                end
            end
        end
    end

    int fails = 0;
    task check(string name, logic ok);
        if (ok) $display("PASS: %s", name); else begin $display("FAIL: %s", name); fails++; end
    endtask
    task write_reg(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr = a; reg_data = d; reg_wr = 1'b1;
        @(negedge clk); reg_wr = 1'b0;
        repeat (3) @(negedge clk);
    endtask
    //  reg_rd_data is registered twice: sample 3 clk after reg_addr changes (the
    //  CPU's 7Fh read comes far later than that on the real bus).
    task read_reg(input [7:0] a, output [7:0] d);
        @(negedge clk); reg_addr = a; repeat (3) @(negedge clk); d = reg_rd_data;
    endtask

    initial begin
        logic [7:0] v, w;
        int bad;
        rst_n = 0; repeat (40) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        write_reg(8'h02, 8'h00);

        //  R1 fields 0..9 of slot 3 (skip field 0: a wave write starts a header load)
        bad = 0;
        for (int f = 1; f < 10; f++) begin
            w = 8'h5A ^ 8'(f * 8'h13);
            write_reg(8'(8'h08 + f*24 + 3), w);
            read_reg(8'(8'h08 + f*24 + 3), v);
            if (v !== w) begin bad++; $display("  field %0d wrote %h read %h", f, w, v); end
        end
        check("R1 slot 3 fields 1..9 read back as written", bad == 0);
        write_reg(8'h6B, 8'h2B); read_reg(8'h6B, v);
        check($sformatf("R1 field 4 bit 5 (LFO reset) survives the inverted storage (%h)", v), v == 8'h2B);
        write_reg(8'h6B, 8'h8D); read_reg(8'h6B, v);
        check($sformatf("R1 field 4 key-on byte reads back (%h)", v), v == 8'h8D);

        //  R2 Neon Horizon's routine over all 24 channels
        for (int n = 0; n < 24; n++) write_reg(8'(8'h68 + n), 8'h80 | 8'((n * 5 + 3) & 8'h3F));
        bad = 0;
        for (int b = 24; b > 0; b--) begin
            logic [7:0] r;
            r = 8'(8'h80 - b);
            read_reg(r, v);
            write_reg(r, (v & 8'h3F) | 8'h40);
        end
        for (int n = 0; n < 24; n++) begin
            read_reg(8'(8'h68 + n), v);
            if (v !== (8'h40 | 8'((n * 5 + 3) & 8'h3F))) begin bad++; $display("  ch %0d read %h", n, v); end
        end
        check("R2 Neon Horizon RMW keeps pan/CH/LFO bits, sets key off + damp", bad == 0);
        //  What the engine itself decodes for slot 0 (dbg_slot0_pan is tied to 0 in
        //  engine2, so it cannot show this): rr_ld while ld_slot is 0.
        wait (dut.ld_slot == 5'd0); @(negedge clk);
        check($sformatf("R2 engine decodes slot 0 pan %0d, damp %0d after the RMW (want 3, 1)", dut.rr_ld.pan, dut.rr_ld.damp),
              dut.ld_slot == 5'd0 && dut.rr_ld.pan == 4'd3 && dut.rr_ld.damp == 1'b1);

        //  R3 header backfill reads back (slot 0, wave 7)
        write_reg(8'h08, 8'd7);
        wait (dbg_hf_pending[0] == 1'b0); repeat (8) @(negedge clk);
        bad = 0;
        for (int i = 0; i < 5; i++) begin
            read_reg(8'(8'h08 + (5 + i) * 24), v);
            if (v !== 8'(8'h11 * (i + 1))) begin bad++; $display("  field %0d read %h", 5 + i, v); end
        end
        check("R3 header bytes 7..11 read back in fields 5..9 after the load", bad == 0);

        //  R4 CPU write after the wave write wins over the backfill (slot 1, wave 9)
        @(negedge clk); reg_addr = 8'h09; reg_data = 8'd9; reg_wr = 1'b1;
        @(negedge clk); reg_addr = 8'h09 + 8'd6*8'd24; reg_data = 8'h7E;   // field 6 slot 1 = 99h
        @(negedge clk); reg_wr = 1'b0;
        check("R4 setup: header for slot 1 still pending after the CPU write", dbg_hf_pending[1] == 1'b1);
        wait (dbg_hf_pending[1] == 1'b0); repeat (8) @(negedge clk);
        read_reg(8'h99, v);
        check($sformatf("R4 field 6 keeps the CPU write 7E (got %h)", v), v == 8'h7E);
        read_reg(8'h81, v); w = v;
        read_reg(8'hB1, v);
        check($sformatf("R4 fields 5 and 7 take the header (A1/C3, got %h/%h)", w, v), w == 8'hA1 && v == 8'hC3);

        //  R5 non-slot registers
        write_reg(8'h00, 8'h5A); write_reg(8'h01, 8'hA5); write_reg(8'h07, 8'h3C);
        write_reg(8'hF8, 8'h1B); write_reg(8'hF9, 8'h2D); write_reg(8'hFF, 8'hC6);
        write_reg(8'h03, 8'hFF); write_reg(8'h04, 8'h12); write_reg(8'h05, 8'h34);
        bad = 0;
        begin
            logic [7:0] a [9]; logic [7:0] e [9];
            a = '{8'h00, 8'h01, 8'h07, 8'hF8, 8'hF9, 8'hFF, 8'h03, 8'h04, 8'h05};
            e = '{8'h5A, 8'hA5, 8'h3C, 8'h1B, 8'h2D, 8'hC6, 8'h3F, 8'h12, 8'h34};
            for (int i = 0; i < 9; i++) begin
                read_reg(a[i], v);
                if (v !== e[i]) begin bad++; $display("  reg %h read %h expected %h", a[i], v, e[i]); end
            end
        end
        check("R5 non-slot registers read back (reg 3 masked to 6 bits)", bad == 0);

        $display("RESULT: %0d error(s)", fails);
        if (fails) $fatal(1, "tb_pcm_regread FAILED");
        $finish;
    end
    initial begin #80ms; $display("RESULT FAIL: timeout"); $fatal(1, "timeout"); end
endmodule
`default_nettype wire
