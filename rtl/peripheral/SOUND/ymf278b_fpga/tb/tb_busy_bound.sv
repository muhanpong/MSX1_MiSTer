// BUSY-bound regression (the vgmplay-OPL4 freeze class).
//
// v2's cpu_issue_ok coupled four FSM conditions; under playback traffic a
// pending CPU mem op could starve FOREVER → cpu_mem_busy stuck 1 → software
// polling BUSY spins → freeze with every freeze-detector dark.
//
// v3 contract under test: cpu_mem_busy NEVER stays asserted longer than
// 2 audio frames (2×1948 cycles), in EVERY situation:
//   1. uploads while 24 slots play under heavy SDRAM contention
//   2. reg02 memory-mode cleared while an op is pending (v2 killer)
//   3. read prefetches (reg05/reg06-read) racing slot fetches
`timescale 1ns/1ps

module tb_busy_bound;
    logic clk = 0;
    always #5.82 clk = ~clk;
    logic rst_n = 0;

    logic [7:0] reg_addr = 0, reg_data = 0;
    logic       reg_wr = 0, reg_rd = 0;
    logic [7:0] cpu_mem_rd_data;
    logic       cpu_mem_busy;
    logic [7:0] reg02_readback;
    logic [21:0] mem_addr;
    logic        mem_rd_en, mem_wr_en;
    logic [7:0]  mem_wr_data;
    logic signed [15:0] pcm_l, pcm_r;
    logic        pcm_v;

    // SDRAM model: variable latency incl. long stalls (contention)
    logic [7:0]  mem [0:65535];
    logic [7:0]  mem_rd_data;
    logic [15:0] mem_rd_data16;
    logic        mem_rd_valid = 0;
    logic        mem_busy_m = 0;
    logic [8:0]  lat_cnt = 0;
    logic [7:0]  lfsr = 8'h5A;
    logic        is_rd;
    logic [21:0] cap_addr;
    logic [7:0]  cap_dat;
    logic [1:0]  mstate = 0;
    always_ff @(posedge clk) begin
        mem_rd_valid <= 1'b0;
        case (mstate)
            2'd0: if (mem_rd_en || mem_wr_en) begin
                cap_addr <= mem_addr; cap_dat <= mem_wr_data; is_rd <= mem_rd_en;
                lfsr <= {lfsr[6:0], lfsr[7]^lfsr[5]};
                lat_cnt <= (lfsr[2:0] == 3'h7) ? 9'd180 : 9'd10;  // 1-in-8 long stall
                mstate <= 2'd1; mem_busy_m <= 1'b1;
            end
            2'd1: begin
                if (lat_cnt != 0) lat_cnt <= lat_cnt - 1'b1;
                else begin
                    if (is_rd) begin
                        mem_rd_data   <= mem[cap_addr[15:0]];
                        mem_rd_data16 <= {mem[{cap_addr[15:1],1'b1}], mem[{cap_addr[15:1],1'b0}]};
                        mem_rd_valid  <= 1'b1;
                    end else
                        mem[cap_addr[15:0]] <= cap_dat;
                    mstate <= 2'd0; mem_busy_m <= 1'b0;
                end
            end
        endcase
    end
    // note: data16 = {odd, even} per sdram.sv ch4 layout

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr), .reg_rd(reg_rd),
        .cpu_mem_rd_data(cpu_mem_rd_data), .cpu_mem_busy(cpu_mem_busy),
        .reg02_readback(reg02_readback),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data),
        .mem_busy(mem_busy_m),
        .pcm_vol(2'd3),
        .pcm_left(pcm_l), .pcm_right(pcm_r), .pcm_valid(pcm_v),
        .dbg_wavetblhdr(), .dbg_hf_pending(),
        .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(),
        .dbg_slot0_pan(), .dbg_slot0_ar(), .dbg_slot0_d1r(),
        .dbg_slot5_wave(), .dbg_slot23_wave(),
        .dbg_slot0_hdr_start(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits()
    );

    int errors = 0;
    longint busy_since = 0;
    localparam longint BUSY_LIMIT_PS = 64'd2 * 1948 * 11640;  // 2 frames in ps

    always @(posedge clk) begin
        if (!cpu_mem_busy) busy_since <= $time;
        else if ($time - busy_since > BUSY_LIMIT_PS) begin
            $display("FAIL[%0t]: cpu_mem_busy stuck > 2 frames", $time);
            errors++;
            busy_since <= $time;
        end
    end

    task automatic wreg(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1; @(negedge clk); reg_wr=0;
        repeat (6) @(negedge clk);
    endtask
    task automatic rreg(input [7:0] a);
        @(negedge clk); reg_addr=a; reg_rd=1; @(negedge clk); reg_rd=0;
        repeat (6) @(negedge clk);
    endtask
    // wait for BUSY clear (like pcmload's poll), bounded
    task automatic wait_busy(input string what);
        int t; t = 0;
        while (cpu_mem_busy && t < 6000) begin @(negedge clk); t++; end
        if (cpu_mem_busy) begin
            $display("FAIL: BUSY never cleared (%s)", what); errors++;
        end
    endtask

    initial begin
        // simple ramp "samples" + fake headers in the model memory
        for (int i = 0; i < 65536; i++) mem[i] = 8'(i * 7);

        repeat (10) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        // key on 24 slots (wave numbers → header fetches → playback traffic)
        for (int s = 0; s < 24; s++) begin
            wreg(8'(8'h08 + s), 8'(s));        // wave
            wreg(8'(8'h68 + s), 8'h80);        // keyon
        end
        repeat (30 * 1948) @(negedge clk);     // let HF/attack settle

        // ── 1. paced upload DURING playback (ST04 streaming pattern) ──
        wreg(8'h02, 8'h11);                    // mem access mode on
        wreg(8'h03, 8'h20); wreg(8'h04, 8'h00); wreg(8'h05, 8'h00);
        for (int i = 0; i < 64; i++) begin
            wreg(8'h06, 8'(i));
            wait_busy($sformatf("upload byte %0d", i));
        end
        $display("upload-during-playback done, errors=%0d", errors);

        // ── 2. v2 killer: clear memory mode while an op is in flight ──
        wreg(8'h06, 8'hA5);                    // write pends
        wreg(8'h02, 8'h10);                    // mode OFF immediately
        wait_busy("mode cleared mid-op");
        repeat (4 * 1948) @(negedge clk);
        if (cpu_mem_busy) begin $display("FAIL: busy stuck after mode clear"); errors++; end

        // ── 3. read prefetch racing playback ──
        wreg(8'h02, 8'h11);
        wreg(8'h03, 8'h20); wreg(8'h04, 8'h00); wreg(8'h05, 8'h00);
        for (int i = 0; i < 32; i++) begin
            rreg(8'h06);
            wait_busy($sformatf("read %0d", i));
        end

        // ── 4. sustained playback, BUSY watchdog armed ──
        repeat (60 * 1948) @(negedge clk);

        if (errors == 0) $display("ALL PASS: BUSY bounded in all scenarios");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #80ms;
        $display("FAIL: TB wedged. busy=%b", cpu_mem_busy);
        $finish;
    end
endmodule
