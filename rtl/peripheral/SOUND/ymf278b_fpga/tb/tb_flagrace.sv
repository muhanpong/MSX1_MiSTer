// engine3 directed bench: a CPU flag write in the clk pass A clears that slot's
// flags (c76854e: the flags are one MLAB word per slot, the clear waits for a
// clk without a CPU flag write and keeps the bits that write sets).
//
// Per slot S in {0, 7, 23}, per event (retrig = wave-number write while keyed
// on, tl_load = field 3 write with bit 0), per offset in {-1, 0, +1}:
//   1. event 1 in frame cycle 1000 of the frame before a pass;
//   2. pass A reads slot S's flags in clk t (A_LD, lcnt 2); its clear is due in
//      t+1.  Event 2 is written so that reg_wr is sampled at the end of clk
//      t + 1 + offset (offset 0 = the clear clk itself);
//   3. at A's next visit of S the flag must read set for offsets 0 and +1
//      (event 2 came after A's read) and clear for -1 (event 2 landed in A's
//      read clk and merged into event 1, as a set and a clear one clk apart).
// Offset 0 also checks that the collision happened (a_take and a CPU flag
// write in the same clk).  The verdict reads engine flags (key_retrig_a,
// tl_load_a), not audio.
//
// Control: without the set-wins mask (a_take_m <= a_take_m) offset 0 FAILs.
`timescale 1ns/1ps

module tb_flagrace #(parameter int CLK_HZ = 128863620);
    localparam real HALF = 1.0e9 / (2.0 * CLK_HZ);
    logic clk = 0;
    always #(HALF) clk = ~clk;
    logic rst_n = 0;

    logic [7:0] reg_addr = 0, reg_data = 0;
    logic       reg_wr = 0;
    logic [21:0] mem_addr;
    logic        mem_rd_en, mem_wr_en;
    logic [7:0]  mem_wr_data, mem_rd_data;
    logic [15:0] mem_rd_data16, mem_rd_data16b;
    logic        mem_rd_valid = 0;
    logic [15:0] late_cnt;

    logic [7:0] mem [0:4194303];
    always_ff @(posedge clk) begin           // latency-1 memory, pairs as the bridge gives them
        mem_rd_valid <= 1'b0;
        if (mem_rd_en) begin
            mem_rd_data    <= mem[mem_addr];
            mem_rd_data16  <= {mem[{mem_addr[21:1], 1'b1}], mem[{mem_addr[21:1], 1'b0}]};
            mem_rd_data16b <= {mem[{mem_addr[21:1] ^ 21'd1, 1'b1}], mem[{mem_addr[21:1] ^ 21'd1, 1'b0}]};
            mem_rd_valid   <= 1'b1;
        end
        if (mem_wr_en) mem[mem_addr] <= mem_wr_data;
    end

    ymf278_pcm_engine3 #(.CLK_HZ(CLK_HZ)) dut (
        .clk, .rst_n, .reg_addr, .reg_data, .reg_wr, .reg_rd(1'b0),
        .cpu_mem_rd_data(), .cpu_mem_busy(), .reg02_readback(), .reg_rd_data(),
        .mem_addr, .mem_rd_en, .mem_rd_data, .mem_rd_data16, .mem_rd_data16b, .mem_rd_valid,
        .mem_wr_en, .mem_wr_data, .mem_busy(1'b0), .pcm_vol(2'd3),
        .pcm_left(), .pcm_right(), .pcm_valid(),
        .dbg_wavetblhdr(), .dbg_hf_pending(), .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(), .dbg_slot0_pan(), .dbg_slot0_ar(),
        .dbg_slot0_d1r(), .dbg_slot5_wave(), .dbg_slot23_wave(), .dbg_slot0_hdr_start(),
        .dbg_slot0_hdr_loop(), .dbg_slot0_hdr_end(), .fm_mix_l_o(), .fm_mix_r_o(),
        .dbg_slot0_hdr_bits(), .dbg_slot0_dyn_pos(), .dbg_slot0_dyn_stepPtr(),
        .dbg_slot0_dyn_env_vol(), .dbg_slot0_dyn_env_state(), .dbg_stage_b_bytes_done(),
        .dbg_stage_advance(), .dbg_stage_b_valid(), .dbg_slot_keyon(), .dbg_slot_active(),
        .dbg_slot_envlive(), .dbg_late_cnt(late_cnt));

    task automatic wr(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr = a; reg_data = d; reg_wr = 1;
        @(negedge clk); reg_wr = 0;
        repeat (2) @(negedge clk);
    endtask
    function automatic [7:0] sreg(input int field, input int s); return 8'(8'h08 + 24 * field + s); endfunction

    //  pass A reads slot s's flags in this clk (sampled at a negedge)
    function automatic bit a_reads(input int s);
        return dut.a_flags_rd && dut.a_slot == 5'(s);
    endfunction
    task automatic wait_frame_cycle(input int c);
        do @(negedge clk); while (int'(dut.frame_cycle) != c);
    endtask

    int n_fail = 0, n_pass = 0, n_hit = 0;
    int SL [3] = '{0, 7, 23};

    //  one case: returns via n_pass / n_fail
    task automatic run_case(input int s, input bit tl, input int off);
        bit got, want, hit;
        $display("case slot %0d %s off %0d", s, tl ? "tl_load" : "retrig", off);
        //  event 1 well before the pass, then wait for A's read of slot s
        wait_frame_cycle(1000);
        if (tl) wr(sreg(3, s), 8'h09); else wr(sreg(0, s), 8'h00);
        do @(negedge clk); while (!a_reads(s));
        //  event 2: reg_wr sampled at the end of clk t + 1 + off
        repeat (off + 1) @(negedge clk);
        reg_addr = tl ? sreg(3, s) : sreg(0, s);
        reg_data = tl ? 8'h0B : 8'h00;
        reg_wr   = 1;
        #1;                                       // let the engine's comb logic see reg_wr
        hit = dut.a_take && dut.ev_cwe && (dut.a_slot == 5'(s));
        @(negedge clk); reg_wr = 0;
        if (off == 0 && hit) n_hit++;
        //  the next visit of slot s
        do @(negedge clk); while (!a_reads(s));
        got  = tl ? dut.tl_load_a : dut.key_retrig_a;
        want = (off >= 0);
        if (off == 0 && !hit) begin
            $display("NOHIT slot %0d %s off %0d: the clear clk and the CPU write did not meet", s, tl ? "tl_load" : "retrig", off);
            n_fail++;
        end else if (got !== want) begin
            $display("BAD slot %0d %s off %0d: flag at the next visit %0d, want %0d", s, tl ? "tl_load" : "retrig", off, got, want);
            n_fail++;
        end else n_pass++;
        //  let the flag (if any) be consumed before the next case
        repeat (2 * dut.CYCLES_PER_FRAME) @(negedge clk);
    endtask

    //  watchdog: the whole run is under 200 frames
    initial begin
        #(200.0 * 1.0e9 / 44100.0);
        $display("FLAGRACE FAIL: watchdog (stuck at a wait), %0d pass %0d fail", n_pass, n_fail);
        $finish;
    end

    initial begin
        string mem_f;
        if (!$value$plusargs("mem=%s", mem_f)) mem_f = "mem.hex";
        $readmemh(mem_f, mem);
        repeat (300) @(negedge clk);
        rst_n = 1; $display("reset released, CPF %0d", dut.CYCLES_PER_FRAME);
        repeat (4 * dut.CYCLES_PER_FRAME) @(negedge clk);
        //  key on slots 0, 7, 23: wave 0 (8-bit ramp, loop), mid pitch, LFO off
        for (int i = 0; i < 3; i++) begin
            int s;
            s = SL[i];
            wr(sreg(0, s), 8'h00);
            wr(sreg(1, s), 8'h00);
            wr(sreg(2, s), 8'h02);
            wr(sreg(3, s), 8'h09);
            wr(sreg(4, s), 8'hA0);
        end
        repeat (4 * dut.CYCLES_PER_FRAME) @(negedge clk);
        for (int i = 0; i < 3; i++)
            for (int tl = 0; tl < 2; tl++)
                for (int off = -1; off <= 1; off++)
                    run_case(SL[i], tl[0], off);
        $display("FLAGRACE %s: %0d cases pass, %0d fail; offset-0 collisions hit %0d/6",
                 (n_fail == 0 && n_hit == 6) ? "PASS" : "FAIL", n_pass, n_fail, n_hit);
        $finish;
    end
endmodule
