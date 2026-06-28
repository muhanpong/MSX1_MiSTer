// =============================================================================
//  flash_changelog  --  A: ASCII16X CHANGE-LOG persistence (primary path)
// -----------------------------------------------------------------------------
//  Capture each validated JEDEC byte-program (addr,data) into a linear journal
//  BRAM at WRITE TIME (passive snoop on prog_we -> NO SDRAM/DQ touch). SAVE writes
//  a tiny <rom>.sav: header sector 0 (magic+mode+count+sum) FIRST, then packed
//  4-byte records. LOAD reads header, re-reads records into the journal, verifies
//  the running sum, and (if ok) REPLAYS each record as a single ch1 WRITE onto the
//  staged pristine ROM at flash16x_base+addr. CPU paused via cl_active.
//
//  header-FIRST: VD0 .sav is grow-on-write (lba<=size) so writes must be
//  sequential from lba 0. Torn writes caught by sum mismatch on load -> ignore.
//  Overflow / out-of-bounds = FAIL-LOUD (cl_overflow sticky, SAVE refuses) -> no
//  silent loss. (Full-dump fallback = separate build B.)
//  entry[31:0] = {type[31], addr[30:8]=addr[22:0], data[7:0]}
// =============================================================================
module flash_changelog #(
    parameter int JDEPTH = 8192
)
(
    input               clk,
    input               reset,

    input               flash16x_active,
    input        [26:0]  flash16x_base,
    input        [15:0]  flash16x_size,

    input               prog_we,
    input        [22:0]  prog_addr,
    input         [7:0]  prog_data,

    input               save_req,
    input               load_req,
    input               upload_active,
    input               log_clear,

    input               img_mounted,
    input               img_readonly,
    input        [63:0]  img_size,

    output reg  [26:0]  sdram_addr,
    output reg          sdram_req,
    output reg          sdram_rnw,
    output reg   [7:0]  sdram_din,
    output              cl_active,

    output reg  [31:0]  sd_lba,
    output reg          sd_rd,
    output reg          sd_wr,
    input               sd_ack,
    input       [13:0]  sd_buff_addr,
    output       [7:0]  sd_buff_din,
    input        [7:0]  sd_buff_dout,

    output reg          cl_overflow
);

localparam [63:0] MAGIC = 64'h4D_46_58_31_36_58_53_56;   // "MFX16XSV"

(* ramstyle = "M10K" *) logic [31:0] jrnl [JDEPTH];
logic [13:0] wp = 14'd0;
logic [31:0] run_sum = 32'd0;
logic [31:0] jq;
wire  [31:0] e = jq;

logic [7:0] sector_buf [512];
logic [8:0] sb_wa;  logic [7:0] sb_wd;  logic sb_we;
assign sd_buff_din = sector_buf[sd_buff_addr[8:0]];

logic pw_q;
wire  pw_rise   = prog_we & ~pw_q;
wire  in_bounds = ({9'd0, prog_addr} < ({16'd0, flash16x_size} << 14));
wire [31:0] cap_entry = {1'b0, prog_addr, prog_data};

// single write port for jrnl (so it infers as M10K, not registers)
wire [31:0] re;                          // (defined below)
wire        capture_now;                 // (defined below)
wire        j_we;  wire [13:0] j_wa;  wire [31:0] j_wd;

typedef enum logic [3:0] {
    IDLE, SV_HDR, SV_HDR_WR, SV_RLOAD, SV_RWRITE, SV_PL_WR,
    LD_HDR_RD, LD_HDR, LD_PL_RD, LD_PL_STORE, LD_VERIFY, LD_REP_RD, LD_REP_WR, DONE
} st_t;
st_t st = IDLE;

logic [13:0] rec_idx;
logic  [6:0] ri;            // record-in-sector 0..127
logic  [1:0] bp;            // byte phase 0..3
logic [15:0] sec;
logic  [8:0] bi;            // header fill byte
logic [13:0] ld_count;
logic [31:0] ld_sum, ld_expsum;
logic  [6:0] sdram_wait;
logic [26:0] sd_to;
logic        save_q, load_q, last_ack, mounted_rw = 1'b0;
logic [63:0] image_size = 64'd0;
logic [63:0] hdr_magic;

assign cl_active = (st != IDLE);
wire save_start = save_req & ~save_q & flash16x_active & mounted_rw;
wire load_start = load_req & ~load_q & flash16x_active & ~upload_active & (image_size > 0);

// combinational reassembly of a record from sector_buf (LOAD)
assign re = { sector_buf[{ri,2'd3}], sector_buf[{ri,2'd2}],
              sector_buf[{ri,2'd1}], sector_buf[{ri,2'd0}] };
assign capture_now = (st==IDLE) & flash16x_active & pw_rise & ~log_clear & in_bounds & (wp != JDEPTH[13:0]);
assign j_we = capture_now | (st==LD_PL_STORE);
assign j_wa = (st==LD_PL_STORE) ? rec_idx : wp;
assign j_wd = (st==LD_PL_STORE) ? re : cap_entry;

always @(posedge clk) begin
    jq <= jrnl[rec_idx];                 // single read port
    if (j_we) jrnl[j_wa] <= j_wd;        // single write port -> infers M10K
    if (sb_we) sector_buf[sb_wa] <= sb_wd;
    sb_we <= 1'b0;

    pw_q     <= prog_we;
    save_q   <= save_req;
    load_q   <= load_req;
    last_ack <= sd_ack;
    if (img_mounted) begin mounted_rw <= ~img_readonly; image_size <= img_size; end

    if (reset) begin
        st<=IDLE; sdram_req<=0; sd_rd<=0; sd_wr<=0; wp<=0; run_sum<=0; cl_overflow<=0; pw_q<=0;
    end else begin
        // ---- capture (live in IDLE only) ----
        if (log_clear) begin wp<=0; run_sum<=0; cl_overflow<=0; end
        else if (st==IDLE & flash16x_active & pw_rise) begin
            if (~in_bounds | (wp==JDEPTH[13:0])) cl_overflow<=1'b1;
            else begin run_sum<=run_sum+cap_entry; wp<=wp+1'b1; end  // jrnl write via j_we
        end

        case (st)
        IDLE: begin
            sdram_req<=0; sd_rd<=0; sd_wr<=0;
            if (save_start) begin
                if (~(cl_overflow | wp==0)) begin sd_lba<=32'd0; bi<=0; st<=SV_HDR; end
            end else if (load_start) begin
                sd_lba<=32'd0; sd_rd<=1'b1; sd_to<='0; st<=LD_HDR_RD;
            end
        end

        // ===== SAVE header (sector 0) =====
        SV_HDR: begin
            sb_we<=1'b1; sb_wa<=bi;
            case (bi)
              0:sb_wd<=MAGIC[7:0];   1:sb_wd<=MAGIC[15:8];  2:sb_wd<=MAGIC[23:16]; 3:sb_wd<=MAGIC[31:24];
              4:sb_wd<=MAGIC[39:32]; 5:sb_wd<=MAGIC[47:40]; 6:sb_wd<=MAGIC[55:48]; 7:sb_wd<=MAGIC[63:56];
              8:sb_wd<=8'h00;
              9:sb_wd<=wp[7:0]; 10:sb_wd<={2'b0,wp[13:8]}; 11:sb_wd<=8'h00; 12:sb_wd<=8'h00;
              13:sb_wd<=run_sum[7:0]; 14:sb_wd<=run_sum[15:8]; 15:sb_wd<=run_sum[23:16]; 16:sb_wd<=run_sum[31:24];
              default: sb_wd<=8'h00;
            endcase
            if (bi==9'd511) begin bi<=0; sd_lba<=32'd0; sd_wr<=1'b1; sd_to<='0; st<=SV_HDR_WR; end
            else bi<=bi+1'b1;
        end
        SV_HDR_WR: begin
            sd_to<=sd_to+1'b1;
            if (&sd_to) begin sd_wr<=0; st<=IDLE; end
            else if (~sd_ack & last_ack) begin
                sd_wr<=0; rec_idx<=0; ri<=0; sec<=16'd1; st<=SV_RLOAD;
            end
        end
        // per-record: 1-cyc load (jq settles), then 4-byte write
        SV_RLOAD: begin bp<=2'd0; st<=SV_RWRITE; end
        SV_RWRITE: begin
            sb_we<=1'b1; sb_wa<={ri,bp};
            case (bp) 2'd0:sb_wd<=e[7:0]; 2'd1:sb_wd<=e[15:8]; 2'd2:sb_wd<=e[23:16]; 2'd3:sb_wd<=e[31:24]; endcase
            if (bp==2'd3) begin
                rec_idx<=rec_idx+1'b1;
                if (rec_idx==wp-1)      begin sd_lba<=32'(sec); sd_wr<=1'b1; sd_to<='0; st<=SV_PL_WR; end
                else if (ri==7'd127)    begin sd_lba<=32'(sec); sd_wr<=1'b1; sd_to<='0; st<=SV_PL_WR; end
                else                    begin ri<=ri+1'b1;      st<=SV_RLOAD; end
            end else bp<=bp+1'b1;
        end
        SV_PL_WR: begin
            sd_to<=sd_to+1'b1;
            if (&sd_to) begin sd_wr<=0; st<=IDLE; end
            else if (~sd_ack & last_ack) begin
                sd_wr<=0;
                if (rec_idx>=wp) st<=DONE;
                else begin sec<=sec+1'b1; ri<=0; st<=SV_RLOAD; end
            end
        end

        // ===== LOAD =====
        LD_HDR_RD: begin
            sd_to<=sd_to+1'b1;
            if (&sd_to) begin sd_rd<=0; st<=IDLE; end
            else begin
                if (sd_ack) case (sd_buff_addr[8:0])
                  0:hdr_magic[7:0]<=sd_buff_dout;   1:hdr_magic[15:8]<=sd_buff_dout;
                  2:hdr_magic[23:16]<=sd_buff_dout; 3:hdr_magic[31:24]<=sd_buff_dout;
                  4:hdr_magic[39:32]<=sd_buff_dout; 5:hdr_magic[47:40]<=sd_buff_dout;
                  6:hdr_magic[55:48]<=sd_buff_dout; 7:hdr_magic[63:56]<=sd_buff_dout;
                  9:ld_count[7:0]<=sd_buff_dout;    10:ld_count[13:8]<=sd_buff_dout[5:0];
                  13:ld_expsum[7:0]<=sd_buff_dout;  14:ld_expsum[15:8]<=sd_buff_dout;
                  15:ld_expsum[23:16]<=sd_buff_dout;16:ld_expsum[31:24]<=sd_buff_dout;
                  default:;
                endcase
                if (~sd_ack & last_ack) begin sd_rd<=1'b0; st<=LD_HDR; end
            end
        end
        LD_HDR: begin
            if (hdr_magic==MAGIC & ld_count!=0 & ld_count<=JDEPTH) begin
                rec_idx<=0; ri<=0; ld_sum<=0; sec<=16'd1; sd_lba<=32'd1; sd_rd<=1'b1; sd_to<='0; st<=LD_PL_RD;
            end else st<=IDLE;
        end
        LD_PL_RD: begin
            sd_to<=sd_to+1'b1;
            if (&sd_to) begin sd_rd<=0; st<=IDLE; end
            else begin
                if (sd_ack) sector_buf[sd_buff_addr[8:0]]<=sd_buff_dout;
                if (~sd_ack & last_ack) begin sd_rd<=0; ri<=0; st<=LD_PL_STORE; end
            end
        end
        LD_PL_STORE: begin
            ld_sum<=ld_sum+re;            // jrnl[rec_idx]<=re via j_we
            if (rec_idx==ld_count[13:0]-1) st<=LD_VERIFY;
            else if (ri==7'd127) begin sec<=sec+1'b1; sd_lba<=32'(sec+1'b1); sd_rd<=1'b1; sd_to<='0; rec_idx<=rec_idx+1'b1; st<=LD_PL_RD; end
            else begin ri<=ri+1'b1; rec_idx<=rec_idx+1'b1; end
        end
        LD_VERIFY: begin
            if (ld_sum==ld_expsum) begin wp<=ld_count[13:0]; run_sum<=ld_sum; rec_idx<=0; st<=LD_REP_RD; end
            else st<=IDLE;
        end
        LD_REP_RD: begin sdram_wait<=7'd0; st<=LD_REP_WR; end   // jq<=jrnl[rec_idx] settling
        LD_REP_WR: begin
            if (~sdram_req & sdram_wait==0) begin
                sdram_addr<=flash16x_base+27'(e[30:8]); sdram_din<=e[7:0];
                sdram_rnw<=1'b0; sdram_req<=1'b1; sdram_wait<=7'd3;
            end else if (sdram_req) sdram_req<=1'b0;
            else if (sdram_wait>0) begin
                sdram_wait<=sdram_wait-1'b1;
                if (sdram_wait==1) begin
                    if (rec_idx==wp-1) st<=DONE;
                    else begin rec_idx<=rec_idx+1'b1; st<=LD_REP_RD; end
                end
            end
        end

        DONE: begin sdram_req<=0; sd_rd<=0; sd_wr<=0; st<=IDLE; end
        default: st<=IDLE;
        endcase
    end
end

endmodule
