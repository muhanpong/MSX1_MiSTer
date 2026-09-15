module mapper_mfrsd3_old
(
   input              clk,
   input              reset, 
   input              cs,
   input       [15:0] cpu_addr,
   input        [7:0] din,
   output       [7:0] mapper_dout,
   input              cpu_mreq,
   input              cpu_wr,
   input              cpu_rd,
   input       [26:0] mfrsd_base_ram,
   input        [7:0] configReg,
   output      [26:0] mem_addr,
   output      [22:0] flash_addr,
   output             mem_unmaped,
   output       logic sd_rx,
   output       logic sd_tx,
   input        [7:0] d_from_sd,
   output             flash_rq,
   output             debug_sd_card
);
/*verilator tracing_off*/
assign debug_sd_card = sd_card_data_en;

logic [7:0] bank[4];

always @(posedge clk) begin
   if (reset) begin
      bank <= '{8'd0, 8'd1, 8'd0, 8'd0};
   end else begin
      if (cs & cpu_mreq & cpu_wr & cpu_addr[15:13] == 3'd3) begin // 6000 - 7fff
         if (bank[cpu_addr[12:11]] != din) begin
            bank[cpu_addr[12:11]] <= din;
         end
      end
   end
end


wire  [1:0] page       = {cpu_addr[15] ^ cpu_addr[14] ? cpu_addr[15] : ~cpu_addr[15], cpu_addr[13]};

assign flash_addr      = 23'h700000 + 23'({bank[page][6:0],13'd0}) + 23'(cpu_addr[12:0]);
assign mem_addr        = mfrsd_base_ram + 27'(flash_addr);
wire   mem_valid       = (cpu_addr[15:14] == 2'b01 | cpu_addr[15:14] == 2'b10);
wire   sd_card_en      = cs & bank[0][7:6] == 2'b01 & cpu_addr[15:13] == 3'b010; // 4000 - 5FFF
wire   sd_card_data_en = sd_card_en & cpu_mreq & cpu_rd;
assign mem_unmaped     = cs & (~mem_valid | sd_card_data_en);

assign mapper_dout = sd_card_data_en & ~cpu_addr[12] ? d_from_sd  : 8'hFF;
assign flash_rq    =  cs & mem_valid & configReg[0];

always @(posedge clk) begin
   logic old_wr, old_rd, select_sd;
   sd_rx <= 1'b0;
   sd_tx <= 1'b0;
   if (~old_rd & cs & cpu_mreq & cpu_rd & sd_card_en) sd_rx <= ~select_sd & ~cpu_addr[12];
   if (~old_wr & cs & cpu_mreq & cpu_wr & sd_card_en) begin
      if (cpu_addr[15:11] == 5'b01011) // >= 5800
         select_sd <= din[0];
      else
         sd_tx <= ~select_sd & ~cpu_addr[12];
   end
   old_rd <= cpu_rd & cpu_mreq;
   old_wr <= cpu_wr & cpu_mreq;
end

endmodule
