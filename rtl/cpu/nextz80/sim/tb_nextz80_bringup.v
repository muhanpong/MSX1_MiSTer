`timescale 1ns/1ps
//
//  NextZ80 bring-up.  Does the core execute Z80 code at all, and does the
//  half-rate clock enable really absorb a registered BRAM's read latency?
//
//  Both questions have to be answered before msx.sv is touched, because the
//  review that put NextZ80 back on the table listed "core samples DI on the
//  same edge it presents ADDR, our memories are clocked spram with registered
//  q" as the biggest unknown.  OCM's own wiring (opl3fm.sv:162-180) claims to
//  solve it by running the core at half the memory clock:
//
//      edge N    CE=1  core advances, ADDR settles combinationally
//      edge N+1  CE=0  BRAM registers ADDR, q becomes valid
//      edge N+2  CE=1  core samples DI
//
//  This testbench reproduces exactly that wiring -- same WAIT = ~CE, same
//  write gate `MREQ & WR & CE` -- against a memory model with the same
//  registered-q behaviour as rtl/peripheral/bram.vhd, and runs a program that
//  exercises fetch, immediate loads, ALU, a taken relative branch, a memory
//  write and a memory read-back.  If the contract is wrong the read-back
//  fails while the write still looks fine, which is why the program does both.
//
module tb_nextz80_bringup;

   reg clk = 0;
   always #5 clk = ~clk;                 // 100 MHz, arbitrary

   reg reset = 1;

   //  The clock enable under test.  CE high = the cycle the core advances on.
   reg CE = 0;
   always @(posedge clk) CE <= ~CE;

   wire [15:0] ADDR;
   wire  [7:0] DO;
   wire        WR, MREQ, IORQ, HALT, M1;
   wire  [7:0] DI;

   NextZ80 cpu (
      .DI    (DI),
      .DO    (DO),
      .ADDR  (ADDR),
      .WR    (WR),
      .MREQ  (MREQ),
      .IORQ  (IORQ),
      .HALT  (HALT),
      .M1    (M1),
      .CLK   (clk),
      .RESET (reset),
      .INT   (1'b0),
      .NMI   (1'b0),
      .WAIT  (~CE)
   );

   //  Memory: registered read, exactly like rtl/peripheral/bram.vhd's
   //  altsyncram (address registered on the clock, q one cycle later).
   reg [7:0] mem [0:8191];
   reg [7:0] q;
   always @(posedge clk) begin
      if (MREQ & WR & CE) mem[ADDR[12:0]] <= DO;
      q <= mem[ADDR[12:0]];
   end
   assign DI = q;

   //        LD HL,1000h / LD B,10 / XOR A / loop: ADD A,B / DJNZ loop
   //        LD (HL),A   / LD A,0  / LD A,(HL) / LD (1001h),A / HALT
   //  Sum 10+9+...+1 = 55 = 0x37.  The write proves the store path, the
   //  read-back into 1001h proves DI arrives when the core expects it.
   //  The core's register file (nextz80reg.v:195, `reg [7:0]data[15:0]`) has
   //  no reset and no initial value.  On a real FPGA that array is distributed
   //  RAM and powers up zeroed, which is what the design relies on; in
   //  simulation it starts X and ADDR -- driven combinationally from it --
   //  stays X forever.  Zero it here so the sim starts where the hardware
   //  does.  This is a testbench concession, not a fix: see the note about
   //  warm reset in README.md.
   integer r;
   initial begin
      for (r = 0; r < 16; r = r + 1) begin
         cpu.CPU_REGS.regs_lo.data[r] = 8'h00;
         cpu.CPU_REGS.regs_hi.data[r] = 8'h00;
      end
   end

   integer i;
   initial begin
      for (i = 0; i < 8192; i = i + 1) mem[i] = 8'h00;
      mem['h0000]=8'h21; mem['h0001]=8'h00; mem['h0002]=8'h10;  // LD HL,1000h
      mem['h0003]=8'h06; mem['h0004]=8'h0A;                     // LD B,10
      mem['h0005]=8'hAF;                                        // XOR A
      mem['h0006]=8'h80;                                        // ADD A,B
      mem['h0007]=8'h10; mem['h0008]=8'hFD;                     // DJNZ -3
      mem['h0009]=8'h77;                                        // LD (HL),A
      mem['h000A]=8'h3E; mem['h000B]=8'h00;                     // LD A,0
      mem['h000C]=8'h7E;                                        // LD A,(HL)
      mem['h000D]=8'h32; mem['h000E]=8'h01; mem['h000F]=8'h10;  // LD (1001h),A
      mem['h0010]=8'h76;                                        // HALT
   end

   //  Bus trace, one line per cycle the core actually advances on.
   integer cyc = 0, adv = 0;
   reg trace = 0;
   always @(posedge clk) begin
      cyc <= cyc + 1;
      if (CE && !reset) begin
         adv <= adv + 1;
         if (trace && adv < 120)
            $display("  adv=%0d cyc=%0d ADDR=%04h DI=%02h DO=%02h M1=%b MREQ=%b WR=%b IORQ=%b HALT=%b",
                     adv, cyc, ADDR, DI, DO, M1, MREQ, WR, IORQ, HALT);
      end
   end

   integer halt_cyc = -1;
   initial begin
      if ($test$plusargs("trace")) trace = 1;
      repeat (8) @(posedge clk);
      reset = 0;
      //  Run until HALT or a generous timeout.
      for (i = 0; i < 4000 && halt_cyc < 0; i = i + 1) begin
         @(posedge clk);
         if (HALT && !reset) halt_cyc = cyc;
      end

      $display("");
      $display("  HALT at cycle %0d (core advances = %0d)", halt_cyc, adv);
      $display("  mem[1000h] = %02h   expect 37", mem['h1000]);
      $display("  mem[1001h] = %02h   expect 37", mem['h1001]);
      if (halt_cyc < 0)
         $display("RESULT: FAIL -- never reached HALT");
      else if (mem['h1000] !== 8'h37)
         $display("RESULT: FAIL -- the store path is wrong (sum or write)");
      else if (mem['h1001] !== 8'h37)
         $display("RESULT: FAIL -- store fine, READ-BACK wrong: DI does not arrive when the core samples it");
      else
         $display("RESULT: PASS -- fetch, ALU, branch, store and load all correct at WAIT=~CE with registered-q memory");
      $finish;
   end

endmodule
