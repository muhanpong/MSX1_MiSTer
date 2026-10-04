module nvram_backup
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
   // SD config
   input                [3:0] img_mounted,
   input                      img_readonly,
   input               [63:0] img_size,
   // SD block level access
   output              [31:0] sd_lba[4],
   output logic         [3:0] sd_rd = 4'd0,
   output logic         [3:0] sd_wr = 4'd0,
   input                [3:0] sd_ack,
   input               [13:0] sd_buff_addr,
   input                [7:0] sd_buff_dout,
   output               [7:0] sd_buff_din[4],
   // BRAM access
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

logic [63:0] image_size[4], new_size;
logic  [3:0] image_mounted;
logic  [3:0] image_ro = 4'b0;
logic        store_new_size = 1'b0;

always @(posedge clk) begin
   //  Read-only is a reason not to WRITE the image, not a reason to refuse to
   //  read it.  Folding it into image_mounted made a read-only .sav skip its
   //  auto-load silently, which looks exactly like the .sav not being there.
   if (img_mounted[0]) begin image_mounted[0] <= 1'b1; image_ro[0] <= img_readonly; image_size[0] <= img_size; end //ROM
   if (img_mounted[1]) begin image_mounted[1] <= 1'b1; image_ro[1] <= img_readonly; image_size[1] <= img_size; end //Extension A
   if (img_mounted[2]) begin image_mounted[2] <= 1'b1; image_ro[2] <= img_readonly; image_size[2] <= img_size; end //Extension B
   if (img_mounted[3]) begin image_mounted[3] <= 1'b1; image_ro[3] <= img_readonly; image_size[3] <= img_size; end //Computer CMOS
   //  size is in kB, so bytes is << 10.  It was << 13, which is eight times too
   //  large; harmless only because image_size is compared against zero and never
   //  used as a length.  Fixed here rather than left for whoever does use it.
   if (store_new_size) image_size[num] <= (64'(lookup_SRAM[num].size)) << 10;
end

//  Which banks could be served right now -- the same conditions STATE_SLEEP checks
//  below, as vectors, so the request block can choose before it commits.
logic [3:0] can_load, can_save;
always_comb begin
   for (int n = 0; n < 4; n++) begin
      can_save[n] = (lookup_SRAM[n].size != 16'h00) & image_mounted[n] & ~image_ro[n];
      can_load[n] = (lookup_SRAM[n].size != 16'h00) & image_mounted[n] & ((n != 0) | (image_size[n] != 64'd0));
   end
end

logic [3:0] request_load = 4'b0, request_save = 4'b0;
logic [1:0] num          = 2'd0;
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
   logic [3:0] rl, rs;
   rl = request_load;
   rs = request_save;

   //  Completion clears the bank it served; an arriving request sets all four.
   //  Doing both on the same edge used to lose one bank, because the bit write
   //  came after the vector write and won.  Setting last means a request is
   //  never lost -- at worst a bank is served twice, which is harmless.
   if (done) begin
      if (wr) rs[num] = 1'b0;
      if (rd) rl[num] = 1'b0;
   end
   if (~last_load_req & load_req) rl = 4'b1111;
   if (~last_save_req & save_req) rs = 4'b1111;
   //  A newly mounted image is read.  The firmware mounts an image without asking
   //  the core (core start for boot<n>.vhd, every ROM load for VD0's .sav, an OSD
   //  pick for an S entry), and until now only load_req ever read one -- so an
   //  image picked mid-session was never read, and the next save wrote the BRAM's
   //  old contents into it.
   rl = rl | img_mounted;
   //  While memory_upload rebuilds the layout the BRAM is being refilled; a save
   //  taken now would write that into the image.  Requests that arrive during it
   //  are dropped; a save asked for BEFORE it started has already run, because
   //  save_guard (guard, below) holds the upload until it has.
   if (upload_busy) rs = 4'b0;
   request_load <= rl;
   request_save <= rs;

   last_load_req <= load_req;
   last_save_req <= save_req;

   //  Age only while something is pending and nothing is in flight.
   if ((rl | rs) == 4'b0 | done)  pend_age <= '0;
   else if (~pend_expired)        pend_age <= pend_age + 1'b1;
   if (pend_expired) begin
      request_load <= 4'b0;
      request_save <= 4'b0;
   end

   if (reset) begin
      wr             <= 1'b0;
      rd             <= 1'b0;
      num            <= 2'd0;
   end else begin
      if (done | unserved) begin
         wr <= 1'b0;
         rd <= 1'b0;
         //  Keeping the request pending is only half of it: the scan has to move
         //  on as well, or it re-offers the same unserviceable bank forever and
         //  never reaches the one that IS ready.  That livelock is the reported
         //  symptom again, so the round-robin advances here and the pending bank
         //  is retried on the next pass.
         if (unserved) num <= (num == 2'd3) ? 2'd0 : num + 2'd1;
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
            if (num == 3) num <= 0;
            else num <= num + 2'b1;
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
   STATE_HDR_RD,           // VD1..3: read the entry header sector (load: verify; save: fetch the counter)
   STATE_HDR_WR            // VD1..3: write the entry header sector, then the data
} state_t;

logic [20:0] block_count;
logic [31:0] lba_start;
logic        done = 1'b0;

//  ---------------------------------------------------------------- image layout
//  VD0 is the slot A ROM's companion .sav: raw SRAM from LBA 0, as it always was.
//  VD1..VD3 are the firmware's boot1..3.vhd (auto-mounted at core start) and hold
//  one 64 kB entry per DEVICE KIND, so an FM-PAC and a GameMaster2 that both land
//  on VD1, or an FS-A1ST (16 kB) and an FS-A1GT (32 kB) that both land on VD3, do
//  not overwrite each other.  Entry n: header sector at LBA 128n (4 kB reserved,
//  one sector used), data from LBA 128n + 8, up to 60 kB.  docs/sram_images.md.
//  A load is skipped -- not retried -- when the header does not match this bank's
//  kind and size; a save always rewrites the header, so a zero-filled file works
//  from the first save.
localparam [7:0] HDR_VER = 8'd1;
function automatic logic [31:0] entry_of(input logic [7:0] kind);
   case (kind)
      MSX::SRAM_KIND_GM2:   entry_of = 32'd1;   // VD1: FM-PAC 0, GM2 1
      MSX::SRAM_KIND_PAN16: entry_of = 32'd1;   // VD3: Halnote 0, ST 1, GT 2
      MSX::SRAM_KIND_PAN32: entry_of = 32'd2;
      default:              entry_of = 32'd0;
   endcase
endfunction
wire        layout    = (num != 2'd0);
wire [31:0] lba_base  = entry_of(lookup_SRAM[num].kind) << 7;   // * 128 sectors
wire [31:0] data_base = layout ? lba_base + 32'd8 : 32'd0;
logic [20:0] sec = 21'd0;                                        // sector within the data area
logic  [7:0] hdr[16];                                            // header bytes read back
logic [31:0] hdr_cnt = 32'd0;                                    // save counter to write
wire         hdr_ok  = hdr[0] == "M" && hdr[1] == "S" && hdr[2] == "X" && hdr[3] == "1" &&
                       hdr[4] == "S" && hdr[5] == "R" && hdr[6] == "A" && hdr[7] == "M" &&
                       hdr[8] == HDR_VER && hdr[9] == lookup_SRAM[num].kind &&
                       {hdr[11], hdr[10]} == lookup_SRAM[num].size;
function automatic logic [7:0] hdr_byte(input logic [8:0] i);
   case (i)
      9'd0: hdr_byte = "M"; 9'd1: hdr_byte = "S"; 9'd2: hdr_byte = "X"; 9'd3: hdr_byte = "1";
      9'd4: hdr_byte = "S"; 9'd5: hdr_byte = "R"; 9'd6: hdr_byte = "A"; 9'd7: hdr_byte = "M";
      9'd8:  hdr_byte = HDR_VER;
      9'd9:  hdr_byte = lookup_SRAM[num].kind;
      9'd10: hdr_byte = lookup_SRAM[num].size[7:0];
      9'd11: hdr_byte = lookup_SRAM[num].size[15:8];
      9'd12: hdr_byte = hdr_cnt[7:0];
      9'd13: hdr_byte = hdr_cnt[15:8];
      9'd14: hdr_byte = hdr_cnt[23:16];
      9'd15: hdr_byte = hdr_cnt[31:24];
      default: hdr_byte = 8'h00;
   endcase
endfunction
//  bytes the image must hold for this bank: data end, in bytes
wire [63:0] need_bytes = 64'(data_base + 32'(lookup_SRAM[num].size) * 2) << 9;
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
assign ram_we         = rd & sd_ack[num] & ~sd_buff_addr[9] & (state == STATE_PROCESS);
assign ram_addr       = lookup_SRAM[num].addr + 18'({sec, sd_buff_addr[8:0]});
assign sd_buff_din[0] = (state == STATE_FLASH_SD_WR) ? sector_buf[sd_buff_addr[8:0]] : ram_dout;
assign sd_buff_din[1] = (state == STATE_HDR_WR) ? hdr_byte(sd_buff_addr[8:0]) : ram_dout;
assign sd_buff_din[2] = (state == STATE_HDR_WR) ? hdr_byte(sd_buff_addr[8:0]) : ram_dout;
assign sd_buff_din[3] = (state == STATE_HDR_WR) ? hdr_byte(sd_buff_addr[8:0]) : ram_dout;

logic last_ack = 1'b0;
state_t state = STATE_SLEEP;

// Hold CPU for the ENTIRE flash save/load operation (avoid rapid WAIT_n toggling)
// wr/rd is which way the CURRENT slot is moving; the overlay shows a save icon
// only for saves, so a boot-time .sav auto-LOAD does not flash it (2026-09-09).
assign dma_save   = dma_active & wr;
assign guard      = (state != STATE_SLEEP) | wr | rd | |(request_save & can_save);
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
      sd_rd     <= 4'b0;
      sd_wr     <= 4'b0;
      sdram_req <= 1'b0;
   end else
   case (state)
      // -----------------------------------------------------------------------
      STATE_SLEEP: begin
         if ((rd | wr) & ~done & ~unserved) begin
            // ASCII16X flash save DISABLED: SDRAM ch1 DMA corrupts SDRAM controller
            // after sustained read traffic. Requires future Flash FSM + BRAM mirror.
            if (1'b0 & num == 2'd0 & flash16x_active & image_mounted[0]
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
            end else if (~layout & lookup_SRAM[num].size > 16'h00 & image_mounted[num]
                         & (wr ? ~image_ro[num] : (image_size[num] > 0))) begin
               // VD0: raw SRAM from LBA 0
               sec         <= 21'd0;
               sd_lba[num] <= 0;
               block_count <= 21'(lookup_SRAM[num].size) << 1;
               sd_wr[num]  <= wr;
               sd_rd[num]  <= rd;
               state       <= STATE_PROCESS;
               $display("START %d", num);
            end else if (layout & lookup_SRAM[num].size > 16'h00 & image_mounted[num]
                         & (wr ? ~image_ro[num] : 1'b1)) begin
               // VD1..3: an entry per kind.  Too small a file cannot be grown by
               // the core (the firmware only creates VD0's .sav), so that is a
               // skip with a message, not a pending request.
               if (image_size[num] < need_bytes) begin
                  $display("SRAM image %0d too small: %0d < %0d bytes (kind %0d, entry %0d)",
                           num, image_size[num], need_bytes, lookup_SRAM[num].kind, lba_base >> 7);
                  done <= 1'b1;
               end else begin
                  block_count <= 21'(lookup_SRAM[num].size) << 1;
                  sd_lba[num] <= lba_base;
                  sd_rd[num]  <= 1'b1;             // load and save both read the header first
                  state       <= STATE_HDR_RD;
                  $display("START %0d kind %0d entry %0d (%s)", num, lookup_SRAM[num].kind, lba_base >> 7, wr ? "save" : "load");
               end
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
         if (~sd_ack[num] & last_ack) begin
            if (sec < (block_count - 21'd1)) begin
               sec         <= sec + 1'b1;
               sd_lba[num] <= data_base + 32'(sec) + 32'd1;
            end else begin
               sd_wr[num]     <= 1'b0;
               sd_rd[num]     <= 1'b0;
               done           <= 1'b1;
               store_new_size <= wr & ~layout;   // VD0's image is exactly the SRAM
               state          <= STATE_SLEEP;
            end
         end
      end

      // -----------------------------------------------------------------------
      // VD1..3 entry header.  Read first in both directions: a load needs it to
      // match, a save needs the counter it carries.
      STATE_HDR_RD: begin
         if (sd_ack[num] & ~sd_buff_addr[9] & sd_buff_addr[8:4] == 5'd0)
            hdr[sd_buff_addr[3:0]] <= sd_buff_dout;
         if (~sd_ack[num] & last_ack) begin
            sd_rd[num] <= 1'b0;
            if (wr) begin
               hdr_cnt     <= hdr_ok ? {hdr[15], hdr[14], hdr[13], hdr[12]} + 32'd1 : 32'd1;
               sd_lba[num] <= lba_base;
               sd_wr[num]  <= 1'b1;
               state       <= STATE_HDR_WR;
            end else if (hdr_ok) begin
               sec         <= 21'd0;
               sd_lba[num] <= data_base;
               sd_rd[num]  <= 1'b1;
               state       <= STATE_PROCESS;
            end else begin
               $display("SRAM image %0d entry %0d: no matching header (kind %0d size %0d kB) -- not loaded",
                        num, lba_base >> 7, lookup_SRAM[num].kind, lookup_SRAM[num].size);
               done  <= 1'b1;
               state <= STATE_SLEEP;
            end
         end
      end

      STATE_HDR_WR: begin
         if (~sd_ack[num] & last_ack) begin
            sec         <= 21'd0;
            sd_lba[num] <= data_base;
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

   last_ack <= sd_ack[num];
end

endmodule
