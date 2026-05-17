// RomAscii16X mapper
//
// Banks:
//   bankRegs[0]: 0x4000-0x7FFF and 0xC000-0xFFFF  (addr[14]=1 → ~addr[14]=0)
//   bankRegs[1]: 0x8000-0xBFFF and 0x0000-0x3FFF  (addr[14]=0 → ~addr[14]=1)
//
// Bank register write: any address with addr[13]=1
//   addr[12]=0 → update bankRegs[0]
//   addr[12]=1 → update bankRegs[1]
//
// 12-bit bank number: {addr[11:8], din[7:0]}

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
    output              flash_rq
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

endmodule
