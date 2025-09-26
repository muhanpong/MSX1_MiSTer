//
// ddram.v
//
// DE10-nano DDR3 memory interface
//
// Copyright (c) 2017 Sorgelig
//
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
//
// ------------------------------------------
//

// 8-bit version

module ddram (
    input         reset,
	input         DDRAM_CLK,

	input         		DDRAM_BUSY,
	output logic  [7:0] DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input        [63:0] DDRAM_DOUT,
	input               DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic  [7:0] DDRAM_BE,
	output logic        DDRAM_WE,

	input  [27:0] addr,        // 256MB at the end of 1GB
	output  [7:0] dout,        // data output to cpu
	input   [7:0] din,         // data input from cpu
	input         we,          // cpu requests write
	input         rd,          // cpu requests read
	output        ready,       // dout is valid. Ready to accept new read/write.
	output [63:0] dout64, 
	input [255:0] debug_data,
	input         debug_wr	
);

typedef enum logic [2:0] {INIT, IDLE, READ, DEBUG, DEBUG_BLOCK} state_t; 

logic   old_rd, old_we, old_debug_wr;
logic   rd_rq, wr_rq, debug_rq, cache_en;
logic  [7:0] cached;
logic  [7:0] ram_q;
logic [27:0] ram_address;
logic [23:0] debug_address;
logic [63:0] ram_cache;

state_t state;

assign ready      = state == IDLE || DDRAM_BUSY;
assign dout     = ram_q;
assign dout64   = ram_cache;

assign rd_rq    = ~old_rd && rd;
assign wr_rq    = ~old_we && we;
assign debug_rq = ~old_debug_wr && debug_wr;

assign cache_en = (ram_address[27:3] == addr[27:3]) && ((cached & (8'd1 << addr[2:0])) != 8'd0);

always @(posedge DDRAM_CLK)
begin
	
	logic old_reset;
	
	old_reset <= reset;
	old_rd <= rd;
	old_we <= we;
	old_debug_wr <= debug_wr;

	if(old_reset && ~reset) begin
		state  <= INIT;
		cached <= 0;
	end

	if(rd_rq && cache_en) begin
		ram_q <= ram_cache[{addr[2:0], 3'b000} +:8];
	end

	if(!DDRAM_BUSY) begin
		DDRAM_RD <= 0;
		DDRAM_WE <= 0;

		case(state)
			INIT: begin
					DDRAM_BURSTCNT <= 1;
					DDRAM_BE       <= 8'hFF;
					DDRAM_ADDR     <= {5'b00110, 24'h400000}; // RAM at 0x32000000
					DDRAM_DIN      <= {32'd0, 32'hDEAD0000};
					DDRAM_WE 	   <= 1;
					debug_address  <= 24'h420000;
					state <= IDLE;
			end
			IDLE: begin
				if(wr_rq) begin
					DDRAM_BURSTCNT                     <= 1;
					DDRAM_WE 	                       <= 1;
					DDRAM_BE                           <= (8'd1<<addr[2:0]);			
					DDRAM_DIN[{addr[2:0], 3'b000} +:8] <= din;				
					DDRAM_ADDR                         <= {4'b0011, addr[27:3]}; // RAM at 0x30000000

					ram_cache[{addr[2:0], 3'b000} +:8] <= din;
					ram_address                        <= addr;			
					cached                             <= ((ram_address[27:3] == addr[27:3]) ? cached : 8'h00) | (8'd1<<addr[2:0]);
				end

				if(rd_rq && ~cache_en) begin
					DDRAM_BURSTCNT <= 1;
					DDRAM_RD       <= 1;
					DDRAM_BE       <= 8'hFF;
					DDRAM_ADDR     <= {4'b0011, addr[27:3]}; // RAM at 0x30000000
					state          <= READ;
					cached         <= 0;
					ram_address    <= addr;
				end else begin
					if (debug_rq && ~wr_rq) begin
						DDRAM_BURSTCNT <= 4;
						DDRAM_DIN      <= debug_data[63:0];
						DDRAM_ADDR     <= {5'b00110, debug_address}; // RAM at 0x30000000
						DDRAM_BE       <= 8'hFF;
						DDRAM_WE 	   <= 1;
						debug_address  <= debug_address + 24'h1;
						state          <= DEBUG;
					end
				end
			end
			READ: begin
				if(DDRAM_DOUT_READY) begin
					ram_q     <= DDRAM_DOUT[{ram_address[2:0], 3'b000} +:8];
					ram_cache <= DDRAM_DOUT;
					cached    <= 8'hFF;
					state     <= IDLE;
				end	
			end
			DEBUG: begin
					DDRAM_DIN      <= debug_data[{debug_address[1:0], 6'b000000} +:64];
					DDRAM_WE 	   <= 1;
					if (debug_address[1:0] == 3) begin
						if (debug_address[16:0] == 17'h1FFFF) begin
							state <= DEBUG_BLOCK;
						end else begin
							state     <= IDLE;
							debug_address  <= debug_address + 24'h1;
						end
					end else begin
						debug_address  <= debug_address + 24'h1;
					end
			end
			DEBUG_BLOCK: begin
				DDRAM_BURSTCNT <= 1;
				DDRAM_BE       <= 8'hFF;
				DDRAM_ADDR     <= {5'b00110, 24'h400000}; // RAM at 0x32000000
				DDRAM_DIN      <= {32'd0, 8'hDE, 8'hAD, 8'h01, 5'h0, debug_address[19:17]};
				DDRAM_WE 	   <= 1;
				if (debug_address[19:17] == 3'd4) begin
					debug_address  <= 24'h420000;
				end else begin
					debug_address  <= debug_address + 24'h1;
				end
				state <= IDLE;
			end
			default: ;
		endcase
	end
end

endmodule
