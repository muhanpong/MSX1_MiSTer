// TL (Total Level) volume ramp — verify the openMSX volume-interpolation:
//   field-3 write: data[7:1]=TL target (0x7f→0xff), data[0]=1 load immediate.
//   advance(): every 9 samples, tl_int_step 0 → TL++ (toward quieter, 1/27 samp),
//              steps 1,2 → TL-- (toward louder, ~1/13.5 samp).
`timescale 1ns/1ps
`default_nettype none

module tb_tlramp;
    localparam real CLK = 1e9/85909090.0;
    logic clk=0, rst_n; always #(CLK/2.0) clk=~clk;

    logic [7:0]  reg_addr=0, reg_data=0; logic reg_wr=0, reg_rd=0;
    logic [21:0] mem_addr; logic mem_rd_en;
    logic [7:0]  mem_rd_data=0; logic [15:0] mem_rd_data16=0; logic mem_rd_valid;
    logic        mem_wr_en; logic [7:0] mem_wr_data; logic mem_busy=0;
    logic signed [15:0] pcm_left, pcm_right; logic pcm_valid;

    // Minimal SDRAM stub: answer every read 1 cycle later (reads always complete
    // so the pipeline advances; TL ramp is independent of read data anyway).
    logic rd_d;
    always_ff @(posedge clk) begin rd_d <= mem_rd_en; mem_rd_valid <= rd_d; end

    logic [7:0] cpu_mem_rd_data; logic cpu_mem_busy; logic [7:0] reg02_readback;
    ymf278_pcm_engine dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(reg_rd),
        .cpu_mem_rd_data(cpu_mem_rd_data), .cpu_mem_busy(cpu_mem_busy), .reg02_readback(reg02_readback),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16), .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data), .mem_busy(1'b0),
        .pcm_vol(2'd1),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_wavetblhdr(), .dbg_hf_pending(),
        .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(),
        .dbg_slot0_pan(), .dbg_slot0_ar(), .dbg_slot0_d1r(),
        .dbg_slot5_wave(), .dbg_slot23_wave(),
        .dbg_slot0_hdr_start(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits()
    );

    int passes=0, fails=0;
    task chk(string n, logic ok); if(ok)begin $display("PASS: %s",n);passes++;end
        else begin $display("FAIL: %s",n);fails++;end endtask
    task wr(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1; @(negedge clk); reg_wr=0; endtask
    task frames(input int n); repeat(n*1948) @(posedge clk); endtask

    // slot 0, field 3 register = 0x08 + 3*24 = 0x50
    localparam [7:0] F3 = 8'h50;

    int t0;
    initial begin
        rst_n=0; repeat(20) @(posedge clk); rst_n=1; repeat(10) @(posedge clk);

        // tl_cur starts at 0
        chk("reset: tl_cur[0]==0", dut.tl_cur[0]==8'd0);

        // --- Ramp UP (toward quieter): target 0x40, bit0=0 (ramp) ---
        //   data = (0x40<<1)|0 = 0x80
        wr(F3, 8'h80);
        frames(70);  // up-ramp is slow (1 step / 27 samples) → ~2 steps after 70
        chk("ramp up: tl_cur moved toward target but not there yet (0<cur<0x40)",
            dut.tl_cur[0] > 8'd0 && dut.tl_cur[0] < 8'h40);
        t0 = dut.tl_cur[0];
        frames(60); // → at least one more step
        chk("ramp up: tl_cur keeps rising toward target", dut.tl_cur[0] > t0[7:0]);

        // --- Immediate load: target 0x10, bit0=1 ---
        //   data = (0x10<<1)|1 = 0x21
        wr(F3, 8'h21);
        frames(1);
        chk("immediate load: tl_cur[0]==0x10 right away", dut.tl_cur[0]==8'h10);

        // --- Ramp DOWN (toward louder, faster): from 0x10 set target 0x00 ---
        //   data = (0x00<<1)|0 = 0x00
        wr(F3, 8'h00);
        t0 = dut.tl_cur[0];
        frames(20); // down-ramp is ~2x faster (/13.5); should drop several steps
        chk("ramp down: tl_cur falls toward 0", dut.tl_cur[0] < t0[7:0]);
        frames(200);
        chk("ramp down: reaches target 0", dut.tl_cur[0]==8'd0);

        // --- TL=0x7f maps to 0xff (max attenuation), immediate ---
        //   data = (0x7f<<1)|1 = 0xFF
        wr(F3, 8'hFF);
        frames(1);
        chk("TL 0x7f -> 0xff immediate", dut.tl_cur[0]==8'hFF);

        $display("\n=== %0d PASS, %0d FAIL ===", passes, fails);
        if (fails==0) $display("*** ALL TESTS PASSED ***");
        $finish;
    end
    initial begin #50ms; $display("TIMEOUT"); $finish; end
endmodule
