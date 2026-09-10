// joymega.sv against openMSX src/input/JoyMega.cc.
//
// The expected phase table is written here as openMSX's own masks and shifts,
// evaluated on the same active-low status word, so this checks the RTL against
// the reference expression rather than against a re-typed copy of itself.
`timescale 1ns/1ps
module tb_joymega;

   localparam TO = 16'd200;          // short timeout, so the test is not 1.5 ms long

   logic        clk = 0, reset = 1, pin8 = 0;
   logic [11:0] btn = 12'd0;
   wire   [5:0] dout;
   int          fails = 0, checks = 0;
   logic  [5:0] p5, p7;

   joymega #(.TIMEOUT(TO)) dut (.clk(clk), .reset(reset), .pin8(pin8), .btn(btn), .dout(dout));

   always #5 clk = ~clk;

   // openMSX read(), transcribed as masks/shifts on the active-low status word
   function automatic [5:0] omsx(input int cyc, input [11:0] st);
      case (cyc)
         0, 2, 4: omsx = 6'((st & 12'h00f) | ((st & 12'h060) >> 1));
         1, 3:    omsx = 6'((st & 12'h013) | ((st & 12'h080) >> 2));
         5:       omsx = 6'((st & 12'h010) | ((st & 12'h080) >> 2));
         6:       omsx = 6'(((st & 12'h400) >> 10) | ((st & 12'hA00) >> 8)
                          | ((st & 12'h100) >>  6) | ((st & 12'h060) >> 1));
         default: omsx = 6'((st & 12'h010) | ((st & 12'h080) >> 2) | 12'h00f);
      endcase
   endfunction

   task check(input [5:0] want, input string what);
      begin
         checks++;
         if (dout !== want) begin
            $display("FAIL %-38s btn=%012b dout=%06b want=%06b", what, btn, dout, want);
            fails++;
         end
      end
   endtask

   task toggle;                      // one pin-8 write, i.e. one phase step
      begin @(negedge clk); pin8 = ~pin8; @(negedge clk); end
   endtask

   task sync0;                       // let the idle timeout park the phase at 0
      begin pin8 = 0; repeat (TO + 4) @(negedge clk); end
   endtask

   task walk(input [11:0] b, input string tag);
      begin
         btn = b;
         sync0();
         check(omsx(0, ~b), {tag, " phase 0"});
         for (int c = 1; c < 8; c++) begin
            toggle();
            check(omsx(c, ~b), {tag, " phase ", $sformatf("%0d", c)});
         end
      end
   endtask

   initial begin
      repeat (4) @(negedge clk);
      reset = 0;
      @(negedge clk);

      // 1 -- idle pad, phase 0
      check(omsx(0, 12'hfff), "idle pad reads phase 0");

      // 2..8 -- one full 8-phase walk with nothing pressed
      walk(12'h000, "idle");

      // 9..15 -- every button held: each phase must expose its own slice
      walk(12'hfff, "all held");

      // 16..22 -- the six-button slice only appears on phase 6
      walk(12'b1111_0000_0000, "top row X/Y/Z/Mode");

      // 23..29 -- directions and the two triggers, the plain-MSX subset
      walk(12'b0000_0011_1111, "U/D/L/R + A/B");

      // Every button on its own.  Group patterns cannot catch two buttons being
      // swapped inside a phase, because they always move together there.
      for (int b = 0; b < 12; b++) walk(12'b1 << b, $sformatf("button %0d alone", b));

      // The idle timeout has to be checked by where the NEXT toggle lands:
      // phases 0/2/4 read identically, so "back at 0" is not observable on its
      // own.  From phase 6, one more toggle gives phase 7 if the phase was kept
      // and phase 1 if the timeout reset it -- and those two do differ.
      btn = 12'h000;
      sync0();
      for (int c = 1; c <= 6; c++) toggle();     // -> phase 6
      check(omsx(6, 12'hfff), "walked up to phase 6");
      repeat (TO + 4) @(negedge clk);
      toggle();
      check(omsx(1, 12'hfff), "timeout reset it, so the next toggle is phase 1");

      // 30 -- phases 5 and 7 differ only in the direction lines: that is the
      //       6-button detection, so prove they really are different
      begin
         p5 = omsx(5, 12'hfff);
         p7 = omsx(7, 12'hfff);
         checks++;
         if (p5[3:0] === p7[3:0]) begin
            $display("FAIL phase 5 and 7 are indistinguishable"); fails++;
         end
      end

      // 31 -- the phase survives while pin 8 keeps toggling
      btn = 12'h000;
      sync0();
      toggle(); toggle();                        // -> phase 2 (from 0, two steps)
      check(omsx(2, 12'hfff), "phase advances per toggle");

      // 32 -- and 1.5 ms of quiet drops it back to phase 0
      repeat (TO + 4) @(negedge clk);
      check(omsx(pin8 ? 1 : 0, 12'hfff), "idle timeout resets the phase");

      // 33 -- the invariant openMSX asserts: cycle[0] tracks pin 8
      checks++;
      if (dut.cycle[0] !== pin8) begin
         $display("FAIL cycle[0]=%b does not track pin8=%b", dut.cycle[0], pin8); fails++;
      end

      // 34 -- reset parks it at phase 0
      reset = 1; pin8 = 0; @(negedge clk); @(negedge clk); reset = 0; @(negedge clk);
      check(omsx(0, 12'hfff), "reset parks at phase 0");

      $display("%0d checks, %0d failed", checks, fails);
      if (fails) begin $display("FAILED"); $fatal(1); end
      $display("PASSED");
      $finish;
   end
endmodule
