// YMF278 PCM Sample Interpolator
// Decodes 8/12/16-bit sample formats and performs linear interpolation.
// External memory interface: byte-wide, async-read model with valid handshake.
// The module issues up to 4 byte reads per slot cycle.
`default_nettype none

module ymf278_pcm_interpolator (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger: one pulse per slot when new sample position is available
    input  wire        start,

    // Sample position and format
    input  wire [21:0] startAddr,
    input  wire [15:0] pos,        // integer sample index
    input  wire [15:0] stepPtr,    // fractional position (0..0xFFFF)
    input  wire [15:0] endAddr,    // 2's complement, for nextPos
    input  wire [15:0] loopAddr,   // loop offset
    input  wire [1:0]  bits,       // 0=8bit, 1=12bit, 2=16bit

    // Memory read interface
    output logic [21:0] mem_addr,
    output logic        mem_rd_req,
    input  wire  [7:0]  mem_rd_data,
    input  wire         mem_rd_valid,

    // Output
    output logic signed [15:0] sample_out,
    output logic               sample_valid,
    output wire                ready         // high when interpolator can accept a new start
);

// nextPos helper — matches YMF278.cc nextPos()
function automatic [15:0] next_pos(
    input [15:0] p,
    input [15:0] inc,
    input [15:0] end_a,
    input [15:0] loop_a
);
    logic [15:0] p2;
    p2 = p + inc;
    if (({1'b0, p2} + {1'b0, end_a}) >= 17'h10000)
        p2 = p2 + end_a + loop_a;
    return p2;
endfunction

// Byte address for a given sample and pos
// For 8-bit:  addr = startAddr + pos
// For 12-bit: addr = startAddr + (pos/2)*3   (+0,+1,+2)
// For 16-bit: addr = startAddr + pos*2        (+0,+1)
function automatic [21:0] byte_addr(
    input [21:0] base,
    input [15:0] p,
    input [1:0]  fmt,
    input [1:0]  byte_sel   // byte within the sample
);
    logic [21:0] a;
    case (fmt)
        2'd0: a = base + {6'd0, p};              // 8-bit: 1 byte/sample
        2'd1: a = base + {6'd0, 16'((p >> 1) * 16'd3)} + {20'd0, byte_sel}; // 12-bit
        2'd2: a = base + {6'd0, p, 1'b0} + {20'd0, byte_sel[0:0]}; // 16-bit
        default: a = base;
    endcase
    return a;
endfunction

// State machine
typedef enum logic [3:0] {
    S_IDLE,
    S_FETCH_A0, S_WAIT_A0,
    S_FETCH_A1, S_WAIT_A1,
    S_FETCH_A2, S_WAIT_A2,
    S_FETCH_B0, S_WAIT_B0,
    S_FETCH_B1, S_WAIT_B1,
    S_FETCH_B2, S_WAIT_B2,
    S_CALC
} state_t;

state_t state;

assign ready = (state == S_IDLE);

logic [7:0]  bytes_a[0:2];   // raw bytes for sample A
logic [7:0]  bytes_b[0:2];   // raw bytes for sample B
logic signed [15:0] samp_a, samp_b;
logic [15:0] pos_b;           // pos+1 (nextPos)
logic [21:0] startAddr_r;
logic [15:0] pos_r, stepPtr_r, endAddr_r, loopAddr_r;
logic [1:0]  bits_r;

// decode_sample: reconstruct int16 from raw bytes
function automatic signed [15:0] decode_sample(
    input [7:0] b0, b1, b2,
    input [15:0] p,
    input [1:0] fmt
);
    case (fmt)
        2'd0: return $signed({b0, 8'h00});
        2'd1: begin
            if (p[0]) // odd pos
                return $signed({b2, b1 & 8'hF0});
            else       // even pos
                return $signed({b0, (b1 << 4) & 8'hF0});
        end
        2'd2: return $signed({b0, b1});
        default: return 16'sh0;
    endcase
endfunction

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_IDLE;
        mem_rd_req   <= 1'b0;
        sample_valid <= 1'b0;
        sample_out   <= 16'sh0;
    end else begin
        mem_rd_req   <= 1'b0;
        sample_valid <= 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    startAddr_r <= startAddr;
                    pos_r       <= pos;
                    stepPtr_r   <= stepPtr;
                    endAddr_r   <= endAddr;
                    loopAddr_r  <= loopAddr;
                    bits_r      <= bits;
                    pos_b       <= next_pos(pos, 16'd1, endAddr, loopAddr);
                    state       <= S_FETCH_A0;
                end
            end

            // --- Sample A byte 0 ---
            S_FETCH_A0: begin
                mem_addr   <= byte_addr(startAddr_r, pos_r, bits_r, 2'd0);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_A0;
            end
            S_WAIT_A0: begin
                if (mem_rd_valid) begin
                    bytes_a[0] <= mem_rd_data;
                    // 8-bit: only need 1 byte for A; go fetch B
                    if (bits_r == 2'd0) state <= S_FETCH_B0;
                    else               state <= S_FETCH_A1;
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            // --- Sample A byte 1 ---
            S_FETCH_A1: begin
                mem_addr   <= byte_addr(startAddr_r, pos_r, bits_r, 2'd1);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_A1;
            end
            S_WAIT_A1: begin
                if (mem_rd_valid) begin
                    bytes_a[1] <= mem_rd_data;
                    if (bits_r == 2'd2) state <= S_FETCH_B0; // 16-bit: 2 bytes done
                    else               state <= S_FETCH_A2;  // 12-bit: need 3rd
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            // --- Sample A byte 2 (12-bit only) ---
            S_FETCH_A2: begin
                mem_addr   <= byte_addr(startAddr_r, pos_r, bits_r, 2'd2);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_A2;
            end
            S_WAIT_A2: begin
                if (mem_rd_valid) begin
                    bytes_a[2] <= mem_rd_data;
                    state      <= S_FETCH_B0;
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            // --- Sample B byte 0 ---
            S_FETCH_B0: begin
                mem_addr   <= byte_addr(startAddr_r, pos_b, bits_r, 2'd0);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_B0;
            end
            S_WAIT_B0: begin
                if (mem_rd_valid) begin
                    bytes_b[0] <= mem_rd_data;
                    if (bits_r == 2'd0) state <= S_CALC;
                    else               state <= S_FETCH_B1;
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            S_FETCH_B1: begin
                mem_addr   <= byte_addr(startAddr_r, pos_b, bits_r, 2'd1);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_B1;
            end
            S_WAIT_B1: begin
                if (mem_rd_valid) begin
                    bytes_b[1] <= mem_rd_data;
                    if (bits_r == 2'd2) state <= S_CALC;
                    else               state <= S_FETCH_B2;
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            S_FETCH_B2: begin
                mem_addr   <= byte_addr(startAddr_r, pos_b, bits_r, 2'd2);
                mem_rd_req <= 1'b1;
                state      <= S_WAIT_B2;
            end
            S_WAIT_B2: begin
                if (mem_rd_valid) begin
                    bytes_b[2] <= mem_rd_data;
                    state      <= S_CALC;
                end else begin
                    mem_rd_req <= 1'b1;
                end
            end

            S_CALC: begin
                // Decode both samples
                samp_a = decode_sample(bytes_a[0], bytes_a[1], bytes_a[2], pos_r,  bits_r);
                samp_b = decode_sample(bytes_b[0], bytes_b[1], bytes_b[2], pos_b,  bits_r);
                // Linear interpolation: out = sA + ((sB - sA) * stepPtr) >> 16
                // Avoids the 0x10000 overflow when stepPtr=0.
                begin
                    logic signed [16:0] diff;
                    logic signed [32:0] prod;
                    diff = $signed({samp_b[15], samp_b}) - $signed({samp_a[15], samp_a});
                    prod = diff * $signed({1'b0, stepPtr_r});
                    sample_out <= samp_a + prod[32:16];
                end
                sample_valid <= 1'b1;
                state        <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire
