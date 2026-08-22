// CRITIC TB #6 — is the erase hijack still reachable through the FIXED WREN gate?
// A flash driver necessarily holds WREN set across the erase (it set it to issue
// the command and clears it afterwards), so `flash_rq & (cpu_rd | flash_wr_en)`
// does not keep CPU writes out of `ce` during the fill.
`timescale 1ns/1ps
`default_nettype none
module tb_hijack_e2e;
   logic clk=0, reset=1;
   logic [15:0] cpu_addr=0; logic [7:0] cpu_dout=0;
   logic cpu_mreq=0, cpu_wr=0, cpu_rd=0, cart_num=0;
   wire mem_unmaped_y, cart_dout_en, scc_req, flash_wr_en, y_flash_rq, prog_we;
   wire [24:0] mem_addr; wire [7:0] cart_dout; wire [1:0] scc_mode;
   wire [22:0] y_flash_addr;
   cart_yamanooto y (.clk(clk), .reset(reset), .mem_size(25'(8*1024*1024)),
      .cpu_addr(cpu_addr), .din(cpu_dout), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr),
      .cpu_rd(cpu_rd), .cs(1'b1), .cart_num(cart_num),
      .mem_unmaped(mem_unmaped_y), .mem_addr(mem_addr), .cart_dout(cart_dout),
      .cart_dout_en(cart_dout_en), .scc_req(scc_req), .scc_mode(scc_mode),
      .flash_wr_en(flash_wr_en), .flash_addr(y_flash_addr), .flash_rq(y_flash_rq),
      .prog_we(prog_we));
   wire [7:0] flash_dout; wire flash_rq; wire debug_erase;
   wire [26:0] f_sa; wire [7:0] f_sd; wire f_sr;
   logic sdram_ready=1; logic sdram_done=0;
   localparam [26:0] BASE = 27'h0C00000;      // slot A ROM store
   localparam [26:0] ENDA = BASE + 27'h800000;// 8MB region end
   flash flash (.clk(clk), .clk_sdram(clk), .addr(23'(y_flash_addr)), .din(cpu_dout),
      .dout(flash_dout), .data_valid(flash_rq), .we(cpu_mreq & cpu_wr), .ce(y_flash_rq),
      .sdram_addr(f_sa), .sdram_din(f_sd), .sdram_req(f_sr),
      .sdram_ready(sdram_ready), .sdram_done(sdram_done), .sdram_offset(BASE),
      .amd_family(y_flash_rq), .boot_sector(1'b0), .erase_limit(27'h800000),
      .debug_erase(debug_erase));
   always #5 clk = ~clk;
   int nwr, nff, nother, noob; longint hi=0;
   always @(posedge clk) begin
      sdram_done <= 1'b0;
      if (f_sr & ~sdram_done) begin
         sdram_done <= 1'b1; nwr++;
         if (f_sd == 8'hFF) nff++; else nother++;
         if (f_sa >= ENDA) noob++;
         if (f_sa > 27'(hi)) hi = f_sa;
      end
   end
   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; cpu_dout=d; cpu_mreq=1; cpu_wr=1;
            repeat(4) @(posedge clk);
            @(negedge clk); cpu_mreq=0; cpu_wr=0; repeat(2) @(posedge clk); end
   endtask
   initial begin
      repeat(4) @(posedge clk); reset=0; repeat(4) @(posedge clk);
      w(16'h7FFF, 8'h12);                       // ENAR <- WREN|SPIEN (the Celica value)
      $display("WREN = %0d  (a driver holds this set across the whole erase)", flash_wr_en);
      // bank page0 to segment 1016 so the erase lands in the TOP 64KB sector
      // (bank writes are suppressed while WREN is set, so drop WREN to bank, then re-arm)
      w(16'h7FFF, 8'h00); w(16'h5000, 8'hF8); w(16'h7FFF, 8'h12);
      $display("page0 flash base = 0x%06h", mem_addr[22:0]);
      // sector erase of the top sector
      w(16'h4AAA,8'hAA); w(16'h4554,8'h55); w(16'h4AAA,8'h80);
      w(16'h4AAA,8'hAA); w(16'h4554,8'h55); w(16'h4000,8'h30);
      repeat(600) @(posedge clk);
      $display("mid-erase: %0d bytes filled, cursor 0x%07h", nwr, f_sa);
      // ONE ordinary CPU write into the cart window while the fill runs
      w(16'h5F00, 8'h42);
      while (debug_erase) @(posedge clk);
      repeat(4) @(posedge clk);
      $display("erase done: %0d writes, highest addr 0x%07h (region ends 0x%07h)",
               nwr, hi[26:0], ENDA);
      $display("  0xFF bytes            : %0d", nff);
      $display("  non-0xFF (CPU data)   : %0d", nother);
      $display("  bytes OUTSIDE the cart region: %0d", noob);
      if (noob > 0 || nother > 1)
         $display("RESULT: *** F3 STILL REACHABLE THROUGH THE FIXED WREN GATE ***");
      else $display("RESULT: not reachable");
      $finish;
   end
endmodule
`default_nettype wire
