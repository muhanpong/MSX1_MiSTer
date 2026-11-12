// MSX-AUDIO (Y8950) add-on: everything of the Y8950 except the FM operators.
//
// The FM part of the Y8950 is OPL (YM3526) compatible.  This core already has an OPL3 (the
// MoonSound's), so the FM register writes are passed on to it (fm_wr / fm_addr / fm_data) with
// the OPL3-only features filtered out, and this module adds what the OPL3 does not have:
//   - the ADPCM unit (4-bit delta ADPCM, playback from the sample RAM or from the CPU,
//     sample RAM read / write by the CPU),
//   - the Y8950 status register, its interrupt mask and the two timers,
//   - the DAC register (R#15-17) and the register read-back.
// Not implemented: ADPCM analysis (recording), CSM, the keyboard matrix and the 4-bit I/O port
// (read back as "nothing connected").
//
// Behaviour follows openMSX (src/sound/Y8950.cc, Y8950Adpcm.cc); the ADPCM arithmetic is the
// same integer arithmetic, one result per `tick` (the 49.7 kHz sample period).  The golden
// model is sim/msx_audio/y8950_model.py, the bench sim/msx_audio/run.sh.
//
// CPU side: one request at a time.  `wr` / `rd` are one-clock pulses for a write to / read of
// the data port with `addr` = the register latch; `busy` is high from the request until the
// operation is done (a sample RAM access can take a few clocks), `rdata` is valid when busy
// falls.  The status port has no side effects: read `status` directly.
`default_nettype none

module y8950_addon (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,          // one pulse per sample period (3.579545 MHz / 72)

    input  wire  [7:0] addr,
    input  wire  [7:0] wdata,
    input  wire        wr,
    input  wire        rd,
    output logic [7:0] rdata,
    output wire        busy,
    output wire  [7:0] status,
    output wire        irq_n,

    // FM register writes for the OPL3 (bank 0), one-clock pulse
    output logic       fm_wr,
    output logic [7:0] fm_addr,
    output logic [7:0] fm_data,

    // sample RAM, 256 KB.  mem_rd / mem_wr are held until mem_done (one clock);
    // mem_rdata is sampled on mem_done.
    output logic [17:0] mem_addr,
    output logic        mem_rd,
    output logic        mem_wr,
    output logic  [7:0] mem_wdata,
    input  wire   [7:0] mem_rdata,
    input  wire         mem_done,

    output wire signed [15:0] adpcm_out,   // about +-2040 at full volume (openMSX scale)
    output logic signed [15:0] dac_out
);

// ---------------------------------------------------------------------------------------------
// registers
// ---------------------------------------------------------------------------------------------
localparam [7:0] ST_T1 = 8'h40, ST_T2 = 8'h20, ST_EOS = 8'h10, ST_BRDY = 8'h08, ST_BSY = 8'h01;

logic [7:0]  regfile [0:255];          // read-back of the last value written (openMSX reg[])
initial for (int i = 0; i < 256; i++) regfile[i] = 8'h00;
logic [7:0]  rf_q;
logic [7:0]  st;                       // raw status flags (bit 7 is derived)
logic [7:0]  st_mask;
logic [7:0]  reg7, reg15, volume;
logic [15:0] delta;
logic [18:0] start_a, stop_a;          // in nibbles
logic        rom_bank, a64k, dac_en;
logic [1:0]  read_delay;
logic [7:0]  r16;
logic [2:0]  r17;
logic [7:0]  r18, r19;
logic [7:0]  t1_val, t2_val, t1_cnt, t2_cnt;
logic        t1_run, t2_run;
logic [3:0]  t_pre;

// play state
logic [19:0] mem_ptr;                  // in nibbles; one bit wider than the addresses
logic [16:0] now_step;
logic signed [15:0] out_q, lev_q;      // out, nextLeveling
logic [14:0] diff;
logic signed [27:0] output_q, step_q;  // output, sampleStep
logic [7:0]  adpcm_data;

wire playing = (reg7[7:6] == 2'b10);
assign adpcm_out = (playing && !reg7[3]) ? 16'(output_q >>> 12) : 16'sd0;

wire [7:0] st_irq = st & st_mask & 8'h78;
assign status = ((st & (8'h07 | st_mask)) & 8'h79) | 8'h06 | {|st_irq, 7'd0};
assign irq_n  = ~|st_irq;

// ---------------------------------------------------------------------------------------------
// one shared multiplier
// ---------------------------------------------------------------------------------------------
logic signed [17:0] mul_a, mul_b;
logic signed [35:0] mul_p;
always_ff @(posedge clk) mul_p <= mul_a * mul_b;

function automatic [7:0] f2(input [2:0] v);
    case (v)
        3'd4:    f2 = 8'd77;
        3'd5:    f2 = 8'd102;
        3'd6:    f2 = 8'd128;
        3'd7:    f2 = 8'd153;
        default: f2 = 8'd57;
    endcase
endfunction

// ---------------------------------------------------------------------------------------------
// sequencer
// ---------------------------------------------------------------------------------------------
typedef enum logic [4:0] {
    S_IDLE, S_WR, S_WR_MEM, S_RD, S_RD2, S_RD_MEM, S_DONE,
    S_T0, S_T_MEM, S_T1, S_T2, S_T3, S_T4, S_T5, S_T6, S_T7, S_T8, S_T9, S_T10, S_T11
} state_t;
state_t s;

logic       cpu_pend, cpu_is_wr, tick_pend, cpu_busy;
logic [7:0] c_addr, c_data;
logic [3:0] val;                       // current nibble
logic signed [15:0] prev_out, prev_lev;
logic signed [17:0] d_lev;
logic [7:0] vws;

assign busy = cpu_pend | cpu_busy;

wire [17:0] byte_addr = a64k ? {2'b00, mem_ptr[16:1]} : mem_ptr[18:1];
wire        past_stop = (mem_ptr > {1'b0, stop_a});

function automatic signed [15:0] clip16(input signed [17:0] x);
    if (x > 18'sd32767)       clip16 = 16'sd32767;
    else if (x < -18'sd32768) clip16 = -16'sd32768;
    else                      clip16 = x[15:0];
endfunction

//  nibble + mode helpers
wire [2:0] mode = reg7[7:5];
wire signed [17:0] sum_lev = 18'(prev_out) + 18'(out_q);     // prevOut + out, for (a + b) / 2
wire signed [17:0] sum_adj = sum_lev + $signed({17'd0, sum_lev[17]});
wire        [17:0] ns_sum  = {1'b0, now_step} + {2'b00, delta};   // nowStep + delta

task automatic restart();
    mem_ptr  <= {1'b0, start_a};
    now_step <= 17'h10000 - {1'b0, delta};
    out_q    <= '0;
    output_q <= '0;
    diff     <= 15'h7F;
    lev_q    <= '0;
    step_q   <= '0;
endtask

always_ff @(posedge clk) begin
    fm_wr <= 1'b0;
    rf_q  <= regfile[c_addr];

    if (wr | rd) begin
        cpu_pend  <= 1'b1;
        cpu_is_wr <= wr;
        c_addr    <= addr;
        c_data    <= wdata;
    end
    if (tick) tick_pend <= 1'b1;

    case (s)
    S_IDLE: begin
        cpu_busy <= 1'b0;
        if (cpu_pend) begin
            cpu_pend <= 1'b0;
            cpu_busy <= 1'b1;
            s <= cpu_is_wr ? S_WR : S_RD;
        end
        else if (tick_pend) begin
            tick_pend <= 1'b0;
            s <= S_T0;
        end
    end

    // ------------------------------------------------------------------ register write
    S_WR: begin
        s <= S_DONE;
        if (!(c_addr == 8'h04 && c_data[7]))
            regfile[c_addr] <= (c_addr == 8'h16) ? (c_data & 8'hC0) :
                               (c_addr == 8'h17) ? (c_data & 8'h07) : c_data;
        case (c_addr)
        8'h02: t1_val <= c_data;
        8'h03: t2_val <= c_data;
        8'h04: begin
            if (c_data[7]) begin
                st <= st & ~8'h78;
                //  adpcm.resetStatus()
                if (mode == 3'b001 || mode == 3'b011 || mode == 3'b000) st[3] <= 1'b1;
            end
            else begin
                st_mask <= ~c_data & 8'h78;
                st      <= st & (8'h87 | (~c_data & 8'h78));
                if (mode == 3'b001 || mode == 3'b011 || mode == 3'b000) st[3] <= 1'b1;
                if (c_data[0] && !t1_run) begin t1_cnt <= t1_val; end
                if (c_data[1] && !t2_run) begin t2_cnt <= t2_val; end
                t1_run <= c_data[0];
                t2_run <= c_data[1];
            end
        end
        8'h07: begin
            st[0] <= c_data[7];                              // PCM BSY
            if (c_data[0]) begin                             // RESET
                reg7 <= 8'h00;
                mem_ptr <= '0;
            end
            else begin
                reg7 <= c_data;
                if (c_data[7]) restart();
                if (c_data[5]) begin                         // external memory
                    mem_ptr    <= {1'b0, start_a};
                    read_delay <= 2'd2;
                    if (!c_data[7]) st[3] <= 1'b1;           // memory read or write: BUF RDY
                end
                else
                    mem_ptr <= '0;
            end
        end
        8'h08: begin
            rom_bank <= c_data[0];
            a64k     <= c_data[1];
            dac_en   <= c_data[2];
            fm_wr    <= 1'b1;                                // NTS (bit 6) is the OPL's too
            fm_addr  <= 8'h08;
            fm_data  <= c_data & 8'h40;
        end
        8'h09: start_a[10:3]  <= c_data;
        8'h0A: start_a[18:11] <= c_data;
        8'h0B: stop_a[10:3]   <= c_data;
        8'h0C: stop_a[18:11]  <= c_data;
        8'h0F: begin
            reg15 <= c_data;
            if (mode == 3'b011) begin                        // sample RAM write
                if (read_delay != 2'd0) read_delay <= 2'd0;
                if (read_delay != 2'd0)
                    mem_ptr <= {1'b0, start_a};
                if ((read_delay != 2'd0) ? (start_a <= stop_a) : !past_stop) begin
                    s <= S_WR_MEM;
                end
            end
            else if (mode == 3'b100)
                st[3] <= 1'b0;                               // CPU-fed playback: buffer full
        end
        8'h10: delta[7:0]  <= c_data;
        8'h11: delta[15:8] <= c_data;
        8'h12: volume      <= c_data;
        8'h15: if (dac_en) begin
            //  ((int8(R15) * 256 + R16) * 4) >> (7 - R17), clipped
            dac_out <= clip16(18'($signed({c_data, r16, 2'b00}) >>> (3'd7 - r17)));
        end
        8'h16: r16 <= c_data & 8'hC0;
        8'h17: r17 <= c_data[2:0];
        8'h18: r18 <= c_data;
        8'h19: r19 <= c_data;
        default: if (c_addr >= 8'h20) begin
            //  FM registers.  The OPL has no waveform select (E0-F5) and no output
            //  selection in C0-C8 (OPL3: bits 4/5 enable the left/right outputs).
            if (c_addr < 8'hE0) begin
                fm_wr   <= 1'b1;
                fm_addr <= c_addr;
                fm_data <= (c_addr[7:4] == 4'hC) ? ((c_data & 8'h0F) | 8'h30) : c_data;
            end
        end
        endcase
    end

    S_WR_MEM: begin
        //  mem_ptr is the write position (set to start_a in S_WR when the delay was pending)
        if (rom_bank) begin
            mem_wr <= 1'b0;
        end
        else begin
            mem_addr  <= byte_addr;
            mem_wdata <= reg15;
            mem_wr    <= 1'b1;
        end
        if (rom_bank || mem_done) begin
            mem_wr <= 1'b0;
            st[3]  <= 1'b1;
            if (mem_ptr + 20'd2 > {1'b0, stop_a}) begin
                st[4]   <= 1'b1;                             // last byte: EOS, pointer wraps
                mem_ptr <= {1'b0, start_a};
            end
            else
                mem_ptr <= mem_ptr + 20'd2;
            s <= S_DONE;
        end
    end

    // ------------------------------------------------------------------ data port read
    S_RD: begin
        s <= S_DONE;
        case (c_addr)
        8'h05: rdata <= 8'hFF;                               // keyboard in: nothing pressed
        8'h0F: begin
            if (mode == 3'b001) begin                        // sample RAM read
                if (read_delay != 2'd0) begin
                    mem_ptr    <= {1'b0, start_a};
                    rdata      <= reg15;
                    read_delay <= read_delay - 2'd1;
                    st[3]      <= 1'b1;
                end
                else if (past_stop) begin
                    rdata <= 8'h00;
                    st[4] <= 1'b1;
                end
                else
                    s <= S_RD_MEM;
            end
            else
                rdata <= 8'h00;
        end
        8'h13: rdata <= output_q[15:8];
        8'h14: rdata <= output_q[23:16];
        8'h19: rdata <= (r19 & r18) | ~r18 | 8'hF0;
        8'h1A: rdata <= 8'hFF;
        default: s <= S_RD2;
        endcase
    end
    S_RD2: begin
        rdata <= rf_q;                                       // addr is stable while busy
        s <= S_DONE;
    end
    S_RD_MEM: begin
        if (rom_bank) begin
            rdata <= 8'h00;
        end
        else begin
            mem_addr <= byte_addr;
            mem_rd   <= 1'b1;
        end
        if (rom_bank || mem_done) begin
            mem_rd <= 1'b0;
            if (!rom_bank) rdata <= mem_rdata;
            mem_ptr <= mem_ptr + 20'd2;
            st[3]   <= 1'b1;
            s <= S_DONE;
        end
    end

    S_DONE: begin
        cpu_busy <= 1'b0;
        s <= S_IDLE;
    end

    // ------------------------------------------------------------------ one sample period
    S_T0: begin
        //  timers: 80 us = 4 sample periods, 320 us = 16
        t_pre <= t_pre + 4'd1;
        if (t1_run && t_pre[1:0] == 2'd3) begin
            if (t1_cnt == 8'hFF) begin t1_cnt <= t1_val; st[6] <= 1'b1; end
            else                       t1_cnt <= t1_cnt + 8'd1;
        end
        if (t2_run && t_pre == 4'd15) begin
            if (t2_cnt == 8'hFF) begin t2_cnt <= t2_val; st[5] <= 1'b1; end
            else                       t2_cnt <= t2_cnt + 8'd1;
        end

        if (!playing)
            s <= S_IDLE;
        else if (ns_sum[17:16] == 2'b00) begin
            //  no new nibble: interpolate
            now_step <= ns_sum[16:0];
            output_q <= output_q + step_q;
            s <= S_IDLE;
        end
        else begin
            now_step <= {1'b0, ns_sum[15:0]};
            if (!mem_ptr[0]) begin
                if (reg7[5]) s <= S_T_MEM;
                else begin
                    adpcm_data <= reg15;
                    st[3]      <= 1'b1;                      // ready for the next byte
                    s <= S_T1;
                end
            end
            else
                s <= S_T1;
        end
    end
    S_T_MEM: begin
        if (rom_bank) begin
            adpcm_data <= 8'h00;
            s <= S_T1;
        end
        else begin
            mem_addr <= byte_addr;
            mem_rd   <= 1'b1;
            if (mem_done) begin
                mem_rd     <= 1'b0;
                adpcm_data <= mem_rdata;
                s <= S_T1;
            end
        end
    end
    S_T1: begin
        val      <= mem_ptr[0] ? adpcm_data[3:0] : adpcm_data[7:4];
        prev_out <= out_q;
        prev_lev <= lev_q;
        s <= S_T2;
    end
    S_T2: begin                                              // diff * |F1|
        mul_a <= 18'({1'b0, diff});
        mul_b <= 18'({val[2:0], 1'b1});
        s <= S_T3;
    end
    S_T3: begin                                              // diff * F2
        mul_a <= 18'({1'b0, diff});
        mul_b <= 18'(f2(val[2:0]));
        s <= S_T4;
    end
    S_T4: begin                                              // mul_p = diff * |F1|
        //  out += (diff * F1) / 8, the division truncating toward zero
        if (val[3]) out_q <= clip16(18'(out_q) - 18'(mul_p[20:3]));
        else        out_q <= clip16(18'(out_q) + 18'(mul_p[20:3]));
        mul_a <= 18'({1'b0, volume});                        // volume * delta
        mul_b <= 18'({1'b0, delta});
        s <= S_T5;
    end
    S_T5: begin                                              // mul_p = diff * F2
        if (mul_p[35:6] > 30'h6000)     diff <= 15'h6000;
        else if (mul_p[35:6] < 30'h7F)  diff <= 15'h7F;
        else                            diff <= mul_p[20:6];
        //  nextLeveling = (prevOut + out) / 2, truncating toward zero
        lev_q <= sum_adj[16:1];
        mul_a <= 18'({1'b0, volume});                        // volume * nowStep
        mul_b <= 18'({1'b0, now_step[15:0]});
        s <= S_T6;
    end
    S_T6: begin                                              // mul_p = volume * delta
        vws   <= mul_p[23:16];
        d_lev <= 18'(lev_q) - 18'(prev_lev);
        s <= S_T7;
    end
    S_T7: begin                                              // mul_p = volume * nowStep
        mul_a <= d_lev;                                      // deltaLeveling * volumeWStep
        mul_b <= 18'({1'b0, vws});
        vws   <= mul_p[23:16];                               // reuse: (volume * nowStep) >> 16
        s <= S_T8;
    end
    S_T8: begin
        mul_a <= d_lev;                                      // deltaLeveling * ((volume * nowStep) >> 16)
        mul_b <= 18'({1'b0, vws});
        s <= S_T9;
    end
    S_T9: begin                                              // mul_p = deltaLeveling * volumeWStep
        step_q <= 28'(mul_p);
        mul_a  <= 18'(prev_lev);                             // prevLeveling * volume
        mul_b  <= 18'({1'b0, volume});
        s <= S_T10;
    end
    S_T10: begin                                             // mul_p = tmp
        output_q <= 28'(mul_p);
        s <= S_T11;
    end
    S_T11: begin                                             // mul_p = prevLeveling * volume
        output_q <= output_q + 28'(mul_p);
        mem_ptr  <= mem_ptr + 20'd1;
        if (reg7[5] && (mem_ptr + 20'd1 > {1'b0, stop_a})) begin
            st[4] <= 1'b1;                                   // end of sample
            if (reg7[4]) restart();
            else         reg7 <= 8'h00;
        end
        s <= S_IDLE;
    end
    default: s <= S_IDLE;
    endcase

    if (!rst_n) begin
        s <= S_IDLE;
        cpu_pend <= 1'b0; cpu_busy <= 1'b0; tick_pend <= 1'b0;
        st <= ST_BRDY; st_mask <= 8'h00;
        reg7 <= 8'h00; reg15 <= 8'h00; volume <= 8'hFF; delta <= 16'h0000;
        start_a <= 19'd0; stop_a <= 19'd7;
        rom_bank <= 1'b0; a64k <= 1'b0; dac_en <= 1'b0; read_delay <= 2'd0;
        r16 <= 8'h00; r17 <= 3'd0; r18 <= 8'h00; r19 <= 8'h00;
        t1_val <= 8'h00; t2_val <= 8'h00; t1_cnt <= 8'h00; t2_cnt <= 8'h00;
        t1_run <= 1'b0; t2_run <= 1'b0; t_pre <= 4'd0;
        mem_ptr <= '0; now_step <= 17'h10000; out_q <= '0; lev_q <= '0; diff <= 15'h7F;
        output_q <= '0; step_q <= '0; adpcm_data <= 8'h00;
        mem_rd <= 1'b0; mem_wr <= 1'b0; fm_wr <= 1'b0; dac_out <= '0;
    end
end

endmodule
`default_nettype wire
