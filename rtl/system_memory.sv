module system_memory #(parameter BRAM_WIDTH = 18) (
    input                   clk,
    memory_bus_if.ram_mp    memory_bus_msx,
    memory_bus_if.ram_mp    memory_bus_upload,
    //memory_bus_if.ram_mp    memory_bus_flash,
    //memory_bus_if.ram_mp    memory_bus_backup,
    memory_bus_if.device_mp memory_bus_sdram_ch1,
    memory_bus_if.device_mp memory_bus_sdram_ch2,
    memory_bus_if.device_mp memory_bus_sdram_ch3,
    input logic             upload
);

    logic [26:0] addr;
    logic  [7:0] data;
    logic  [7:0] q;
    logic        rnw;
    logic        cs;
    logic        bram_cs;
    logic        sdram_cs;

    assign addr = upload ? memory_bus_upload.addr   : memory_bus_msx.addr;
    assign rnw  = upload ? memory_bus_upload.rnw    : memory_bus_msx.rnw;
    assign cs   = upload ? memory_bus_upload.ram_cs : memory_bus_msx.ram_cs;
    assign data = upload ? memory_bus_upload.data   : memory_bus_msx.data;

    generate
        if (BRAM_WIDTH == 0) begin
            assign bram_cs  = 1'b0;
            assign sdram_cs = cs;
        end else begin
            assign bram_cs  = addr[26:BRAM_WIDTH] == '0 && cs;
            assign sdram_cs = addr[26:BRAM_WIDTH] != '0 && cs;
        end
    endgenerate

    assign q = bram_cs ? bram_data : memory_bus_sdram_ch1.q;

    assign memory_bus_sdram_ch1.addr =
        (BRAM_WIDTH == 0) ? addr : addr - (27'd1 << BRAM_WIDTH);
    assign memory_bus_sdram_ch1.data    = data;
    assign memory_bus_sdram_ch1.rnw     = rnw;
    assign memory_bus_sdram_ch1.ram_cs  = sdram_cs;
    assign memory_bus_sdram_ch1.sram_cs = '0;

    assign memory_bus_upload.q           = memory_bus_upload.ram_cs ? q : '1;
    assign memory_bus_upload.sdram_ready = memory_bus_sdram_ch1.sdram_ready;
    assign memory_bus_upload.sdram_done  = memory_bus_sdram_ch1.sdram_done;

    assign memory_bus_msx.q              = memory_bus_msx.ram_cs    ? q : '1;
    assign memory_bus_msx.sdram_ready    = memory_bus_sdram_ch1.sdram_ready;
    assign memory_bus_msx.sdram_done     = memory_bus_sdram_ch1.sdram_done;

    logic [7:0] bram_data;
    generate
        if (BRAM_WIDTH > 0) begin : with_bram
            dpram #(.addr_width(BRAM_WIDTH), .mem_name("SYSTEM")) system_ram (
                .clock(clk),
                .address_a(addr[BRAM_WIDTH-1:0]),
                .wren_a(!rnw && bram_cs),
                .data_a(data),
                .q_a(bram_data),
                .address_b(),
                .wren_b(),
                .data_b(),
                .q_b()
            );
        end else begin : no_bram
            assign bram_data = 8'hFF;
        end
    endgenerate

endmodule
