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
   input            sccDevice,     // 0-SCC 1-SCC+
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

   // Chip mode per CART SLOT (the consumer, scc_sound, has one IKASCC per slot):
   // SCC+ if any subslot of that slot is in SCC+ mode.
   assign scc_mode = { sccDevice & |{sccMode[4][5] & bank[4][3][7], sccMode[5][5] & bank[5][3][7],
                                    sccMode[6][5] & bank[6][3][7], sccMode[7][5] & bank[7][3][7]},
                       sccDevice & |{sccMode[0][5] & bank[0][3][7], sccMode[1][5] & bank[1][3][7],
                                    sccMode[2][5] & bank[2][3][7], sccMode[3][5] & bank[3][3][7]} };
   // Writes are suppressed while the segment is RAM (openMSX + real SCC+ agree).
   // Reads are deliberately NOT gated: openMSX cites Sean Young for read-through and
   // issue #1964 is still open on it -- mfrsd.sv makes the same choice.
   assign scc_req  = cpu_mreq & (cpu_rd | (cpu_wr & ~en_ram)) &
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
       