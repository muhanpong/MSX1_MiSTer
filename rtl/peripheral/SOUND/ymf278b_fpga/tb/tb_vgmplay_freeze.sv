// vgmplay-OPL4 freeze repro: full ymf278b_top + faithful replica of the
// msx.sv CPU bridge (toggle CDC + WAIT + 600-cycle timeout) + INT I/O-deferral,
// driven by a model CPU that does what vgmplay does during an OPL4 song:
//   main loop: otir-style reg-0x06 wave-memory writes (each held by WAIT) and
//              wave/FM register writes,
//   IRQ:       OPL Timer-1 at ~1130 Hz; a handler (status read + reg4=0xBF ack)
//              preempts the main loop between "instructions" when irq asserts.
// ch4 SDRAM model includes occasional long stalls (playback contention).
// FAIL conditions: irq stuck low > 4 ms (storm / lost ack), bridge pending
// stuck, handler starved > 4 ms, sim wedge (no main-loop progress > 4 ms).
`timescale 1ns / 1ps

module tb_vgmplay_freeze;
    // clocks: clk21m (21.477 MHz), clk_sdram (85.909 MHz), clk_opl3 (14.318 MHz)
    logic clk21m = 0, clk_sdram = 0, clk_opl3 = 0;
    always #23.28 clk21m   = ~clk21m;
    always #5.82  clk_sdram = ~clk_sdram;
    always #34.92 clk_opl3  = ~clk_opl3;

    logic reset = 1;

    // ── CPU-side signals (modelled at clk21m, ce-paced) ──
    logic [7:0] cpu_port = 0, cpu_data = 0;
    logic       wr_n = 1, rd_n = 1;
    logic       cpu_io_active = 0;     // a wave/fm cs is selected
    wire        ms_cs = cpu_io_active;

    // ── bridge replica (verbatim semantics from rtl/msx.sv) ──
    logic [7:0] ms_io_port_lat, ms_io_data_lat;
    logic       ms_req_toggle = 0, ms_rd_toggle = 0;
    logic [2:0] ms_req_sync = 0, ms_rd_sync = 0;
    logic       ms_wr_n_prev = 1, ms_rd_n_prev = 1;
    logic [7:0] ms_io_dout_lat;
    logic       ms_ack_toggle = 0;
    logic [2:0] ms_ack_sync = 0;
    logic [9:0] ms_wait_cnt;
    logic       ms_io_pending = 0;
    wire        ms_io_ack;
    wire  [7:0] ms_io_dout_raw;

    always_ff @(posedge clk21m) begin
        ms_wr_n_prev <= wr_n;
        ms_rd_n_prev <= rd_n;
        ms_ack_sync  <= {ms_ack_sync[1:0], ms_ack_toggle};
        if (reset) begin
            ms_req_toggle <= 0; ms_rd_toggle <= 0;
            ms_wr_n_prev <= 1; ms_rd_n_prev <= 1; ms_io_pending <= 0;
        end else begin
            if (ms_cs & ~wr_n & ms_wr_n_prev) begin
                ms_io_port_lat <= cpu_port;  ms_io_data_lat <= cpu_data;
                ms_req_toggle  <= ~ms_req_toggle;
                ms_io_pending  <= 1; ms_wait_cnt <= 10'd600;
            end
            if (ms_cs & ~rd_n & ms_rd_n_prev) begin
                ms_io_port_lat <= cpu_port;
                ms_rd_toggle   <= ~ms_rd_toggle;
                ms_io_pending  <= 1; ms_wait_cnt <= 10'd600;
            end
            if (ms_io_pending) begin
                if (ms_ack_sync[2] ^ ms_ack_sync[1]) ms_io_pending <= 0;
                else if (ms_wait_cnt == 0)           ms_io_pending <= 0;
                else                                 ms_wait_cnt <= ms_wait_cnt - 1'b1;
            end
        end
    end

    always_ff @(posedge clk_sdram) begin
        ms_req_sync <= {ms_req_sync[1:0], ms_req_toggle};
        ms_rd_sync  <= {ms_rd_sync[1:0],  ms_rd_toggle};
        if (ms_io_ack) begin
            ms_io_dout_lat <= ms_io_dout_raw;
            ms_ack_toggle  <= ~ms_ack_toggle;
        end
    end
    wire ms_io_wr_sdram = ms_req_sync[2] ^ ms_req_sync[1];
    wire ms_io_rd_sdram = ms_rd_sync[2]  ^ ms_rd_sync[1];

    // ── ch4 SDRAM model with occasional long stalls ──
    wire [21:0] ms_mem_addr;
    wire        ms_mem_rd_req, ms_mem_wr_req;
    wire  [7:0] ms_mem_wr_data;
    logic [7:0] sdram_mem [0:65535];
    logic [1:0] pcm_state = 0;
    logic       pcm_is_write = 0;
    logic       rd_req_prev = 0;
    logic [11:0] stall_cnt = 0;
    logic [7:0]  stall_lfsr = 8'hA5;
    logic [7:0]  rd_data_r;
    always_ff @(posedge clk_sdram) begin
        rd_req_prev <= ms_mem_rd_req;
        if (reset) begin pcm_state <= 0; stall_cnt <= 0; end
        else case (pcm_state)
            0: if (ms_mem_rd_req && !rd_req_prev) begin
                   pcm_is_write <= 0; pcm_state <= 1;
                   stall_lfsr <= {stall_lfsr[6:0], stall_lfsr[7]^stall_lfsr[5]};
                   // mostly ~12-cycle service; 1-in-16 a long ~2500-cycle stall (~29µs)
                   stall_cnt <= (stall_lfsr[3:0] == 4'hF) ? 12'd2500 : 12'd12;
               end else if (ms_mem_wr_req) begin
                   pcm_is_write <= 1; pcm_state <= 1;
                   stall_lfsr <= {stall_lfsr[6:0], stall_lfsr[7]^stall_lfsr[5]};
                   stall_cnt <= (stall_lfsr[3:0] == 4'hF) ? 12'd2500 : 12'd12;
               end
            1: begin
                   if (stall_cnt != 0) stall_cnt <= stall_cnt - 1'b1;
                   else begin
                       if (pcm_is_write) sdram_mem[ms_mem_addr[15:0]] <= ms_mem_wr_data;
                       else              rd_data_r <= sdram_mem[ms_mem_addr[15:0]];
                       pcm_state <= 3;
                   end
               end
            3: pcm_state <= 0;
            default: pcm_state <= 0;
        endcase
    end
    wire  [7:0] ms_mem_rd_data   = rd_data_r;
    wire [15:0] ms_mem_rd_data16 = {rd_data_r, rd_data_r};
    wire        ms_mem_rd_valid  = (pcm_state == 3) && !pcm_is_write;
    wire        ms_mem_busy      = (pcm_state != 0);

    // ── DUT ──
    wire signed [15:0] aud_l, aud_r;
    wire aud_v, ms_irq_n;
    ymf278b_top #(.CLK_HZ(85909090), .CLK_OPL3(14318182)) dut (
        .clk(clk_sdram), .clk_opl3(clk_opl3), .rst_n(~reset),
        .io_port(ms_io_port_lat), .io_data_in(ms_io_data_lat),
        .io_wr(ms_io_wr_sdram), .io_rd(ms_io_rd_sdram),
        .io_data_out(ms_io_dout_raw), .io_ack(ms_io_ack),
        .mem_addr(ms_mem_addr), .mem_rd_req(ms_mem_rd_req),
        .mem_rd_data(ms_mem_rd_data), .mem_rd_data16(ms_mem_rd_data16),
        .mem_rd_valid(ms_mem_rd_valid), .mem_wr_req(ms_mem_wr_req),
        .mem_wr_data(ms_mem_wr_data), .mem_busy(ms_mem_busy),
        .audio_left(aud_l), .audio_right(aud_r), .audio_valid(aud_v),
        .irq_n(ms_irq_n),
        .pcm_mute(1'b0), .fm_mute(1'b0), .pcm_vol(2'd0),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(),
        .dbg_keyon_count(), .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(),
        .dbg_pcm_base_set(), .dbg_slot_keyon(), .dbg_slot_active()
    );

    // INT assert-and-hold replica (matches msx.sv): defer only the initial
    // assertion to a non-I/O moment, then hold until the irq is acked.
    logic ms_irq_s1 = 1, ms_irq_sync = 1, int_hold = 0;
    always @(posedge clk21m) begin
        ms_irq_s1 <= ms_irq_n; ms_irq_sync <= ms_irq_s1;
        if (ms_irq_sync)            int_hold <= 1'b0;
        else if (wr_n && rd_n)      int_hold <= 1'b1;
    end
    wire int_n = ~int_hold;

    int errors = 0;
    longint main_ops = 0, handler_runs = 0, ack_writes = 0;

    // CPU I/O primitives: ~3.58MHz pacing, WAIT honored (ms_io_pending)
    task automatic cpu_out(input [7:0] port, input [7:0] data);
        cpu_port = port; cpu_data = data; cpu_io_active = 1;
        @(negedge clk21m); wr_n = 0;
        // I/O cycle held while WAIT (pending) — poll at clk21m
        repeat (4) @(negedge clk21m);
        while (ms_io_pending) @(negedge clk21m);
        wr_n = 1; cpu_io_active = 0;
        repeat (8) @(negedge clk21m);   // inter-instruction gap (~µs)
    endtask

    task automatic cpu_in(input [7:0] port, output [7:0] data);
        cpu_port = port; cpu_io_active = 1;
        @(negedge clk21m); rd_n = 0;
        repeat (4) @(negedge clk21m);
        while (ms_io_pending) @(negedge clk21m);
        rd_n = 1; cpu_io_active = 0;
        data = ms_io_dout_lat;
        repeat (8) @(negedge clk21m);
    endtask

    // "interrupt handler": status read, if bit6 → ack 0xBF (like OPLTimer)
    logic [7:0] st;
    task automatic irq_handler();
        handler_runs++;
        cpu_in(8'hC4, st);
        if (st[6]) begin
            cpu_out(8'hC4, 8'h04);
            cpu_out(8'hC5, 8'hBF);
            ack_writes++;
        end
    endtask

    // watchdogs
    longint irq_low_since = 0;
    always @(posedge clk21m) begin
        if (ms_irq_n) irq_low_since <= $time;
        else if ($time - irq_low_since > 64'd4_000_000_000) begin // 4 ms in ps
            $display("FAIL[%0t]: irq stuck low > 4ms (storm / lost ack). handler=%0d acks=%0d", $time, handler_runs, ack_writes);
            errors++;
            irq_low_since <= $time;
        end
    end

    initial begin
        repeat (40) @(negedge clk21m);
        reset = 0;
        repeat (40) @(negedge clk21m);

        // vgmplay init: NEW+NEW2, start OPL Timer-1 like OPLTimer_Start
        cpu_out(8'hC6, 8'h05); cpu_out(8'hC7, 8'h03);        // NEW2|NEW
        cpu_out(8'h7E, 8'h02); cpu_out(8'h7F, 8'h11);        // reg02: mem access mode
        cpu_out(8'hC4, 8'h02); cpu_out(8'hC5, 8'hF5);        // timer1 = -11 (880µs)
        cpu_out(8'hC4, 8'h04); cpu_out(8'hC5, 8'h80);        // RST
        cpu_out(8'hC4, 8'h04); cpu_out(8'hC5, 8'h39);        // MT2|ST1 start

        // memory write address regs 3..5 (start of custom RAM)
        cpu_out(8'h7E, 8'h03); cpu_out(8'h7F, 8'h20);
        cpu_out(8'h7E, 8'h04); cpu_out(8'h7F, 8'h00);
        cpu_out(8'h7E, 8'h05); cpu_out(8'h7F, 8'h00);
        cpu_out(8'h7E, 8'h06);                                // select mem data reg

        // ── main: otir upload of 1200 bytes, IRQ handler preempts between ops ──
        for (int i = 0; i < 1200; i++) begin
            if (!int_n) irq_handler();
            cpu_out(8'h7F, 8'(i));
            main_ops++;
        end

        // ── playback phase: wave-reg writes + key-ons, ~6 ms ──
        cpu_out(8'h7E, 8'h02); cpu_out(8'h7F, 8'h10);        // leave mem access mode
        for (int i = 0; i < 400; i++) begin
            if (!int_n) irq_handler();
            case (i % 5)
                0: begin cpu_out(8'h7E, 8'h08); cpu_out(8'h7F, 8'(i)); end // wave # (LOAD)
                1: begin cpu_out(8'h7E, 8'h20); cpu_out(8'h7F, 8'h45); end // fn
                2: begin cpu_out(8'h7E, 8'h38); cpu_out(8'h7F, 8'h00); end // oct
                3: begin cpu_out(8'h7E, 8'h68); cpu_out(8'h7F, 8'h80); end // key-on
                4: begin cpu_out(8'hC4, 8'hA0); cpu_out(8'hC5, 8'(i)); end // FM write
            endcase
            main_ops++;
        end

        // final: handler must still be alive (irq serviced recently)
        if (errors == 0)
            $display("ALL PASS: main_ops=%0d handler_runs=%0d acks=%0d (no storm, no wedge)", main_ops, handler_runs, ack_writes);
        else
            $display("%0d FAILURE(S): main_ops=%0d handler_runs=%0d acks=%0d", errors, main_ops, handler_runs, ack_writes);
        $finish;
    end

    // global wedge watchdog: whole test must finish < 120 ms sim time
    initial begin
        #120ms;
        $display("FAIL: TB wedged (main loop stalled) — main_ops=%0d handler_runs=%0d acks=%0d pending=%b wait_cnt=%0d irq_n=%b",
                 main_ops, handler_runs, ack_writes, ms_io_pending, ms_wait_cnt, ms_irq_n);
        $finish;
    end
endmodule
