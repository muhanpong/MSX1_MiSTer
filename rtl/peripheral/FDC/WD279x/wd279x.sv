// WD279x FDC
//
// Copyright (c) 2024-2025 Molekula
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Redistributions in synthesized form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// * Neither the name of the author nor the names of other contributors may
//   be used to endorse or promote products derived from this software without
//   specific prior written agreement from the author.
//
// * License is granted for non-commercial use only.  A fee may not be charged
//   for redistributions as source code or in synthesized/hardware form without
//   specific prior written agreement from the author.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//

module wd279x #(parameter WD279_57=1, parameter sysCLK) 
(
	input  logic        clk,         // sys clock
	input  logic        MRn,	      // master reset
	input  logic        CSn,		  // i/o enable
	input  logic        REn,         // i/o read
	input  logic        WEn,         // i/o write
	input  logic  [1:0] A,           // i/o port addr
	input  logic  [7:0] DIN,         // i/o data in
	output logic  [7:0] DOUT,  		// i/o data out
	output logic        DRQ,  		// DMA request
	output logic        INTRQ,

	output logic 		STEPn,
	output logic 		SDIRn,
	input  logic 		INDEXn,
	input  logic 		TRK00n,
	input  logic        READYn,
	input  logic        WPROTn,
	output logic        HLD,
	output logic        SSO,
	input  logic        RAWRDn,
	input  logic        DDENn
);

	localparam A_COMMAND         = 0;
	localparam A_STATUS          = 0;
	localparam A_TRACK           = 1;
	localparam A_SECTOR          = 2;
	localparam A_DATA            = 3;

	logic [7:0] reg_cmd, reg_track, reg_sector, reg_data, status;
	logic       command_start;
	logic       busy;
	logic       INTRQ_ACK;

	assign busy = command_start | status[0];
	assign INTRQ = INTRQ_I | INTRQ_II || INTRQ_IV;
	assign status = status_command_type_I | status_command_type_II | status_command_type_IV;
	assign HLD = HLD_I | HLD_II ;
	always_comb begin
		DOUT = '1;
		INTRQ_ACK = 0;
		if (!(REn || CSn))
			case (A)
				A_DATA:   DOUT = reg_data;
				A_STATUS: begin DOUT = status; INTRQ_ACK = 1; end
				A_SECTOR: DOUT = reg_sector;
				A_TRACK:  DOUT = reg_track;
			endcase
	end

	logic last_REn, last_WEn, write_rq, read_rq;
	always_ff @(posedge clk) begin
		last_REn <= REn;
		last_WEn <= WEn;
	end

	assign write_rq = ~CSn && last_WEn && ~WEn;
	assign read_rq  = ~CSn && last_REn && ~REn;
	
	
	//Command register
	always_ff @(posedge clk) begin
		command_start <= 0;
		if (~MRn)	begin
			reg_cmd <= 8'h03;
			command_start <= 1;
		end else begin
			if (write_rq && A == A_COMMAND) begin
				if (!busy || DIN[7:4] == 4'hD) begin
					//$display("SET CMD %X", DIN);
					reg_cmd <= DIN;
					command_start <= 1;
				end
			end
		end
	end

	//Track register
	always_ff @(posedge clk) begin
		if (~MRn)	begin
			reg_track <= 0;
		end	else begin
			if (write_rq && A == A_TRACK && !busy ) begin
				reg_track <= DIN;
				//$display("SET TRACK %X", DIN);
			end
			if (reg_track_write) 
				reg_track <= reg_track_out;
		end
	end

	//Sector register
	always_ff @(posedge clk) begin
		if (~MRn)	begin
			reg_sector <= 1;
		end	else begin
			if (write_rq && A == A_SECTOR && !busy ) begin
				reg_sector <= DIN;
				//$display("SET SECTOR %X", DIN);
			end
			if (reg_sector_write) 
				reg_sector <= reg_sector_out;
		end
	end

	//Data register Používá třeba seek
	//logic reg_lost_data;		//TODO: Implement lost data
	always_ff @(posedge clk) begin
		if (~MRn)	begin
			reg_data <= 0;
	//		reg_lost_data <= 0;
		end	else begin
			if (write_rq && A == A_DATA) begin
				//$display("SET DATA  %X", DIN);
				reg_data <= DIN;
			end
			
			if (reg_data_write_I) begin
				reg_data <= reg_data_out_I;
			end

			if (enable_write_reg_data_II && fdd_rx) begin
	//			if (DRQ) begin
	//				reg_lost_data <= 1;
	//			end
				reg_data <= fdd_data;
				DRQ <= 1;
			end
			
			if (read_rq && A == A_DATA) begin
				DRQ <= 0;
			end
		end
	end

logic [7:0] reg_track_out;
logic       reg_track_write;
logic [7:0] reg_data_out_I;
logic       reg_data_write_I;
logic [7:0] status_command_type_I;
logic       INTRQ_I;
logic 		HLD_I;
wd279x_command_I command_I (
	.clk(clk),
	.msclk(msclk),
	.interrupt(interrupt),
	.MRn(MRn),
	.command(reg_cmd),
	.command_start(command_start),
	.status(status_command_type_I),
	.reg_data(reg_data),
	.reg_data_out(reg_data_out_I),
	.reg_data_write(reg_data_write_I),
	.track(reg_track_write ? reg_track_out : reg_track),
	.track_out(reg_track_out),
	.track_write(reg_track_write),
	.IDAM_valid(IDAM_valid),
	.IDAM_data(IDAM_data),
	.STEPn(STEPn),
	.SDIRn(SDIRn),
	.INDEXn(INDEXn),
	.READYn(READYn),
	.WPROTn(WPROTn),
	.TRK00n(TRK00n),
	.HLD(HLD_I),
	.INTRQ(INTRQ_I),
	.INTRQ_ACK(INTRQ_ACK)
);

logic [7:0] reg_sector_out;
logic       reg_sector_write;
logic [7:0] status_command_type_II;
logic       INTRQ_II;
logic       enable_write_reg_data_II;
logic       HLD_II;
wd279x_command_II #(.WD279_57(WD279_57)) command_II (
	.clk(clk),
	.msclk(msclk),
	.interrupt(interrupt),
	.MRn(MRn),
	.command(reg_cmd),
	.command_start(command_start),
	.status(status_command_type_II),
	.track(reg_track),
	.sector(reg_sector_write ? reg_sector_out : reg_sector),
	.sector_out(reg_sector_out),
	.sector_write(reg_sector_write),
	.INDEXn(INDEXn),
	.READYn(READYn),
	.WPROTn(WPROTn),
	.SSO(SSO),
	.HLD(HLD_II),
	.INTRQ(INTRQ_II),
	.INTRQ_ACK(INTRQ_ACK),
	.DRQ(DRQ),
	.enable_write_reg_data(enable_write_reg_data_II),
	.IDAM_valid(IDAM_valid),
	.IDAM_data(IDAM_data),
	.DAM_valid(DAM_valid),
	.DAM_deleted(DAM_deleted),
	.DAM_CRC_valid(DAM_CRC_valid),
	.data_rx(fdd_rx)
);

logic       INTRQ_IV;
logic       interrupt;
logic [7:0] status_command_type_IV;
wd279x_command_IV  command_IV (
	.clk(clk),
	.interrupt(interrupt),
	.MRn(MRn),
	.command(reg_cmd),
	.command_start(command_start),
	.status(status_command_type_IV),
	.INTRQ(INTRQ_IV),
	.INTRQ_ACK(INTRQ_ACK),
	.INDEXn(INDEXn),
	.READYn(READYn),
	.WPROTn(WPROTn),
	.TRK00n(TRK00n),
	.HLD(HLD)
);

	
logic  [7:0] IDAM_data[6];
logic  [7:0] fdd_data;
logic        fdd_rx;
logic        IDAM_valid;
logic        DAM_valid;
logic        DAM_deleted;
logic        DAM_CRC_valid;

wd279x_demodulator #(.sysCLK(sysCLK)) modulator (
	.clk(clk),
	.MRn(MRn),
	.INDEXn(INDEXn),
	.DDENn(DDENn),
	.RAWRDn(RAWRDn),
	.IDAM_data(IDAM_data),
    .fdd_data(fdd_data),
    .fdd_rx(fdd_rx),
    .IDAM_valid(IDAM_valid),
	.DAM_valid(DAM_valid),
	.DAM_deleted(DAM_deleted),
    .DAM_CRC_valid(DAM_CRC_valid)
);

logic msclk;
clockEnabler #(.clkFreq(sysCLK), .targetFreq(1000)) FDD_MS(
	.clk(clk),
	.en(msclk)
);

endmodule

