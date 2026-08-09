// =============================================================================
//  flash_dirtysave  --  ASCII16X dirty-block selective persistence
// -----------------------------------------------------------------------------
//  Idea (per design discussion): track WHICH 64KB blocks changed with a cheap
//  flip-flop bitmap (128 bits, 0 M10K), and at SAVE time read the ACTUAL data
//  for those blocks straight from SDRAM (the change-log's per-byte value journal
//  is dropped -> no BRAM blowup, no overflow). Because dirty is tracked at 64KB
//  granularity and the game programs within each block it erases, dumping the
//  whole dirty block captures BOTH the byte-programs AND the erase (0xFF) state.
//
//  Dirty marking: passive snoop on prog_we (the validated ascii16x byte-program).
//    dirty[prog_addr[22:16]] <= 1.  (erase-only blocks w/o any program are not
//    marked; games that erase-then-program -- e.g. Neon Horizon -- are covered.)
//
//  .sav layout (VD0, grow-on-write so written sequentially from lba 0):
//    sector 0  = header: MAGIC("MFX16XDB") + mode + 128-bit dirty bitmap.
//    sectors 1.. = the dirty 64KB blocks (128 sectors each), ascending block idx.
//  LOAD reads the header bitmap, then restores each dirty block to SDRAM at
//  flash16x_base + block*64KB via ch1 WRITES (the proven-safe half). Unknown
//  magic -> ignore (fail-quiet). Loaded blocks are re-marked dirty so a later
//  SAVE still re-emits them (avoids losing earlier blocks on an incremental save).
//
//  SAVE-MERGE (robustness): SAVE must NEVER drop a previously-saved block just
//  because LOAD did not run / the dirty set is incomplete this session. So SAVE
//  first reads the EXISTING .sav header and, for every previously-saved block we
//  did NOT change this session, restores it from the old .sav into SDRAM (blocks
//  we DID change keep their current SDRAM data -- restore is skipped). It then
//  dumps the UNION (old | this-session) from SDRAM to the new .sav. Routing the
//  old data through SDRAM (rather than copying old.sav->new.sav in place) avoids
//  ever reading and overwriting the same file region at once, so reordering a
//  newly-inserted low block ahead of an old high block cannot corrupt the copy.
// =============================================================================
module flash_dirtysave #(
    parameter int RDWAIT = 68            // SDRAM dead-reckon read latency (sim can override)
)
(
    input               clk,            // clk21m
    input               reset,

    input               flash16x_active,
    input        [26:0] flash16x_base,
    input        [15:0] flash16x_size,  // 16KB units (unused for blocks; kept for parity)

    input               prog_we,        // validated ascii16x byte-program strobe
    input        [22:0] prog_addr,      // flash byte address of that program

    input               save_req,       // status[38]
    input               load_req,       // status[39] | load_sram
    input               upload_active,  // ROM staging in progress
    input               log_clear,      // new ROM loaded -> clear dirty

    input               img_mounted,
    input               img_readonly,
    input        [63:0] img_size,

    // SDRAM ch1 (read for SAVE, write for LOAD)
    output reg  [26:0]  sdram_addr,
    output reg          sdram_req,
    output reg          sdram_rnw,      // 1=read, 0=write
    output reg   [7:0]  sdram_din,
    input        [7:0]  sdram_dout,
    output              cl_active,       // owns ch1 + pauses CPU (== dump_active)

    // SD VD0 block interface
    output reg  [31:0]  sd_lba,
    output reg          sd_rd,
    output reg          sd_wr,
    input               sd_ack,
    input       [13:0]  sd_buff_addr,
    output       [7:0]  sd_buff_din,
    input        [7:0]  sd_buff_dout,
    input               sd_buff_wr     // per-byte strobe: sd_buff_dout valid for sd_buff_addr THIS cycle
);

localparam [63:0] MAGIC = 64'h4D_46_58_31_36_58_44_42; // "MFX16XDB" (byte i = MAGIC[8*i+:8])

logic [7:0] sector_buf [512];
assign sd_buff_din = sector_buf[sd_buff_addr[8:0]];

logic [127:0] dirty = '0;     // 1 bit per 64KB block, indexed by addr[22:16]
logic [127:0] ld_bm;
logic [63:0]  hdr_magic;

typedef enum logic [3:0] {
    IDLE, SV_HDR, SV_HDR_WR, SV_SCAN, SV_RD_REQ, SV_RD_WAIT, SV_SD_WR,
    LD_HDR_RD, LD_HDR, LD_SCAN, LD_SD_RD, LD_WR_REQ, LD_WR_WAIT, DONE
} st_t;
st_t st = IDLE;

logic  [7:0] scan;          // 0..128 (bit7 set => scanned all)
logic  [6:0] cur_block;
logic  [6:0] sec_in_block;  // 0..127
logic  [8:0] byte_ptr;
logic  [8:0] bi;            // header fill index
logic  [6:0] sdram_wait;
logic [26:0] sd_to;
logic        save_q, load_q, last_ack, mounted_rw = 1'b0;
logic [63:0] image_size = 64'd0;
logic        pw_q;
// ---- SAVE-MERGE: before overwriting the .sav, fold in any previously-saved
//  blocks that are NOT dirty this session so a partial-dirty SAVE never loses
//  them. Implemented by routing old.sav -> SDRAM (restore the missing blocks,
//  skipping the ones we changed this session) and THEN dumping the UNION from
//  SDRAM to the new .sav. Going via SDRAM (never read+write the same file
//  region at once) avoids in-place overlap corruption. ----
logic        merge_save = 1'b0;  // this LOAD pass is the restore phase of a SAVE
logic [127:0] dsave = '0;        // snapshot of `dirty` at SAVE start (this session's blocks)

assign cl_active = (st != IDLE);

logic load_pending = 1'b0;   // latched LOAD request; executes once all gates are ready
wire pw_rise    = prog_we & ~pw_q;
wire in_bounds  = ({9'd0, prog_addr} < ({16'd0, flash16x_size} << 14));
wire save_start = save_req & ~save_q & flash16x_active & mounted_rw;
// LOAD trigger is latched (load_sram is a 1-cycle pulse at staging-end; gates such as
// ~upload_active / image_size>0 may not all be ready that exact cycle) -> wait for them.
wire load_ready = load_pending & flash16x_active & ~upload_active & (image_size > 0);
wire any_dirty  = |dirty;

always @(posedge clk) begin
    pw_q     <= prog_we;
    save_q   <= save_req;
    load_q   <= load_req;
    last_ack <= sd_ack;
    if (img_mounted) begin mounted_rw <= ~img_readonly; image_size <= img_size; end

    if (reset) begin
        st<=IDLE; sdram_req<=0; sd_rd<=0; sd_wr<=0; dirty<='0; pw_q<=0; load_pending<=0; merge_save<=0;
    end else begin
        // ---- dirty capture (passive snoop, live in IDLE only) ----
        if (log_clear) dirty <= '0;
        else if (st==IDLE & flash16x_active & pw_rise & in_bounds)
            dirty[prog_addr[22:16]] <= 1'b1;

        // ---- latch a LOAD request (load_req pulse); cleared when it starts ----
        if (log_clear)                load_pending <= 1'b0;   // new game: drop stale request
        else if (load_req & ~load_q)  load_pending <= 1'b1;   // capture SRAM Load / load_sram pulse

        case (st)
        IDLE: begin
            sdram_req<=0; sd_rd<=0; sd_wr<=0;
            if (save_start & any_dirty) begin
                // SAVE-MERGE phase 1: read the existing .sav header and restore the
                // previously-saved blocks we did NOT change this session into SDRAM,
                // then fall through to the normal SAVE dump (UNION) -- reuses LD_*.
                merge_save<=1'b1; dsave<=dirty;
                sd_lba<=32'd0; sd_rd<=1'b1; sd_to<='0; st<=LD_HDR_RD;
            end else if (load_ready) begin
                merge_save<=1'b0; load_pending<=1'b0;
                sd_lba<=32'd0; sd_rd<=1'b1; sd_to<='0; st<=LD_HDR_RD;
            end
        end

        // ===== SAVE: header sector 0, then each dirty 64KB block =====
        SV_HDR: begin
            if      (bi < 9'd8)                      sector_buf[bi[8:0]] <= MAGIC[8*bi[2:0] +: 8];
            else if (bi == 9'd8)                     sector_buf[bi[8:0]] <= 8'h02;            // mode = dirty-block
            else if (bi >= 9'd16 && bi <= 9'd31)     sector_buf[bi[8:0]] <= dirty[ 8*(bi-9'd16) +: 8 ];
            else                                     sector_buf[bi[8:0]] <= 8'h00;
            if (bi == 9'd511) begin sd_lba<=32'd0; sd_wr<=1'b1; sd_to<='0; st<=SV_HDR_WR; end
            else bi <= bi + 1'b1;
        end
        SV_HDR_WR: begin
            sd_to <= sd_to + 1'b1;
            if (&sd_to) begin sd_wr<=0; st<=IDLE; end
            else if (~sd_ack & last_ack) begin sd_wr<=0; sd_lba<=32'd1; scan<=8'd0; st<=SV_SCAN; end
        end
        SV_SCAN: begin
            if (scan[7]) st<=DONE;                                  // all 128 scanned
            else if (dirty[scan[6:0]]) begin
                cur_block<=scan[6:0]; sec_in_block<=7'd0; byte_ptr<=9'd0; st<=SV_RD_REQ;
            end else scan<=scan+1'b1;
        end
        SV_RD_REQ: begin
            sdram_addr <= flash16x_base + 27'({cur_block, sec_in_block, byte_ptr});
            sdram_rnw<=1'b1; sdram_req<=1'b1; sdram_wait<=7'(RDWAIT); st<=SV_RD_WAIT;
        end
        SV_RD_WAIT: begin
            sdram_req<=1'b0;
            if (sdram_wait>0) sdram_wait<=sdram_wait-1'b1;
            else begin
                sector_buf[byte_ptr] <= sdram_dout;
                if (byte_ptr==9'd511) begin byte_ptr<=9'd0; sd_wr<=1'b1; sd_to<='0; st<=SV_SD_WR; end
                else begin byte_ptr<=byte_ptr+1'b1; st<=SV_RD_REQ; end
            end
        end
        SV_SD_WR: begin
            sd_to <= sd_to + 1'b1;
            if (&sd_to) begin sd_wr<=0; st<=IDLE; end
            else if (~sd_ack & last_ack) begin
                sd_wr<=0; sd_lba<=sd_lba+1'b1;
                if (sec_in_block==7'd127) begin scan<=scan+1'b1; st<=SV_SCAN; end
                else begin sec_in_block<=sec_in_block+1'b1; byte_ptr<=9'd0; st<=SV_RD_REQ; end
            end
        end

        // ===== LOAD: read header bitmap, restore each dirty block =====
        LD_HDR_RD: begin
            sd_to <= sd_to + 1'b1;
            if (&sd_to) begin sd_rd<=0; st<=IDLE; end
            else begin
                if (sd_buff_wr) begin                 // capture on the per-byte strobe (NOT sd_ack -> off-by-one)
                    if (sd_buff_addr[8:0] < 9'd8)
                        hdr_magic[8*sd_buff_addr[2:0] +: 8] <= sd_buff_dout;
                    else if (sd_buff_addr[8:0] >= 9'd16 && sd_buff_addr[8:0] <= 9'd31)
                        ld_bm[ 8*(sd_buff_addr[8:0]-9'd16) +: 8 ] <= sd_buff_dout;
                end
                if (~sd_ack & last_ack) begin sd_rd<=0; st<=LD_HDR; end
            end
        end
        LD_HDR: begin
            if (hdr_magic==MAGIC) begin
                dirty <= dirty | ld_bm;                 // UNION: keep previously-saved blocks (re-emitted on SAVE)
                sd_lba<=32'd1; scan<=8'd0; st<=LD_SCAN;
            end else if (merge_save) begin
                bi<=0; st<=SV_HDR;                      // no valid old .sav -> just save this session's dirty
            end else st<=IDLE;
        end
        LD_SCAN: begin
            if (scan[7]) begin
                if (merge_save) begin bi<=0; st<=SV_HDR; end  // restore done -> dump UNION from SDRAM
                else st<=DONE;
            end else if (ld_bm[scan[6:0]]) begin
                if (merge_save & dsave[scan[6:0]]) begin
                    // block changed THIS session: skip restore (keep current SDRAM data),
                    // but still consume its 128 sectors in the old .sav layout.
                    sd_lba<=sd_lba+32'd128; scan<=scan+1'b1;
                end else begin
                    cur_block<=scan[6:0]; sec_in_block<=7'd0; sd_rd<=1'b1; sd_to<='0; st<=LD_SD_RD;
                end
            end else scan<=scan+1'b1;
        end
        LD_SD_RD: begin
            sd_to <= sd_to + 1'b1;
            if (&sd_to) begin sd_rd<=0; st<=IDLE; end
            else begin
                if (sd_buff_wr) sector_buf[sd_buff_addr[8:0]] <= sd_buff_dout;  // per-byte strobe (aligned)
                if (~sd_ack & last_ack) begin sd_rd<=0; byte_ptr<=9'd0; st<=LD_WR_REQ; end
            end
        end
        LD_WR_REQ: begin
            sdram_addr <= flash16x_base + 27'({cur_block, sec_in_block, byte_ptr});
            sdram_rnw<=1'b0; sdram_din<=sector_buf[byte_ptr]; sdram_req<=1'b1; sdram_wait<=7'd3; st<=LD_WR_WAIT;
        end
        LD_WR_WAIT: begin
            sdram_req<=1'b0;
            if (sdram_wait>0) sdram_wait<=sdram_wait-1'b1;
            else begin
                if (byte_ptr==9'd511) begin
                    sd_lba<=sd_lba+1'b1;
                    if (sec_in_block==7'd127) begin scan<=scan+1'b1; st<=LD_SCAN; end
                    else begin sec_in_block<=sec_in_block+1'b1; byte_ptr<=9'd0; sd_rd<=1'b1; sd_to<='0; st<=LD_SD_RD; end
                end else begin byte_ptr<=byte_ptr+1'b1; st<=LD_WR_REQ; end
            end
        end

        DONE: begin sdram_req<=0; sd_rd<=0; sd_wr<=0; st<=IDLE; end
        default: st<=IDLE;
        endcase
    end
end

endmodule
