module track_buffer #(ID = 0)
(
    input  logic        clk,
    input  logic        reset,
    
    input  logic  [6:0] track,
    input  logic        USEL,
    input  logic        side,
    
    input  logic [12:0] buffer_addr,
    output logic  [7:0] buffer_q,
    output logic        ready,
    
    block_device_if.device_mp block_device[2],
    
    //Image info
    input  logic        disk_mounted,
    input  logic        disk_readonly,
    input  logic        disk_sides
);

    logic [6:0] reg_track;
    logic       reg_USEL;
    logic       reg_side;

    logic       load;
    logic       sd_ack;

    wire changed = {reg_track, reg_USEL, reg_side} != {track, USEL, side};
    
    assign block_device[0].wr = 0;     //TODO Write functionality
    assign block_device[1].wr = 0;     //TODO Write functionality

    assign sd_ack = reg_USEL ? block_device[1].ack : block_device[0].ack;
    assign ready  = !changed && !load && !load_busy && disk_mounted;

    always_ff @(posedge clk) begin
        if (reset) begin
            load <= 1;
        end else begin
            
            if (!load_busy && changed) load <= 1;
            if (load_busy && sd_ack) load <= 0;
        end       
    end

    logic load_busy;
    logic [4:0] sectors;

    always_ff @(posedge clk) begin
        if (reset) begin
            load_busy <= 0;
        end else begin
            if (!load_busy && load && disk_mounted) begin
                {reg_track, reg_USEL, reg_side} <= {track,  USEL, side};
                load_busy <= 1;
                if (USEL) begin
                    $display("LOAD Track USEL 1  %t",  $time);
                    block_device[1].lba <=  (track * (disk_sides ? 18 : 9)) + (side == 1'b1 ? 9 : 0);
                    block_device[1].blk_cnt <= 8 ;
                    block_device[1].rd <= 1;
                end else begin
                    $display("Load Track USEL 0  %t",  $time);
                    block_device[0].lba <=  (track * (disk_sides ? 18 : 9)) + (side == 1'b1 ? 9 : 0);
                    block_device[0].blk_cnt <= 8 ;
                    block_device[0].rd <= 1;
                end
            end

            if (~reg_USEL && block_device[0].rd && block_device[0].ack && load_busy) block_device[0].rd <= 0;
            
            if (reg_USEL && block_device[1].rd && block_device[1].ack && load_busy) block_device[1].rd <= 0;
            
            if (!load && !sd_ack ) load_busy <= 0;
        end
    end

    logic [7:0] dpram_sd_buff_din;
    always_ff @(posedge clk) begin
        if (reg_USEL) begin
            block_device[1].buff_din <= dpram_sd_buff_din;
        end else begin
            block_device[0].buff_din <= dpram_sd_buff_din;
        end
    end
    
    dpram #(.addr_width(13), .mem_name(ID)) track_dpram (
        .clock(clk),
        .address_a(reg_USEL ? block_device[1].buff_addr[12:0] : block_device[0].buff_addr[12:0]),
        .data_a(reg_USEL ? block_device[1].buff_dout : block_device[0].buff_dout),
        .wren_a(reg_USEL ? block_device[1].buff_wr : block_device[0].buff_wr),
        .q_a(dpram_sd_buff_din),

        .address_b(buffer_addr),
        .wren_b(0),
        .data_b(0),
        .q_b(buffer_q)
    );

endmodule
