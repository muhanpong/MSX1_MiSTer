// YMF278B register file and I/O port decode
// Separates OPL3 register writes from PCM wave register writes.
// Handles BUSY/LOAD counters and NEW2 enable check.
`default_nettype none

module ymf278b_regs #(
    parameter int CLK_HZ = 33868800
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU I/O bus
    input  wire [7:0]  io_port,      // low byte of I/O address
    input  wire [7:0]  io_data_in,
    input  wire        io_wr,
    input  wire        io_rd,
    output logic [7:0] io_data_out,
    output logic       io_ack,

    // NEW2 bit (from OPL3 register 0x105 bit 1)
    input  wire        new2,

    // OPL3 register write (to OPL3 core)
    output logic [8:0] opl3_reg_addr,  // bank(1) + addr(8)
    output logic [7:0] opl3_reg_data,
    output logic       opl3_reg_wr,
    output logic       opl3_status_rd,
    output logic       opl3_reg_rd,
    input  wire  [7:0] opl3_status,
    input  wire  [7:0] opl3_reg_dout,

    // PCM wave register write (to ymf278_pcm_top)
    output logic [7:0] pcm_reg_addr,
    output logic [7:0] pcm_reg_data,
    output logic       pcm_reg_wr,
    output logic       pcm_reg_rd,
    input  wire  [7:0] pcm_reg_dout,
    input  wire        pcm_reg_rd_done,    // pulses when CPU mem read completes
    input  wire        pcm_cpu_mem_busy,   // engine: CPU mem op (reg 0x06) still in flight

    // BUSY/LOAD status
    output logic       busy,
    output logic       load_busy
);

// Timing delays in clock cycles (at 33.8688 MHz)
localparam int FM_REG_SELECT_DELAY    = 56;
localparam int FM_REG_WRITE_DELAY     = 56;
localparam int WAVE_REG_SELECT_DELAY  = 88;
localparam int WAVE_REG_WRITE_DELAY   = 88;
localparam int MEM_READ_DELAY         = 38;
// MEM_WRITE_DELAY paces wave-memory writes.  With WAIT_n + deferred ack this is
// how long the CPU is held per reg-0x06 write, so it MUST exceed the host's
// natural write spacing to actually throttle an unpaced `otir` blast (otir is
// ~21 Z80 T-states ≈ 5.9 µs ≈ 507 clk_sdram/byte; a small delay is absorbed and
// adds nothing).  ~1024 ≈ 12 µs/byte, between otir (fails) and pcmload (~16 µs,
// works).  Tunable: lower if uploads are too slow, raise if large uploads still
// freeze. NOTE: keep msx.sv's MoonSound WAIT_n timeout > this (in clk21m).
localparam int MEM_WRITE_DELAY        = 1024;
localparam int LOAD_DELAY             = 10000;

localparam int DELAY_W = $clog2(LOAD_DELAY + 1);

logic [DELAY_W-1:0] busy_cnt;
logic [DELAY_W-1:0] load_cnt;

// FM register write-back shadow.  The gtaylormb OPL3 core does not support
// register readback (a read returns status/0xFF), but the YMF278B FM data
// port returns the written register value — MoonSound software detects the
// chip by writing a byte to an FM register (e.g. 0xA0=0x43) and reading it
// back.  Shadow every FM register write and return it on an FM register read.
logic [7:0] fm_shadow [0:511];

logic [7:0] opl4latch;   // PCM register latch
logic [8:0] opl3latch;   // OPL3 register latch (includes bank bit)

// YMF278B device-ID one-shot per datasheet page 10:
//   When status is read after NEW2 was set to 1, 02H is output.  After
//   reading, this bit is reset.  However, 02H is read only once after
//   initialization.  Software (e.g. MoonBlaster) uses this to detect OPL4
//   vs plain OPL3.
logic       new2_prev;
logic       new2_signature_pending;

// Wait state for PCM memory reads (regs 3-6 read via SDRAM).
// Holds io_ack low until pcm_reg_rd_done pulses so the CPU latches
// the fresh pcm_reg_dout instead of a stale value.
logic pcm_rd_wait;
// Same idea for PCM memory WRITES (regs 3-6): hold io_ack low until the write
// has actually completed (busy_cnt drained AND engine cpu-mem op done = the same
// BUSY the status bit exposes).  Paced drivers (pcmload) poll BUSY between bytes
// and so never outrun the SDRAM write; an unpaced `otir` blast (vgmplay) does.
// Deferring the ack makes WAIT_n hold the CPU until the write lands — i.e. it
// throttles the host to the real memory speed, exactly like pcmload's BUSY poll.
logic pcm_wr_wait;

assign pcm_reg_addr = opl4latch;

// Busy / Load counters
// CPU mem (reg 0x03-0x06) access: the fixed MEM_*_DELAY only bridges the first
// cycles; the engine issues the SDRAM op opportunistically (HF/Stage B must be
// idle) so it can take far longer than the fixed delay during playback.  OR in
// the engine's actual in-flight flag so the CPU's BUSY poll waits for the op to
// truly complete — otherwise cpu_wr_data_latch/cpu_mem_adr get overwritten by
// the next byte before the previous write issues (custom-wave corruption).
assign busy      = (busy_cnt != '0) | pcm_cpu_mem_busy;
assign load_busy = (load_cnt != '0);

// Merged: busy/load counters + I/O port decode (single driver per signal)
always_ff @(posedge clk) begin
    io_ack         <= 1'b0;
    opl3_reg_wr    <= 1'b0;
    opl3_status_rd <= 1'b0;
    opl3_reg_rd    <= 1'b0;
    pcm_reg_wr     <= 1'b0;
    pcm_reg_rd     <= 1'b0;
    io_data_out    <= 8'hFF;

    if (!rst_n) begin
        busy_cnt    <= '0;
        load_cnt    <= '0;
        opl4latch   <= 8'd0;
        opl3latch   <= 9'd0;
        pcm_rd_wait <= 1'b0;
        pcm_wr_wait <= 1'b0;
        new2_prev   <= 1'b0;
        new2_signature_pending <= 1'b0;
    end else begin
        // Detect NEW2 rising edge to arm the YMF278B device-ID signature
        new2_prev <= new2;
        if (new2 && !new2_prev) new2_signature_pending <= 1'b1;
        // If waiting for PCM memory read to finish, hold io_ack low until
        // pcm_reg_rd_done pulses, then deliver the data and ack the CPU.
        if (pcm_rd_wait) begin
            if (pcm_reg_rd_done) begin
                io_data_out <= pcm_reg_dout;
                io_ack      <= 1'b1;
                pcm_rd_wait <= 1'b0;
            end
        end
        // PCM memory WRITE: hold the ack until BUSY clears (busy_cnt drained AND
        // the engine's cpu-mem op finished).  This is what makes a fast unpaced
        // uploader behave like pcmload — the host can't issue the next byte until
        // this one has actually landed in SDRAM.
        if (pcm_wr_wait) begin
            if (busy_cnt == '0 && !pcm_cpu_mem_busy) begin
                io_ack      <= 1'b1;
                pcm_wr_wait <= 1'b0;
            end
        end
        // Counter decrement (write below overrides for the current cycle)
        if (busy_cnt != '0) busy_cnt <= busy_cnt - 1;
        if (load_cnt != '0) load_cnt <= load_cnt - 1;

        if (io_wr) begin
        // I/O port map (low byte):
        // 0x7E-0x7F: WAVE (PCM)  — only writable when NEW2=1
        // 0xC4-0xC7: FM  (OPL3)
        if (io_port[7:1] == 7'b0111111) begin
            // 0x7E / 0x7F — WAVE part
            if (new2) begin
                if (!io_port[0]) begin
                    // select
                    busy_cnt   <= DELAY_W'(WAVE_REG_SELECT_DELAY);
                    opl4latch  <= io_data_in;
                    io_ack     <= 1'b1;
                end else begin
                    // write
                    if (opl4latch >= 8'h08 && opl4latch <= 8'h1F)
                        load_cnt <= DELAY_W'(LOAD_DELAY);
                    pcm_reg_data <= io_data_in;
                    pcm_reg_wr   <= 1'b1;
                    if (opl4latch >= 8'h03 && opl4latch <= 8'h06) begin
                        // wave-memory data write → defer ack until BUSY clears,
                        // so an unpaced uploader (otir) is throttled to the real
                        // SDRAM write speed (matches pcmload's BUSY poll).
                        busy_cnt    <= DELAY_W'(MEM_WRITE_DELAY);
                        pcm_wr_wait <= 1'b1;
                    end else begin
                        // non-memory wave register write → ack now
                        busy_cnt <= DELAY_W'(WAVE_REG_WRITE_DELAY);
                        io_ack   <= 1'b1;
                    end
                end
            end else begin
                io_ack <= 1'b1;   // !new2: write ignored, ack immediately
            end
        end else if (io_port[7:2] == 6'b110001) begin
            // 0xC4..0xC7 — FM part
            case (io_port[1:0])
                2'd0: begin   // bank 0 select
                    opl3latch  <= {1'b0, io_data_in};
                    busy_cnt   <= DELAY_W'(FM_REG_SELECT_DELAY);
                end
                2'd2: begin   // bank 1 select
                    opl3latch  <= {1'b1, io_data_in};
                    busy_cnt   <= DELAY_W'(FM_REG_SELECT_DELAY);
                end
                2'd1, 2'd3: begin   // FM write
                    busy_cnt       <= DELAY_W'(FM_REG_WRITE_DELAY);
                    opl3_reg_addr  <= opl3latch;
                    opl3_reg_data  <= io_data_in;
                    opl3_reg_wr    <= 1'b1;
                    fm_shadow[opl3latch] <= io_data_in;  // for readback (chip detect)
                end
            endcase
            io_ack <= 1'b1;
        end
    end else if (io_rd) begin
        if (io_port[7:1] == 7'b0111111) begin
            // WAVE read
            if (!io_port[0]) begin
                io_data_out <= 8'hFF;  // latch not readable
                io_ack      <= 1'b1;
            end else if (opl4latch >= 8'h03 && opl4latch <= 8'h06) begin
                // PCM memory read goes through SDRAM — multi-cycle.
                // Only START a new read if we're not already waiting for
                // one to finish.  Z80 may keep io_rd high for a cycle
                // after seeing io_ack, which would otherwise re-trigger.
                if (!pcm_rd_wait) begin
                    busy_cnt    <= DELAY_W'(MEM_READ_DELAY);
                    pcm_reg_rd  <= 1'b1;
                    pcm_rd_wait <= 1'b1;
                end
                // io_ack NOT set here — set above on pcm_reg_rd_done
            end else begin
                // Immediate-response PCM register read (reg 0x02 device-ID
                // and other write-only regs that return latched state).
                // Fall through to pcm_reg_dout — engine drives reg 0x02
                // readback including the latched mode/type/hdr bits so
                // software writing e.g. mem_type=1 sees 0x22.  The old
                // hardcoded `0x20` override here masked all of that.
                pcm_reg_rd  <= 1'b1;
                io_data_out <= pcm_reg_dout;
                io_ack      <= 1'b1;
            end
        end else if (io_port[7:2] == 6'b110001) begin
            // FM read
            case (io_port[1:0])
                2'd0, 2'd2: begin  // status
                    opl3_status_rd <= 1'b1;
                    // Layer YMF278B signature 0x02 (D1=1) on the first status
                    // read after NEW2 rises — one-shot, cleared on this read.
                    if (new2_signature_pending) begin
                        io_data_out <= opl3_status | {6'd0, load_busy, busy} | 8'h02;
                        new2_signature_pending <= 1'b0;
                    end else begin
                        io_data_out <= opl3_status | {6'd0, load_busy, busy};
                    end
                end
                2'd1, 2'd3: begin  // FM register read → return shadowed value
                    opl3_reg_rd <= 1'b1;
                    io_data_out <= fm_shadow[opl3latch];
                end
            endcase
            io_ack <= 1'b1;
        end
    end // io_rd
    end // else begin
end // always_ff

endmodule
`default_nettype wire
