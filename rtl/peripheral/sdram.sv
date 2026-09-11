//
// sdram
// Copyright (c) 2015-2019 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

module sdram
#(
    // ch2 (CPU) read cache: direct-mapped, one 16-bit word per line, so a fill
    // is exactly one ordinary SDRAM read and no burst mode is involved.  The
    // 1-line version of this (the "word latch") measured 40% of CPU reads
    // answered without touching the chip; more lines stop code, stack and data
    // evicting each other.  Power of two; 0 = disabled (A/B without revert).
    // 8192 lines = 16 kB of data, ~30 M10K blocks with tags.
    parameter CACHE_LINES = 8192
)
(
    input             init,        // reset to initialize RAM
    input             clk,         // clock 64MHz
   
    input             doRefresh,

    inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
    output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
    output            SDRAM_DQML,  // two byte masks
    output            SDRAM_DQMH,  // 
    output reg  [1:0] SDRAM_BA,    // two banks
    output            SDRAM_nCS,   // a single chip select
    output            SDRAM_nWE,   // write enable
    output            SDRAM_nRAS,  // row address select
    output            SDRAM_nCAS,  // columns address select
    output            SDRAM_CKE,   // clock enable
    output            SDRAM_CLK,   // clock for chip

    input      [26:0] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
    output reg  [7:0] ch1_dout,    // data output to cpu
    input       [7:0] ch1_din,
    input             ch1_req,     // request
    input             ch1_rnw,     // 1 - read, 0 - write
    output reg        ch1_ready,
    
    input      [26:0] ch2_addr,    
    output reg  [7:0] ch2_dout,    
	input       [7:0] ch2_din,     
    input             ch2_req,
	input             ch2_rnw,     // 1 - read, 0 - write
    output reg        ch2_ready,
    // Flips once per completed ch2 READ (at data capture).  A toggle is the
    // safe way to consume completion from the related clk21m domain: unlike
    // ch2_ready's level (whose busy-low phase can be shorter than one clk21m
    // period on writes), a toggle transition can never be missed by a slower
    // sampler.  Consumer: the turbo bus guard's closed-loop read release
    // (msx.sv P3, 20260826).
    output reg        ch2_rdtog,
    // This ch2 read was answered from the cache: no SDRAM access is issued and
    // ch2_rdtog will NOT toggle, so msx.sv's closed-loop guard must open on
    // this instead of sitting on its watchdog.  A level held for the request
    // window (not a toggle) because the completion is near-immediate and
    // cannot satisfy the ">= 2 clk21m away" ordering the toggle path relies on.
    output            ch2_hit,

    input      [26:0] ch3_addr,
    output reg  [7:0] ch3_dout,
    input       [7:0] ch3_din,
    input             ch3_req,
    input             ch3_rnw,     // 1 - read, 0 - write
    output reg        ch3_ready,
	output reg        ch3_done,

    // ch4: MoonSound PCM sample memory (read/write)
    input      [26:0] ch4_addr,
    output reg  [7:0] ch4_dout,
    output     [15:0] ch4_dout16,  // full 16-bit word (both bytes) for PCM burst
    input       [7:0] ch4_din,
    input             ch4_req,
    input             ch4_rnw,     // 1 - read, 0 - write
    output reg        ch4_ready
);

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];


// Burst length = 4
localparam BURST_LENGTH        = 1;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd500;  // (64000*64)/8192-1 Calc'd as (64ms @ 64MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;
reg        chip;
reg        ch1_saved_a0, ch2_saved_a0, ch3_saved_a0, ch4_saved_a0;
// ---------------------------------------------------------------------------
// ch2 read cache
//   line  = {valid, tag, data[15:0]}   index = word address low bits
//   fill  = at ch2 read-data capture, from the same SDRAM_DQ word
//   drop  = at every write ISSUE (ch1..ch4), by index only -- a direct-mapped
//           cache has one line per index, so clearing that line is always
//           correct whether or not the tag matched (a lost hit at worst) and
//           needs no tag lookup on the write path
//   hit   = decided two clk_sdram after the request edge.  The index handed to
//           the M10K is REGISTERED (ch2_caddr), not ch2_addr straight off the
//           CPU bus: the combinational mapper chain from the T80 into an M10K
//           address port does not close in one clk_sdram, and MSX1.sdc's
//           multicycle exception is name-matched on {*sdram*ch2_*}, so a
//           register called c_* or an inferred RAM's portb_address_reg falls
//           outside it and gets analysed single-cycle (measured -11.9 ns; the
//           SDC comment records -9.1 ns for the same chain into ch2_addr_1).
//           Capturing into ch2_caddr puts the cross-domain hop back inside the
//           exception and leaves the RAM port fed from a local flop.  A miss
//           therefore issues two cycles after the request instead of one
//   RAM read-during-write to the same index is undefined on M10K, so a lookup
//   that overlaps a write to its own index (either the edge it read on or the
//   edge after) is forced to miss.  Writes are rare next to reads; the cost is
//   an occasional redundant fetch, never a stale hit.
// ---------------------------------------------------------------------------
localparam CL = (CACHE_LINES > 1) ? CACHE_LINES : 2;
localparam CW = $clog2(CL);          // index bits
localparam TW = 26 - CW;             // tag bits (word address is 26 bits)
localparam LW = 1 + TW + 16;         // line width

reg  [LW-1:0] cmem [0:CL-1];
reg  [LW-1:0] c_rdata;
reg           c_we = 1'b0;
reg  [CW-1:0] c_waddr;
reg  [LW-1:0] c_wdata;
reg           c_we_d = 1'b0;         // write applied on the previous edge
reg  [CW-1:0] c_waddr_d;
always @(posedge clk) begin
    if (c_we) cmem[c_waddr] <= c_wdata;
    c_rdata  <= cmem[ch2_caddr[CW:1]];   // registered index -- see note above
    c_we_d   <= c_we;
    c_waddr_d<= c_waddr;
end

reg           c_flush = 1'b1;        // valid-bit sweep after init; no hits until done
reg  [CW-1:0] c_flush_idx = '0;
// Stage 1 is named ch2_* so MSX1.sdc's {*sdram*ch2_*} multicycle covers the
// clk21m -> clk_sdram hop, exactly as it does for ch2_addr_1.  Stage 2 must NOT
// be: it is a plain clk_sdram -> clk_sdram dependency and relaxing it by 6
// cycles would be wrong.
reg           ch2_cpend = 1'b0;      // index captured; the RAM is read this cycle
reg  [26:0]   ch2_caddr;
reg           c_pend2   = 1'b0;      // c_rdata valid; compare this cycle
reg [25:0]    ch2_inflight_word;     // word address of the read given to SDRAM

wire [CW-1:0] c_pidx   = ch2_caddr[CW:1];
wire          c_hazard = (c_we   && c_waddr   == c_pidx)
                       | (c_we_d && c_waddr_d == c_pidx);
wire          c_match  = c_rdata[LW-1] && c_rdata[LW-2:16] == ch2_caddr[26:CW+1];

// Held for the whole request window rather than pulsed: clk21m samples this and
// a one-clk_sdram pulse would be missed, exactly as the ch2_ready comment warns.
reg        ch2_hit_r = 1'b0;
assign     ch2_hit = ch2_hit_r;
reg [15:0] ch1_saved_data, ch2_saved_data, ch3_saved_data, ch4_saved_data;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_IDLE    = 4;
localparam STATE_IDLE_1  = 5;
localparam STATE_IDLE_2  = 6;
localparam STATE_IDLE_3  = 7;
localparam STATE_IDLE_4  = 8;
localparam STATE_IDLE_5  = 9;
localparam STATE_RFSH    = 10;

// (CH4_HOLD burst-priority RETIRED 2026-06-12.  It served the v2 engine's
// fixed 64-cycle slot windows; with priority held, a ch2 (CPU) read could
// miss its fixed ~24-cycle consumption deadline — ch2 has NO handshake, so
// the CPU silently consumed the PREVIOUS read's data.  Hardware forensics:
// IM2 vector/opcode fetches sporadically returned stale bytes during PCM
// playback → wild execution → vgmplay freeze.  The v3 engine is fully
// latency-tolerant (blocking FSM + per-slot word cache), so the CPU now has
// absolute priority and ch4 takes the leftovers.)

assign ch1_dout = ch1_saved_a0 ? ch1_saved_data[15:8] : ch1_saved_data[7:0];
assign ch2_dout = ch2_saved_a0 ? ch2_saved_data[15:8] : ch2_saved_data[7:0];
assign ch3_dout = ch3_saved_a0 ? ch3_saved_data[15:8] : ch3_saved_data[7:0];
assign ch4_dout = ch4_saved_a0 ? ch4_saved_data[15:8] : ch4_saved_data[7:0];
// Full 16-bit word: [7:0] = mem[even byte], [15:8] = mem[odd byte].  PCM
// engine issues word-aligned (even) addresses and consumes both bytes.
assign ch4_dout16 = ch4_saved_data;

always @(posedge clk) begin
    reg [CAS_LATENCY+BURST_LENGTH+1:0] data_ready_delay1, data_ready_delay2, data_ready_delay3, data_ready_delay4;

    reg        saved_wr;
    reg [12:0] cas_addr;
    reg [15:0] saved_data;
    reg  [3:0] state = STATE_STARTUP;

    reg       ch1_req_1, ch2_req_1, ch3_req_1, ch4_req_1;
    reg       ch1_rq, ch2_rq, ch3_rq, ch4_rq;
    reg [1:0] ch;

    reg        ch1_rnw_1,ch2_rnw_1,ch3_rnw_1,ch4_rnw_1;
    reg [26:0] ch1_addr_1,ch2_addr_1,ch3_addr_1,ch4_addr_1;
    reg  [7:0] ch1_din_1,ch2_din_1,ch3_din_1,ch4_din_1;

    reg        doRefresh_1;
    
    ch1_req_1 <= ch1_req;
    ch2_req_1 <= ch2_req;
    ch3_req_1 <= ch3_req;
    ch4_req_1 <= ch4_req;
      
    doRefresh_1 <= doRefresh;

    if (ch1_req & ~ch1_req_1) begin
        ch1_rq     <= 1;
        ch1_rnw_1  <= ch1_rnw;
        ch1_addr_1 <= ch1_addr;
        ch1_din_1  <= ch1_din;
    end
    c_we <= 0;                                   // one-cycle write pulses below
    if (~ch2_req) ch2_hit_r <= 0;
    if (ch2_req & ~ch2_req_1) begin
        if (CACHE_LINES != 0 && ch2_rnw) begin
            ch2_cpend <= 1;          // RAM is read next cycle, compared the one after
            ch2_caddr <= ch2_addr;
        end else begin
            ch2_rq <= 1;
            ch2_rnw_1  <= ch2_rnw;
            ch2_addr_1 <= ch2_addr;
            ch2_din_1  <= ch2_din;
        end
    end
    if (ch2_cpend) begin
        ch2_cpend <= 0;
        c_pend2   <= 1;
    end else if (c_pend2) begin
        c_pend2 <= 0;
        if (~c_flush && ~ch2_rq && c_match && ~c_hazard) begin
            // ~ch2_rq: no ch2 access is queued, so ch2_saved_data cannot be
            // replaced underneath this reply.  Does NOT toggle ch2_rdtog.
            ch2_saved_data <= c_rdata[15:0];
            ch2_saved_a0   <= ch2_caddr[0];
            ch2_ready      <= 1;
            ch2_hit_r      <= 1;
        end else begin
            ch2_rq     <= 1;
            ch2_rnw_1  <= 1;
            ch2_addr_1 <= ch2_caddr;
        end
    end
    if (ch3_req & ~ch3_req_1) begin
        ch3_rq <= 1;
        ch3_rnw_1  <= ch3_rnw;
        ch3_addr_1 <= ch3_addr;
        ch3_din_1  <= ch3_din;
    end
    if (ch4_req & ~ch4_req_1) begin
        ch4_rq     <= 1;
        ch4_addr_1 <= ch4_addr;
        ch4_rnw_1  <= ch4_rnw;
        ch4_din_1  <= ch4_din;
    end
	if (~ch3_req) ch3_done <= 0;

    refresh_count <= refresh_count+1'b1;

    data_ready_delay1 <= data_ready_delay1>>1;
    data_ready_delay2 <= data_ready_delay2>>1;
    data_ready_delay3 <= data_ready_delay3>>1;
    data_ready_delay4 <= data_ready_delay4>>1;


    if(data_ready_delay1[CAS_LATENCY+BURST_LENGTH-1]) ch1_saved_data <= SDRAM_DQ;
    if(data_ready_delay1[CAS_LATENCY+BURST_LENGTH-1]) ch1_ready <= 1;

    if(data_ready_delay2[CAS_LATENCY+BURST_LENGTH-1]) ch2_saved_data <= SDRAM_DQ;
	if(data_ready_delay2[CAS_LATENCY+BURST_LENGTH-1]) ch2_ready <= 1;
	if(data_ready_delay2[CAS_LATENCY+BURST_LENGTH-1]) ch2_rdtog <= ~ch2_rdtog;
    if(data_ready_delay2[CAS_LATENCY+BURST_LENGTH-1]) begin   // fill
        c_we    <= 1;
        c_waddr <= ch2_inflight_word[CW-1:0];
        c_wdata <= {1'b1, ch2_inflight_word[25:CW], SDRAM_DQ};
    end

	
	if(data_ready_delay3[CAS_LATENCY+BURST_LENGTH-1]) ch3_saved_data <= SDRAM_DQ;
	if(data_ready_delay3[CAS_LATENCY+BURST_LENGTH-1]) ch3_ready <= 1;

	if(data_ready_delay4[CAS_LATENCY+BURST_LENGTH-1]) ch4_saved_data <= SDRAM_DQ;
	if(data_ready_delay4[CAS_LATENCY+BURST_LENGTH-1]) ch4_ready <= 1;

    SDRAM_DQ <= 16'bz;

    command <= CMD_NOP;

    case (state)
        STATE_STARTUP: begin
            SDRAM_A    <= 0;
            SDRAM_BA   <= 0;

            if (refresh_count == (startup_refresh_max-64)) chip <= 0;
            if (refresh_count == (startup_refresh_max-32)) chip <= 1;

            // All the commands during the startup are NOPS, except these
            if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
                // ensure all rows are closed
                command     <= CMD_PRECHARGE;
                SDRAM_A[10] <= 1;  // all banks
                SDRAM_BA    <= 2'b00;
            end
            if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
                // these refreshes need to be at least tREF (66ns) apart
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
                command     <= CMD_AUTO_REFRESH;
            end
            if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
                // Now load the mode register
                command     <= CMD_LOAD_MODE;
                SDRAM_A     <= MODE;
            end

            if (!refresh_count) begin
                state   <= STATE_IDLE;
                refresh_count <= 0;
                ch1_ready <= 1;
				ch2_ready <= 1;
				ch3_ready <= 1;
				ch4_ready <= 1;
            end
        end

        STATE_IDLE_5: state <= STATE_IDLE_4;
        STATE_IDLE_4: state <= STATE_IDLE_3;
        STATE_IDLE_3: state <= STATE_IDLE_2;
        STATE_IDLE_2: state <= STATE_IDLE_1;
        STATE_IDLE_1: state <= STATE_IDLE;

        STATE_RFSH: begin
            state    <= STATE_IDLE_5;
            command  <= CMD_AUTO_REFRESH;
            chip     <= 1;
        end

        STATE_IDLE: begin
            if (refresh_count > cycles_per_refresh) begin // emergency refresh, mainly for downloading rom/paused core
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
                chip          <= 0;
            end 
            else if(ch2_rq) begin
                // CPU channel: absolute priority — it has a fixed consumption
                // deadline and no handshake (stale-data corruption otherwise).
                if (ch2_rnw_1)
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch2_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch2_addr_1[0],ch2_addr_1[0], 1'b1, ch2_addr_1[25:1]};
                chip       <= ch2_addr_1[26];
                saved_data <= {ch2_din_1,ch2_din_1};
                saved_wr   <= ~ch2_rnw_1;
				ch2_saved_a0 <= ch2_addr_1[0];
                ch2_inflight_word <= ch2_addr_1[26:1];
                if (~ch2_rnw_1) begin                          // drop the line at this index
                    c_we <= 1; c_waddr <= ch2_addr_1[CW:1]; c_wdata <= '0;
                end
                ch         <= 1;
                ch2_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
				ch2_ready  <= 0;
            end
            else if(ch1_rq) begin
                if (ch1_rnw_1)
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch1_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch1_addr_1[0],ch1_addr_1[0], 1'b1, ch1_addr_1[25:1]};
                chip       <= ch1_addr_1[26];
                saved_data <= {ch1_din_1,ch1_din_1};
                saved_wr   <= ~ch1_rnw_1;
                ch1_saved_a0 <= ch1_addr_1[0];
                if (~ch1_rnw_1) begin                          // drop the line at this index
                    c_we <= 1; c_waddr <= ch1_addr_1[CW:1]; c_wdata <= '0;
                end
                ch         <= 0;
                ch1_rq     <= 0;
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
                ch1_ready  <= 0;
            end
            else if(ch3_rq) begin
                chip       <= ch3_addr_1[26];
                saved_data <= {ch3_din_1,ch3_din_1};
                saved_wr   <= ~ch3_rnw_1;
				ch3_saved_a0 <= ch3_addr_1[0];
                if (~ch3_rnw_1) begin                          // drop the line at this index
                    c_we <= 1; c_waddr <= ch3_addr_1[CW:1]; c_wdata <= '0;
                end
                ch         <= 2;
                ch3_rq     <= 0;
                if (ch3_rnw) 
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch3_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch3_addr_1[0],ch3_addr_1[0], 1'b1, ch3_addr_1[25:1]};
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
				ch3_ready  <= 0;
            end
            else if(ch4_rq) begin
                chip       <= ch4_addr_1[26];
                saved_data <= {ch4_din_1,ch4_din_1};
                saved_wr   <= ~ch4_rnw_1;
				ch4_saved_a0 <= ch4_addr_1[0];
                if (~ch4_rnw_1) begin                          // drop the line at this index
                    c_we <= 1; c_waddr <= ch4_addr_1[CW:1]; c_wdata <= '0;
                end
                ch         <= 3;
                ch4_rq     <= 0;
                if (ch4_rnw_1)
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch4_addr_1[25:1]};
                else
                    {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {~ch4_addr_1[0],ch4_addr_1[0], 1'b1, ch4_addr_1[25:1]};
                command    <= CMD_ACTIVE;
                state      <= STATE_WAIT;
				ch4_ready  <= 0;
            end
            else if (doRefresh_1) begin
                state         <= STATE_RFSH;
                command       <= CMD_AUTO_REFRESH;
                refresh_count <= 0;
                chip          <= 0;
            end
        end

        STATE_WAIT: state <= STATE_RW1;
        STATE_RW1: begin
            SDRAM_A <= cas_addr;
            if(saved_wr) begin
                command  <= CMD_WRITE;
                SDRAM_DQ <= saved_data;
                if(ch == 0) ch1_ready  <= 1;
                if(ch == 1) ch2_ready  <= 1;
                if(ch == 2) begin ch3_ready  <= 1; ch3_done   <= 1; end
                if(ch == 3) ch4_ready  <= 1;
                state <= STATE_IDLE_2;
            end
            else begin
                command <= CMD_READ;
                state   <= STATE_IDLE_3;
                     if(ch == 0) data_ready_delay1[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 1) data_ready_delay2[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else if(ch == 2) data_ready_delay3[CAS_LATENCY+BURST_LENGTH+1] <= 1;
                else             data_ready_delay4[CAS_LATENCY+BURST_LENGTH+1] <= 1;
            end
        end
      
    endcase

    // valid-bit sweep: runs concurrently with the SDRAM start-up sequence and
    // takes CL cycles; hits are gated on ~c_flush until it completes.  Placed
    // last so it wins the write port over anything above during that window.
    if (c_flush && ~init) begin
        c_we <= 1; c_waddr <= c_flush_idx; c_wdata <= '0;
        c_flush_idx <= c_flush_idx + 1'b1;
        if (&c_flush_idx) c_flush <= 0;
    end

    if (init) begin
        state <= STATE_STARTUP;
        c_flush     <= 1;
        c_flush_idx <= '0;
        ch2_cpend   <= 0;
        c_pend2     <= 0;
        ch2_hit_r   <= 0;
        refresh_count <= startup_refresh_max - sdram_startup_cycles;
    end
end

altddio_out
#(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
)
sdramclk_ddr
(
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(clk),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

endmodule
