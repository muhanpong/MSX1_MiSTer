// YMF278 PCM LFO — vibrato (vib_offset) and tremolo (am_atten)
// 24-slot time-multiplexed; per-slot lfo_cnt stored in BRAM.
// Translates openMSX compute_vib() and compute_am().
`default_nettype none

module ymf278_pcm_lfo (
    input  wire        clk,
    input  wire        rst_n,

    // Scheduler interface
    input  wire [4:0]  slot_idx,
    input  wire        slot_valid,

    // Per-slot parameters
    input  wire [2:0]  lfo_speed,      // lfo register value
    input  wire [2:0]  vib_depth_sel,  // vib register value
    input  wire [2:0]  am_depth_sel,   // AM register value
    input  wire        lfo_active,     // LFO enable for this slot
    input  wire        lfo_reset,      // reset lfo_cnt to 0

    // Outputs
    output logic signed [15:0] vib_offset,  // F-Num vibrato offset
    output logic       [15:0]  am_atten     // tremolo attenuation (unsigned)
);

// LFO period table: steps per sample at 44.1kHz
// L(f) = round(LFO_PERIOD * f / 44100)
// LFO_PERIOD = 1<<18 = 262144
localparam int LFO_PERIOD = 262144;

logic [17:0] lfo_period_rom [0:7];
initial begin
    lfo_period_rom[0] = 18'd1;   // 0.168 Hz → 1
    lfo_period_rom[1] = 18'd12;  // 2.019 Hz → 12
    lfo_period_rom[2] = 18'd19;  // 3.196 Hz → 19
    lfo_period_rom[3] = 18'd25;  // 4.206 Hz → 25
    lfo_period_rom[4] = 18'd31;  // 5.215 Hz → 31
    lfo_period_rom[5] = 18'd35;  // 5.888 Hz → 35
    lfo_period_rom[6] = 18'd37;  // 6.224 Hz → 37
    lfo_period_rom[7] = 18'd42;  // 7.066 Hz → 42
end

// vib_depth[8]: F-Num units for vibrato
logic signed [15:0] vib_depth_rom [0:7];
initial begin
    vib_depth_rom[0] = 16'sd0;
    vib_depth_rom[1] = 16'sd2;
    vib_depth_rom[2] = 16'sd3;
    vib_depth_rom[3] = 16'sd4;
    vib_depth_rom[4] = 16'sd6;
    vib_depth_rom[5] = 16'sd12;
    vib_depth_rom[6] = 16'sd24;
    vib_depth_rom[7] = 16'sd48;
end

// am_depth[8]
logic [7:0] am_depth_rom [0:7];
initial begin
    am_depth_rom[0] = 8'h00;
    am_depth_rom[1] = 8'h14;
    am_depth_rom[2] = 8'h20;
    am_depth_rom[3] = 8'h28;
    am_depth_rom[4] = 8'h30;
    am_depth_rom[5] = 8'h40;
    am_depth_rom[6] = 8'h50;
    am_depth_rom[7] = 8'h80;
end

// Per-slot BRAM: lfo_cnt[17:0]
logic [17:0] lfo_cnt_mem [0:23];
initial begin
    for (int i = 0; i < 24; i++) lfo_cnt_mem[i] = 18'd0;
end

// Pipeline stage 1: read BRAM
logic [17:0] lfo_cnt_rd;
logic        slot_valid_d1;
logic [4:0]  slot_idx_d1;
logic [2:0]  lfo_speed_d1, vib_depth_sel_d1, am_depth_sel_d1;
logic        lfo_active_d1, lfo_reset_d1;

always_ff @(posedge clk) begin
    lfo_cnt_rd      <= lfo_cnt_mem[slot_idx];
    slot_valid_d1   <= slot_valid;
    slot_idx_d1     <= slot_idx;
    lfo_speed_d1    <= lfo_speed;
    vib_depth_sel_d1<= vib_depth_sel;
    am_depth_sel_d1 <= am_depth_sel;
    lfo_active_d1   <= lfo_active;
    lfo_reset_d1    <= lfo_reset;
end

// Update lfo_cnt and compute vibrato/tremolo
logic [17:0] new_lfo_cnt;
logic signed [15:0] vib_out;
logic [15:0]        am_out;

always_comb begin
    new_lfo_cnt = lfo_cnt_rd;
    vib_out     = 16'sd0;
    am_out      = 16'd0;

    if (lfo_reset_d1) begin
        new_lfo_cnt = 18'd0;
    end else if (lfo_active_d1) begin
        new_lfo_cnt = lfo_cnt_rd + {12'd0, lfo_period_rom[lfo_speed_d1]};
        // wrap at LFO_PERIOD
        if (new_lfo_cnt >= 18'(LFO_PERIOD))
            new_lfo_cnt -= 18'(LFO_PERIOD);
    end

    // compute_vib: lfo_cnt >> 12 gives 0..63 (6-bit index)
    // Triangle: 0..15(+), 15..0(+), 0..15(-), 15..0(-)
    begin
        logic [5:0] lfo_fm6;
        logic signed [5:0] lfo_fm_s;
        lfo_fm6 = new_lfo_cnt[17:12];         // 0..63
        if (lfo_fm6[4]) lfo_fm6 = lfo_fm6 ^ 6'h1F;   // invert lower 5 bits → 0..15 zigzag
        lfo_fm_s = (lfo_fm6[5]) ? -$signed({2'b0, lfo_fm6[3:0]})
                                :  $signed({2'b0, lfo_fm6[3:0]});
        vib_out = 16'($signed(lfo_fm_s) * $signed({1'b0, vib_depth_rom[vib_depth_sel_d1]}) / 16'sd12);
    end

    // compute_am: lfo_cnt >> 10 gives 0..255, fold to triangle 0..127
    begin
        logic [7:0] lfo_am8;
        lfo_am8 = new_lfo_cnt[17:10];         // 0..255
        if (lfo_am8[7]) lfo_am8 = lfo_am8 ^ 8'hFF;   // fold to 0..127
        am_out = 16'((lfo_am8[6:0] * {1'b0, am_depth_rom[am_depth_sel_d1]}) >> 7);
    end
end

// Write back lfo_cnt
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++) lfo_cnt_mem[i] <= 18'd0;
    end else if (slot_valid_d1) begin
        lfo_cnt_mem[slot_idx_d1] <= new_lfo_cnt;
    end
end

// Registered outputs
always_ff @(posedge clk) begin
    if (!rst_n) begin
        vib_offset <= 16'sd0;
        am_atten   <= 16'd0;
    end else if (slot_valid_d1) begin
        vib_offset <= vib_out;
        am_atten   <= am_out;
    end
end

endmodule
`default_nettype wire
