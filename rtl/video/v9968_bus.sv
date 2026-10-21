//  v9968_bus -- the MSX CPU's I/O cycles to ports 98h-9Fh onto the V9968's host bus
//  (2026-10-21, plan S5, MSX_V9968 build).
//
//  clk21m (the CPU side) and clk_vdp (85.909 MHz, the V9968) come from one PLL at phase
//  0 and clk_vdp = 4 x clk21m: every clk21m edge is a clk_vdp edge.  The CPU-side
//  signals are sampled on clk_vdp directly (a register launched on clk21m reaches the
//  clk_vdp edge 11.64 ns later; the edge they share sees the old value), and the
//  results go back the same way -- timed paths, no synchronisers.
//
//  One CPU I/O cycle to the V9968 = one V9968 bus transaction, started on the first
//  clk_vdp edge that sees the strobe (IORQ with RD or WR, M1 high) and the port in
//  98h-9Fh.  Writes: bus_valid until the V9968 takes it (bus_ready), then done.  Reads:
//  then wait for bus_rdata_en and keep that byte in rdata until the next read.  The
//  V9968's bus_ready also stays low while it still works on the previous port-98h
//  access; the transaction simply waits for it.
//
//  busy (clk_vdp, read by msx.sv in clk21m): this CPU cycle's transaction is not done.
//  msx.sv turns it into WAIT only for a handshaked CPU (cpu_paced); the stock T80s gets
//  no WAIT, as on the real machine, and late_cnt counts the reads whose byte was not
//  there by the cycle's end (sim/v9968_vram: data <= 38 clk_vdp after acceptance, the
//  stock IN window is ~60).
module v9968_bus (
    input  wire        clk_vdp,
    input  wire        reset_n,        // clk_vdp domain (the V9968's own reset)

    //  CPU side (clk21m registers / decode)
    input  wire        io_cyc,         // ~IORQ & M1 & (~RD | ~WR) & port 98h-9Fh
    input  wire        io_wr,          // ~WR
    input  wire  [2:0] io_a,
    input  wire  [7:0] io_d,
    output logic [7:0] rdata,          // the byte of the last read
    output logic       busy,
    output logic       done_tog,       // flips when a transaction completes (msx.sv WAIT)
    output logic [15:0] late_cnt,      // reads still pending when the CPU's cycle ended

    //  V9968 host bus (clk_vdp)
    output logic [2:0] bus_address,
    output logic       bus_ioreq,
    output logic       bus_write,
    output logic       bus_valid,
    input  wire        bus_ready,
    output logic [7:0] bus_wdata,
    input  wire  [7:0] bus_rdata,
    input  wire        bus_rdata_en
);
    typedef enum logic [1:0] { S_IDLE, S_REQ, S_RDWAIT, S_DONE } st_t;
    st_t st;
    logic cyc_q;
    assign bus_ioreq = 1'b1;     // the V9968 re-arms bus_ready from it after each access

    always_ff @(posedge clk_vdp) begin
        if (!reset_n) begin
            st <= S_IDLE; cyc_q <= 1'b0; bus_valid <= 1'b0; busy <= 1'b0;
            bus_write <= 1'b0; bus_address <= 3'd0; bus_wdata <= 8'd0; late_cnt <= '0;
            rdata <= 8'hFF; done_tog <= 1'b0;
        end else begin
            cyc_q <= io_cyc;
            case (st)
            S_IDLE:
                if (io_cyc && !cyc_q) begin            // a new CPU I/O cycle to the VDP
                    bus_address <= io_a; bus_write <= io_wr; bus_wdata <= io_d;
                    bus_valid <= 1'b1; busy <= 1'b1; st <= S_REQ;
                end
            S_REQ:
                if (bus_valid && bus_ready) begin      // taken on this edge
                    bus_valid <= 1'b0;
                    if (bus_write) begin busy <= 1'b0; done_tog <= ~done_tog; st <= S_DONE; end
                    else st <= S_RDWAIT;
                end
            S_RDWAIT:
                if (bus_rdata_en) begin rdata <= bus_rdata; busy <= 1'b0; done_tog <= ~done_tog; st <= S_DONE; end
            S_DONE: ;
            endcase
            //  the CPU's cycle ended: back to idle (a read still pending is late)
            if (!io_cyc && cyc_q && st != S_IDLE) begin
                if (busy && !bus_write && late_cnt != '1) late_cnt <= late_cnt + 1'b1;
                if (st == S_DONE) st <= S_IDLE;
            end
            if (st == S_DONE && !io_cyc) st <= S_IDLE;
        end
    end
endmodule
