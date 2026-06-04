module nvram_backup
(
   input                      clk,
   input                      reset,
   input MSX::lookup_SRAM_t   lookup_SRAM[4],
   input                      load_req,
   input                      save_req,
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
   output                     dma_active
);

logic [63:0] image_size[4], new_size;
logic  [3:0] image_mounted;
logic        store_new_size = 1'b0;

always @(posedge clk) begin
   if (img_mounted[0]) begin image_mounted[0] <= ~img_readonly; image_size[0] <= img_size; end //ROM
   if (img_mounted[1]) begin image_mounted[1] <= ~img_readonly; image_size[1] <= img_size; end //Extension A
   if (img_mounted[2]) begin image_mounted[2] <= ~img_readonly; image_size[2] <= img_size; end //Extension B
   if (img_mounted[3]) begin image_mounted[3] <= ~img_readonly; image_size[3] <= img_size; end //Computer CMOS
   if (store_new_size) image_size[num] <= (64'(lookup_SRAM[num].size)) << 13;
end

logic [3:0] request_load = 4'b0, request_save = 4'b0;
logic [1:0] num          = 2'd0;
logic       wr           = 1'b0, rd = 1'b0;

logic last_load_req = 1'b0;
logic last_save_req = 1'b0;
always @(posedge clk) begin
   if (reset) begin
      request_load   <= 4'b0;
      request_save   <= 4'b0;
      wr             <= 1'b0;
      rd             <= 1'b0;
      num            <= 2'd0;
      last_load_req  <= 1'b0;
      last_save_req  <= 1'b0;
   end else begin
      if (~last_load_req & load_req) request_load <= 4'b1111;
      if (~last_save_req & save_req) request_save <= 4'b1111;
      if (done) begin
         wr <= 1'b0;
         rd <= 1'b0;
         if (wr) request_save[num] <= 1'b0;
         if (rd) request_load[num] <= 1'b0;
      end
      if (~wr & ~rd) begin
         if (request_save[num]) begin
            wr <= 1'b1;
         end else if (request_load[num]) begin
            rd <= 1'b1;
         end else begin
            if (num == 3) num <= 0;
            else num <= num + 2'b1;
         end
      end
      last_load_req <= load_req;
      last_save_req <= save_req;
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
   STATE_NEXT
} state_t;

logic [20:0] block_count;
logic [31:0] lba_start;
logic        done = 1'b0;

// Flash DMA state
logic  [8:0] flash_byte_ptr;
logic [15:0] flash_sector;
logic [15:0] flash_total_sectors;
logic  [7:0] sector_buf[512];
logic  [6:0] sdram_wait;
logic [26:0] sd_wr_timeout;

assign ram_we         = rd & sd_ack[num] & ~sd_buff_addr[9];
assign ram_addr       = lookup_SRAM[num].addr + 18'({sd_lba[num],sd_buff_addr[8:0]});
assign sd_buff_din[0] = (state == STATE_FLASH_SD_WR) ? sector_buf[sd_buff_addr[8:0]] : ram_dout;
assign sd_buff_din[1] = ram_dout;
assign sd_buff_din[2] = ram_dout;
assign sd_buff_din[3] = ram_dout;

logic last_ack = 1'b0;
state_t state = STATE_SLEEP;

// Hold CPU for the ENTIRE flash save/load operation (avoid rapid WAIT_n toggling)
assign dma_active = (state == STATE_FLASH_PREFETCH)
                  | (state == STATE_FLASH_RD_WAIT)
                  | (state == STATE_FLASH_SD_WR)
                  | (state == STATE_FLASH_SD_RD)
                  | (state == STATE_FLASH_SDRAM_WR)
                  | (state == STATE_FLASH_WR_WAIT);

always @(posedge clk) begin
   done           <= 1'b0;
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
         if ((rd | wr) & ~done) begin
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
            end else if (lookup_SRAM[num].size > 16'h00 & image_mounted[num]
                         & (wr | (rd & (image_size[num] > 0)))) begin
               // Existing BRAM path
               sd_lba[num] <= 0;
               block_count <= 21'(lookup_SRAM[num].size) << 1;
               sd_wr[num]  <= wr;
               sd_rd[num]  <= rd;
               state       <= STATE_PROCESS;
               $display("START %d", num);
            end else begin
               done <= 1'b1;
            end
         end
      end

      // -----------------------------------------------------------------------
      // Existing BRAM save/load
      STATE_PROCESS: begin
         if (~sd_ack[num] & last_ack) begin
            if (sd_lba[num][20:0] < (block_count - 21'd1)) begin
               sd_lba[num] <= sd_lba[num] + 1'b1;
            end else begin
               sd_wr[num]     <= 1'b0;
               sd_rd[num]     <= 1'b0;
               done           <= 1'b1;
               store_new_size <= wr;
               state          <= STATE_SLEEP;
            end
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
