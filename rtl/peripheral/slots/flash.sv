module flash (
	input             clk,
	input             clk_sdram,
	input      [22:0] addr,
	input       [7:0] din,
	output      [7:0] dout,
	output            data_valid,
	input             we,
	input             ce,
	input             sdram_ready,
	input             sdram_done,
	output reg [26:0] sdram_addr,
	output reg  [7:0] sdram_din,
	output reg        sdram_req,
	input      [26:0] sdram_offset,
	// One flag used to select two unrelated things at once.  Split because the
	// manufacturer id and the sector map are independent: every part served here
	// is bottom-boot (8 x 8KB then 127 x 64KB) but they are not all AMD.
	input             amd_family,    // AMD/Spansion: manufacturer id 01h + CFI query
	input             boot_sector,   // bottom-boot device: 0x0-0xFFFF is 8 x 8KB
	input      [26:0] erase_limit,   // bytes in the owner's region: an erase may never write past it
	output            debug_erase
);
/*verilator tracing_off*/

	reg [2:0] index;
	reg [7:0] cmd[5];
	
	assign debug_erase = erase;
	
	initial begin
		index = 3'd0;
	end
	
	// CFI query (AMD-family parts only).  Real MegaFlashROM-class drivers probe CFI
	// BEFORE autoselect: write 98h to word offset 55h (byte 0AAh) and expect the
	// "QRY" signature at word offsets 10h/11h/12h (byte 20h/22h/24h).  Without it
	// the read falls through to the ROM copy and the driver reports
	// "Flash support not found, save games will not work" (MSXdev25 GoFigure).
	// Only the 3 signature bytes are served — that is all such probes read.
	reg cfi_state = 0;

	assign dout = ~ce     		     ? 8'hFF :
	              erase              ? 8'h00 :
	              cfi_state          ? (addr[11:1] == 11'h010 ? 8'h51 :   // 'Q'
	                                    addr[11:1] == 11'h011 ? 8'h52 :   // 'R'
	                                    addr[11:1] == 11'h012 ? 8'h59 :   // 'Y'
	                                                            8'h00) :
	 			  ~state             ? 8'hFF :
	              // Manufacturer: ASCII16-X drivers check for AMD/Spansion (01h);
	              // MFRSD software expects the legacy ST id (20h) -> keep it split.
				  addr[2:1] == 2'b00 ? (amd_family  ? 8'h01 : 8'h20) :
                  addr[2:1] == 2'b01 ? 8'h7e :
				  addr[2:1] == 2'b10 ? 8'h00 :
				                       8'h01 ;

	assign data_valid = ce & ~we & (state | erase | cfi_state);

	reg       erase_block = 0;
	reg [7:0] erase_block_num;
	reg       erase_boot = 0;   // 8KB boot-sector erase (M29W640 bottom-boot: 0x0-0xFFFF = 8x8KB)
	// Sector base/length of the pending erase (used by the bounds clamp below).
	wire [26:0] erase_base = erase_boot ? (27'(erase_block_num) << 13) : (27'(erase_block_num) << 16);
	wire [15:0] erase_span = erase_boot ? 16'h1FFF : 16'hFFFF;   // write_cnt = bytes-1
//	reg       erase_chip = 0;

	reg old_we;
	reg state;
	always @(posedge clk) begin
		old_we <= we;
	end
	
	always @(posedge clk) begin
		if (clk) begin
		   erase_block <= 0;
//			erase_chip  <= 0;
			if (~valid) index <= 0;
			if (we & ~old_we & ce) begin
				cmd[index] <= din;
				index <= index + 1'b1;
				if (int_valid5) begin
					index <= 0;
					// All three carts this instance serves are BOTTOM-BOOT parts with
					// identical geometry -- 8 x 8KB then 127 x 64KB -- per openMSX's
					// chip table: ASCII16X = S29GL064S70TFI040 (RomAscii16X.cc:25),
					// Yamanooto = S29GL064N90TFI04 (Yamanooto.cc:38), MFRSD-SD =
					// M29W640GB (MegaFlashRomSCCPlusSD.cc:274).  They differ only in
					// manufacturer id (AMD/AMD/STM), which is the amd_family half.
					// So the address-based index below is right for everyone; the old
					// defect was that erase_boot -- the <<13 scaling -- was gated on
					// the ASCII16X path alone, leaving MFRSD with the correct 8KB
					// index scaled as if it were a 64KB one (flash 0x2000 erased
					// 0x10000-0x1FFFF and left the target sector intact).
					if (din == 8'h30) begin
						erase_block <= 1;
						erase_boot  <= boot_sector & ~(addr > 23'hFFFF);
						erase_block_num <= (addr > 23'hFFFF) ? {1'b0, addr[22:16]}
						                                     : {5'd0, addr[15:13]};
					end
					//if (din == 8'h10) erase_chip  <= 1;
				end
				if (addr[11:1] != (index == 3'd1 | index == 3'd4 ? 11'h2aa : 11'h555) & ~(din == 8'hF0 & index == 0) ) begin
					index <= 0;
				end	
			end
			// CFI query enter/exit.  Enter on 98h at the CFI entry offset (ASCII16X
			// only); any F0h (read-array/reset) or an autoselect leaves CFI mode.
			// The 98h write itself cannot disturb the command FSM above: cmd[0]=98h
			// is not in the int_valid1 whitelist and the offset check clears index.
			if (we & ~old_we & ce) begin
				if (amd_family  & din == 8'h98 & addr[11:1] == 11'h055) cfi_state <= 1'b1;
				else if (din == 8'hF0)                                  cfi_state <= 1'b0;
			end
			if (reset) begin
				index <= 0;
				state <= 0;
				cfi_state <= 1'b0;
			end
			if (ident) begin
				index <= 0;
				state <= 1;
				cfi_state <= 1'b0;
			end
		end
	end
	
	//TODO potřebuji valid ?
	wire reset            = valid & int_valid1 & cmd[0] == 8'hF0;
	wire doubleProgram    = valid & int_valid1 & cmd[0] == 8'h50;
	wire quadrupleProgram = valid & int_valid1 & cmd[0] == 8'h56;
	wire bytePrgram       = valid & int_valid3 & cmd[2] == 8'hA0;
	wire ident            = valid & int_valid3 & cmd[2] == 8'h90;
    


	wire int_valid1 =              index > 3'd0 & (cmd[0] == 8'hF0 | cmd[0] == 8'h50 | cmd[0] == 8'h56 | cmd[0] == 8'hAA);
	wire int_valid2 = int_valid1 & index > 3'd1 & (cmd[1] == 8'h55);
	wire int_valid3 = int_valid2 & index > 3'd2 & (cmd[2] == 8'h80 | cmd[2] == 8'h90 | cmd[2] == 8'hA0);
	wire int_valid4 = int_valid3 & index > 3'd3 & (cmd[3] == 8'hAA);
	wire int_valid5 = int_valid4 & index > 3'd4 & (cmd[4] == 8'h55);	
	
	wire valid      = index == 3'd1 ? int_valid1 :
	                  index == 3'd2 ? int_valid2 :
					  index == 3'd3 ? int_valid3 :
					  index == 3'd4 ? int_valid4 :
					  index == 3'd5 ? int_valid5 :
					                  1'b0;
	
   //wire [7:0] num1 = {5'd0,addr[15:13]};
   //wire [7:0] num2 = addr[22:16] + 7;

	reg erase;
//write to SDRAM
	always @(posedge clk) begin
		reg sdram_need_wr;
		reg [15:0] write_cnt;
		
		if (sdram_req & sdram_done) begin
			sdram_req <= 0; //request se zpracovava
			write_cnt <= write_cnt - 1'b1;
			if (erase) begin
				if (write_cnt == 0) begin
					erase <= 0;
					write_cnt <= 0;
				end else begin
				//	write_cnt <= write_cnt - 1'b1;
				//if (erase) begin
					sdram_addr <= sdram_addr + 1'b1;
					sdram_need_wr <= 1;
				end
			end
		end
		if (sdram_need_wr & sdram_ready & ~sdram_req) begin
			sdram_need_wr <= 0;
			sdram_req <= 1;
		end
		if (erase_block) begin
			// BOUNDS CLAMP: the erase address comes straight from the cart's bank
			// register, so a cart that erases above its loaded image (e.g. a 7.86MB
			// image on an 8MB chip saving into the top sectors) would otherwise fill
			// 0xFF over whatever region follows this one in SDRAM — main RAM / SUB
			// ROM.  Skip a sector that starts past the region, and truncate one that
			// straddles the end.  Reads there already return 0xFF, so the cart still
			// sees an "erased" sector; only the corruption is removed.
			if (erase_base < erase_limit) begin
				write_cnt <= (27'(erase_span) <= (erase_limit - erase_base)) ? erase_span
				                                                            : 16'(erase_limit - erase_base - 27'd1);
				sdram_din <=  8'hFF;
				sdram_need_wr <= 1;
				sdram_addr <= sdram_offset + erase_base;
				erase <= 1;
			end
		end else
		// `write_cnt > 0` is NOT a safe proxy for "a program is in progress": the
		// erase loop borrows the same counter (it is loaded with erase_span above),
		// so without `~erase` a single ordinary CPU write during the 64KB fill
		// retargets sdram_addr and substitutes its own byte for 0xFF -- measured
		// 65528 of 65536 bytes written as the CPU's data, running past the sector
		// end, and the erase_limit clamp is bypassed because it only runs in the
		// one erase_block cycle.  A driver holds WREN set across the erase by
		// construction, so gating flash_rq on WREN does not cover this.
		// Real AMD parts likewise ignore writes during an erase (bar erase-suspend).
		if ((quadrupleProgram | write_cnt > 0) & we & ~old_we & ce & ~erase) begin
			//Zkontrolovat zda je writable sector num1 a num2 vypocet
			sdram_addr <= sdram_offset + 27'(addr);
			sdram_din <= din;
			if (sdram_ready) begin
				sdram_req <= 1;
			end else begin
				sdram_need_wr <= 1;
			end
			if (quadrupleProgram) write_cnt <= 4;
			if (doubleProgram) write_cnt <= 2;
			if (bytePrgram) write_cnt <= 1;
			if (erase_block) write_cnt <= 16'hFFFF;
		end
	end
	
endmodule
