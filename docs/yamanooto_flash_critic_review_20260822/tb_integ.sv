// CRITIC TB #2 — cart_yamanooto + flash.sv wired EXACTLY as msx_slots.sv does.
// Question: with WREN CLEAR (no flash write enable), can ordinary CPU writes in
// the 0x4000-0xBFFF window reach and disturb the shared flash command FSM?
`timescale 1ns/1ps
`default_nettype none
module tb_integ;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0;
   logic  [7:0] cpu_dout=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0;
   logic cart_num=0;
   logic [24:0] mem_size = 25'(8*1024*1024);

   wire mem_unmaped_y, cart_dout_en, scc_req, flash_wr_en, y_flash_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode;
   wire [22:0] y_flash_addr;

   cart_yamanooto y (
      .clk(clk), .reset(reset), .mem_size(mem_size), .cpu_addr(cpu_addr),
      .din(cpu_dout), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .cs(1'b1), .cart_num(cart_num),
      .mem_unmaped(mem_unmaped_y), .mem_addr(mem_addr), .cart_dout(cart_dout),
      .cart_dout_en(cart_dout_en), .scc_req(scc_req), .scc_mode(scc_mode),
      .flash_wr_en(flash_wr_en), .flash_addr(y_flash_addr), .flash_rq(y_flash_rq),
      .prog_we(prog_we));

   // ---- exactly the msx_slots.sv wiring for the Yamanooto-only case ----
   wire [7:0] flash_dout; wire flash_rq;
   wire own_flash_rq = y_flash_rq;                 // no ASCII16X / MFRSD present
   wire [26:0] base_ram = 27'h0C00000;             // slot A ROM store
   wire [15:0] size     = 16'd512;                 // 8MB in 16KB units
   logic sdram_ready=1; logic sdram_done=0;
   wire [26:0] f_sdram_addr; wire [7:0] f_sdram_din; wire f_sdram_req;
   wire debug_erase;

   flash flash (
      .clk(clk), .clk_sdram(clk),
      .addr(23'(y_flash_addr)),
      .din(cpu_dout), .dout(flash_dout), .data_valid(flash_rq),
      .we(cpu_mreq & cpu_wr),
      .ce(y_flash_rq),
      .sdram_addr(f_sdram_addr), .sdram_din(f_sdram_din), .sdram_req(f_sdram_req),
      .sdram_ready(sdram_ready), .sdram_done(sdram_done),
      .sdram_offset(base_ram),
      .amd_family(own_flash_rq),
      .boot_sector(1'b0),
      .erase_limit(own_flash_rq ? 27'(size) << 14 : 27'h800000),
      .debug_erase(debug_erase));

   // global mem_unmaped, per msx_slots.sv
   wire mem_unmaped = mem_unmaped_y | flash_rq;
   // what the CPU actually reads from the cart window (ram_dout modelled as 'ROM')
   localparam [7:0] ROMBYTE = 8'h5A;
   wire [7:0] cpu_din = flash_dout & (mem_unmaped ? 8'hFF : ROMBYTE);

   always #5 clk = ~clk;

   int nwr; logic [26:0] wr_addr[$]; logic [7:0] wr_data[$];
   always @(posedge clk) begin
      sdram_done <= 1'b0;
      if (f_sdram_req & ~sdram_done) begin
         sdram_done <= 1'b1; nwr++;
         if (nwr <= 12) begin wr_addr.push_back(f_sdram_addr); wr_data.push_back(f_sdram_din); end
      end
   end

   task automatic w(input [15:0] a, input [7:0] d);
      begin
         @(negedge clk); cpu_addr=a; cpu_dout=d; cpu_mreq=1; cpu_wr=1;
         repeat(4) @(posedge clk);
         @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk);
      end
   endtask
   task automatic rd(input [15:0] a, output [7:0] d);
      begin
         @(negedge clk); cpu_addr=a; cpu_mreq=1; cpu_rd=1;
         @(posedge clk); d = cpu_din;
         @(negedge clk); cpu_mreq=0; cpu_rd=0; repeat(2) @(posedge clk);
      end
   endtask

   logic [7:0] v;
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      $display("WREN = %0d (must be 0 for every test below)", flash_wr_en);
      rd(16'h4000, v);
      $display("baseline read 0x4000 = 0x%02h (ROM = 0x%02h)  %s", v, ROMBYTE, v===ROMBYTE?"OK":"BAD");

      // ---- A: a Konami-5 BANK WRITE that happens to carry value 0x98 to 0x50AA
      //         (0x50AA is inside the 0x5000-0x57FF bank window, and its low 12
      //          bits are 0x0AA -> word offset 0x055 = the CFI entry offset)
      $display("\n[A] bank write: LD (0x50AA),0x98   -- WREN is CLEAR");
      w(16'h50AA, 8'h98);
      $display("    flash.cfi_state = %0d", flash.cfi_state);
      rd(16'h4000, v);
      $display("    read 0x4000 = 0x%02h   %s", v,
               (v===ROMBYTE) ? "ok" : "*** ROM WINDOW NO LONGER RETURNS ROM ***");
      rd(16'h4020, v);
      $display("    read 0x4020 = 0x%02h  (CFI 'Q' = 0x51)", v);
      // recover
      w(16'h4000, 8'hF0);
      rd(16'h4000, v); $display("    after F0: read 0x4000 = 0x%02h", v);

      // ---- B: autoselect with WREN clear
      $display("\n[B] AA/55/90 autoselect  -- WREN is CLEAR");
      w(16'h4AAA, 8'hAA); w(16'h4554, 8'h55); w(16'h4AAA, 8'h90);
      $display("    flash.state = %0d", flash.state);
      rd(16'h4000, v);
      $display("    read 0x4000 = 0x%02h   %s", v,
               (v===ROMBYTE) ? "ok" : "*** ROM WINDOW REPLACED BY DEVICE ID ***");
      w(16'h4000, 8'hF0);

      // ---- C: quadruple-program 0x56 with WREN clear -> real SDRAM writes
      $display("\n[C] LD (0x4AAA),0x56 then 5 ordinary writes -- WREN is CLEAR");
      nwr=0; wr_addr.delete(); wr_data.delete();
      w(16'h4AAA, 8'h56);
      w(16'h4100, 8'hDE);
      w(16'h4101, 8'hAD);
      w(16'h4102, 8'hBE);
      w(16'h4103, 8'hEF);
      w(16'h4104, 8'h99);
      repeat(20) @(posedge clk);
      $display("    SDRAM writes issued by flash.sv = %0d", nwr);
      for (int i=0; i<wr_addr.size(); i++)
         $display("      -> SDRAM[0x%07h] <= 0x%02h", wr_addr[i], wr_data[i]);
      $display("    prog_we (mapper path) was never used; every one of those CPU");
      $display("    writes is mem_unmaped (WREN clear) so the normal path wrote nothing.");
      if (nwr > 0) $display("    *** ROM IMAGE CORRUPTED WITHOUT WREN ***");
      $finish;
   end
endmodule
`default_nettype wire
