// joykey.sv -- extra pad buttons -> MSX key matrix.
//
// The expectation table below is written from the MSX keyboard matrix itself
// (row 6: SHIFT CTRL GRAPH CAPS CODE F1 F2 F3 / row 7: F4 F5 ESC TAB STOP BS
// SELECT RET / row 8: SPACE HOME INS DEL LEFT UP DOWN RIGHT), not from the
// module, so a transposed bit in joykey.sv fails here.
`timescale 1ns/1ps
module tb_joykey;

   logic [2:0] btn;
   logic [3:0] kb_row;
   wire  [7:0] mask;
   int         fails = 0, checks = 0;

   joykey dut (.btn(btn), .kb_row(kb_row), .mask(mask));

   task check(input [7:0] want, input string what);
      begin
         checks++;
         #1;
         if (mask !== want) begin
            $display("FAIL %-34s row=%0d btn=%b  mask=%08b want=%08b", what, kb_row, btn, mask, want);
            fails++;
         end
      end
   endtask

   // one button at a time, in the row it belongs to
   task one(input int b, input [3:0] r, input int bit_pos, input string name);
      begin
         btn = 3'b0; btn[b] = 1'b1; kb_row = r;
         check(8'b1 << bit_pos, {name, " asserts its own bit"});
      end
   endtask

   // the same button must do nothing in every other row
   task quiet_elsewhere(input int b, input [3:0] own, input string name);
      begin
         btn = 3'b0; btn[b] = 1'b1;
         for (int r = 0; r < 16; r++) begin
            if (r[3:0] != own) begin
               kb_row = r[3:0];
               check(8'b0, {name, " silent off-row"});
            end
         end
      end
   endtask

   initial begin
      // 1..5 -- each button lands on the right row and bit
      one(0, 4'd8, 0, "Space");
      one(1, 4'd7, 7, "Return");
      one(2, 4'd6, 5, "F1");


      // 6..10 -- and nowhere else
      quiet_elsewhere(0, 4'd8, "Space");
      quiet_elsewhere(1, 4'd7, "Return");
      quiet_elsewhere(2, 4'd6, "F1");


      // 11 -- nothing pressed is a clean matrix in every row
      btn = 3'b0;
      for (int r = 0; r < 16; r++) begin
         kb_row = r[3:0];
         check(8'b0, "idle leaves the row alone");
      end

      // a full press is confined to its row
      btn = 3'b111;
      kb_row = 4'd8; check(8'b0000_0001, "all pressed, row 8");
      kb_row = 4'd7; check(8'b1000_0000, "all pressed, row 7");
      kb_row = 4'd6; check(8'b0010_0000, "all pressed, row 6");
      kb_row = 4'd0; check(8'b0000_0000, "all pressed, row 0");

      $display("%0d checks, %0d failed", checks, fails);
      if (fails) begin $display("FAILED"); $fatal(1); end
      $display("PASSED");
      $finish;
   end
endmodule
