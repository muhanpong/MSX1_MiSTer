// Debug overlay — status panel, top-left corner.
// 4 indicator rows × 8px each + 2px border = 34px tall.
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
    input  wire        dbg_mem_nonzero,       // Unused legacy
    input  wire        dbg_interp_nonzero,    // Used for base_set
    input  wire signed [15:0] dbg_pcm_level,
    input  wire        dbg_new2,
    input  wire [4:0]  dbg_keyon_count,       // Unused legacy
    input  wire [4:0]  dbg_accum_cnt,         // Unused legacy
    input  wire [9:0]  dbg_env_min,           // Unused legacy
    input  wire [23:0] dbg_slot_keyon,        // per-slot host key-on
    input  wire [23:0] dbg_slot_active        // per-slot envelope running
);

// ─── CDC sync ───────────────────────────────────────────────────────────────────────
logic [1:0] pcm_sync, opl3_sync, new2_sync;
logic [1:0] base_sync;
logic [15:0] lvl_sync1, lvl_sync2;

always_ff @(posedge CLK_VIDEO) begin
    pcm_sync      <= {pcm_sync[0],   dbg_pcm_valid};
    opl3_sync     <= {opl3_sync[0],  dbg_opl3_valid};
    new2_sync     <= {new2_sync[0],  dbg_new2};
    base_sync     <= {base_sync[0],  dbg_interp_nonzero}; // base_set
    lvl_sync1   <= dbg_pcm_level;   lvl_sync2   <= lvl_sync1;
end

// Per-slot masks (slow-changing) — 2-FF CDC into the video clock.
logic [23:0] keyon_s1, keyon_s2, active_s1, active_s2;
always_ff @(posedge CLK_VIDEO) begin
    keyon_s1  <= dbg_slot_keyon;   keyon_s2  <= keyon_s1;
    active_s1 <= dbg_slot_active;  active_s2 <= active_s1;
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

logic [15:0] pcm_peak;
always_ff @(posedge CLK_VIDEO) begin
    if (abs_lvl > pcm_peak) pcm_peak <= abs_lvl;
end
wire [5:0] level_bar = pcm_peak[13:8];

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
localparam PH = 8'd50;  // 6 rows × 8px + 2 border  (rows 5,6 = per-slot maps)
wire in_panel = en && !hblank && !vblank && (h_cnt < PW) && (v_cnt < PH) && !drew_this_line;
wire border   = (h_cnt == 11'd0) || (h_cnt == PW-1) || (v_cnt == 8'd0) || (v_cnt == PH-1);
wire [7:0] px = h_cnt[7:0] - 8'd1;
wire [7:0] py = v_cnt       - 8'd1;
// Counts of keyon / active slots → bar length (×2 px, max 24 slots = 48px).
// Manual popcount ($countones isn't synthesizable in Quartus 17.1).
logic [5:0] keyon_cnt, active_cnt;
always_comb begin
    keyon_cnt = 6'd0; active_cnt = 6'd0;
    for (int i = 0; i < 24; i++) begin
        keyon_cnt  = keyon_cnt  + {5'd0, keyon_s2[i]};
        active_cnt = active_cnt + {5'd0, active_s2[i]};
    end
end
wire [7:0] keyon_w    = {1'b0, keyon_cnt, 1'b0};   // count*2
wire [7:0] active_w   = {1'b0, active_cnt, 1'b0};

always_comb begin
    R_out = R_in; G_out = G_in; B_out = B_in;
    if (in_panel) begin
        if (border) begin
            R_out = 8'h00; G_out = 8'h00; B_out = 8'h00;
        end else begin
            R_out = 8'h10; G_out = 8'h10; B_out = 8'h10;
            if (py < 8'd8) begin        // ROM Base Set — green=set, red=missing
                R_out = base_sync[1] ? 8'h00 : 8'hFF;
                G_out = base_sync[1] ? 8'hFF : 8'h00;
                B_out = 8'h00;
            end else if (py < 8'd16) begin // PCM valid — green
                R_out = 8'h00; G_out = (pcm_hold > 0) ? 8'hFF : 8'h40; B_out = 8'h00;
            end else if (py < 8'd24) begin // PCM level — yellow bar
                if (px < {2'd0, level_bar}) begin R_out=8'hFF; G_out=8'hE0; B_out=8'h00; end
                else begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else if (py < 8'd32) begin // NEW2 — cyan
                R_out = 8'h00;
                G_out = new2_sync[1] ? 8'hFF : 8'h30;
                B_out = new2_sync[1] ? 8'hFF : 8'h30;
            end else if (py < 8'd40) begin // KEYON COUNT — green bar (length = #keyon)
                if (px < keyon_w)  begin R_out=8'h00; G_out=8'hFF; B_out=8'h00; end
                else               begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end else begin                 // ACTIVE COUNT — cyan bar (length = #active)
                // If shorter than the keyon bar above → keyon-but-silent voices.
                if (px < active_w) begin R_out=8'h00; G_out=8'hFF; B_out=8'hFF; end
                else               begin R_out=8'h20; G_out=8'h20; B_out=8'h20; end
            end
        end
    end
end

endmodule
`default_nettype wire
