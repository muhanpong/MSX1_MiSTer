// YMF278 PCM Memory Interface
// 4MB address space managed via memPtrs[32] (32 × 128KB blocks).
// Arbitrates between CPU register accesses (regs 3-6) and PCM engine reads.
// External bus: byte-wide, synchronous request/ack model.
`default_nettype none

module ymf278_pcm_memory (
    input  wire        clk,
    input  wire        rst_n,

    // Register 2 bit 0: RAM write enable; bit 1: memory mode
    input  wire        reg2_ram_wr_en,   // regs[2] bit 0
    input  wire        reg2_mode,        // regs[2] bit 1 (mode select)

    // CPU memory access (via registers 3-6)
    input  wire [7:0]  cpu_reg,          // register number (3..6)
    input  wire [7:0]  cpu_data_in,      // data written
    input  wire        cpu_wr,           // write strobe
    input  wire        cpu_rd,           // read strobe
    output logic [7:0] cpu_data_out,
    output logic       cpu_ack,

    // PCM engine sample read
    input  wire [21:0] pcm_addr,
    input  wire        pcm_rd_req,
    output logic [7:0] pcm_rd_data,
    output logic       pcm_rd_valid,

    // External memory bus (single port, byte-wide)
    // Connect to SDRAM, SRAM or Flash controller
    output logic [21:0] ext_addr,
    output logic        ext_rd_en,
    output logic        ext_wr_en,
    output logic [7:0]  ext_wr_data,
    input  wire  [7:0]  ext_rd_data,
    input  wire         ext_rd_valid,
    input  wire         ext_busy,

    output logic        busy         // 1 when internal operation in progress
);

// Internal address register (latched from regs 3,4,5)
logic [21:0] mem_adr;

// Arbitration: CPU has lower priority than PCM
typedef enum logic [2:0] {
    ARB_IDLE,
    ARB_PCM_RD,
    ARB_CPU_RD,
    ARB_CPU_WR,
    ARB_WAIT,
    ARB_COOLDOWN  // 1-cycle gap after PCM read so the requester can
                  // drop pcm_rd_req before we re-sample it.  Without
                  // this, back-to-back reads (HF FSM 12-byte fetch)
                  // see the IDLE arbiter re-fire with the previous
                  // cycle's stale pcm_addr.
} arb_state_t;

arb_state_t arb_state;

// Saved address for sequential reg 3/4/5 writes
logic [7:0] reg3_buf, reg4_buf;

// CPU write latch — captures the 1-cycle cpu_wr pulse so it isn't dropped
// when the arbiter is busy serving PCM reads.
logic       cpu_wr_pending;
logic [7:0] cpu_wr_data_latched;

// Merged: CPU register interface + Arbitration FSM (single driver per signal)
always_ff @(posedge clk) begin
    // Defaults
    cpu_ack      <= 1'b0;
    // cpu_data_out: do NOT reset to 0xFF every cycle.  ARB_CPU_RD writes
    // the SDRAM data into cpu_data_out for exactly one cycle when valid
    // arrives; if we reset every cycle it disappears before downstream
    // logic can latch it.  Hold the last read value instead.
    ext_rd_en    <= 1'b0;
    ext_wr_en    <= 1'b0;
    pcm_rd_valid <= 1'b0;
    busy         <= 1'b0;

    if (!rst_n) begin
        arb_state           <= ARB_IDLE;
        mem_adr             <= 22'd0;
        reg3_buf            <= 8'd0;
        reg4_buf            <= 8'd0;
        cpu_wr_pending      <= 1'b0;
        cpu_wr_data_latched <= 8'd0;
        cpu_data_out        <= 8'hFF;  // reset only
    end else begin
        // CPU register writes (immediate for regs 3-5)
        if (cpu_wr) begin
            case (cpu_reg)
                8'd3: begin reg3_buf <= cpu_data_in & 8'h3F; cpu_ack <= 1'b1; end
                8'd4: begin reg4_buf <= cpu_data_in;          cpu_ack <= 1'b1; end
                8'd5: begin mem_adr  <= {reg3_buf[5:0], reg4_buf, cpu_data_in}; cpu_ack <= 1'b1; end
                8'd6: begin
                    if (!reg2_ram_wr_en) begin
                        cpu_ack <= 1'b1;
                    end else begin
                        // Latch the byte — arbiter will process it when free.
                        // ACK is given immediately so the CPU can advance.
                        cpu_wr_pending      <= 1'b1;
                        cpu_wr_data_latched <= cpu_data_in;
                        cpu_ack             <= 1'b1;
                    end
                end
                default: ;
            endcase
        end else if (cpu_rd && cpu_reg == 8'd6 && !reg2_ram_wr_en) begin
            cpu_data_out <= 8'hFF;
            cpu_ack      <= 1'b1;
        end

        // Arbitration FSM (overrides cpu_ack/cpu_data_out/mem_adr when active)
        // Priority: pending CPU write > PCM read > CPU read > new CPU write
        // (Latched CPU writes go first to avoid starvation by continuous PCM reads.)
        case (arb_state)
            ARB_IDLE: begin
                if (cpu_wr_pending) begin
                    ext_addr       <= mem_adr;
                    ext_wr_en      <= 1'b1;
                    ext_wr_data    <= cpu_wr_data_latched;
                    arb_state      <= ARB_CPU_WR;
                    busy           <= 1'b1;
                    cpu_wr_pending <= 1'b0;
                end else if (pcm_rd_req) begin
                    ext_addr  <= pcm_addr;
                    ext_rd_en <= 1'b1;
                    arb_state <= ARB_PCM_RD;
                    busy      <= 1'b1;
                end else if (cpu_rd && cpu_reg == 8'd6 && reg2_ram_wr_en) begin
                    ext_addr  <= mem_adr;
                    ext_rd_en <= 1'b1;
                    arb_state <= ARB_CPU_RD;
                    busy      <= 1'b1;
                end
            end

            ARB_PCM_RD: begin
                busy      <= 1'b1;
                // ext_rd_en was already pulsed in ARB_IDLE.
                // msx.sv bridge uses edge detection, so do NOT hold it high.
                if (ext_rd_valid) begin
                    pcm_rd_data  <= ext_rd_data;
                    pcm_rd_valid <= 1'b1;
                    arb_state    <= ARB_COOLDOWN;
                end
            end

            ARB_COOLDOWN: begin
                // Give the requester one cycle to observe pcm_rd_valid
                // and drop pcm_rd_req before we sample it again.
                // Without this, back-to-back HF FSM reads see IDLE
                // re-fire with the previous cycle's stale pcm_addr.
                busy      <= 1'b1;
                arb_state <= ARB_IDLE;
            end

            ARB_CPU_RD: begin
                busy      <= 1'b1;
                if (ext_rd_valid) begin
                    cpu_data_out <= ext_rd_data;
                    cpu_ack      <= 1'b1;
                    mem_adr      <= mem_adr + 22'd1;
                    arb_state    <= ARB_IDLE;
                end
            end

            ARB_CPU_WR: begin
                busy <= 1'b1;
                if (!ext_busy) begin
                    mem_adr   <= mem_adr + 22'd1;
                    arb_state <= ARB_IDLE;
                end
            end

            default: arb_state <= ARB_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
