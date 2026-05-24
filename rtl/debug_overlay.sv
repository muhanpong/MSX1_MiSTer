// Debug overlay — status panel, top-left corner.
// 8 indicator rows × 8px each + 2px border = 66px tall.
`default_nettype none

module debug_overlay (
    input  wire        CLK_VIDEO,
    input  wire        ce_pix,
    input  wire        hblank,
    input  wire        vblank,
    input  wire [7:0]  R_in, G_in, B_in,
    output reg  [7:0]  R_out, G_out, B_out,
    input  wire        en,
    input  wire        dbg_pcm_valid,
    input  wire        dbg_opl3_valid,
    input  wire        dbg_mem_nonzero,
    input  wire        dbg_interp_nonzero,
    input  wire signed [15:0] dbg_pcm_level,
    input  wire        dbg_new2,
    input  wire [4:0]  dbg_keyon_count,
    input  wire [4:0]  dbg_accum_cnt,
    input  wire [9:0]  dbg_env_min      // 0=loud, 0x280=silent
);

// ─── CDC sync ───────────────────────────────────────────────────────────────────────
logic [1:0] pcm_sync, opl3_sync, new2_sync;
logic [1:0] memnz_sync, interpnz_sync;
logic [15:0] lvl_sync1, lvl_sync2;
logic [4:0]  keyon_sync1, keyon_sync2, accum_sync1, accum_sync2;
logic [9:0]  envmin_sync1, envmin_sync2;

always_ff @(posedge CLK_VIDEO) begin
    pcm_sync      <= {pcm_sync[0],   dbg_pcm_valid};
    opl3_sync     <= {opl3_sync[0],  dbg_opl3_valid};
    new2_sync     <= {new2_sync[0],  dbg_new2};
    memnz_sync    <= {memnz_sync[0], dbg_mem_nonzero};
    interpnz_sync <= {interpnz_sync[0], dbg_interp_nonzero};
    lvl_sync1   <= dbg_pcm_level;   lvl_sync2   <= lvl_sync1;
    keyon_sync1 <= dbg_keyon_count; keyon_sync2 <= keyon_sync1;
    accum_sync1 <= dbg_accum_cnt;   accum_sync2 <= accum_sync1;
    envmin_sync1<= dbg_env_min;     envmin_sync2<= envmin_sync1;
end

// ─── Hold counters (8/frame decay) ───────────────────────────────────────────
logic [7:0] pcm_hold, opl3_hold;
logic vblank_prev;
always_ff @(posedge CLK_VIDEO) begin
    vblank_prev <= vblank;
    if (pcm_sync[1])   pcm_hold   <= 8'hFF;
    else if (!vblank_prev && vblank && pcm_hold > 0)
        pcm_hold <= (pcm_hold > 8'd8) ? pcm_hold - 8'd8 : 8'd0;
    if (opl3_sync[1])  opl3_hold  <= 8'hFF;
    else if (!vblank_prev && vblank && opl3_hold > 0)
        opl3_hold <= (opl3_hold > 8'd8) ? opl3_hold - 8'd8 : 8'd0;
end

// Bar computations
wire [15:0] abs_lvl = lvl_sync2[15] ? (~lvl_sync2 + 16'd1) : lvl_sync2;

// PCM level peak hold (sticky max).  Without this, single-slot output
// (which is sample/16 ≈ -2048..+2047) often falls below the level_bar
// resolution and Row 4 looks empty even when PCM is producing real audio.
// Peak hold latches the highest |pcm_left| ever observed since reset.
logic [15:0] pcm_peak;
always_ff @(posedge CLK_VIDEO) begin
    if (abs_lvl > pcm_peak) pcm_peak <= abs_lvl;
end
// Also lower the threshold by 4 bits so smaller signals show.
// bits [13:8] gives 64 levels over range [0x100, 0x3FFF].
wire [5:0] level_bar = pcm_peak[13:8];
wire [7:0] keyon_bar_w = {3'd0, keyon_sync2} * 8'd3;
wire [5:0] keyon_bar = (keyon_bar_w > 8'd63) ? 6'd63 : keyon_bar_w[5:0];
wire [7:0] accum_bar_w = {3'd0, accum_sync2} * 8'd3;
wire [5:0] accum_bar = (accum_bar_w > 8'd63) ? 6'd63 : accum_bar_w[5:0];
// env_min bar: 0x280=silent→0px, 0=loud→63px.  Invert and scale.
// 0x280=640. bar = 63 - (envmin * 63 / 640) ≈ 63 - (envmin / 10)
wire [9:0] env_inv = (envmin_sync2 >= 10'h280) ? 10'd0 : (10'h280 - envmin_sync2);
wire [5:0] env_bar = (env_inv[9:4] > 6'd63) ? 6'd63 : env_inv[9:4];

// ─── Pixel position ──────────────────────────────────────────────────────────
logic [10:0] h_cnt;
logic [7:0]  v_cnt;
logic hbl_prev, vbl_prev;
logic drew_this_line;

always_ff @(posedge CLK_VIDEO) begin
    hbl_prev <= hblank;  vbl_prev <= vblank;
    if (!vbl_prev && vblank) v_cnt <= '0;
    else if (hbl_prev && !hblank && !vblank) v_cnt <= v_cnt + 8'd1;
    if (hblank) begin h_cnt <= '0; drew_this_line <= 1'b0; end
    else if (ce_pix && h_cnt < 11'd2047) h_cnt <= h_cnt + 11'd1;
end

// ─── Render ──────────────────────────────────────────────────────────────────
localparam PW = 11'd66;
localparam PH = 8'd66;  // 8 rows × 8px + 2 border
wire in_panel = en && !hblank && !vblank && (h_cnt < PW) && (v_cnt < PH) && !drew_this_line;
wire border   = (h_cnt == 11'd0) || (h_cnt == PW-1) || (v_cnt == 8'd0) || (v_cnt == PH-1);
wire [7:0] px = h_cnt[7:0] - 8'd1;
wire [7:0] py = v_cnt       - 8'd1;

always_comb begin
    R_out = R_in; G_out = G_in; B_out = B_in;
    if (in_panel) begin
        if (border) begin
            R_out = 8'h00; G_out = 8'h00; B_out = 8'h00;
        end else begin
            R_out = 8'h10; G_out = 8'h10; B_out = 8'h10;
            if (py < 8'd8) begin        // MEM_NONZERO — green=got data, red=all zeros
                R_out = memnz_sync[1] ? 8'h00 : 8'hFF;
                G_out = memnz_sync[1] ? 8'hFF : 8'h00;
                B_out = 8'h00;
            end else if (py < 8'd16) begin // INTERP_NONZERO — green=got samples, red=all zeros
                R_out = interpnz_sync[1] ? 8'h00 : 8'hFF;
                G_out = interpnz_sync[1] ? 8'hFF : 8'h00;
                B_out = 8'h00;
            end else if (py < 8'd24) begin // PCM valid — green
                R_out = 8'h00; G_out = (pcm_hold > 0) ? 8'hFF : 8'h40; B_out = 8'h00;
            end else if (py < 8'd32) begin // PCM level — yellow bar
                if (px < {2'd0, level_bar}) begin R_out=8'hFF; G_out=8'hE0; B_out=8'h00; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (py < 8'd40) begin // NEW2 — cyan
                R_out = 8'h00;
                G_out = new2_sync[1] ? 8'hFF : 8'h30;
                B_out = new2_sync[1] ? 8'hFF : 8'h30;
            end else if (py < 8'd48) begin // KEY_ON — magenta bar
                if (px < {2'd0, keyon_bar}) begin R_out=8'hFF; G_out=8'h00; B_out=8'hFF; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (py < 8'd56) begin // ACCUM — white bar
                if (px < {2'd0, accum_bar}) begin R_out=8'hFF; G_out=8'hFF; B_out=8'hFF; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else begin                // ENV_MIN — orange bar (longer=louder)
                if (px < {2'd0, env_bar}) begin R_out=8'hFF; G_out=8'h80; B_out=8'h00; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end
        end
    end
end

endmodule
`default_nettype wire
