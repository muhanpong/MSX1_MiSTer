//  tb_matsushita -- Panasonic switched I/O device (manufacturer ID 8), ports 40H/41H.
//
//  Checks the protocol as documented from three independent primary sources:
//      OUT 40H,8  -> INP(40H) = F7H            (ID written DIRECTLY, complement reads back)
//      OUT 41H,0  -> 5.37MHz                   (bit0 ACTIVE LOW)
//      OUT 41H,1  -> 3.58MHz
//      INP(41H) bit2 = 0                       (turbo hardware present, read-only)
//
//  and the two deliberate divergences:
//      * turbo reflects ONLY what software wrote -- the OSD speed is not visible here
//        (that is a property of the top level, checked by inspection, not here)
//      * bit7 reads 1: no 3-3 firmware ROM in the pack, so the firmware switch is OFF
//
//  and the things that must NOT happen:
//      * a machine without the device (cs=0) must never answer, and never request turbo
//      * selecting any OTHER manufacturer ID must leave 40H and 41H floating at FFH
//        -- answering ID 8 is what 8 non-turbo machines wrongly do
//      * M1+IORQ is an interrupt acknowledge, not an I/O access
//
//  NEGCTL=1 holds cs low, i.e. reverts to "this machine has no Matsushita device".
//  Every presence check below must then FAIL (that is the point of the control).

`timescale 1ns/1ps

module tb_matsushita;

   logic       clk = 0, reset = 1;
   logic       cpu_iorq = 0, cpu_m1 = 0, cpu_wr = 0, cpu_rd = 0;
   logic [7:0] cpu_addr = 8'h00, cpu_dout = 8'h00;
   logic       cs_drv = 1'b1;
   wire  [7:0] dout;
   wire        turbo;

`ifdef NEGCTL
   wire cs = 1'b0;
`else
   wire cs = cs_drv;
`endif

   dev_matsushita dut (.*, .cs(cs), .dout(dout), .turbo(turbo));

   always #10 clk = ~clk;

   int errors = 0;
   task automatic ck(input string what, input logic ok);
      if (!ok) begin errors++; $display("FAIL  %s", what); end
      else                     $display("ok    %s", what);
   endtask

   task automatic io_write(input [7:0] a, input [7:0] d);
      @(negedge clk); cpu_addr = a; cpu_dout = d; cpu_iorq = 1; cpu_m1 = 0; cpu_wr = 1;
      @(posedge clk);
      @(negedge clk); cpu_iorq = 0; cpu_wr = 0;
   endtask

   // combinational read: drive the bus, sample, release
   task automatic io_read(input [7:0] a, output [7:0] d);
      @(negedge clk); cpu_addr = a; cpu_iorq = 1; cpu_m1 = 0; cpu_rd = 1;
      #1 d = dout;
      @(negedge clk); cpu_iorq = 0; cpu_rd = 0;
   endtask

   logic [7:0] r;

   initial begin
      repeat (2) @(posedge clk);
      reset = 0;
      @(negedge clk);

      // ---- power-on -------------------------------------------------------
      ck("reset: turbo off",                turbo === 1'b0);
      io_read(8'h41, r);
      ck("reset: 41H floats (unselected)",  r === 8'hFF);

      // ---- selecting a FOREIGN id must not make us answer -------------------
      io_write(8'h40, 8'h07);
      io_read(8'h40, r);
      ck("other id: 40H = FFH",             r === 8'hFF);
      io_read(8'h41, r);
      ck("other id: 41H = FFH",             r === 8'hFF);

      // ---- select ID 8 ------------------------------------------------------
      io_write(8'h40, 8'd8);
      io_read(8'h40, r);
      ck("OUT 40H,8 -> INP(40H)=F7H",       r === 8'hF7);

      io_read(8'h41, r);
      ck("41H bit2=0 (turbo present)",      r[2] === 1'b0);
      ck("41H bit7=1 (firmware sw off)",    r[7] === 1'b1);
      ck("41H bit0=1 (turbo still off)",    r[0] === 1'b1);
      ck("41H unused bits are 1",           {r[6:3],r[1]} === 5'b11111);

      // ---- turbo ON is bit0 = 0 (ACTIVE LOW) --------------------------------
      io_write(8'h41, 8'h00);
      ck("OUT 41H,0 -> turbo asserted",     turbo === 1'b1);
      io_read(8'h41, r);
      ck("turbo on: INP(41H) = FAH",        r === 8'hFA);

      io_write(8'h41, 8'h01);
      ck("OUT 41H,1 -> turbo released",     turbo === 1'b0);
      io_read(8'h41, r);
      ck("turbo off: INP(41H) = FBH",       r === 8'hFB);

      // only bit0 matters; the other written bits must be ignored
      io_write(8'h41, 8'hFE);
      ck("OUT 41H,FEH -> turbo asserted",   turbo === 1'b1);

      // ---- M1+IORQ is an interrupt acknowledge, not I/O ---------------------
      io_write(8'h41, 8'h01);              // back to off
      @(negedge clk); cpu_addr = 8'h41; cpu_dout = 8'h00; cpu_iorq = 1; cpu_m1 = 1; cpu_wr = 1;
      @(posedge clk);
      @(negedge clk); cpu_iorq = 0; cpu_wr = 0; cpu_m1 = 0;
      ck("M1 cycle does not write 41H",     turbo === 1'b0);

      // ---- deselecting must silence 41H again -------------------------------
      io_write(8'h41, 8'h00);              // turbo on while selected
      io_write(8'h40, 8'h00);              // now select nothing
      io_read(8'h41, r);
      ck("deselected: 41H = FFH",           r === 8'hFF);

      // ---- reads must not drive the bus outside our ports -------------------
      io_write(8'h40, 8'd8);
      io_read(8'h42, r);
      ck("42H is not ours",                 r === 8'hFF);
      io_read(8'hF4, r);
      ck("F4H (reset status) is not ours",  r === 8'hFF);

      // ---- reset clears the switch ------------------------------------------
      io_write(8'h41, 8'h00);
      ck("turbo on before reset",           turbo === 1'b1);
      @(negedge clk); reset = 1; @(posedge clk); @(negedge clk); reset = 0;
      ck("reset releases turbo",            turbo === 1'b0);

      $display("errors=%0d", errors);
      if (errors) $fatal(1, "tb_matsushita FAILED (%0d)", errors);
      $display("tb_matsushita PASSED");
      $finish;
   end

endmodule
