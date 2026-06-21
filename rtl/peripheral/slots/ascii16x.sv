// RomAscii16X mapper  (+ volatile JEDEC byte-program emulation, flash.sv NOT involved)
//
// Banks:
//   bankRegs[0]: 0x4000-0x7FFF and 0xC000-0xFFFF  (addr[14]=1 -> ~addr[14]=0)
//   bankRegs[1]: 0x8000-0xBFFF and 0x0000-0x3FFF  (addr[14]=0 -> ~addr[14]=1)
//
// Bank register write: any address with addr[13]=1
//   addr[12]=0 -> update bankRegs[0]
//   addr[12]=1 -> update bankRegs[1]
//   12-bit bank number: {addr[11:8], din[7:0]}
//
// Volatile flash detection (e.g. Neon Horizon "16X" build):
//   The cart probes for writable flash with the AMD/JEDEC byte-program command:
//     AA @ off[11:1]=0x555, 55 @ off[11:1]=0x2AA, A0 @ off[11:1]=0x555, then a
//     data write to the target. We detect that exact sequence here and let ONLY
//     that one data write reach the SDRAM ROM copy (via prog_we -> msx_slots).
//   Volatile (SDRAM is reloaded on ROM reload); never touches the shared
//   flash.sv module, so MFRSD is completely unaffected.

module cart_ascii16x
(
    input               clk,
    input               reset,
    input        [24:0] rom_size,
    input        [15:0] cpu_addr,
    input         [7:0] din,
    input               cpu_mreq,
    input               cpu_wr,
    input               cs,
    input               cart_num,
    output              mem_unmaped,
    output       [24:0] mem_addr,
    output       [22:0] flash_addr,
    output              flash_rq,
    output              prog_we      // this CPU write is a validated byte-program -> write SDRAM
);
/*verilator tracing_off*/
logic [11:0] bankRegs[2][2]; // [cart_num][bank_index]

always @(posedge clk) begin
    if (reset) begin
        bankRegs[0] <= '{12'd0, 12'd0};
        bankRegs[1] <= '{12'd0, 12'd0};
    end else begin
        if (cs & cpu_mreq & cpu_wr & cpu_addr[13])
            bankRegs[cart_num][cpu_addr[12]] <= {cpu_addr[11:8], din};
    end
end

wire        bank_index = ~cpu_addr[14];
wire [11:0] bank       = bankRegs[cart_num][bank_index];
wire [24:0] ram_addr   = 25'({bank, cpu_addr[13:0]});

assign mem_addr    = ram_addr;
assign mem_unmaped = cs & (ram_addr >= rom_size);
assign flash_addr  = 23'(ram_addr);
assign flash_rq    = cs;

// ---- Volatile JEDEC AMD byte-program FSM (ASCII16X only) -------------------
wire        cart_wr  = cs & cpu_mreq & cpu_wr;          // any write to this cart
wire        unlock_a = (cpu_addr[11:1] == 11'h555);     // unlock cycles 1 & 3 offset
wire        unlock_b = (cpu_addr[11:1] == 11'h2AA);     // unlock cycle 2 offset

logic       old_cart_wr;
wire        wr_rise = cart_wr & ~old_cart_wr;           // one event per CPU write
wire        wr_fall = ~cart_wr & old_cart_wr;

logic [1:0] jedec_st;       // 0 idle, 1:AA seen, 2:55 seen, 3:A0 seen (armed)
logic       prog_arm;       // current CPU write is the validated program write

always @(posedge clk) begin
    if (reset) begin
        jedec_st    <= 2'd0;
        prog_arm    <= 1'b0;
        old_cart_wr <= 1'b0;
    end else begin
        old_cart_wr <= cart_wr;
        if (wr_fall) prog_arm <= 1'b0;                  // program write finished
        if (wr_rise & ~cpu_addr[13]) begin              // command/data window only
            case (jedec_st)
                2'd0: jedec_st <= (din == 8'hAA & unlock_a) ? 2'd1 : 2'd0;
                2'd1: jedec_st <= (din == 8'h55 & unlock_b) ? 2'd2 :
                                  (din == 8'hAA & unlock_a) ? 2'd1 : 2'd0;
                2'd2: jedec_st <= (din == 8'hA0 & unlock_a) ? 2'd3 : 2'd0;
                2'd3: begin                              // this write = byte-program data
                    prog_arm <= ~mem_unmaped;            // only program in-bounds
                    jedec_st <= 2'd0;
                end
            endcase
        end
        // bank-register writes (cpu_addr[13]=1) never advance the JEDEC FSM
    end
end

assign prog_we = prog_arm & cart_wr;                    // held across the program write

endmodule
