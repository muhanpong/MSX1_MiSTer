// VDP port-0x99 write probe (diagnostic, Zanac-EX title R#2 wedge hunt).
// In-System Memory "MPRB" 1024x96 (dump: quartus_stp -t tools/dump_mprobe.tcl).
//
// Layout (96-bit words):
//   [0..63]    last-write table, word = reg#:      {8'hA5, 8'(reg), 8'(val), 16'(frame), 9'(line), rest 0}
//   [64..79]   R#2 write history ring (newest overwrites oldest slot cyclically):
//                                                  {8'hB2, 8'(idx), 8'(val), 16'(frame), 9'(line), ...}
//   [80..1023] raw 0x99 event ring, frozen while msx_pause:
//              {8'hC0|type, 8'(data), 16'(frame), 9'(line), ...}
//              type: 0=write byte, 1=read (status), 2=committed reg write (probe-side pairing)
// Pairing replica mirrors vdp_register: 1st byte latches, 2nd byte with bit7
// commits reg write; a 0x99 READ resets to 1st-byte state.
`default_nettype none

module vdp_regprobe (
    input  wire        clk,          // clk21m
    input  wire        reset,
    input  wire [15:0] a,
    input  wire [7:0]  din,
    input  wire        wr_n,
    input  wire        rd_n,
    input  wire        iorq_n,
    input  wire        m1_n,
    input  wire        vdp_en,
    input  wire        vblank,
    input  wire        hblank,
    input  wire        msx_pause,
    // display-probe outputs (screen-readable fallback when JTAG is unavailable)
    output logic [23:0] p_r2,        // {val8, frame16} of last R#2 commit
    output logic [23:0] p_r23,       // {val8, frame16} of last R#23 commit
    output logic [23:0] p_r0,        // {val8, frame16} of last R#0 commit
    output logic [15:0] p_frame      // current frame counter
);

// ── frame / line counters ────────────────────────────────────────────────
logic [15:0] frame_cnt = '0;
logic [8:0]  line_cnt  = '0;
logic vbl_d, hbl_d;
always_ff @(posedge clk) begin
    vbl_d <= vblank; hbl_d <= hblank;
    if (!vbl_d && vblank) begin frame_cnt <= frame_cnt + 16'd1; line_cnt <= '0; end
    else if (!hbl_d && hblank) line_cnt <= line_cnt + 9'd1;
end

// ── port 0x99 access edges ───────────────────────────────────────────────
wire port99 = vdp_en && ~iorq_n && m1_n && (a[7:0] == 8'h99);
logic wr_d = 1'b1, rd_d = 1'b1;
always_ff @(posedge clk) begin wr_d <= wr_n; rd_d <= rd_n; end
wire wr99 = port99 && ~wr_n && wr_d;   // falling edge of wr during 0x99
wire rd99 = port99 && ~rd_n && rd_d;

// ── pairing replica ──────────────────────────────────────────────────────
logic       second = 1'b0;
logic [7:0] byte1  = '0;
wire commit    = wr99 && second && din[7];       // register write commit
wire [5:0] creg = din[5:0];
always_ff @(posedge clk) begin
    if (reset)      second <= 1'b0;
    else if (rd99)  second <= 1'b0;              // status read resets pair state
    else if (wr99) begin
        if (!second) byte1 <= din;
        second <= ~second;
    end
end

// ── ISM BRAM 1024x96 ─────────────────────────────────────────────────────
logic [9:0]  wa;
logic [95:0] wd;
logic        we;

logic       r2_pend = 1'b0;
logic [7:0] r2_val;
logic [15:0] r2_frm;
logic [8:0]  r2_lin;
logic [3:0]  r2_idx  = '0;
logic [9:0]  ring    = 10'd80;
// one event per clock max; arbitration priority: commit table > r2 hist > raw ring
always_ff @(posedge clk) begin
    we <= 1'b0;
    if (commit) begin
        we <= 1'b1;
        wa <= {4'd0, creg};
        wd <= {8'hA5, 2'b00, creg, byte1, frame_cnt, line_cnt, 47'd0};
        if (creg == 6'd2) r2_pend <= 1'b1;       // log R#2 history next cycle
    end else if (r2_pend) begin
        r2_pend <= 1'b0;
        we <= 1'b1;
        wa <= 10'd64 + {6'd0, r2_idx};
        wd <= {8'hB2, 4'd0, r2_idx, r2_val, r2_frm, r2_lin, 47'd0};
        r2_idx <= (r2_idx == 4'd15) ? 4'd0 : r2_idx + 4'd1;
    end else if ((wr99 || rd99) && !msx_pause) begin
        we <= 1'b1;
        wa <= ring;
        wd <= {8'hC0 | {6'd0, rd99, 1'b0}, din, frame_cnt, line_cnt, 55'd0};
        ring <= (ring == 10'd1023) ? 10'd80 : ring + 10'd1;
    end
end
always_ff @(posedge clk) if (commit && creg == 6'd2) begin
    r2_val <= byte1; r2_frm <= frame_cnt; r2_lin <= line_cnt;
end

always_ff @(posedge clk) begin
    if (commit && creg == 6'd2)  p_r2  <= {byte1, frame_cnt};
    if (commit && creg == 6'd23) p_r23 <= {byte1, frame_cnt};
    if (commit && creg == 6'd0)  p_r0  <= {byte1, frame_cnt};
    p_frame <= frame_cnt;
end

altsyncram #(
    .operation_mode("SINGLE_PORT"),
    .width_a(96), .widthad_a(10), .numwords_a(1024),
    .outdata_reg_a("UNREGISTERED"),
    .lpm_hint("ENABLE_RUNTIME_MOD=YES, INSTANCE_NAME=MPRB"),
    .lpm_type("altsyncram")
) u_mprb (
    .clock0(clk), .address_a(wa), .data_a(wd), .wren_a(we), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .address_b(1'b1), .addressstall_a(1'b0),
    .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b(1'b1), .eccstatus(), .q_b(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
);

endmodule
`default_nettype wire
