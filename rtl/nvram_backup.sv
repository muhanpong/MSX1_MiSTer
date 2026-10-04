module nvram_backup
#(
   //  Autosave timing; benches shrink these.  2^(QUIET_BITS-1) clocks of no
   //  writes (~0.78 s at 21.48 MHz), or 2^(AGE_BITS-1) clocks after the first
   //  write (~12.5 s) if they never stop.
   parameter int QUIET_BITS = 25,
   parameter int AGE_BITS   = 29
)
(
   input                      clk,
   input                      reset,
   input MSX::lookup_SRAM_t   lookup_SRAM[4],
   input                      load_req,
   input                      save_req,
   //  memory_upload is rebuilding the slot layout and the SRAM BRAM (its reset_rq).
   //  No transfer starts and no save is kept while it is high -- see the request
   //  block below.
   input                      upload_busy,
   //  Autosave on write (status[52]): a bank whose SRAM the CPU wrote is saved once
   //  writes have been quiet for ~0.8 s, or ~12 s after the first write if they
   //  never stop, or at once when `flush` rises (a file download or a reset button
   //  -- something that is about to replace or reset what the SRAM holds).
   input                      autosave_en,
   input                      cpu_wr,          // CPU write into the SRAM BRAM (port A, not the upload)
   input               [17:0] cpu_wr_addr,
   input                      rtc_dirty,       // CPU write into the RTC settings memory
   input                      flush,
   // SD config.  VD0 = slot A ROM's .sav, VD1 = the SRAM file (OSD SC1).
   input                [1:0] img_mounted,
   input                      img_readonly,
   input               [63:0] img_size,
   // SD block level access
   output              [31:0] sd_lba[2],
   output logic         [1:0] sd_rd = 2'd0,
   output logic         [1:0] sd_wr = 2'd0,
   input                [1:0] sd_ack,
   input               [13:0] sd_buff_addr,
   input                [7:0] sd_buff_dout,
   output               [7:0] sd_buff_din[2],
   // BRAM access.  Bank 4 (RTC) is addressed at 18'h20000: bit 17 is beyond the
   // 64 kB SRAM BRAM, and MSX1.sv routes that range to the RTC's second port.
   output              [17:0] ram_addr,
   output                     ram_we,
   input                [7:0] ram_dout,
   // ASCII16X flash save/load (Slot A, cart 0)
   input                      flash16x_active,
   input               [26:0] flash16x_base,
   input               [15:0] flash16x_size,  // in 16 kB units
   // SDRAM ch1 (shared with upload when upload is idle)
   output logic        [26:0] sdram_addr  = 27'h0,
   output logic               sdram_req   = 1'b0,
   output logic               sdram_rnw   = 1'b0,
   output logic         [7:0] sdram_din   = 8'h0,
   input                [7:0] sdram_dout,
   input                      sdram_ready,
   // Hold CPU via WAIT_n while flash DMA uses SDRAM ch1
   output                     dma_active,
   output                     dma_save,    // dma_active AND the operation is a save (icon only)
   //  A transfer is in flight, or a save is waiting that can be served.  For
   //  save_guard: a reset button or a ROM upload must wait for it (MSX1.sv).
   output                     guard
);

//  ---------------------------------------------------------------- banks
//  0     slot A ROM cart          -> VD0 .sav, raw from LBA 0
//  1     slot A FM-PAC / GM2      -> VD1 entry kind-1
//  2     slot B FM-PAC / GM2      -> VD1 entry kind-1, unless bank 1 has the same kind
//  3     machine SRAM (Halnote, Panasonic firmware mapper) -> VD1 entry kind-1
//  4     RTC settings memory      -> VD1 entry 5
//  Banks 1..4 share ONE file, so two banks of the same kind would write the same
//  entry: the lower bank wins and the other is not saved or loaded (slot A over
//  slot B, user decision 2026-10-04).
localparam int NB = 5;
logic [17:0] bk_addr[NB];
logic [15:0] bk_size[NB];
logic  [7:0] bk_kind[NB];
always_comb begin
   for (int n = 0; n < 4; n++) begin
      bk_addr[n] = lookup_SRAM[n].addr;
      bk_size[n] = lookup_SRAM[n].size;
      bk_kind[n] = lookup_SRAM[n].kind;
   end
   bk_addr[4] = 18'h20000;
   bk_size[4] = 16'd1;                 // 1 kB; the RTC has 64 nibbles, the rest is copies
   bk_kind[4] = MSX::SRAM_KIND_RTC;
end

logic [63:0] image_size[2];
logic  [1:0] image_mounted = 2'b0;
logic  [1:0] image_ro = 2'b0;
logic        store_new_size = 1'b0;

always @(posedge clk) begin
   //  Read-only is a reason not to WRITE the image, not a reason to refuse to
   //  read it.  Folding it into image_mounted made a read-only .sav skip its
   //  auto-load silently, which looks exactly like the .sav not being there.
   if (img_mounted[0]) begin image_mounted[0] <= 1'b1; image_ro[0] <= img_readonly; image_size[0] <= img_size; end //ROM .sav
   if (img_mounted[1]) begin image_mounted[1] <= 1'b1; image_ro[1] <= img_readonly; image_size[1] <= img_size; end //SRAM file
   //  size is in kB, so bytes is << 10.  Only VD0's image is exactly the SRAM.
   if (store_new_size) image_size[0] <= (64'(bk_size[0])) << 10;
end

//  Which banks could be served right now -- the same conditions STATE_SLEEP checks
//  below, as vectors, so the request block can choose before it commits.
logic [NB-1:0] eligible, can_load, can_save;
always_comb begin
   eligible[0] = bk_size[0] != 16'h00;
   for (int n = 1; n < NB; n++) begin
      eligible[n] = (bk_size[n] != 16'h00) & (bk_kind[n] >= MSX::SRAM_KIND_FMPAC) & (bk_kind[n] <= MSX::SRAM_KIND_RTC);
      for (int m = 1; m < n; m++)
         if ((bk_size[m] != 16'h00) & (bk_kind[m] == bk_kind[n])) eligible[n] = 1'b0;
   end
   for (int n = 0; n < NB; n++) begin
      can_save[n] = eligible[n] & image_mounted[n != 0] & ~image_ro[n != 0];
      can_load[n] = eligible[n] & image_mounted[n != 0] & ((n != 0) | (image_size[0] != 64'd0));
   end
end

//  ---------------------------------------------------------------- autosave
logic [NB-1:0]         dirty = '0;
logic [QUIET_BITS-1:0] quiet = '0;
logic [AGE_BITS-1:0]   age   = '0;
logic                  flush_q = 1'b0;
logic [NB-1:0]         wr_hit;
always_comb begin
   for (int n = 0; n < 4; n++)
      wr_hit[n] = cpu_wr & (bk_size[n] != 16'h00) & (cpu_wr_addr >= bk_addr[n]) &
                  ({1'b0, cpu_wr_addr} < {1'b0, bk_addr[n]} + {3'b0, bk_size[n]} * 19'd1024);
   wr_hit[4] = rtc_dirty;
end
wire autosave_fire = autosave_en & (|dirty) &
                     (quiet[QUIET_BITS-1] | age[AGE_BITS-1] | (flush & ~flush_q));

always @(posedge clk) begin
   flush_q <= flush;
   //  A write during the upload is the upload's own (memory_upload refills the
   //  BRAM), and what was dirty before it belongs to the layout it replaced.
   if (upload_busy | ~autosave_en) begin
      dirty <= '0;
      quiet <= '0;
      age   <= '0;
   end else begin
      dirty <= (autosave_fire ? '0 : dirty) | wr_hit;
      if (|wr_hit)                       quiet <= '0;
      else if (~quiet[QUIET_BITS-1])     quiet <= quiet + 1'b1;
      if ((dirty == '0) | autosave_fire) age <= '0;
      else if (~age[AGE_BITS-1])         age <= age + 1'b1;
   end
end

logic [NB-1:0] request_load = '0, request_save = '0;
logic    [2:0] num          = 3'd0;
wire           v            = (num != 3'd0);   // which VD this bank lives on
logic       wr           = 1'b0, rd = 1'b0;

logic last_load_req = 1'b0;
logic last_save_req = 1'b0;
//  The request edges are sampled OUTSIDE the reset branch, and a reset does not
//  clear a request that arrived during it.  `load_sram` is a one-clock pulse that
//  memory_upload raises on the same edge it leaves its FSM -- which is the edge
//  `reset_rq` falls -- and since 2026-09-20 the machine reset is stretched 63
//  clk21m past that (MSX1.sv `rst_hold`).  With the latch inside `else`, that
//  pulse landed entirely inside reset, was never seen, and never came again: no
//  .sav was read when a ROM was loaded, while the OSD's own SRAM Load (no reset)
//  still worked.  A load/save request is a host command, not machine state.
//  `unserved` is a bank the engine looked at and could not act on yet -- the
//  image is not mounted, or has no size.  That is NOT completion: clearing the
//  request there threw the auto-load away for good, because nothing ever asks
//  again (load_req is the OSD button or memory_upload's one-clock end-of-upload
//  pulse, and a later img_mounted raises neither).  Keep it pending and come
//  back, with a bound so a request that can never be served does not spin for
//  the rest of the session.
localparam int PEND_BITS = 26;              // ~3 s at 21.477272 MHz
logic [PEND_BITS-1:0] pend_age = '0;
wire                  pend_expired = pend_age[PEND_BITS-1];

always @(posedge clk) begin
   logic [NB-1:0] rl, rs;
   rl = request_load;
   rs = request_save;

   //  Completion clears the bank it served; an arriving request sets all of them.
   //  Doing both on the same edge used to lose one bank, because the bit write
   //  came after the vector write and won.  Setting last means a request is
   //  never lost -- at worst a bank is served twice, which is harmless.
   if (done) begin
      if (wr) rs[num] = 1'b0;
      if (rd) rl[num] = 1'b0;
   end
   if (~last_load_req & load_req) rl = '1;
   if (~last_save_req & save_req) rs = '1;
   if (autosave_fire)             rs = rs | dirty;
   //  A newly mounted image is read.  The firmware mounts an image without asking
   //  the core (core start for boot<n>.vhd, every ROM load for VD0's .sav, an OSD
   //  pick for an S entry), and until now only load_req ever read one -- so an
   //  image picked mid-session was never read, and the next save wrote the BRAM's
   //  old contents into it.
   rl = rl | {{(NB-1){img_mounted[1]}}, img_mounted[0]};
   //  While memory_upload rebuilds the layout the BRAM is being refilled; a save
   //  taken now would write that into the image.  Requests that arrive during it
   //  are dropped; a save asked for BEFORE it started has already run, because
   //  save_guard (guard, below) holds the upload until it has.
   if (upload_busy) rs = '0;
   request_load <= rl;
   request_save <= rs;

   last_load_req <= load_req;
   last_save_req <= save_req;

   //  Age only while something is pending and nothing is in flight.
   if ((rl | rs) == '0 | done)    pend_age <= '0;
   else if (~pend_expired)        pend_age <= pend_age + 1'b1;
   if (pend_expired) begin
      request_load <= '0;
      request_save <= '0;
   end

   if (reset) begin
      wr             <= 1'b0;
      rd             <= 1'b0;
      num            <= 3'd0;
   end else begin
      if (done | unserved) begin
         wr <= 1'b0;
         rd <= 1'b0;
         //  Keeping the request pending is only half of it: the scan has to move
         //  on as well, or it re-offers the same unserviceable bank forever and
         //  never reaches the one that IS ready.  That livelock is the reported
         //  symptom again, so the round-robin advances here and the pending bank
         //  is retried on the next pass.
         if (unserved) num <= (num == 3'(NB-1)) ? 3'd0 : num + 3'd1;
      end
      //  Load before save.  After an upload the BRAM holds the fill pattern until
      //  the load has run, so a save served first wrote 0xFF over the image -- the
      //  load would then read that back.  Only start what can be served; a bank
      //  with nothing servable is passed over and its pending load retried on the
      //  next pass (the round-robin must keep moving, see above).
      if (~wr & ~rd & ~upload_busy) begin
         if (request_load[num] & can_load[num]) begin
            rd <= 1'b1;
         end else if (request_save[num] & can_save[num]) begin
            wr <= 1'b1;
         end else begin
            if (num == 3'(NB-1)) num <= 3'd0;
            else num <= num + 3'd1;
         end
      end
   end
end

typedef enum logic [3:0] {
   STATE_SLEEP,
   STATE_PROCESS,          // BRAM-based SRAM save/load
   STATE_FLASH_PREFETCH,   // Issue SDRAM read for byte flash_byte_ptr
   STATE_FLASH_RD_WAIT,    // Wait for SDRAM read completion (fills sector_buf)
   STATE_FLASH_SD_WR,      // Write sector_buf to SD
   STATE_FLASH_SD_RD,      // Read sector from SD into sector_buf
   STATE_FLASH_SDRAM_WR,   // Issue SDRAM write for byte flash_byte_ptr (from sector_buf)
   STATE_FLASH_WR_WAIT,    // Wait for SDRAM write completion
   STATE_CHECK_SIZE,
   STATE_FORMAT,
   STATE_NEXT,
   STATE_HDR_RD,           // VD1: read the entry header sector (load: verify; save: fetch the counter)
   STATE_HDR_WR            // VD1: write the entry header sector, then the data
} state_t;

logic [20:0] block_count;
logic [31:0] lba_start;
logic        done = 1'b0;

//  ---------------------------------------------------------------- image layout
//  VD0 is the slot A ROM's companion .sav: raw SRAM from LBA 0, as it always was.
//  VD1 is the SRAM file (OSD SC1, remembered in config/MSX1.s1) and holds one
//  64 kB entry per DEVICE KIND, entry = kind - 1: FM-PAC 0, GM2 1, Halnote 2,
//  Panasonic 16 kB 3, Panasonic 32 kB 4, RTC 5 -- 384 kB in all.  Entry n: header
//  sector at LBA 128n (4 kB reserved, one sector used), data from LBA 128n + 8, up
//  to 60 kB.  docs/sram_images.md.  A load is skipped -- not retried -- when the
//  header does not match this bank's kind and size; a save always rewrites the
//  header, so a zero-filled file works from the first save.
localparam [7:0] HDR_VER = 8'd1;
wire        layout    = v;
wire [31:0] lba_base  = 32'(bk_kind[num] - 8'd1) << 7;           // * 128 sectors
wire [31:0] data_base = layout ? lba_base + 32'd8 : 32'd0;
logic [20:0] sec = 21'd0;                                        // sector within the data area
logic  [7:0] hdr[16];                                            // header bytes read back
logic [31:0] hdr_cnt = 32'd0;                                    // save counter to write
wire         hdr_ok  = hdr[0] == "M" && hdr[1] == "S" && hdr[2] == "X" && hdr[3] == "1" &&
                       hdr[4] == "S" && hdr[5] == "R" && hdr[6] == "A" && hdr[7] == "M" &&
                       hdr[8] == HDR_VER && hdr[9] == bk_kind[num] &&
                       {hdr[11], hdr[10]} == bk_size[num];
function automatic logic [7:0] hdr_byte(input logic [8:0] i, input logic [7:0] kind,
                                        input logic [15:0] size, input logic [31:0] cnt);
   case (i)
      9'd0: hdr_byte = "M"; 9'd1: hdr_byte = "S"; 9'd2: hdr_byte = "X"; 9'd3: hdr_byte = "1";
      9'd4: hdr_byte = "S"; 9'd5: hdr_byte = "R"; 9'd6: hdr_byte = "A"; 9'd7: hdr_byte = "M";
      9'd8:  hdr_byte = HDR_VER;
      9'd9:  hdr_byte = kind;
      9'd10: hdr_byte = size[7:0];
      9'd11: hdr_byte = size[15:8];
      9'd12: hdr_byte = cnt[7:0];
      9'd13: hdr_byte = cnt[15:8];
      9'd14: hdr_byte = cnt[23:16];
      9'd15: hdr_byte = cnt[31:24];
      default: hdr_byte = 8'h00;
   endcase
endfunction
//  bytes the image must hold for this bank: data end, in bytes
wire [63:0] need_bytes = 64'(data_base + 32'(bk_size[num]) * 2) << 9;
logic        unserved = 1'b0;   // looked at, cannot act yet -- keep the request

// Flash DMA state
logic  [8:0] flash_byte_ptr;
logic [15:0] flash_sector;
logic [15:0] flash_total_sectors;
logic  [7:0] sector_buf[512];
logic  [6:0] sdram_wait;
logic [26:0] sd_wr_timeout;

//  Only DATA sectors touch the BRAM: a header sector being read must not land in
//  the SRAM, so ram_we is qualified on STATE_PROCESS.
assign ram_we         = rd & sd_ack[v] & ~sd_buff_addr[9] & (state == STATE_PROCESS);
assign ram_addr       = bk_addr[num] + 18'({sec, sd_buff_addr[8:0]});
assign sd_buff_din[0] = (state == STATE_FLASH_SD_WR) ? sector_buf[sd_buff_addr[8:0]] : ram_dout;
assign sd_buff_din[1] = (state == STATE_HDR_WR) ? hdr_byte(sd_buff_addr[8:0], bk_kind[num], bk_size[num], hdr_cnt) : ram_dout;

logic last_ack = 1'b0;
state_t state = STATE_SLEEP;

// Hold CPU for the ENTIRE flash save/load operation (avoid rapid WAIT_n toggling)
// wr/rd is which way the CURRENT slot is moving; the overlay shows a save icon
// only for saves, so a boot-time .sav auto-LOAD does not flash it (2026-09-09).
assign dma_save   = dma_active & wr;
//  A dirty bank counts as a save waiting -- a load or a reset button arriving
//  before the quiet timer runs out waits for it, and `flush` (which they raise)
//  turns it into a save at once.  While flush is held the dirty term is dropped,
//  or a game that writes its SRAM every frame would hold an upload off for good.
assign guard      = (state != STATE_SLEEP) | wr | rd | |(request_save & can_save)
                  | (autosave_en & ~flush & |(dirty & can_save));
assign dma_active = (state == STATE_FLASH_PREFETCH)
                  | (state == STATE_FLASH_RD_WAIT)
                  | (state == STATE_FLASH_SD_WR)
                  | (state == STATE_FLASH_SD_RD)
                  | (state == STATE_FLASH_SDRAM_WR)
                  | (state == STATE_FLASH_WR_WAIT);

always @(posedge clk) begin
   done           <= 1'b0;
   unserved       <= 1'b0;
   store_new_size <= 1'b0;

   if (reset) begin
      state     <= STATE_SLEEP;
      sd_rd     <= 2'b0;
      sd_wr     <= 2'b0;
      sdram_req <= 1'b0;
   end else
   case (state)
      // -----------------------------------------------------------------------
      STATE_SLEEP: begin
         if ((rd | wr) & ~done & ~unserved) begin
            // ASCII16X flash save DISABLED: SDRAM ch1 DMA corrupts SDRAM controller
            // after sustained read traffic. Requires future Flash FSM + BRAM mirror.
            if (1'b0 & num == 3'd0 & flash16x_active & image_mounted[0]
                & (wr | (rd & (image_size[0] > 0)))) begin
               // ASCII16X flash: use SDRAM DMA path via VD0 (Slot A ROM companion)
               flash_sector        <= 16'd0;
               flash_total_sectors <= 16'(flash16x_size) << 5;  // * 32 sectors per 16 kB
               flash_byte_ptr      <= 9'd0;
               sd_lba[0]           <= 32'd0;
               if (wr) begin
                  state <= STATE_FLASH_PREFETCH;
               end else begin
                  sd_rd[0] <= 1'b1;
                  state    <= STATE_FLASH_SD_RD;
               end
            end else if (~layout & (wr ? can_save[0] : can_load[0])) begin
               // VD0: raw SRAM from LBA 0
               sec         <= 21'd0;
               sd_lba[0]   <= 0;
               block_count <= 21'(bk_size[0]) << 1;
               sd_wr[0]    <= wr;
               sd_rd[0]    <= rd;
               state       <= STATE_PROCESS;
               $display("START %d", num);
            end else if (layout & (wr ? can_save[num] : can_load[num])) begin
               // VD1: an entry per kind.  Too small a file cannot be grown by the
               // core (an SC mount is opened without O_CREAT and cannot grow), so
               // that is a skip with a message, not a pending request.
               if (image_size[1] < need_bytes) begin
                  $display("SRAM file too small: %0d < %0d bytes (bank %0d kind %0d, entry %0d)",
                           image_size[1], need_bytes, num, bk_kind[num], lba_base >> 7);
                  done <= 1'b1;
               end else begin
                  block_count <= 21'(bk_size[num]) << 1;
                  sd_lba[1]   <= lba_base;
                  sd_rd[1]    <= 1'b1;             // load and save both read the header first
                  state       <= STATE_HDR_RD;
                  $display("START %0d kind %0d entry %0d (%s)", num, bk_kind[num], lba_base >> 7, wr ? "save" : "load");
               end
            end else if (layout & ~eligible[num]) begin
               // Nothing to do for this bank: no SRAM, an unknown kind, or another
               // bank of the same kind owns the entry.  Not pending -- it never will be.
               done <= 1'b1;
            end else begin
               //  Not done -- just not now.  `done` here would clear the
               //  request and the auto-load would never happen.
               unserved <= 1'b1;
            end
         end
      end

      // -----------------------------------------------------------------------
      // Existing BRAM save/load
      STATE_PROCESS: begin
         if (~sd_ack[v] & last_ack) begin
            if (sec < (block_count - 21'd1)) begin
               sec         <= sec + 1'b1;
               sd_lba[v]   <= data_base + 32'(sec) + 32'd1;
            end else begin
               sd_wr[v]       <= 1'b0;
               sd_rd[v]       <= 1'b0;
               done           <= 1'b1;
               store_new_size <= wr & ~layout;   // VD0's image is exactly the SRAM
               state          <= STATE_SLEEP;
            end
         end
      end

      // -----------------------------------------------------------------------
      // VD1 entry header.  Read first in both directions: a load needs it to
      // match, a save needs the counter it carries.
      STATE_HDR_RD: begin
         if (sd_ack[1] & ~sd_buff_addr[9] & sd_buff_addr[8:4] == 5'd0)
            hdr[sd_buff_addr[3:0]] <= sd_buff_dout;
         if (~sd_ack[v] & last_ack) begin
            sd_rd[1] <= 1'b0;
            if (wr) begin
               hdr_cnt     <= hdr_ok ? {hdr[15], hdr[14], hdr[13], hdr[12]} + 32'd1 : 32'd1;
               sd_lba[1]   <= lba_base;
               sd_wr[1]    <= 1'b1;
               state       <= STATE_HDR_WR;
            end else if (hdr_ok) begin
               sec         <= 21'd0;
               sd_lba[1]   <= data_base;
               sd_rd[1]    <= 1'b1;
               state       <= STATE_PROCESS;
            end else begin
               $display("SRAM file entry %0d: no matching header (bank %0d kind %0d size %0d kB) -- not loaded",
                        lba_base >> 7, num, bk_kind[num], bk_size[num]);
               done  <= 1'b1;
               state <= STATE_SLEEP;
            end
         end
      end

      STATE_HDR_WR: begin
         if (~sd_ack[v] & last_ack) begin
            sec         <= 21'd0;
            sd_lba[1]   <= data_base;
            state       <= STATE_PROCESS;   // sd_wr stays high for the data sectors
         end
      end

      // -----------------------------------------------------------------------
      // Flash save: SDRAM -> sector_buf -> SD
      STATE_FLASH_PREFETCH: begin
         sdram_addr <= flash16x_base + 27'({flash_sector, flash_byte_ptr});
         sdram_rnw  <= 1'b1;
         sdram_req  <= 1'b1;
         sdram_wait <= 7'd68;  // Bandwidth throttle: ch1 takes ~1.5% SDRAM time
         state      <= STATE_FLASH_RD_WAIT;
      end

      STATE_FLASH_RD_WAIT: begin
         sdram_req <= 1'b0;
         if (sdram_wait > 0) begin
            sdram_wait <= sdram_wait - 1'd1;
         end else begin
            sector_buf[flash_byte_ptr] <= sdram_dout;
            flash_byte_ptr             <= flash_byte_ptr + 1'd1;
            if (flash_byte_ptr == 9'd511) begin
               flash_byte_ptr <= 9'd0;
               sd_lba[0]      <= {16'd0, flash_sector};
               sd_wr[0]       <= 1'b1;
               sd_wr_timeout  <= 27'd0;
               state          <= STATE_FLASH_SD_WR;
            end else begin
               state <= STATE_FLASH_PREFETCH;
            end
         end
      end

      STATE_FLASH_SD_WR: begin
         sd_wr_timeout <= sd_wr_timeout + 1'd1;
         if (&sd_wr_timeout) begin  // ~6.3s timeout: abort if ARM never acks
            sd_wr[0] <= 1'b0;
            done     <= 1'b1;
            state    <= STATE_SLEEP;
         end else if (~sd_ack[0] & last_ack) begin
            sd_wr[0]      <= 1'b0;
            flash_sector  <= flash_sector + 1'd1;
            if (flash_sector + 1'd1 < flash_total_sectors) begin
               flash_byte_ptr <= 9'd0;
               state          <= STATE_FLASH_PREFETCH;
            end else begin
               done  <= 1'b1;
               state <= STATE_SLEEP;
            end
         end
      end

      // -----------------------------------------------------------------------
      // Flash load: SD -> sector_buf -> SDRAM
      STATE_FLASH_SD_RD: begin
         if (sd_ack[0])
            sector_buf[sd_buff_addr[8:0]] <= sd_buff_dout;
         if (~sd_ack[0] & last_ack) begin
            sd_rd[0]       <= 1'b0;
            flash_byte_ptr <= 9'd0;
            state          <= STATE_FLASH_SDRAM_WR;
         end
      end

      STATE_FLASH_SDRAM_WR: begin
         sdram_addr <= flash16x_base + 27'({flash_sector, flash_byte_ptr});
         sdram_rnw  <= 1'b0;
         sdram_din  <= sector_buf[flash_byte_ptr];
         sdram_req  <= 1'b1;
         sdram_wait <= 7'd3;  // 3 clk21m cycles: safe margin for write completion
         state      <= STATE_FLASH_WR_WAIT;
      end

      STATE_FLASH_WR_WAIT: begin
         sdram_req <= 1'b0;
         if (sdram_wait > 0) begin
            sdram_wait <= sdram_wait - 1'd1;
         end else begin
            flash_byte_ptr <= flash_byte_ptr + 1'd1;
            if (flash_byte_ptr == 9'd511) begin
               flash_sector <= flash_sector + 1'd1;
               if (flash_sector + 1'd1 < flash_total_sectors) begin
                  sd_lba[0] <= {16'd0, flash_sector + 1'd1};
                  sd_rd[0]  <= 1'b1;
                  state     <= STATE_FLASH_SD_RD;
               end else begin
                  done  <= 1'b1;
                  state <= STATE_SLEEP;
               end
            end else begin
               state <= STATE_FLASH_SDRAM_WR;
            end
         end
      end

      default: ;
   endcase

   last_ack <= sd_ack[v];
end

endmodule
