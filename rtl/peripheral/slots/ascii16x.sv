// RomAscii16X mapper  (+ volatile JEDEC byte-program emulation; erase via flash.sv)
//
// Banks:
//   bankRegs[0]: 0x4000-0x7FFF and 0xC000-0xFFFF  (addr[14]=1 -> ~addr[14]=0)
//   bankRegs[1]: 0x8000-0xBFFF and 0x0000-0x3FFF  (addr[14]=0 -> ~addr[14]=1)
//
// Bank register write: an address with addr[13]=1 ...
//   addr[12]=0 -> update bankRegs[0]
//   addr[12]=1 -> update bankRegs[1]
//   12-bit bank number: {addr[11:8], din[7:0]}
//   ... EXCEPT when the write is a recognized JEDEC flash-command cycle (see below):
//   real MegaFlashROM routes those to the flash chip, not the bank latch, so we
//   suppress the bank update for them.
//
// Volatile flash command emulation (e.g. Neon Horizon "16X" build):
//   The cart drives the flash chip through the BANKED window. Neon Horizon's
//   in-game save uses the 0x6000-0x7FFF (addr[13]=1) window for both its erase
//   command cycles (0x7AAA/0x7555/0x7000) and some byte-program DATA writes
//   (DE=0x7000). The earlier core gated the JEDEC FSM with ~addr[13], so those
//   addr[13]=1 program-data writes were dropped -> the game's program verify-poll
//   (LD (DE),A; LD A,(DE); CP (HL); JR NZ) never matched -> hard freeze.
//   Fix: the JEDEC FSM now runs over the FULL window (addr[13] agnostic), keyed
//   on the flash command offsets off[11:1]=0x555/0x2AA. We recognize:
//     byte-program : AA, 55, A0, <data>           -> prog_we writes SDRAM ROM copy
//     sector-erase : AA, 55, 80, AA, 55, 30       -> performed by shared flash.sv
//     chip-erase   : AA, 55, 80, AA, 55, 10       -> performed by shared flash.sv
//   and suppress the bank-register latch for every write that is part of a
//   recognized command sequence, so flash commands in the bank window no longer
//   scramble the banks. Volatile (SDRAM is reloaded on ROM reload); MFRSD's use
//   of flash.sv is unaffected.

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
    output              prog_we,     // this CPU write is a validated byte-program -> write SDRAM
    // Same fact, but valid on the write's FIRST clock: prog_we rides prog_arm,
    // which is only latched at that write's wr_rise, so it is one clock late for
    // flash.sv's `we & ~old_we` edge.  flash.sv needs to know at the edge that
    // this write is data, not a command cycle.
    output              prog_phase
);
/*verilator tracing_off*/
logic [11:0] bankRegs[2][2]; // [cart_num][bank_index]

// ---- JEDEC command FSM (ASCII16X), runs over the full window -----------------
localparam [2:0] S_IDLE = 3'd0,  // waiting for AA @0x555
                 S_AA   = 3'd1,  // AA seen, waiting 55 @0x2AA
                 S_55   = 3'd2,  // 55 seen, waiting command @0x555 (A0 prog / 80 erase)
                 S_PROG = 3'd3,  // A0 seen, next write is byte-program data
                 S_E1   = 3'd4,  // 80 seen, waiting AA @0x555
                 S_E2   = 3'd5,  // AA seen, waiting 55 @0x2AA
                 S_E3   = 3'd6;  // 55 seen, waiting confirm (30 sector / 10 chip)

wire        cart_wr  = cs & cpu_mreq & cpu_wr;          // any write to this cart
wire        unlock_a = (cpu_addr[11:1] == 11'h555);     // unlock cycles 1 & 3 offset
wire        unlock_b = (cpu_addr[11:1] == 11'h2AA);     // unlock cycle 2 offset

logic       old_cart_wr;
wire        wr_rise = cart_wr & ~old_cart_wr;           // one event per CPU write
wire        wr_fall = ~cart_wr & old_cart_wr;

logic [2:0] jedec_st;
logic       prog_arm;       // current CPU write is the validated program write

// Combinational: does THIS write (at the current pre-transition state) match a
// defined flash command cycle? Used to suppress the bank-register latch for it.
logic       flash_cmd;
always @(*) begin
    case (jedec_st)
        S_IDLE:  flash_cmd = (din == 8'hAA) & unlock_a;
        S_AA:    flash_cmd = ((din == 8'h55) & unlock_b) | ((din == 8'hAA) & unlock_a);
        S_55:    flash_cmd = ((din == 8'hA0) & unlock_a) | ((din == 8'h80) & unlock_a)
                           | ((din == 8'hAA) & unlock_a);
        S_PROG:  flash_cmd = 1'b1;                       // byte-program data write
        S_E1:    flash_cmd = (din == 8'hAA) & unlock_a;
        S_E2:    flash_cmd = ((din == 8'h55) & unlock_b) | ((din == 8'hAA) & unlock_a);
        S_E3:    flash_cmd = (din == 8'h30) | (din == 8'h10); // erase confirm (any addr)
        default: flash_cmd = 1'b0;
    endcase
end

always @(posedge clk) begin
    if (reset) begin
        bankRegs[0] <= '{12'd0, 12'd0};
        bankRegs[1] <= '{12'd0, 12'd0};
    end else begin
        // latch a bank register only for genuine bank writes, not flash commands
        if (wr_rise & cpu_addr[13] & ~flash_cmd)
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

always @(posedge clk) begin
    if (reset) begin
        jedec_st    <= S_IDLE;
        prog_arm    <= 1'b0;
        old_cart_wr <= 1'b0;
    end else begin
        old_cart_wr <= cart_wr;
        if (wr_fall) prog_arm <= 1'b0;                  // program write finished
        if (wr_rise) begin
            case (jedec_st)
                S_IDLE: jedec_st <= ((din == 8'hAA) & unlock_a) ? S_AA : S_IDLE;
                S_AA:   jedec_st <= ((din == 8'h55) & unlock_b) ? S_55 :
                                    ((din == 8'hAA) & unlock_a) ? S_AA : S_IDLE;
                S_55:   jedec_st <= ((din == 8'hA0) & unlock_a) ? S_PROG :
                                    ((din == 8'h80) & unlock_a) ? S_E1   :
                                    ((din == 8'hAA) & unlock_a) ? S_AA   : S_IDLE;
                S_PROG: begin                            // this write = byte-program data
                    prog_arm <= ~mem_unmaped;            // only program in-bounds
                    jedec_st <= S_IDLE;
                end
                S_E1:   jedec_st <= ((din == 8'hAA) & unlock_a) ? S_E2 : S_IDLE;
                S_E2:   jedec_st <= ((din == 8'h55) & unlock_b) ? S_E3 :
                                    ((din == 8'hAA) & unlock_a) ? S_AA : S_IDLE;
                S_E3:   jedec_st <= S_IDLE;              // 30/10 confirm: flash.sv does the fill
                default: jedec_st <= S_IDLE;
            endcase
        end
    end
end

assign prog_we    = prog_arm & cart_wr;                 // held across the program write
assign prog_phase = (jedec_st == S_PROG) & cart_wr;     // combinational: true from clock 1

endmodule
