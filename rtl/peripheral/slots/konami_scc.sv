module cart_konami_scc
(
   input            clk,
   input            reset,
   input     [24:0] mem_size,
   input     [15:0] cpu_addr,
   input      [7:0] din,
   input            cpu_mreq,
   input            cpu_wr,
   input            cpu_rd,
   input            cs,
   input            cart_num,
   input      [1:0] subslot,       // of the addressed page: bank/mode state is per (cart slot, subslot)
   input            sccDevice,     // 0-SCC 1-SCC+, of the cart being ADDRESSED.
                                   // Correct for the register-write conditions below,
                                   // which only fire during an access to that cart.
   input      [1:0] scc2_slot,     // SCC+ present in slot {B,A}.  Static per slot, so it
                                   // is the one safe to gate scc_mode with (see below).
   output           mem_unmaped,
   output    [20:0] mem_addr,
   output           scc_req,
   output    [1:0]  scc_mode
);
   /*verilator tracing_off*/
   // State is per (cart slot, subslot), not per cart slot: an expanded slot can hold
   // a KonamiSCC game in one subslot and an SCC+ cart in another, and on real
   // hardware those are two chips with two register sets.  idx = {cart_num, subslot}.
   // The SOUND chip is still one IKASCC per cart slot (scc_sound.sv), so two
   // SCC-family devices in one slot share it -- documented limitation.
   wire  [2:0] idx = {cart_num, subslot};
   logic [7:0] sccMode[8];
   logic [7:0] bank[8][4];
   logic [7:0] sccEnable;
   always @(posedge clk) begin
      if (reset) begin
         for (int i = 0; i < 8; i++) begin
            bank[i]    <= '{'h00, 'h01, 'h02, 'h03};
            sccMode[i] <= 8'h00;
         end
         sccEnable   <= 8'h00;
      end else begin
         // openMSX MSXSCCPlusCart::writeMem() is a priority chain with early returns:
         //   mode register (0xBFFE/F) -> return
         //   segment in RAM mode      -> write RAM, return   <-- suppresses the bank window
         //   bank window              -> setMapper()
         // While a segment is RAM, a store into that segment's 2KB bank window is plain
         // data and must NOT reach the bank register.  Snatcher (1988) depends on this:
         // it sets mode 0x20 to program the bank, then mode 0x30 (all RAM) and copies 8KB
         // across 0x8000-0x9FFF, crossing 0x9000-0x97FF.  SD Snatcher [SCC+] does the same
         // at 0xB1AA6.  See docs/sccplus_spec.md S8-1.
         if (cs & cpu_mreq & cpu_wr & ~en_ram) begin

            case (cpu_addr[15:11])
               5'b01010: // 5000-57ffh
                     bank[idx][2'd0] <= din;
               5'b01110: // 7000-77ffh
                     bank[idx][2'd1] <= din;
               5'b10010: // 9000-97ffh
                     bank[idx][2'd2] <= din;
               5'b10110: // b000-b7ffh
                     bank[idx][2'd3] <= din;
               default: ;
            endcase
         end
         // The mode register has top priority in openMSX and is reached even when the
         // segment is RAM, so it is decoded outside the ~en_ram gate above.
         if (cs & cpu_mreq & cpu_wr) begin
            if ({cpu_addr[15:1],1'b0} == 16'hBFFE & sccDevice)  sccMode[idx] <= din;
            if (cpu_addr[15:11]       == 5'b10010 & ~sccDevice & ~en_ram) sccEnable[idx] <= din[5:0] == 6'h3F;
         end
      end
   end

   // ---- CHIP MODE (sound), not window visibility (mapper) --------------------
   // These are two different things and must not be folded together:
   //
   //   chip mode        openMSX MegaFlashRomSCCPlusSD.cc:621
   //                    scc.setMode((value & 0x20) ? Plus : Compatible)   <- bit5 ONLY
   //   window visible   :503  (sccMode & 0x20) && (sccBanks[3] & 0x80)
   //                    :505  !(sccMode & 0x20) && ((sccBanks[2] & 0x3F) == 0x3F)
   //
   // scc_mode drives IKASCC's i_SCCP_MODE, which the audio path consumes
   // CONTINUOUSLY (IKASCC_player_s.v:309 latches ch5's waveform from ch4's shared
   // RAM unless the mode reads Plus).  Folding bank3 bit7 in here meant that
   // paging a bank without bit7 into 0xA000-0xBFFF during playback flipped the
   // CHIP to Compatible and ch5 audibly became a ch4 mirror.  The window term
   // belongs in scc_req below, and stays there.  (docs/TODO_scc_divergences.md D5;
   // cc183c9 fixed the address half of the same mistake and left this half.)
   //
   // Per CART SLOT, because scc_sound has one IKASCC per slot: Plus if any subslot
   // of that slot is in Plus.
   // Gated with scc2_slot, NOT sccDevice.  sccDevice is |(cart_device[cart_num] & DEV_SCC2)
   // and cart_num is the ADDRESSED page's cart, so it collapses to 0 the moment the CPU
   // touches anything that is not an SCC+ cart -- an FM-PAC in a neighbouring subslot, or
   // simply the other cart slot.  Both slots' mode bits then dropped to Compatible mid-
   // playback and ch5 became a ch4 mirror: the same D5 defect this comment block warns
   // about, reached through a third route after cc183c9 fixed the address half and the
   // bank-bit half was kept out.  Hardware: SCC+ crackled whenever FM-PAC shared the slot.
   assign scc_mode = { scc2_slot[1] & |{sccMode[4][5], sccMode[5][5], sccMode[6][5], sccMode[7][5]},
                       scc2_slot[0] & |{sccMode[0][5], sccMode[1][5], sccMode[2][5], sccMode[3][5]} };
   // Writes are suppressed while the segment is RAM (openMSX + real SCC+ agree).
   // Reads are deliberately NOT gated: openMSX cites Sean Young for read-through and
   // issue #1964 is still open on it -- mfrsd.sv makes the same choice.
   // cs (= mapper == MAPPER_KONAMI_SCC) qualifies this.  Without it scc_req was
   // decoded from the ADDRESS and the register state alone, so any access to
   // 0xB800-0xB8FF or 0x9800-0x9FFF -- ordinary RAM addresses a program touches
   // constantly -- raised it.  msx_slots feeds the result straight into
   // scc_sound's cs, where scc_cs_A = ~cart_num & cs: every non-cartridge page
   // has cart_num == 0, so the stray CS landed on SLOT A's IKASCC and never on
   // slot B's.  That is why slot A crackled while slot B stayed clean, why it
   // only showed with SCC+ (the 0xB8 window opens in Plus mode), and why it
   // varied by machine pack (different RAM layouts hit those addresses at
   // different rates).  yamanooto.sv:130 and mfrsd.sv:102 already gate theirs.
   assign scc_req  = cs & cpu_mreq & (cpu_rd | (cpu_wr & ~en_ram)) &
                     ((sccMode[idx][5] & bank[idx][3][7] & cpu_addr[15:8] == 8'hB8)                    ||   //SCC+
                     (~sccMode[idx][5] & bank[idx][2][5:0] == 6'b111111 & cpu_addr[15:11] == 5'b10011) ||   //SCC+ mode SCC
                     (~sccDevice && sccEnable[idx] & cpu_addr[15:11] == 5'b10011));                              //SCC

   wire maped, en_ram;
   wire [7:0] bank_base;
   assign {maped, en_ram, bank_base} = cpu_addr[15:13] == 3'b010 ? {1'b1,(sccMode[idx][4] | sccMode[idx][0]                         ),bank[idx][0]} :   //4000 - 5FFF
                                       cpu_addr[15:13] == 3'b011 ? {1'b1,(sccMode[idx][4] | sccMode[idx][1]                         ),bank[idx][1]} :   //6000 - 7FFF
                                       cpu_addr[15:13] == 3'b100 ? {1'b1,(sccMode[idx][4] | (sccMode[idx][5] & sccMode[idx][2])),bank[idx][2]} :   //8000 - 9FFF
                                       cpu_addr[15:13] == 3'b101 ? {1'b1,(sccMode[idx][4]                                                ),bank[idx][3]} :   //A000 - BFFF
                                                               10'd0 ;    

   wire modereg_wr = cpu_wr & cpu_mreq & sccDevice & ({cpu_addr[15:1],1'b0} == 16'hBFFE);
   assign mem_unmaped = cs & (scc_req  | ~maped | modereg_wr | (cpu_wr & cpu_mreq & ~en_ram));
   assign mem_addr = {bank_base, cpu_addr[12:0]};

endmodule
       