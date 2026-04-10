module transmit #(parameter sysCLK)
(
    input  logic        clk,
    input  logic        reset,
    
    input  logic        drive_motor_rpm,
    input  logic        floppy_bitRate,
    input  logic        floppy_mfm,
    input  logic  [5:0] floppy_sectors,
    input  logic  [1:0] floppy_sectors_size,

    output logic [12:0] buffer_addr,
    input  logic  [7:0] buffer_q,
    input  logic        track_ready,
    input  logic  [6:0] track,
    input  logic        side,
    output logic        INDEXn,
    output logic        READ_DATAn
);
    
    typedef enum { 
        WRITE_DATA,
        WRITE_A1,
        WRITE_C2,
        WRITE_CRC1,
        WRITE_CRC2,
        WAIT
    } write_type_t;

    typedef enum { 
        FDD_GAP4a,
        FDD_SYNC_1,
        FDD_IAM,
        FDD_IAM_2,
        FDD_GAP1,
        FDD_SYNC_2,
        FDD_IDAM,
        FDD_IDAM_2,
        FDD_C,
        FDD_H,
        FDD_R,
        FDD_N,
        FDD_CRC,
        FDD_CRC1,
        FDD_CRC2,
        FDD_GAP2,
        FDD_SYNC_3,
        FDD_DDAM,
        FDD_DDAM_2,
        FDD_DATA,
        FDD_CRC_D,
        FDD_CRC_D1,
        FDD_CRC_D2,
        FDC_GAP3,
        FDD_GAP4b
    } fdd_track_state_t;

    logic [10:0] sector_sz;
    logic [10:0] write_count;
    logic [10:0] buff_pos;
    logic [12:0] track_position;
    logic  [5:0] sector;
    logic  [5:0] next_sector;
    logic  [7:0] txdat;
    logic        crc_calc;
    logic        txwr;
    logic        fm_txmf8;
    logic        fm_txmfb;
    logic        fm_txmfc;
    logic        fm_txmfe;
    logic        mfm_txma1;
    logic        mfm_txmc2;
    
    assign next_sector = sector + 6'd1;
    assign buffer_addr = (sector_sz * sector) + {2'd0,buff_pos};
    assign sector_sz   = 11'd128 << floppy_sectors_size;
    
    assign READ_DATAn  = ~(floppy_mfm ? mfm_bitout : fm_bitout);

    write_type_t write_type;
    fdd_track_state_t fdd_state_next;

    always_ff @(posedge clk) begin
        if (reset) begin
            fdd_state_next <= FDD_GAP4b;
            fdd_state_next <= FDD_GAP4b;
            write_count    <= 0;
            write_type     <= WRITE_DATA;
            INDEXn         <= 1;
            crc_calc       <= 0;
        end else begin
            if (drive_motor_rpm) begin
                fdd_state_next <= FDD_GAP4a;
                write_count    <= floppy_mfm ?  11'd80 : 11'd40;
                txdat          <= floppy_mfm ?  8'h4E : 8'hFF;
                sector         <= 0;
                INDEXn         <= 0;
            end
            if (txemp) begin
                if (write_count > 0) begin
                    write_count <= write_count - 11'd1;
                    case(write_type)
                        WRITE_DATA: txwr      <= 1;
                        WRITE_A1:   mfm_txma1 <= 1;
                        WRITE_C2:   mfm_txmc2 <= 1;
                        WRITE_CRC1: begin  txwr <= 1; txdat <= crc_out[15:8]; end
                        WRITE_CRC2: begin  txwr <= 1; txdat <= crc_out[7:0]; end
                        default:;
                    endcase
                    if (fdd_state_next == FDD_DATA) begin
                        txdat    <= buffer_q;
                        buff_pos <= buff_pos + 11'd1;              
                    end
                end else begin
                    case (fdd_state_next)
                        FDD_GAP4b: begin
                            write_count        <= 1;
                            txdat              <= floppy_mfm ?  8'h4E : 8'hFF;
                        end
                        FDD_GAP4a: begin
                            write_count        <= floppy_mfm ?  11'd12 : 11'd6;
                            txdat              <= 8'd00;
                            fdd_state_next     <= FDD_SYNC_1;
                        end
                        FDD_SYNC_1: begin
                            if (floppy_mfm) begin
                                write_count    <= 3;
                                txdat          <= 8'hC2;
                                write_type     <= WRITE_C2;
                                fdd_state_next <= FDD_IAM;
                            end else begin
                                fm_txmfc       <= 1;
                                INDEXn         <= 1;
                                fdd_state_next <= FDD_IAM_2;
                            end
                        end
                        FDD_IAM: begin
                            write_type     <= WRITE_DATA;
                            write_count    <= 3;
                            txdat          <= 8'hFC;
                            INDEXn         <= 1;
                            fdd_state_next <= FDD_IAM_2;
                        end
                        FDD_IAM_2: begin
                            write_count    <= floppy_mfm ?  11'd50 : 11'd26;
                            txdat          <= floppy_mfm ?  8'h4E : 8'hFF;
                            fdd_state_next <= FDD_GAP1;
                        end
                        FDD_GAP1: begin
                            write_count    <= floppy_mfm ?  11'd12 : 11'd6;
                            txdat          <= 8'd00;
                            fdd_state_next <= FDD_SYNC_2;
                        end

                        FDD_SYNC_2: begin
                            crc_calc           <= 1;
                            if (floppy_mfm) begin
                                write_count    <= 3;
                                txdat          <= 8'hA1;
                                write_type     <= WRITE_A1;
                                fdd_state_next <= FDD_IDAM;
                            end else begin
                                txdat          <= 8'hFE;
                                fm_txmfe       <= 1;
                                fdd_state_next <= FDD_IDAM_2;
                            end
                        end
                        FDD_IDAM: begin
                            write_count    <= 1;
                            write_type     <= WRITE_DATA;
                            txdat          <= 8'hFE;
                            fdd_state_next <= FDD_IDAM_2;
                        end
                        FDD_IDAM_2: begin
                            write_count    <= 1;
                            txdat          <= {8'(track)};
                            fdd_state_next <= FDD_C;
                        end
                        FDD_C: begin
                            write_count    <= 1;
                            txdat          <= {8'(side)};
                            fdd_state_next <= FDD_H;
                        end
                        FDD_H: begin
                            write_count    <= 1;
                            txdat          <= {8'(next_sector)};
                            fdd_state_next <= FDD_R;
                        end
                        FDD_R: begin
                            write_count    <= 1;
                            txdat          <= {8'(floppy_sectors_size)};
                            fdd_state_next <= FDD_N;
                        end
                        FDD_N: begin
                            crc_calc       <= 0;
                            write_count    <= 1;
                            write_type     <= WAIT;
                            fdd_state_next <= FDD_CRC;
                        end
                        FDD_CRC: begin
                            write_count    <= 1;
                            write_type     <= WRITE_CRC1;
                            fdd_state_next <= FDD_CRC1;
                        end
                        FDD_CRC1: begin
                            write_count    <= 1;
                            write_type     <= WRITE_CRC2;
                            fdd_state_next <= FDD_CRC2;
                        end
                        FDD_CRC2: begin
                            write_type     <= WRITE_DATA;
                            write_count    <= floppy_mfm ?  11'd22 : 11'd11;
                            txdat          <= floppy_mfm ?  8'h4E : 8'hFF;
                            fdd_state_next <= FDD_GAP2;
                        end
                        FDD_GAP2: begin
                            write_count    <= floppy_mfm ?  11'd12 : 11'd6;
                            txdat          <= 8'd00;
                            fdd_state_next <= FDD_SYNC_3;
                        end
                        FDD_SYNC_3: begin
                            buff_pos       <= 0;
                            crc_calc       <= 1;
                            if (floppy_mfm) begin
                                write_count    <= 3;
                                txdat          <= 8'hA1;
                                write_type     <= WRITE_A1;
                                fdd_state_next <= FDD_DDAM;
                            end else begin
                                txdat          <= 8'hFB;
                                fm_txmfb       <= 1;          // TODO fm_txmfb nebo fm_txmf8 podle toho zda jsou data delete
                                fdd_state_next <= FDD_DDAM_2;
                            end

                        end
                        FDD_DDAM: begin
                            write_type     <= WRITE_DATA;
                            write_count    <= 1;
                            txdat          <= 8'hFB;         // TODO FB nebo F8 podle toho zda jsou data delete
                            fdd_state_next <= FDD_DDAM_2;
                        end
                        FDD_DDAM_2: begin
                            write_count    <= sector_sz;
                            if (track_ready) begin
                                txdat      <= buffer_q;
                            end else begin
                                txwr       <= 0;
                            end
                            fdd_state_next <= FDD_DATA;
                        end
                        FDD_DATA: begin
                            crc_calc       <= 0;
                            write_count    <= 1;
                            write_type     <= WAIT;
                            fdd_state_next <= FDD_CRC_D;
                        end
                        FDD_CRC_D: begin
                            write_count    <= 1;
                            write_type     <= WRITE_CRC1;
                            fdd_state_next <= FDD_CRC_D1;
                        end
                        FDD_CRC_D1: begin
                            write_count    <= 1;
                            write_type     <= WRITE_CRC2;
                            fdd_state_next <= FDD_CRC_D2;
                        end
                        FDD_CRC_D2: begin
                            write_type     <= WRITE_DATA;
                            write_count    <= floppy_mfm ?  11'd83 : 11'd42;        // TODO ověřit
                            txdat          <= floppy_mfm ?  8'h4E : 8'hFF;
                            fdd_state_next <= FDC_GAP3;
                        end
                        FDC_GAP3: begin
                            if (sector == 8)
                                fdd_state_next <= FDD_GAP4b;
                            else begin
                                fdd_state_next <= FDD_GAP1;
                                sector         <= next_sector;
                            end
                        end
                        default: ;
                    endcase
                end
            end else begin
                if (txwr)      txwr      <= 0;
                if (fm_txmf8)  fm_txmf8  <= 0;
                if (fm_txmfb)  fm_txmfb  <= 0;
                if (fm_txmfc)  fm_txmfc  <= 0;
                if (fm_txmfe)  fm_txmfe  <= 0;
                if (mfm_txma1) mfm_txma1 <= 0;
                if (mfm_txmc2) mfm_txmc2 <= 0;
            end
        end
    end

logic txemp, crcwr;
assign txemp = floppy_mfm ? mfm_txemp : fm_txemp;
assign crcwr = txwr | mfm_txma1 | mfm_txmc2 | fm_txmfb | fm_txmf8 | fm_txmfe;

logic fm_txemp;
logic fm_bitout;
fmmod fmmod(
      .txdat(txdat),
      .txwr(~floppy_mfm & txwr),
      .txmf8(fm_txmf8),
      .txmfb(fm_txmfb),
      .txmfc(fm_txmfc),
      .txmfe(fm_txmfe),
      .txend(),
      .txemp(fm_txemp),
      .brk(1'b0),
      .sft(floppy_bitRate),
   
      .bitout(fm_bitout),
      .clk(clk),
      .rstn(~reset)
);

logic mfm_txemp;
logic mfm_bitout;
mfmmod mfmmod(
      .txdat(txdat),
      .txwr(floppy_mfm & txwr),
      .txma1(mfm_txma1),
      .txmc2(mfm_txmc2),
      .brk(1'b0),
   
      .txemp(mfm_txemp),
      .txend(),
   
      .bitout(mfm_bitout),
   
      .sft(floppy_bitRate),
      .clk(clk),
      .rstn(~reset)
);

logic [15:0] crc_out;
fdd_crc #(.POLYNOM(16'h1021)) crc (
    .clk(clk),
    .valid(crc_calc),
    .we(crcwr),
    .data_in(txdat),
    .crc(crc_out)
);

endmodule
