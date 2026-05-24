// YMF278 PCM Volume and Panning
// Applies envelope volume, TL, and pan per-channel.
// Translates vol_factor() and pan_left/pan_right from openMSX YMF278.cc
`default_nettype none

module ymf278_pcm_volume (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,           // pulse when new sample + params are valid

    // Inputs
    input  wire signed [15:0] sample_in,
    input  wire [9:0]  env_vol,         // 0=max, 0x280=silence
    input  wire [7:0]  tl_vol,          // TL level (0..0xFF)
    input  wire [3:0]  pan,             // pan index 0..15

    // Outputs
    output logic signed [15:0] left_out,
    output logic signed [15:0] right_out,
    output logic               out_valid
);

localparam int MAX_ATT_INDEX = 10'h280;

// pan_left[16], pan_right[16]: attenuation in 3dB steps
// 0 = 0dB (full), 8 = -24dB, 255 = silence
logic [7:0] pan_left_rom [0:15];
logic [7:0] pan_right_rom [0:15];
initial begin
    pan_left_rom  = '{8'd0,8'd8,8'd16,8'd24,8'd32,8'd40,8'd48,8'd255,
                      8'd255,8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
    pan_right_rom = '{8'd0,8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0,
                      8'd255,8'd255,8'd48,8'd40,8'd32,8'd24,8'd16,8'd8};
end

// vol_factor: apply volume attenuation
// In: x (signed 16-bit), envVol (10-bit)
// Out: x attenuated
function automatic signed [31:0] vol_factor(
    input signed [15:0] x,
    input [9:0] evol
);
    // vol_mul range = 0x80 - (evol & 0x3F) ∈ [0x41, 0x80] → needs 8 bits.
    // Previous 6-bit declaration truncated 0x80 to 0, silencing the
    // loudest case (evol = 0).
    logic [7:0] vol_mul;
    logic [4:0] vol_shift;
    logic signed [31:0] tmp;
    if (evol >= 10'(MAX_ATT_INDEX)) return 32'sd0;
    vol_mul   = 8'h80 - {2'b0, evol[5:0]};         // 0x80 - (envVol & 0x3F)
    vol_shift = 5'(4'd7 + {1'b0, evol[9:6]});      // 7 + (envVol >> 6)
    tmp = (32'sh8000 * $signed({1'b0, vol_mul})) >>> vol_shift;
    return ($signed(x) * tmp) >>> 15;
endfunction

// pan attenuation: (0x20 - (p & 0x0F)) >> (p >> 4)
// (0x20 - 0..0xF) ∈ [0x11, 0x20] → needs 6 bits before the right shift.
// Previous 5-bit return truncated pan=0 (centre/loudest) to 0.
function automatic [5:0] pan_att(input [7:0] p);
    if (p == 8'd255) return 6'd0;   // silence: multiply by 0
    return 6'((6'h20 - {2'b0, p[3:0]}) >> p[7:4]);
endfunction

// Pipeline registers
logic signed [15:0] sample_r;
logic [9:0]  env_vol_r;
logic [7:0]  tl_vol_r;
logic [3:0]  pan_r;
logic        valid_r;

always_ff @(posedge clk) begin
    sample_r  <= sample_in;
    env_vol_r <= env_vol;
    tl_vol_r  <= tl_vol;
    pan_r     <= pan;
    valid_r   <= start;
end

always_ff @(posedge clk) begin
    out_valid <= 1'b0;
    if (!rst_n) begin
        left_out  <= 16'sh0;
        right_out <= 16'sh0;
    end else if (valid_r) begin
        // Apply envelope then TL (each clips independently at -60dB)
        begin
            logic signed [31:0] after_env;
            logic signed [31:0] after_tl;
            logic [5:0] vl, vr;     // widened to match pan_att width
            logic [9:0] tl_shifted;

            tl_shifted = {tl_vol_r, 2'b00};   // TL << TL_SHIFT (2)

            after_env = vol_factor(sample_r,  env_vol_r);
            after_tl  = vol_factor(after_env[15:0], tl_shifted);

            vl = pan_att(pan_left_rom[pan_r]);
            vr = pan_att(pan_right_rom[pan_r]);

            // CRITICAL: do the multiplication in wider context BEFORE the
            // shift.  Verilog evaluates the expression at the LHS width, so
            // 16'(a * b >>> 5) truncates a*b to 16-bit (overflows!) and then
            // shifts the truncated value.  Cast operands to 32-bit signed
            // first so the multiplication preserves full precision, then
            // shift, then truncate to 16-bit.
            left_out  <= 16'((32'($signed(after_tl[15:0])) * 32'($signed({1'b0, vl}))) >>> 5);
            right_out <= 16'((32'($signed(after_tl[15:0])) * 32'($signed({1'b0, vr}))) >>> 5);
        end
        out_valid <= 1'b1;
    end
end

endmodule
`default_nettype wire
