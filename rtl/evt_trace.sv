//  evt_trace -- time-ordered CPU event recorder, read over JTAG with the In-System
//  Memory Content Editor (quartus_stp -t tools/dump_evtrace.tcl, then
//  tools/parse_evtrace.py).  Same mechanism as az80_trace / vdp_regprobe.
//  Diagnostic only.
//
//  Why it exists (2026-09-20): two turbo R programs (Illusion City, SCMD under
//  CORER.SYS) end the same way -- on the Z80, interrupts nesting without ever
//  returning, the stack eaten top to bottom until the BIOS ISR's PUSHes land on
//  0038h.  The debug panel only keeps LAST values, so it shows the wreck and never
//  the first nested interrupt.  This keeps the order.
//
//  One 80-bit word per EVENT (not per clock), into an 8192-word ring that runs from
//  configuration and wraps.  2048 was the original depth and it held 24 ms of a
//  machine emitting ~10^5 events a second -- far less than the distance between a
//  hang and its cause.  Loop folding bought 4x of that; this buys another 4x, and
//  costs 48 more M10K out of 166 spare.  Time span, measured on the board: 24 ms
//  at 2048 unfolded, 103 ms at 2048 folded.
//     INTA   an interrupt acceptance          data = {6'b0, ms_int_n, vdp_int_n}
//     IOR    IN  from 98h-9Bh, C4h, A5h/A7h, D0h-D7h (FDC)  data = value read
//     IOW    OUT to  98h-9Bh, A8h, E4h/E5h, A5h/A7h, D0h-D7h  data = value written
//     SWAP   use_nz changed                   data = new use_nz
//     IFF    IFF1 changed                     data = new IFF1
//     SUB    a write to FFFFh, the secondary slot register of whichever primary
//            slot page 3 currently selects -- the other half of "which ROM is
//            actually mapped", and the half an A8 log cannot show.  SUBR is a
//            read of it (the BIOS reads it back complemented).
//     RST38  an M1 fetch of the RST 38h vector, data+port = the PC of the
//            instruction fetched just before it -- i.e. WHERE the runaway is
//            executing.  A machine running off into FF-filled memory executes
//            FF = RST 38h, lands in the BIOS ISR and returns, over and over,
//            with IFF1 still set and no interrupt acceptance anywhere (board,
//            2026-09-20: ISR body at 6.5 kHz, INTA 0, IFF1 1).
//     RST    machine reset
//  LOOPS are folded, and that is what makes the ring long enough to be useful.
//  After LOOPIN fetches of one branch target the recorder stops storing that loop
//  -- its repeats AND the port traffic inside it -- and only counts; when some
//  other branch target (or an interrupt) finally breaks it, ONE K_LOOP word goes
//  in carrying the address and the repeat count.  Without this a single LDIR or a
//  polling loop overwrites the whole 2048-word ring in milliseconds and the dump
//  says nothing about how the CPU got there.
//
//  TRIGGER 2, the wedge: one branch target, unbroken, for WEDGE_T -- TIME, not a
//  repeat count.  Counting cannot tell a wedge from a loop that is working:
//    * LDIR re-fetches its own ED prefix once per byte, so on the address bus it
//      is indistinguishable from `jr $` (a byte test fails too -- ED B0 is TWO M1
//      fetches, so the last byte sampled at the repeat is B0, not ED).  The first
//      build of this trigger froze on the BIOS clearing 3191 bytes at 7B78.
//    * an ADDRESS test (a two-byte opcode fetches addr+1 between repeats) fixed
//      that one and then froze, on the board, on the turbo R BIOS RAM-size search
//      at 7D60 -- LD A,(HL)/CPL/LD (HL),A/CP (HL)/.../INC L/JR NZ, one address
//      repeated 28672 times over 545 ms while making perfect progress.
//  No legal loop holds one target for seconds: the longest measured are that
//  search (545 ms) and a full 64 KB LDIR (440 ms at 3.58 MHz).  A wedge holds it
//  forever, so ~2 s separates them with a 4x margin and costs 2 s of latency.
//  HALT is still caught: with interrupts off it fetches its own address forever.
//  TRIGGER: STORM RST 38h executions in a row with no interrupt acceptance
//  between them -- a machine walking through FF-filled memory, which is how every
//  hang captured on 2026-09-20 ends.  POST more events are then recorded, the ring
//  stops and a marker word is written at the stop position, so the dump holds the
//  ~2000 events BEFORE the storm: how the CPU got there.  A reset re-arms it; the
//  ring keeps its data.
//
//  Word layout:
//     15:0 PC   31:16 SP   39:32 data   47:40 port (a[7:0])   51:48 kind
//     52 use_nz  53 iff1  54 vdp_int_n  55 ms_int_n   79:56 time, 16 clk21m per tick
//     K_LOOP: 15:0 the loop's address, 47:32 the repeat count, time = when it ended
//     marker: all ones
module evt_trace
(
   input         clk,
   input         reset,
   input  [15:0] pc,
   input  [15:0] pc_bus,        // the address bus (an M1 fetch address, unlike `pc`)
   input  [15:0] sp,
   input         iff1,
   input         use_nz,
   input         vdp_int_n,
   input         ms_int_n,
   input         mreq_n,
   input         m1_n,
   input         iorq_n,
   input         rd_n,
   input         wr_n,
   input   [7:0] a_lo,
   input   [7:0] d_wr,          // data from the CPU
   input   [7:0] d_rd           // data to the CPU
);
   localparam [3:0]  K_INTA = 4'd1, K_IOR = 4'd2, K_IOW = 4'd3, K_SWAP = 4'd4, K_IFF = 4'd5, K_R38 = 4'd6, K_RST = 4'd7, K_BR = 4'd8, K_SUB = 4'd9, K_SUBR = 4'd10, K_LOOP = 4'd11;
   localparam [7:0]  STORM = 8'd8;
   localparam [15:0] LOOPIN = 16'd8;            // repeats stored before a loop is folded
   localparam [25:0] WEDGE_T = 26'd43_000_000;  // ~2.0 s at 21.48 MHz: one target that long is a wedge
   localparam [12:0] POST = 13'd64;

   logic [27:0] tdiv = 28'd0;
   wire  [23:0] now  = tdiv[27:4];
   always_ff @(posedge clk) tdiv <= tdiv + 28'd1;

   wire inta  = ~m1_n & ~iorq_n;
   wire io_rd = ~iorq_n & ~rd_n & m1_n;
   wire io_wr = ~iorq_n & ~wr_n & m1_n;
   wire p_vdp = (a_lo[7:2] == 6'b100110);                       // 98h-9Bh
   wire p_fdc = (a_lo[7:3] == 5'b11010);                        // D0h-D7h (WD2793 + side/motor)
   wire p_map = (a_lo[7:2] == 6'b111111);                       // FCh-FFh (memory mapper)
   wire p_rd  = p_vdp | p_fdc | p_map | (a_lo == 8'hC4) | (a_lo == 8'hA7) | (a_lo[7:1] == 7'b1010001);
   wire p_wr  = p_vdp | p_fdc | p_map | (a_lo == 8'hA8) | (a_lo[7:1] == 7'b1110010) | (a_lo[7:1] == 7'b1010001) | (a_lo == 8'hA7);
   //  Opcode-fetch tracking: the address of the fetch BEFORE the one at 0038h is
   //  the runaway's own PC, which names the FF-reading region.
   wire       m1_fetch = ~m1_n & ~mreq_n & ~rd_n;
   logic      m1f_q    = 1'b0;
   logic [15:0] m1_a = 16'd0, br_last = 16'd0;
   logic  [7:0] m1_op = 8'd0;       // the byte of the fetch in progress
   wire       fetch_38 = m1_fetch & ~m1f_q & (pc_bus == 16'h0038);
   //  Secondary slot register.  A memory cycle, so an I/O log never sees it, yet
   //  it decides which subslot of an expanded primary answers a fetch: the board's
   //  runaway began on a BIOS inter-slot call jumping to 7900h and reading FF
   //  (2026-09-20), which is what an empty subslot looks like.
   wire       sub_wr   = ~mreq_n & ~wr_n & (pc_bus == 16'hFFFF);
   wire       sub_rd   = ~mreq_n & ~rd_n &  m1_n & (pc_bus == 16'hFFFF);
   logic      subw_q = 1'b0, subr_q = 1'b0;
   //  Branch trace: an opcode fetch whose address is not 1..4 bytes past the
   //  previous one -- every jump, call, return and loop-back, and nothing else
   //  (no Z80 opcode is longer than four bytes).  A machine wedged in a loop that
   //  touches no port shows up here as the same address over and over, which is
   //  what the board's two silent hangs need (2026-09-20).
   wire [15:0] delta    = pc_bus - m1_a;
   wire        is_br    = m1_fetch & ~m1f_q & ((delta == 16'd0) | (delta > 16'd4));

   logic inta_q = 1'b0, iord_q = 1'b0, iowr_q = 1'b0, nz_q = 1'b0, iff_q = 1'b0, rst_q = 1'b0;
   logic [7:0]  rd_val = 8'd0, rd_port = 8'd0;
   logic [15:0] sp_last = 16'hFFFF;
   logic [7:0]  depth = 8'd0;
   logic        trig = 1'b0, stopped = 1'b0, marked = 1'b0;
   logic [12:0] post = 13'd0, ptr = 13'd0, wa = 13'd0;
   logic        we = 1'b0;
   logic [79:0] wd = 80'd0;
   //  Loop folding.  in_loop: the recorder is inside a loop it has stopped storing;
   //  rep counts its repeats; run_t times it, and is cleared by a branch anywhere
   //  else.  pend holds the event that broke a loop, written the clock after the
   //  K_LOOP summary (events are never closer than a memory cycle, ~6 clk21m).
   logic        in_loop = 1'b0, pend = 1'b0;
   logic [15:0] rep     = 16'd0;
   logic [25:0] run_t   = 26'd0;
   logic [79:0] pend_wd = 80'd0;

   //  At most one event per clock is kept; the priorities only matter when two
   //  coincide, which the bus does not allow for the pairs that matter.
   logic        ev;
   logic [3:0]  ev_kind;
   logic [7:0]  ev_data;
   always_comb begin
      ev = 1'b1; ev_kind = K_RST; ev_data = 8'd0;
      if      (reset & ~rst_q)                  begin ev_kind = K_RST;  ev_data = 8'd0; end
      else if (fetch_38)                        begin ev_kind = K_R38;  ev_data = m1_a[7:0]; end
      else if (is_br)                           begin ev_kind = K_BR;   ev_data = pc_bus[7:0]; end
      else if (sub_wr & ~subw_q)                begin ev_kind = K_SUB;  ev_data = d_wr; end
      else if (sub_rd & ~subr_q)                begin ev_kind = K_SUBR; ev_data = d_rd; end
      else if (inta & ~inta_q)                  begin ev_kind = K_INTA; ev_data = {6'd0, ms_int_n, vdp_int_n}; end
      else if (iord_q & ~(io_rd & p_rd))        begin ev_kind = K_IOR;  ev_data = rd_val; end   // end of the read: value settled
      else if ((io_wr & p_wr) & ~iowr_q)        begin ev_kind = K_IOW;  ev_data = d_wr; end
      else if (use_nz != nz_q)                  begin ev_kind = K_SWAP; ev_data = {7'd0, use_nz}; end
      else if (iff1 != iff_q)                   begin ev_kind = K_IFF;  ev_data = {7'd0, iff1}; end
      else                                      ev = 1'b0;
   end

   wire [79:0] norm_wd = {now, ms_int_n, vdp_int_n, iff1, use_nz, ev_kind,
                          (ev_kind == K_R38) ? m1_a[15:8]  :
                          (ev_kind == K_BR)  ? pc_bus[15:8] :
                          (ev_kind == K_IOR) ? rd_port      : a_lo, ev_data, sp, pc};
   wire [79:0] loop_wd = {now, ms_int_n, vdp_int_n, iff1, use_nz, K_LOOP, rep, sp, br_last};

   wire br_ev   = ev & (ev_kind == K_BR);
   wire br_same = br_ev & (pc_bus == br_last);
   //  What belongs to a folded loop: its own repeats and the port traffic inside
   //  it.  An interrupt, a slot switch or a branch anywhere else ends it.
   wire quiet   = (ev_kind == K_IOR) | (ev_kind == K_IOW) | (ev_kind == K_SUB) | (ev_kind == K_SUBR);
   wire hush    = in_loop & ev & (br_same | quiet);
   wire lp_end  = in_loop & ev & ~hush & ~reset;

   always_ff @(posedge clk) begin
      we     <= 1'b0;
      inta_q <= inta;
      iord_q <= io_rd & p_rd;
      iowr_q <= io_wr & p_wr;
      nz_q   <= use_nz;
      iff_q  <= iff1;
      rst_q  <= reset;
      m1f_q  <= m1_fetch;
      subw_q <= sub_wr;
      subr_q <= sub_rd;
      if (m1_fetch & ~m1f_q) m1_a <= pc_bus;
      if (m1_fetch)          m1_op <= d_rd;   // settles by the end of the fetch
      //  A read's address bus has often moved on by the time the cycle ends, which
      //  logged one S#0 read as "port 0D" (the low byte of the next fetch address).
      //  Latch the port at the START of the read, the data at the end.
      if (io_rd & p_rd) begin rd_val <= d_rd; if (~iord_q) rd_port <= a_lo; end

      if (reset) begin                                  // re-arm, keep the ring
         trig <= 1'b0; stopped <= 1'b0; marked <= 1'b0; post <= 13'd0;
         depth <= 8'd0; sp_last <= 16'hFFFF;
         in_loop <= 1'b0; rep <= 16'd0; pend <= 1'b0;
      end

      //  The wedge timer runs only inside a folded loop and is cleared by a branch
      //  to any other target.  It measures "one target, unbroken", which is the
      //  only thing that separates a wedge from a loop doing its job.
      if (reset | (br_ev & ~br_same)) run_t <= 26'd0;
      else if (in_loop)               run_t <= run_t + 26'd1;

      if (stopped & ~reset) begin
         if (!marked) begin marked <= 1'b1; we <= 1'b1; wa <= ptr; wd <= {80{1'b1}}; end
      end else if (pend) begin                           // the event that broke a loop
         we <= 1'b1; wa <= ptr; wd <= pend_wd; ptr <= ptr + 13'd1; pend <= 1'b0;
         if (trig) begin
            if (post == 13'd1) stopped <= 1'b1;
            post <= post - 13'd1;
         end
      end else if (lp_end) begin                         // one word for the whole loop
         we <= 1'b1; wa <= ptr; wd <= loop_wd; ptr <= ptr + 13'd1;
         in_loop <= 1'b0; rep <= 16'd0;
         pend <= 1'b1; pend_wd <= norm_wd;
         if (br_ev) br_last <= pc_bus;
         if (ev_kind == K_INTA) depth <= 8'd0;
         else if (ev_kind == K_R38) begin
            depth <= depth + 8'd1;
            if (!trig && depth == STORM - 8'd1) begin trig <= 1'b1; post <= POST; end
         end
         if (trig) begin
            if (post == 13'd1) stopped <= 1'b1;
            post <= post - 13'd1;
         end
      end else if (hush) begin                           // inside a folded loop: count only
         if (br_same && rep != 16'hFFFF) rep <= rep + 16'd1;
      end else if (ev) begin
         we  <= 1'b1;
         wa  <= ptr;
         wd  <= norm_wd;
         ptr <= ptr + 13'd1;
         if (br_ev) begin
            br_last <= pc_bus;
            if (br_same) begin
               rep <= rep + 16'd1;
               if (!trig && rep >= LOOPIN - 16'd1) in_loop <= 1'b1;
            end else rep <= 16'd0;
         end
         if (ev_kind == K_INTA) depth <= 8'd0;              // a real interrupt: not a storm
         else if (ev_kind == K_R38) begin
            depth <= depth + 8'd1;
            if (!trig && depth == STORM - 8'd1) begin trig <= 1'b1; post <= POST; end
         end
         if (trig) begin
            if (post == 13'd1) stopped <= 1'b1;
            post <= post - 13'd1;
         end
      end

      //  Last word: once the wedge fires, unfold, so the POST events store the
      //  wedge itself at the tail of the dump, and never fold again.
      if (!trig && in_loop && run_t == WEDGE_T) begin
         trig <= 1'b1; post <= POST; in_loop <= 1'b0; rep <= 16'd0;
      end
   end

   altsyncram #(
      .operation_mode("SINGLE_PORT"),
      .width_a(80), .widthad_a(13), .numwords_a(8192),
      .outdata_reg_a("UNREGISTERED"),
      .lpm_hint("ENABLE_RUNTIME_MOD=YES, INSTANCE_NAME=EVTR"),
      .lpm_type("altsyncram")
   ) u_evtr (
      .clock0(clk), .address_a(wa), .data_a(wd), .wren_a(we), .q_a(),
      .aclr0(1'b0), .aclr1(1'b0), .address_b(1'b1), .addressstall_a(1'b0),
      .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b1),
      .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
      .data_b(1'b1), .eccstatus(), .q_b(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
   );
endmodule
