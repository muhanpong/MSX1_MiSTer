//  turbo R PCMPLY hardware player.
//
//  The BIOS overlay in turbor.sv answers the opcode fetch of 0186h.  Rather than
//  let that fetch complete, the machine is parked inside it (WAIT held) and this
//  block takes the bus: one memory read per sample, straight into the D/A on the
//  PCM tick grid divided by q+1.  When the run ends the fetch is allowed to
//  finish and the opcode handed back is 37h (SCF -- carry set, aborted by
//  CTRL+STOP) or B7h (OR A -- carry clear), so the caller's carry is the
//  documented abort flag with no register write-back and no extra stub bytes.
//  0187h stays C9 (RET).
//
//    A  = v 0 0 0 0 0 q q   v: 1 = VRAM (not implemented here), q: rate
//    HL = start address, BC = length in bytes
//    rate q = 0..3 -> 15.75 / 7.875 / 5.25 / 3.9375 kHz
//
//  Parameters come from the active core's register export, which is stable at
//  the fetch: the entry is the first M1 after the caller's CALL, and the only
//  register this instruction touches is the one it does not need (A is read
//  before the fetch completes).  All registers are destroyed on a real turbo R,
//  so nothing is written back.
//
//  BC = 0 and VRAM plays nothing at all: the fetch is never parked, so the
//  caller gets the stock B7h / carry clear.
module pcm_play
(
   input  logic         clk,          // clk21m
   input  logic         reset,
   input  logic         en,           // Turbo R features on
   input  logic         tick,         // 15.75 kHz PCM grid from turbor
   input  logic         arm,          // opcode fetch of 0186h, slot 0-0 page 0
   input  logic [211:0] cpu_reg,      // active core's register export
   input  logic         ctrl_stop,    // CTRL + STOP held
   input  logic         pace_n,       // the machine's own wait_n, without our term
   input  logic   [7:0] d_bus,        // d_to_cpu
   output logic         busy,         // park the CPU (WAIT) -- high through the settle
   output logic         bus_own,      // drive the bus in place of the CPU
   output logic  [15:0] m_a,
   output logic         m_mreq_n,
   output logic         m_rd_n,
   output logic   [7:0] dac,          // sample for the D/A
   output logic         dac_we,       // one clock per sample
   output logic         aborted       // latched: CTRL + STOP ended the run
);

//  Register export slices (T80_Reg / nextz80reg layout).
wire  [7:0] r_a  = cpu_reg[7:0];
wire [15:0] r_bc = cpu_reg[95:80];
wire [15:0] r_hl = cpu_reg[127:112];

//  A read is held long enough to cover a stock-speed Z80 read at every CPU
//  speed; the machine's own pacers stretch it further through `pace_n`.  At the
//  fastest rate a sample is 1365 clk21m apart, so the cadence has room to spare.
localparam [5:0] RD_LEN  = 6'd24;     // ~4 T-states at 3.58 MHz
localparam [5:0] GAP_LEN = 6'd8;      // strobes released between reads
localparam [5:0] SET_LEN = 6'd8;      // bus back to the CPU before WAIT releases

localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_READ = 3'd2,
                 S_GAP  = 3'd3, S_SET  = 3'd4;

logic  [2:0] st   = S_IDLE;
logic [15:0] ptr  = 16'd0;
logic [15:0] len  = 16'd0;
logic  [1:0] rate = 2'd0;
logic  [1:0] divc = 2'd0;
logic  [5:0] cnt  = 6'd0;

always_ff @(posedge clk) begin
   dac_we <= 1'b0;

   if (reset | ~en) begin
      st      <= S_IDLE;
      cnt     <= 6'd0;
      aborted <= 1'b0;
   end else if (st != S_IDLE && st != S_SET && ctrl_stop) begin
      //  CTRL + STOP ends the run wherever it is; the bus goes back first.
      aborted <= 1'b1;
      cnt     <= 6'd0;
      st      <= S_SET;
   end else case (st)
      S_IDLE:
         if (arm) begin
            aborted <= 1'b0;
            if (|r_bc & ~r_a[7]) begin
               ptr  <= r_hl;
               len  <= r_bc;
               rate <= r_a[1:0];
               divc <= 2'd0;             // first sample on the next grid tick
               cnt  <= 6'd0;
               st   <= S_WAIT;
            end
         end

      //  Between samples the bus is held idle, still ours: handing it back and
      //  taking it again per sample would re-edge the parked CPU's own strobes.
      S_WAIT:
         if (tick) begin
            if (divc == 2'd0) begin
               divc <= rate;
               cnt  <= 6'd0;
               st   <= S_READ;
            end else
               divc <= divc - 2'd1;
         end

      S_READ:
         if (pace_n) begin
            if (cnt == RD_LEN - 6'd1) begin
               dac    <= d_bus;
               dac_we <= 1'b1;
               ptr    <= ptr + 16'd1;
               len    <= len - 16'd1;
               cnt    <= 6'd0;
               st     <= S_GAP;
            end else
               cnt <= cnt + 6'd1;
         end

      S_GAP:
         if (cnt == GAP_LEN - 6'd1) begin
            cnt <= 6'd0;
            st  <= (len == 16'd0) ? S_SET : S_WAIT;
         end else
            cnt <= cnt + 6'd1;

      //  Bus back to the CPU, WAIT still held, so the overlay byte for 0186h is
      //  settled by the time the parked fetch is allowed to latch it.
      S_SET:
         if (cnt == SET_LEN - 6'd1) st <= S_IDLE;
         else                       cnt <= cnt + 6'd1;

      default: st <= S_IDLE;
   endcase
end

assign busy     = (st != S_IDLE);
assign bus_own  = busy & (st != S_SET);
assign m_a      = ptr;
assign m_mreq_n = (st != S_READ);
assign m_rd_n   = (st != S_READ);

endmodule
