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
	// "this CPU write is program DATA, not a command cycle".  The command FSM
	// below decodes EVERY write in the cart window, and the unlock-address
	// compare is only addr[11:1] -- correct for the part (openMSX AmdFlash masks
	// (addr>>1)&0x7FF the same way; the upper bits really are don't-care), but it
	// means a data byte whose value is a command opener and whose address happens
	// to alias 0x555/0x2AA restarts the sequence and eats the NEXT command.
	// A real part cannot do that: the data cycles of a program are consumed
	// positionally, not re-decoded (openMSX checkCommandProgramHelper keeps its
	// anchored cmd[] buffer while cmd.size() < cmdSeq.size()+numBytes).
	// Carts that run their own program FSM (ASCII16X, Yamanooto) already know
	// which write is data and say so here; the MFRSD path derives it internally
	// from prog_cnt/prog_grp below.
	input             data_phase,
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
			if (we & ~old_we & ce & cmd_inhibit) begin
				// DATA cycle: consume it, never decode it.  This is the whole fix
				// -- without it a data byte in {50,56,AA} landing on an aliased
				// unlock offset becomes cmd[0], survives the `~valid` sweep above,
				// and the NEXT write (the following group's 0x56) lands in cmd[1],
				// so quadrupleProgram never asserts and that whole group is lost.
				// (F0 was harmless even before: it self-heals via `reset` below.)
				if (prog_start) begin
					prog_cnt <= 3'd3;              // three more bytes after this one
					prog_grp <= addr[22:2];
					// The command has been consumed; drop index so quadrupleProgram
					// cannot stay asserted and swallow the next group's command.
					index    <= 0;
				end else if (prog_more) begin
					prog_cnt <= prog_cnt - 1'b1;
				end
			end else if (we & ~old_we & ce) begin
				// Not data -> a command cycle.  Any half-finished program phase
				// ends here: this covers both a driver that abandoned a group and
				// the erase sequence, whose six writes all arrive on this path.
				prog_cnt <= 3'd0;
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
			// This is a SEPARATE if from the command FSM above, so it needs its own
			// data-phase guard: entry is a single unsequenced write of 0x98, so a
			// program-data byte of that value on an aliased offset would otherwise
			// hijack the whole read window (data_valid below then masks the ROM).
			if (we & ~old_we & ce & ~cmd_inhibit) begin
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
	wire quadrupleProgram = valid & int_valid1 & cmd[0] == 8'h56;
	// doubleProgram (0x50) and bytePrgram (0xA0) used to be decoded here but could
	// never fire: the write gate was `(quadrupleProgram | write_cnt > 0)` and they
	// could only set write_cnt from INSIDE that gate.  That was not an oversight --
	// ascii16x.sv:24 and yamanooto.sv:202-207 say so and run their own byte-program
	// FSM, driving the data byte through msx_slots' prog_we with the mapper's
	// in-bounds check.  Deleted rather than revived so that touching the gate here
	// cannot resurrect a second, unchecked write path.  0x50 stays in int_valid1
	// and 0xA0 in int_valid3 below: those are real M29W640 openers and dropping
	// them would only paper over one trigger value of the bug fixed above.
	wire ident            = valid & int_valid3 & cmd[2] == 8'h90;
    


	// ---- program data phase (this instance's own 0x56 path) -------------------
	// prog_cnt = data bytes still owed AFTER the current one.  It is decremented
	// per accepted CPU write, NOT per SDRAM completion -- the old counter did the
	// latter, so an SDRAM stall could let a 5th write in.
	// prog_grp closes the phase by ADDRESS as well as by count.  M29W640's
	// quadruple program requires the four bytes to differ only in A1/A0, so
	// addr[22:2] is invariant across a group by spec, not by luck.  A driver that
	// abandons a group mid-way therefore closes the phase on its very next write
	// instead of wedging the FSM -- which matters because flash.sv has no reset
	// port at all (msx_slots.sv's reset is not connected here).
	reg  [2:0]  prog_cnt = 3'd0;
	reg  [20:0] prog_grp;
	wire        prog_start = quadrupleProgram & ~erase;        // this write is data byte 1
	wire        prog_more  = (prog_cnt != 3'd0) & (addr[22:2] == prog_grp);
	wire        prog_data  = prog_start | prog_more;           // flash.sv owns this write
	// Commands are not decoded while any owner says "this is data".
	wire        cmd_inhibit = prog_data | data_phase;

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
		// Erase fill only.  The program byte count is prog_cnt above, counted per
		// CPU write; this one counts SDRAM completions and the two must not be the
		// same register.  Loaded with erase_span = bytes-1, so it retires exactly
		// erase_span+1 bytes (0xFFFF -> 0 inclusive = 64KB, 0x1FFF = 8KB).
		reg [15:0] erase_cnt;

		if (sdram_req & sdram_done) begin
			sdram_req <= 0; //request se zpracovava
			if (erase) begin
				erase_cnt <= erase_cnt - 1'b1;
				if (erase_cnt == 0) begin
					erase <= 0;
					erase_cnt <= 0;
				end else begin
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
			// The `<=` is deliberate but only safe because of an alignment
			// invariant that is worth stating: erase_limit is either 27'(size)<<14
			// or 27'h800000, so a multiple of 0x4000, and erase_base is a multiple
			// of 0x10000 (or 0x2000 for a boot sector).  The remainder is therefore
			// never exactly erase_span (0xFFFF / 0x1FFF), which is the one input
			// where `<=` would write span+1 bytes and overrun by one.
			if (erase_base < erase_limit) begin
				erase_cnt <= (27'(erase_span) <= (erase_limit - erase_base)) ? erase_span
				                                                            : 16'(erase_limit - erase_base - 27'd1);
				sdram_din <=  8'hFF;
				sdram_need_wr <= 1;
				sdram_addr <= sdram_offset + erase_base;
				erase <= 1;
			end
		end else
		// KEEP the `~erase` term even though the counters are now separate.  Its
		// reason is NOT the shared counter: the erase_block branch above has
		// priority and unconditionally retargets sdram_addr / sdram_din, so a CPU
		// write accepted during the 64KB fill hijacks the fill -- measured 65528 of
		// 65536 bytes written as the CPU's data, running past the sector end, with
		// the erase_limit clamp bypassed because it only runs in the one
		// erase_block cycle (fixed in c361934).  A driver holds WREN set across the
		// erase by construction, so gating flash_rq on WREN does not cover this.
		// Real AMD parts likewise ignore writes during an erase (bar erase-suspend).
		//
		// Only this instance's own program path writes here.  data_phase means
		// "the MAPPER is doing the program" (ASCII16X / Yamanooto drive the byte
		// through msx_slots' prog_we), so it must NOT open this gate or the byte
		// would be written twice, and without the mapper's in-bounds check.
		if (prog_data & we & ~old_we & ce & ~erase) begin
			sdram_addr <= sdram_offset + 27'(addr);
			sdram_din <= din;
			if (sdram_ready) begin
				sdram_req <= 1;
			end else begin
				sdram_need_wr <= 1;
			end
		end
	end
	
endmodule
