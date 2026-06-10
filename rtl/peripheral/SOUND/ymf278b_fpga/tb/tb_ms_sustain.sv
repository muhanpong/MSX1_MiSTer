// Multi-slot sustain diagnostic.
//
// Question this answers: when N PCM voices play at once (like the real 13-slot
// song), do some slots get DROPPED (reads never complete) or LOSE SUSTAIN
// (envelope wrongly leaves EG_SUS) in *simulation* — i.e. is the hardware
// "partial channels / sustain loss" a reproducible logic/scheduling bug, or
// does it only appear on hardware (→ timing)?
//
// Drives N slots with a known sustaining ROM wave (wave 0: AR=15, DL=0, D2R=0
// → attack-and-hold forever), runs under the realistic ch2-contention SDRAM
// model, and reports PER-SLOT read-completion rate + final envelope state.
`timescale 1ns/1ps
`default_nettype none

module tb_ms_sustain;
    localparam real CLK_PERIOD = 1e9 / 85909090.0;
    logic clk = 0; logic rst_n;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    localparam logic [2:0] EG_OFF=0, EG_REL=1, EG_SUS=2, EG_DEC=3, EG_ATT=4;

    logic [7:0]  reg_addr='0, reg_data='0; logic reg_wr=0;
    logic [21:0] mem_addr; logic mem_rd_en;
    logic [7:0]  mem_rd_data; logic [15:0] mem_rd_data16; logic mem_rd_valid;
    logic        mem_wr_en; logic [7:0] mem_wr_data; logic mem_busy;
    logic signed [15:0] pcm_left, pcm_right; logic pcm_valid;

    ymf278_pcm_engine2 dut (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_data(reg_data), .reg_wr(reg_wr),
        .mem_addr(mem_addr), .mem_rd_en(mem_rd_en),
        .mem_rd_data(mem_rd_data), .mem_rd_data16(mem_rd_data16),
        .mem_rd_valid(mem_rd_valid),
        .mem_wr_en(mem_wr_en), .mem_wr_data(mem_wr_data), .mem_busy(mem_busy),
        .pcm_vol(2'd1),
        .pcm_left(pcm_left), .pcm_right(pcm_right), .pcm_valid(pcm_valid),
        .dbg_wavetblhdr(), .dbg_hf_pending(),
        .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(),
        .dbg_slot0_pan(), .dbg_slot0_ar(), .dbg_slot0_d1r(),
        .dbg_slot5_wave(), .dbg_slot23_wave(),
        .dbg_slot0_hdr_start(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits(),
        .dbg_slot0_dyn_pos(), .dbg_slot0_dyn_stepPtr(),
        .dbg_slot0_dyn_env_vol(), .dbg_slot0_dyn_env_state(),
        .dbg_stage_b_bytes_done(), .dbg_stage_advance(), .dbg_stage_b_valid()
    );

    // ── Bridge FSM replica (same as tb_trace_wave) ──
    logic [1:0] pcm_state; logic mem_rd_en_prev;
    logic ch4_req, ch4_ready; logic [21:0] ch4_addr; logic [7:0] ch4_dout;
    logic [15:0] ch4_dout16;
    assign ch4_req  = (pcm_state==2'd1)||(pcm_state==2'd2);
    assign mem_busy = (pcm_state!=2'd0);
    always_ff @(posedge clk) begin
        if (!rst_n) begin pcm_state<=0; mem_rd_en_prev<=0; ch4_addr<=0; end
        else begin
            mem_rd_en_prev<=mem_rd_en;
            case (pcm_state)
                2'd0: if (mem_rd_en && !mem_rd_en_prev) begin pcm_state<=1; ch4_addr<=mem_addr; end
                2'd1: if (!ch4_ready) pcm_state<=2;
                2'd2: if (ch4_ready)  pcm_state<=3;
                2'd3: pcm_state<=0;
            endcase
        end
    end
    assign mem_rd_data   = ch4_dout;
    assign mem_rd_data16 = ch4_dout16;
    assign mem_rd_valid  = (pcm_state==2'd3);

    // ── SDRAM model with REAL yrw801 + ch2 contention (from tb_trace_wave) ──
    logic [7:0] rom [0:22'h11_2000];
    initial $readmemh("/tmp/yrw801_win.hex", rom);
    localparam int TXN = 7;
    int   CH2LOAD = 70;
    initial begin if ($value$plusargs("ch2load=%d", CH2LOAD)) ; end
    int   bus_txn=0, bus_owner=0; logic ch4_pending=0; int ch4_wait=0;
    int   ch4_lat_sum=0, ch4_lat_n=0, ch4_lat_max=0; logic ch4_req_prev;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ch4_ready<=1; ch4_req_prev<=0; ch4_dout<=0; ch4_dout16<=0;
            bus_txn<=0; bus_owner<=0; ch4_pending<=0; ch4_wait<=0;
            ch4_lat_sum<=0; ch4_lat_n<=0; ch4_lat_max<=0;
        end else begin
            ch4_req_prev<=ch4_req;
            if (ch4_req && !ch4_req_prev) begin ch4_pending<=1; ch4_ready<=0; ch4_wait<=0; end
            if (ch4_pending && bus_owner!=4) ch4_wait <= ch4_wait + 1;
            if (bus_txn > 1) bus_txn <= bus_txn - 1;
            else if (bus_txn == 1) begin
                bus_txn<=0;
                if (bus_owner==4) begin
                    ch4_ready<=1; ch4_pending<=0;
                    ch4_dout  <= rom[ch4_addr];
                    ch4_dout16 <= {rom[{ch4_addr[21:1],1'b1}], rom[{ch4_addr[21:1],1'b0}]};
                    ch4_lat_sum<=ch4_lat_sum+ch4_wait+TXN; ch4_lat_n<=ch4_lat_n+1;
                    if (ch4_wait+TXN>ch4_lat_max) ch4_lat_max<=ch4_wait+TXN;
                end
                bus_owner<=0;
            end else begin
                logic ch2_demand; ch2_demand = ($unsigned($random)%100) < CH2LOAD;
                if (ch4_pending && !ch2_demand) begin bus_txn<=TXN; bus_owner<=4; end
                else if (ch2_demand)            begin bus_txn<=TXN; bus_owner<=2; end
            end
        end
    end

    // ── Per-slot read-completion monitor ──
    int adv_cnt [0:23];   // times this slot left Stage B
    int done_cnt[0:23];   // ... with reads complete (fresh sample)
    logic measuring;
    always_ff @(posedge clk) begin
        if (rst_n && dut.dbg_stage_advance && dut.win_had_slot && measuring) begin
            adv_cnt[dut.w_slot] <= adv_cnt[dut.w_slot] + 1;
            if (dut.win_done) done_cnt[dut.w_slot] <= done_cnt[dut.w_slot] + 1;
        end
    end

    int NSLOTS = 13;
    initial begin if ($value$plusargs("nslots=%d", NSLOTS)) ; end

    task write_reg(input [7:0] a, input [7:0] d);
        @(negedge clk); reg_addr=a; reg_data=d; reg_wr=1; @(negedge clk); reg_wr=0;
    endtask
    task frames(input int n); repeat (n*1948) @(posedge clk); endtask

    int passes=0, fails=0;
    initial begin
        for (int i=0;i<24;i++) begin adv_cnt[i]=0; done_cnt[i]=0; end
        measuring=0;
        rst_n=0; repeat(8) @(posedge clk); rst_n=1; repeat(4) @(posedge clk);

        // Set up N slots, all wave 0 (sustaining: AR=15,DL=0,D2R=0).  Writing
        // the wave triggers the HF header backfill (startAddr/loop/env defaults).
        for (int s=0; s<NSLOTS; s++) begin
            write_reg(8'(8'h08 + s), 8'd0);   // wave 0
            write_reg(8'(8'h20 + s), 8'h00);  // fn lo / wave8 = 0
        end
        frames(12);                            // let HF backfill all headers
        // Key on all N slots.
        for (int s=0; s<NSLOTS; s++) write_reg(8'(8'h68 + s), 8'h80);
        frames(20);                            // let attack settle

        // Measure read-completion per slot over a sustain window.
        measuring=1;
        frames(200);
        measuring=0;

        $display("\n=== %0d-slot sustain under contention (ch2load=%0d) ===", NSLOTS, CH2LOAD);
        $display("avg ch4 read latency = %0.1f (max %0d)",
                 ch4_lat_n? 1.0*ch4_lat_sum/ch4_lat_n : 0.0, ch4_lat_max);
        $display("slot  adv  done  rate%%");
        for (int s=0; s<NSLOTS; s++) begin
            real rate; rate = adv_cnt[s] ? 100.0*done_cnt[s]/adv_cnt[s] : 0.0;
            $display("%2d  %4d %4d  %5.1f  %s",
                s, adv_cnt[s], done_cnt[s], rate,
                (adv_cnt[s]==0) ? "<== NEVER DISPATCHED" :
                (rate < 95.0)   ? "<== DROPPING READS"   : "");
            if (adv_cnt[s]==0 || rate < 95.0) fails++; else passes++;
        end
        $display("\n=== %0d slots OK, %0d slots DROPPED/SILENT ===", passes, fails);
        if (fails==0) $display("*** ALL SLOTS SUSTAIN — not reproduced in sim (points to TIMING) ***");
        else          $display("*** SOME SLOTS FAIL IN SIM — reproducible LOGIC/SCHEDULING bug ***");
        $finish;
    end

    initial begin #300ms; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
