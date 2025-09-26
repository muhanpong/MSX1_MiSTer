module fdd #(parameter sysCLK, SECTORS=9, SECTOR_SIZE=512, TRACKS=80, ID=0, TEST=0)
(
    input  logic              clk,
    input  logic              reset,
    FDD_if.FDD_mp             FDD_bus,
    block_device_if.device_mp block_device[2],
    //device config
    input logic         [1:0] speed,          // 0 - 300rpm / 1 - 360rpm
    input logic         [1:0] mfm,            // 0 - FM     / 1 - MFM
    input logic         [1:0] sides,          // 0 - SS     / 1 - DS
    input logic         [1:0] density[2],     // 0 - 250kbit     / 1 - 500kbit    / 2 - 1000kbit
    input logic         [5:0] sectors[2],     // sectors per track
    input logic         [1:0] sector_size[2]  // 0 - 128B / 1 - 256B / 2 - 512B / 3 - 1024B
);

    
//https://map.grauw.nl/articles/low-level-disk/
//https://retrocmp.de/fdd/general/floppy-formats.htm

    logic motor_360rmp;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(6)) FDD_RPM360(
        .clk(clk),
        .en(motor_360rmp)
    );
    
    logic motor_300rmp;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(5)) FDD_RPM300(
        .clk(clk),
        .en(motor_300rmp)
    );

    logic msclk;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(1000)) FDD_MS(
        .clk(clk),
        .en(msclk)
    );

    logic bitRate_250;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(250000*2)) FDD_BITRATE_250(
        .clk(clk),
        .en(bitRate_250)
    );

    logic bitRate_500;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(500000*2)) FDD_BITRATE_500(
        .clk(clk),
        .en(bitRate_500)
    );

    logic bitRate_1000;
    clockEnabler #(.clkFreq(sysCLK), .targetFreq(1000000*2))  FDD_BITRATE_1000(
        .clk(clk),
        .en(bitRate_1000)
    );


    logic       drive_motor_rpm;
    logic       floppy_mfm;
    logic       floppy_sides;
    logic       floppy_bitRate;
    logic [5:0] floppy_sectors;
    logic [1:0] floppy_sectors_size;

    always_comb begin
        case (density[FDD_bus.USEL])
            2'd0: floppy_bitRate = bitRate_250;    
            2'd1: floppy_bitRate = bitRate_500;   
            2'd2: floppy_bitRate = bitRate_1000;
            default floppy_bitRate = bitRate_250;
        endcase

        drive_motor_rpm     = speed[FDD_bus.USEL] ? motor_360rmp : motor_300rmp;
        floppy_mfm          = mfm[FDD_bus.USEL];
        floppy_sectors      = sectors[FDD_bus.USEL];
        floppy_sectors_size = sector_size[FDD_bus.USEL];
        floppy_sides        = sides[FDD_bus.USEL];
    end

    logic [1:0] motor_run;         // Stav motoru

    motor #(.TIMEOUTms(16'd30000), .DELAYms(3'd3)) FDD_motor(
        .clk(clk),
        .msclk(msclk),
        .reset(reset),
        .USEL(FDD_bus.USEL),
        .MOTORn(FDD_bus.MOTORn),
        .motor_run(motor_run)
    );

    //logic sides;
    ready FDD_ready(
        .clk(clk),
        .reset(reset),
        .USEL(FDD_bus.USEL),
        .motor_run(motor_run),
        .READYn(FDD_bus.READYn),
        .WPROTn(FDD_bus.WPROTn),
        .sides(/*sides*/),
        .img_mounted({block_device[1].img_mounted, block_device[0].img_mounted}),
        .img_readonly({block_device[1].img_readonly, block_device[0].img_readonly}),
        .img_size('{block_device[0].img_size, block_device[1].img_size})
    );

    logic  [6:0] track;
    logic [12:0] buffer_addr;
    logic  [7:0] buffer_q;
    logic        track_ready;

    track #(.DELAYms(3'd3), .MAX_TRACKS(80), .ID(ID)) FDD_track(
        .clk(clk),
        .msclk(msclk),
        .reset(reset),
        .USEL(FDD_bus.USEL),
        .READYn(FDD_bus.READYn),
        .STEPn(FDD_bus.STEPn),
        .SDIRn(FDD_bus.SDIRn),
        .TRACK0n(FDD_bus.TRACK0n),
        .SIDEn(FDD_bus.SIDEn),
        
        .track(track),
        .block_device(block_device),
        .disk_mounted(~FDD_bus.READYn),
        .disk_readonly(~FDD_bus.WPROTn),
        .disk_sides(floppy_sides),

        .track_ready(track_ready),
        .buffer_addr(buffer_addr),
        .buffer_q(buffer_q)
    );

    transmit #(.sysCLK(sysCLK)) FDD_transmit(
        .clk(clk),
        .reset(reset),
        
        .drive_motor_rpm(drive_motor_rpm),
        .floppy_bitRate(floppy_bitRate),
        .floppy_mfm(floppy_mfm),
        .floppy_sectors(floppy_sectors),
        .floppy_sectors_size(floppy_sectors_size),

        //Track buffer
        .buffer_addr(buffer_addr),
        .buffer_q(buffer_q),
        .track_ready(track_ready),

        .track(track),
        .side(~FDD_bus.SIDEn),
        
        .INDEXn(FDD_bus.INDEXn),
        .READ_DATAn(FDD_bus.READ_DATAn)
    );

endmodule
