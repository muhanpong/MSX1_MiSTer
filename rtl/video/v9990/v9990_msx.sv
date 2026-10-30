// v9990_msx: the V9990 (GFX9000) on the nextz80 core.
//
// Three clocks, all outputs of the one PLL and phase-aligned, so every crossing
// below is a synchronous, timed path (no async FIFOs):
//   clk_sdram 85.909 MHz = 2 x clk_v99 = 4 x clk21m
//   clk_v99   42.955 MHz   the V9990 core (2736 clocks a line, as the core expects)
//   clk21m    21.477 MHz   the MSX bus, CLK_VIDEO
//
// CPU (ports 60h-6Fh): the core's host bus wants req held with wrt / adr / dbo
// until a one-clock ack.  The clk21m side latches the access on the strobe's
// falling edge, raises `pending` (the caller ORs it into the bus WAIT, as for
// MoonSound) and holds `h_req`; the clk_v99 side passes it to the core, keeps
// the ack as `h_done` until h_req drops (a one-clock ack could fall between
// two clk21m edges), and the clk21m side then latches dbi and releases WAIT.
// A watchdog releases WAIT if the core never answers (it only waits for a
// VRAM access to finish, so this is a hang guard, not a timing).
//
// VRAM: v9990_vram_cache (4 lines) in front of sdram.sv ch5.  The cache holds
// m_req until a one-clock m_ack and may present the next request on the next
// clock, so a request is handed over as a toggle (clk_v99 -> clk_sdram) and the
// completion comes back as a toggle; m_ack is one clk_v99 clock.
//
// Video: RGB / syncs / blanks registered on clk21m (every other core clock).
// The core's narrowest pixel in B0-B3, P1, P2 is 4 core clocks (512 wide), so
// ce_pix every other clk21m (10.74 MHz, as the V9958's DHClk) takes each pixel
// once.  B4 / B7 (1024 wide) come out at half resolution; B5 / B6 (25 / 31 kHz
// high scan) are not supported by this path.
//
// en = 0 holds the core and the cache in reset: no port decode, no VRAM
// request, ch5 never selected, so the rest of the machine is exactly as without
// the V9990.

module v9990_msx
(
   input  logic        clk21m,
   input  logic        clk_v99,
   input  logic        clk_sdram,
   input  logic        reset,          // clk21m domain
   input  logic        en,             // OSD: V9990 present

   // MSX bus (clk21m)
   input  logic        iorq_n,
   input  logic        m1_n,
   input  logic        rd_n,
   input  logic        wr_n,
   input  logic [7:0]  a,
   input  logic [7:0]  d_from_cpu,
   output logic        cs,             // ports 60h-6Fh selected (read data mux)
   output logic [7:0]  d_out,
   output logic        pending,        // hold the CPU (WAIT)
   output logic        int_n,          // assert-and-hold, see below

   // SDRAM ch5 (clk_sdram)
   input  logic [26:0] vram_base,      // byte address of the 512 KB VRAM
   output logic [26:0] ch5_addr,
   output logic [15:0] ch5_din,
   output logic  [1:0] ch5_be,
   output logic        ch5_req = 1'b0,
   output logic        ch5_rnw,
   input  logic [63:0] ch5_dout,
   input  logic        ch5_ready,

   // Video (clk21m)
   output logic  [7:0] R,
   output logic  [7:0] G,
   output logic  [7:0] B,
   output logic        hsync_n,
   output logic        vsync_n,
   output logic        hblank,
   output logic        vblank,
   output logic        ce_pix,
   output logic        disp_en         // R#8 DISP of this frame
);

// ── reset into the core domain ─────────────────────────────────────────────
logic [1:0] rst_v = 2'b11;
always_ff @(posedge clk_v99) rst_v <= {rst_v[0], reset | ~en};
wire reset_v_n = ~rst_v[1];

// ── CPU side (clk21m) ──────────────────────────────────────────────────────
assign cs = en & ~iorq_n & m1_n & (a[7:4] == 4'h6);

logic        wr_n_d = 1'b1, rd_n_d = 1'b1;
logic        h_req = 1'b0;            // held until the core side reports done
logic        h_wrt;
logic  [3:0] h_adr;
logic  [7:0] h_dbo;
logic        h_done;                  // clk_v99
logic  [7:0] h_dbi;                   // clk_v99, valid with h_done
logic [11:0] h_wd;                    // watchdog, clk21m

always_ff @(posedge clk21m) begin
   wr_n_d <= wr_n;
   rd_n_d <= rd_n;
   if (reset | ~en) begin
      h_req   <= 1'b0;
      pending <= 1'b0;
   end else begin
      if (cs & ((~wr_n & wr_n_d) | (~rd_n & rd_n_d)) & ~h_req) begin
         h_req   <= 1'b1;
         h_wrt   <= ~wr_n;
         h_adr   <= a[3:0];
         h_dbo   <= d_from_cpu;
         pending <= 1'b1;
         h_wd    <= 12'd4000;          // ~186 us, as MoonSound's
      end
      if (h_req) begin
         if (h_done) begin
            h_req   <= 1'b0;
            pending <= 1'b0;
            d_out   <= h_dbi;
         end else if (h_wd == 12'd0) begin
            h_req   <= 1'b0;
            pending <= 1'b0;
            d_out   <= 8'hFF;
         end else
            h_wd <= h_wd - 12'd1;
      end
   end
end

// ── CPU side (clk_v99) ─────────────────────────────────────────────────────
logic       c_ack;
logic [7:0] c_dbi;
always_ff @(posedge clk_v99) begin
   if (~reset_v_n | ~h_req) h_done <= 1'b0;
   else if (c_ack) begin
      h_done <= 1'b1;
      h_dbi  <= c_dbi;
   end
end
wire c_req = h_req & ~h_done & reset_v_n;

// ── interrupt (clk21m): defer the first assertion to a non-I/O moment, then
//    hold until the core releases it (msx.sv ms_int_hold, same reasons) ──────
logic c_int_n;
logic [1:0] int_s = 2'b11;
logic int_hold = 1'b0;
always_ff @(posedge clk21m) begin
   int_s <= {int_s[0], c_int_n};
   if (int_s[1] | ~en)       int_hold <= 1'b0;
   else if (iorq_n | ~m1_n)  int_hold <= 1'b1;
end
assign int_n = ~int_hold;

// ── VRAM: core -> cache (clk_v99) ──────────────────────────────────────────
logic        v_req, v_we, v_ack;
logic  [1:0] v_be;
logic [17:0] v_addr;
logic [15:0] v_wdata, v_rdata;
logic        m_req, m_we, m_ack;
logic  [1:0] m_be;
logic [17:0] m_addr;
logic [15:0] m_wdata;
logic [63:0] m_rdata;
logic        w_room, w_post;           // posted writes straight from the cache (local change)

// ── video from the core (clk_v99) ──────────────────────────────────────────
logic [7:0] c_r, c_g, c_b;
logic       c_hs_n, c_vs_n, c_hb, c_vb, c_disp;

v9990_core u_core
(
   .clk         (clk_v99),
   .reset_n     (reset_v_n),
   .req_i       (c_req),
   .wrt_i       (h_wrt),
   .adr_i       (h_adr),
   .dbo_i       (h_dbo),
   .ack_o       (c_ack),
   .dbi_o       (c_dbi),
   .int_n_o     (c_int_n),
   .vram_req_o  (v_req),
   .vram_we_o   (v_we),
   .vram_be_o   (v_be),
   .vram_addr_o (v_addr),
   .vram_wdata_o(v_wdata),
   .vram_ack_i  (v_ack),
   .vram_rdata_i(v_rdata),
   .red_o       (c_r),
   .grn_o       (c_g),
   .blu_o       (c_b),
   .hsync_n_o   (c_hs_n),
   .vsync_n_o   (c_vs_n),
   .hblank_o    (c_hb),
   .vblank_o    (c_vb),
   .interlace_o (),
   .disp_en_o   (c_disp),
   .hscan_o     (),
   .vid_x_o     (),
   .vid_y_o     ()
);

v9990_vram_cache #(.LINES(4)) u_cache
(
   .clk     (clk_v99),
   .reset_n (reset_v_n),
   .req     (v_req),
   .we      (v_we),
   .be      (v_be),
   .addr    (v_addr),
   .wdata   (v_wdata),
   .ack     (v_ack),
   .rdata   (v_rdata),
   .m_req   (m_req),
   .m_we    (m_we),
   .m_be    (m_be),
   .m_addr  (m_addr),
   .m_wdata (m_wdata),
   .m_ack   (m_ack),
   .m_rdata (m_rdata),
   .w_room  (w_room),
   .w_post  (w_post)
);

// ── cache -> ch5: a 4-entry queue written on clk_v99, drained on clk_sdram ──
// Writes are posted: m_ack the clock after the entry is queued, so a command
// engine fill runs at the SDRAM's write rate instead of paying the clk_v99 <->
// clk_sdram round trip per word (first build: 17.7 ms for the 3D demo's sky fill,
// over a frame).  A read is queued behind any writes, so the memory sees them in
// order, and is acked when its line comes back (d_tog, one toggle per read).
// The pointers cross directly (one PLL, timed paths); each side registers the
// other's pointer once before using it, so a queue entry is stable for a whole
// clk_sdram period before it is read -- MSX1.sdc gives f_* -> ch5_* and
// d_line -> m_rdata 2-cycle setup / 1-cycle hold on that basis.
localparam int QD = 4;
logic        f_we   [QD];
logic [17:0] f_addr [QD];
logic [15:0] f_data [QD];
logic  [1:0] f_be   [QD];
logic  [2:0] wp = 3'd0, rp_q = 3'd0;  // clk_v99
logic  [2:0] rp = 3'd0, wp_q = 3'd0;  // clk_sdram
logic        rd_inflight = 1'b0, d_seen = 1'b0, d_tog_q = 1'b0;
logic        d_tog = 1'b0;             // clk_sdram, flips once per completed read
logic [63:0] d_line;                   // clk_sdram, set with d_tog

always_ff @(posedge clk_v99) begin
   m_ack   <= 1'b0;
   d_tog_q <= d_tog;
   rp_q    <= rp;
   // every completion is a read's (writes do not toggle d_tog); one read in flight
   if (d_tog_q != d_seen) begin
      d_seen      <= d_tog_q;
      rd_inflight <= 1'b0;
      if (reset_v_n) begin
         m_ack   <= 1'b1;
         m_rdata <= d_line;
      end
   end else if (w_post) begin         // a posted write: w_room promised the entry
      f_we  [wp[1:0]] <= 1'b1;
      f_addr[wp[1:0]] <= m_addr;
      f_data[wp[1:0]] <= m_wdata;
      f_be  [wp[1:0]] <= m_be;
      wp <= wp + 3'd1;
   end else if (reset_v_n & m_req & ~m_ack & ~rd_inflight & ((wp - rp_q) != 3'(QD))) begin
      f_we  [wp[1:0]] <= m_we;
      f_addr[wp[1:0]] <= m_addr;
      f_data[wp[1:0]] <= m_wdata;
      f_be  [wp[1:0]] <= m_be;
      wp <= wp + 3'd1;
      if (m_we) m_ack       <= 1'b1;   // posted
      else      rd_inflight <= 1'b1;
   end
end

// Room for a posted write: rp_q lags rp, so this can only under-report the space.
// Not while a completion is being taken (that clock does not enqueue).
assign w_room = ((wp - rp_q) < 3'(QD)) & (d_tog_q == d_seen);

logic [1:0] s_st = 2'd0;               // 0 idle, 1 wait taken (ready low), 2 wait done
always_ff @(posedge clk_sdram) begin
   wp_q <= wp;
   case (s_st)
      2'd0: if (rp != wp_q) begin
               ch5_addr <= vram_base + {8'd0, f_addr[rp[1:0]], 1'b0};
               ch5_rnw  <= ~f_we[rp[1:0]];
               ch5_din  <= f_data[rp[1:0]];
               ch5_be   <= f_be[rp[1:0]];
               ch5_req  <= 1'b1;
               s_st     <= 2'd1;
            end
      2'd1: if (~ch5_ready) s_st <= 2'd2;
      2'd2: if (ch5_ready) begin
               ch5_req <= 1'b0;        // low for at least one clock: the next request is an edge
               if (ch5_rnw) begin
                  d_line <= ch5_dout;
                  d_tog  <= ~d_tog;
               end
               rp   <= rp + 3'd1;
               s_st <= 2'd0;
            end
      default: s_st <= 2'd0;
   endcase
end

// ── video into clk21m ──────────────────────────────────────────────────────
logic ce_t = 1'b0;
always_ff @(posedge clk21m) begin
   R       <= c_r;
   G       <= c_g;
   B       <= c_b;
   hsync_n <= c_hs_n;
   vsync_n <= c_vs_n;
   hblank  <= c_hb;
   vblank  <= c_vb;
   disp_en <= c_disp & en;
   ce_t    <= ~ce_t;
end
assign ce_pix = ce_t;

endmodule
