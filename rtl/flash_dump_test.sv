// =============================================================================
//  flash_dump_test  --  B: ASCII16X full-image SAVE/RESTORE engine (fulldump)
// -----------------------------------------------------------------------------
//  Round-trip persistence for ASCII16X flash:
//    SAVE (save_req): read the cart ROM region (flash16x_base .. +size) from SDRAM
//                     via ch1 (dead-reckoned, proven) -> VD0 <rom>.sav, sequential.
//    LOAD (load_req): read VD0 <rom>.sav -> write back into SDRAM at flash16x_base
//                     via ch1 WRITES (the proven-safe half; only sustained READS
//                     corrupt). Runs AFTER ROM staging (~upload_active).
//  CPU paused throughout via dump_active. Raw image (no header) — A's change-log
//  loader recognizes a headerless full-size .sav as a legacy fulldump.
//  This engine also serves as the OVERFLOW FALLBACK for the A (change-log) build.
// =============================================================================
module flash_dump_test
(
    input               clk,            // clk21m
    input               reset,

    // cart ROM region in SDRAM (from msx_slots flash16x_*)
    input               flash16x_active,
    input        [26:0] flash16x_base,
    input        [15:0] flash16x_size,  // 16 KB units

    // triggers (OSD SRAM Save / Load) + staging gate
    input               save_req,       // status[38]
    input               load_req,       // status[39] | load_sram
    input               upload_active,   // ROM staging in progress

    // VD0 mount status
    input               img_mounted,
    input               img_readonly,
    input        [63:0] img_size,

    // SDRAM ch1 (read for SAVE, write for LOAD)
    output reg  [26:0]  sdram_addr,
    output reg          sdram_req,
    output reg          sdram_rnw,      // 1=read (save), 0=write (load)
    output reg   [7:0]  sdram_din,      // write data (load)
    input        [7:0]  sdram_dout,     // read data (save)
    output              dump_active,    // owns ch1 + pauses CPU

    // SD VD0 block interface
    output reg  [31:0]  sd_lba,
    output reg          sd_rd,
    output reg          sd_wr,
    input               sd_ack,
    input       [13:0]  sd_buff_addr,
    output       [7:0]  sd_buff_din,    // SAVE: BRAM -> SD
    input        [7:0]  sd_buff_dout    // LOAD: SD -> BRAM
);

logic [7:0] sector_buf [512];
assign sd_buff_din = sector_buf[sd_buff_addr[8:0]];

typedef enum logic [2:0] {
    IDLE,
    S_RD_REQ, S_RD_WAIT, S_SD_WR,       // SAVE: SDRAM read -> buf -> SD
    L_SD_RD,  L_WR_REQ,  L_WR_WAIT      // LOAD: SD -> buf -> SDRAM write
} state_t;
state_t state = IDLE;

logic [15:0] total_sectors;             // flash16x_size << 5
logic [15:0] sector;
logic  [8:0] byte_ptr;
logic  [6:0] sdram_wait;
logic [26:0] sd_wr_timeout;
logic        save_q, load_q, last_ack, mounted_rw = 1'b0;
logic [63:0] image_size = 64'd0;

assign dump_active = (state != IDLE);

wire save_start = save_req & ~save_q & flash16x_active & mounted_rw;                 // writable mount needed
wire load_start = load_req & ~load_q & flash16x_active & ~upload_active & (image_size > 0);

always @(posedge clk) begin
    save_q   <= save_req;
    load_q   <= load_req;
    last_ack <= sd_ack;
    if (img_mounted) begin mounted_rw <= ~img_readonly; image_size <= img_size; end

    if (reset) begin
        state <= IDLE; sdram_req <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0;
    end else case (state)
        IDLE: begin
            sdram_req <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0;
            total_sectors <= 16'(flash16x_size) << 5;        // 16KB/512 = 32 sectors per unit
            sector <= 16'd0; byte_ptr <= 9'd0;
            if (save_start)      state <= S_RD_REQ;
            else if (load_start) begin sd_lba <= 32'd0; sd_rd <= 1'b1; state <= L_SD_RD; end
        end

        // ---------- SAVE: SDRAM(ch1 read) -> sector_buf -> SD(VD0) ----------
        S_RD_REQ: begin
            sdram_addr <= flash16x_base + 27'({sector, byte_ptr});
            sdram_rnw  <= 1'b1;
            sdram_req  <= 1'b1;
            sdram_wait <= 7'd68;                              // dead-reckoned read (proven)
            state      <= S_RD_WAIT;
        end
        S_RD_WAIT: begin
            sdram_req <= 1'b0;
            if (sdram_wait > 0) sdram_wait <= sdram_wait - 1'd1;
            else begin
                sector_buf[byte_ptr] <= sdram_dout;
                if (byte_ptr == 9'd511) begin
                    byte_ptr <= 9'd0; sd_lba <= 32'(sector); sd_wr <= 1'b1;
                    sd_wr_timeout <= '0; state <= S_SD_WR;
                end else begin byte_ptr <= byte_ptr + 1'd1; state <= S_RD_REQ; end
            end
        end
        S_SD_WR: begin
            sd_wr_timeout <= sd_wr_timeout + 1'd1;
            if (&sd_wr_timeout) begin sd_wr <= 1'b0; state <= IDLE; end   // ARM no-ack abort
            else if (~sd_ack & last_ack) begin
                sd_wr <= 1'b0;
                if (sector == total_sectors - 1) state <= IDLE;
                else begin sector <= sector + 1'd1; byte_ptr <= 9'd0; state <= S_RD_REQ; end
            end
        end

        // ---------- LOAD: SD(VD0) -> sector_buf -> SDRAM(ch1 write) ----------
        L_SD_RD: begin
            sd_wr_timeout <= sd_wr_timeout + 1'd1;
            if (&sd_wr_timeout) begin sd_rd <= 1'b0; state <= IDLE; end
            else begin
                if (sd_ack) sector_buf[sd_buff_addr[8:0]] <= sd_buff_dout;
                if (~sd_ack & last_ack) begin sd_rd <= 1'b0; byte_ptr <= 9'd0; state <= L_WR_REQ; end
            end
        end
        L_WR_REQ: begin
            sdram_addr <= flash16x_base + 27'({sector, byte_ptr});
            sdram_rnw  <= 1'b0;                               // write
            sdram_din  <= sector_buf[byte_ptr];
            sdram_req  <= 1'b1;
            sdram_wait <= 7'd3;                               // write completes fast (proven idiom)
            state      <= L_WR_WAIT;
        end
        L_WR_WAIT: begin
            sdram_req <= 1'b0;
            if (sdram_wait > 0) sdram_wait <= sdram_wait - 1'd1;
            else begin
                if (byte_ptr == 9'd511) begin
                    if (sector == total_sectors - 1) state <= IDLE;
                    else begin
                        sector <= sector + 1'd1; byte_ptr <= 9'd0;
                        sd_lba <= 32'(sector + 1'd1); sd_rd <= 1'b1;
                        sd_wr_timeout <= '0; state <= L_SD_RD;
                    end
                end else begin byte_ptr <= byte_ptr + 1'd1; state <= L_WR_REQ; end
            end
        end

        default: state <= IDLE;
    endcase
end

endmodule
