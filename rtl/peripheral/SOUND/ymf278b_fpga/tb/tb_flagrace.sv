// engine3 directed bench: a CPU flag write in the clk pass A clears that slot's
// flags (c76854e: the flags are one MLAB word per slot, the clear waits for a
// clk without a CPU flag write and keeps the bits that write sets).
//
// Per case: pass A reads slot S's flags in clk t (A_LD, lcnt 2) and clears them
// in t+1; a CPU write is placed so that reg_wr is sampled at the end of clk
// t + 1 + offset (offset 0 = the clear clk itself):
//   retrig  (wave-number write while keyed on; slots 0, 7, 23; offsets -1..+1)
//   tl_load (field 3 write with bit 0;          slots 0, 7, 23; offsets -1..+1)
//   pos_clr (wave-number write while keyed off; slot 12, releasing; -1..+1)
//     event 1 lands in frame cycle 1000 before the pass, event 2 at the offset;
//     at A's next visit the flag must be set for offsets 0 and +1 (event 2 came
//     after A's read) and clear for -1 (merged into event 1, as a set and a
//     clear one clk apart on flip-flops);
//   keyoff  (field 4 write with key-on 0: only the word's keyon bit changes;
//     slots 0, 7, 23; offsets -2..+1): the keyon bit must read 0 at the next
//     visit -- A's clear builds its word from the MLAB in its own clk, so it
//     cannot write an older keyon back.
// Every offset-0 case must hit the collision (a_take and a CPU flag write in the
// same clk).  The verdict reads engine flags, not audio.
// Controls (harness `flagrace`): set-wins mask dropped, A's clear taking the port
// over the CPU, and A's clear writing the word it read in clk t (stale).
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

    //  pass A reads slot s's flags in this clk (sampled at a negedge); a_lcnt is 1 only in
    //  the A_LD clk before (A_SEL zeroes it, only A_LD counts)
    function automatic bit a_reads(input int s);
        return dut.a_flags_rd && dut.a_slot == 5'(s);
    endfunction
    function automatic bit a_before(input int s);
        return dut.a_lcnt == 5'd1 && dut.a_slot == 5'(s);
    endfunction
    task automatic wait_frame_cycle(input int c);
        do @(negedge clk); while (int'(dut.frame_cycle) != c);
    endtask

    int n_fail = 0, n_pass = 0, n_hit = 0, n_k0 = 0;
`ifdef FR_TRACE
    //  every flag-word write to slot FR_TRACE, and pass A's read of it
    always @(negedge clk) if (rst_n && dut.ev_we && dut.ev_wa == 5'(`FR_TRACE))
        $display("t%0t fc %0d EVW %b cpu %0d take %0d", $time, dut.frame_cycle, dut.ev_wd, dut.ev_cwe, dut.a_take);
    always @(negedge clk) if (rst_n && dut.a_flags_rd && dut.a_slot == 5'(`FR_TRACE))
        $display("t%0t fc %0d AREAD %b", $time, dut.frame_cycle, dut.ev_rd);
`endif
    int SL [3] = '{0, 7, 23};
    localparam int K_RETRIG = 0, K_TL = 1, K_PCLR = 2, K_KOFF = 3;
    function automatic string kname(input int k);
        return (k == K_RETRIG) ? "retrig" : (k == K_TL) ? "tl_load" : (k == K_PCLR) ? "pos_clr" : "keyoff";
    endfunction

    //  one case.  A reads the flags in clk t (lcnt 2) and clears them in t+1; the CPU write
    //  is sampled at the end of clk t + 1 + off (off 0 = the clear clk).
    //    retrig / tl_load / pos_clr: event 1 at frame cycle 1000 before the pass, event 2 at
    //      off; the flag at the next visit is set for off >= 0, clear for off = -1 (merged)
    //    keyoff: a field 4 write with key-on 0 (the word's keyon bit only); the keyon bit
    //      must read 0 at the next visit for every off -- the clear writes the word it reads
    //      in its own clk, so it cannot write the old keyon back
    task automatic run_case(input int s, input int k, input int off);
        bit got, want, hit, ran;
        logic [7:0] a, d;
        a = (k == K_TL) ? sreg(3, s) : (k == K_KOFF) ? sreg(4, s) : sreg(0, s);
        d = (k == K_TL) ? 8'h0B : (k == K_KOFF) ? 8'h20 : 8'h00;
        wait_frame_cycle(1000);
        if (k == K_TL) wr(a, 8'h09); else if (k != K_KOFF) wr(a, 8'h00);
        do @(negedge clk); while (!a_before(s));
        repeat (off + 2) @(negedge clk);
        reg_addr = a; reg_data = d; reg_wr = 1;
        #1;                                       // let the engine's comb logic see reg_wr
        hit = dut.a_take && dut.ev_cwe && (dut.a_slot == 5'(s));
        @(negedge clk); reg_wr = 0;
        if (off == 0) begin n_k0++; if (hit) n_hit++; end
        do @(negedge clk); while (!a_reads(s));
        ran  = (dut.d_est != 3'd0) || dut.key_retrig_a;   // EG_OFF = 0: the slot runs
        got  = (k == K_RETRIG) ? dut.key_retrig_a : (k == K_TL) ? dut.tl_load_a :
               (k == K_PCLR) ? dut.pos_clr_a : dut.ev_b[s][3];
        want = (k == K_KOFF) ? 1'b0 : (off >= 0);
        if (off == 0 && !hit) begin
            $display("NOHIT slot %0d %s off %0d: the clear clk and the CPU write did not meet", s, kname(k), off);
            n_fail++;
        end else if (k == K_PCLR && !ran) begin
            $display("INVALID slot %0d pos_clr off %0d: the slot is off, A does not consume pos_clr", s, off);
            n_fail++;
        end else if (got !== want) begin
            $display("BAD slot %0d %s off %0d: %s at the next visit %0d, want %0d", s, kname(k), off,
                     (k == K_KOFF) ? "keyon bit" : "flag", got, want);
            n_fail++;
        end else n_pass++;
        repeat (2 * dut.CYCLES_PER_FRAME) @(negedge clk);
        if (k == K_KOFF) begin
            //  key on again away from the pass (frame cycle 1000) and check it took: a
            //  restore that lands in A's clear clk by accident is what showed the stale
            //  mutant wiping keyon on slot 0, unchecked, before this check (2026-10-29)
            wait_frame_cycle(1000);
            wr(sreg(4, s), 8'hA0);
            do @(negedge clk); while (!a_reads(s));
            if (dut.ev_b[s][3] !== 1'b1) begin
                $display("BAD slot %0d keyoff off %0d: key-on again did not stick (keyon bit 0)", s, off);
                n_fail++;
            end
            repeat (2 * dut.CYCLES_PER_FRAME) @(negedge clk);
        end
    endtask

    //  watchdog: the whole run is under 500 frames
    initial begin
        #(500.0 * 1.0e9 / 44100.0);
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
        for (int i = 0; i < 4; i++) begin
            int s;
            s = (i < 3) ? SL[i] : 12;
            wr(sreg(0, s), 8'h00);
            wr(sreg(1, s), 8'h00);
            wr(sreg(2, s), 8'h02);
            wr(sreg(3, s), 8'h09);
            wr(sreg(4, s), 8'hA0);
        end
        repeat (4 * dut.CYCLES_PER_FRAME) @(negedge clk);
        for (int i = 0; i < 3; i++)
            for (int k = K_RETRIG; k <= K_TL; k++)
                for (int off = -1; off <= 1; off++) run_case(SL[i], k, off);
        //  pos_clr: slot 12 keyed off, still releasing (RR from wave 0's header)
        wr(sreg(4, 12), 8'h20);
        for (int off = -1; off <= 1; off++) run_case(12, K_PCLR, off);
        for (int i = 0; i < 3; i++)
            for (int off = -2; off <= 1; off++) run_case(SL[i], K_KOFF, off);
        $display("FLAGRACE %s: %0d cases pass, %0d fail; offset-0 collisions hit %0d/%0d",
                 (n_fail == 0 && n_hit == n_k0) ? "PASS" : "FAIL", n_pass, n_fail, n_hit, n_k0);
        $finish;
    end
endmodule
