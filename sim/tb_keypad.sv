// tb_keypad -- MSX numeric keypad (keyboard matrix rows 9 and 10).
//
// The core's keymap is a 512x8 table addressed by {extended, ps2_code}; each
// entry is {row[3:0], col[3:0]} and 0xFF means "unmapped".  Rows 9 and 10 are
// the numeric keypad and used to be entirely empty, so no host key could reach
// them.  This bench drives real PS/2 make/break codes into `keyboard` and reads
// the matrix back through kb_row/kb_data exactly as the PPI does.
//
// The table comes from rtl/peripheral/kbd.mif, converted to $readmemh by
// sim/run_keypad.sh.  NEGCTL=1 rebuilds that table with rows 9/10 forced back
// to 0xFF (the pre-fix state) -- every keypad check MUST then fail, which is
// what proves the checks are actually looking at the keypad and not at nothing.

`timescale 1ns/1ps

module spram #(
   parameter        addr_width    = 8,
   parameter        data_width    = 8,
   parameter string mem_init_file = "",
   parameter string mem_name      = "MEM"
)(
   input                         clock,
   input      [addr_width-1:0]   address,
   input      [data_width-1:0]   data,
   input                         wren,
   output reg [data_width-1:0]   q
);
   reg [data_width-1:0] mem [(2**addr_width)-1:0];
   initial if (mem_init_file != "") $readmemh(mem_init_file, mem);
   always @(posedge clock) begin
      if (wren) mem[address] <= data;
      q <= wren ? data : mem[address];
   end
endmodule

module tb_keypad;

   logic        clk = 0;
   logic        reset = 1;
   logic [10:0] ps2_key = 0;
   logic  [3:0] kb_row = 0;
   logic  [7:0] kb_data;

   always #10 clk = ~clk;

   keyboard dut (
      .clk(clk), .reset(reset),
      .ps2_key(ps2_key),
      .kb_row(kb_row), .kb_data(kb_data),
      .kbd_addr(9'd0), .kbd_din(8'd0), .kbd_we(1'b0), .kbd_request(1'b0)
   );

   int errors = 0;
   logic toggle = 0;

   task automatic settle();
      repeat (6) @(posedge clk);
   endtask

   // press/release one host key and check the matrix bit it owns
   task automatic check_key(input string name,
                            input logic ext, input logic [7:0] code,
                            input int row, input int bitn);
      logic [7:0] want_down, want_up;
      begin
         want_down = 8'hFF ^ (8'h01 << bitn);
         want_up   = 8'hFF;

         toggle = ~toggle;
         ps2_key = {toggle, 1'b1, ext, code};      // make
         settle();
         kb_row = row[3:0];
         settle();
         if (kb_data !== want_down) begin
            $display("FAIL %-12s make : row %0d = %02h, expected %02h (bit %0d low)",
                     name, row, kb_data, want_down, bitn);
            errors++;
         end

         toggle = ~toggle;
         ps2_key = {toggle, 1'b0, ext, code};      // break
         settle();
         if (kb_data !== want_up) begin
            $display("FAIL %-12s break: row %0d = %02h, expected %02h",
                     name, row, kb_data, want_up);
            errors++;
         end
      end
   endtask

   initial begin
      repeat (4) @(posedge clk);
      reset = 0;
      settle();

      // ---- rows 9 and 10: the keypad -----------------------------------
      // 15 of these are lifted verbatim from the shipped
      // Sony_HB-F1XV_128KB.MSX pack; '/' , ',' and keypad-Enter are ours.
      check_key("KP *",     1'b0, 8'h7C,  9, 0);
      check_key("KP +",     1'b0, 8'h79,  9, 1);
      check_key("KP /",     1'b1, 8'h4A,  9, 2);   // E0 4A
      check_key("KP 0",     1'b0, 8'h70,  9, 3);
      check_key("KP 1",     1'b0, 8'h69,  9, 4);
      check_key("KP 2",     1'b0, 8'h72,  9, 5);
      check_key("KP 3",     1'b0, 8'h7A,  9, 6);
      check_key("KP 4",     1'b0, 8'h6B,  9, 7);
      check_key("KP 5",     1'b0, 8'h73, 10, 0);
      check_key("KP 6",     1'b0, 8'h74, 10, 1);
      check_key("KP 7",     1'b0, 8'h6C, 10, 2);
      check_key("KP 8",     1'b0, 8'h75, 10, 3);
      check_key("KP 9",     1'b0, 8'h7D, 10, 4);
      check_key("KP -",     1'b0, 8'h7B, 10, 5);
      check_key("KP ,",     1'b0, 8'h7E, 10, 6);   // ScrollLock stands in
      check_key("KP .",     1'b0, 8'h71, 10, 7);

      // keypad Enter is an alias of RET (row 7 bit 7), like the shift aliases
      check_key("KP Enter", 1'b1, 8'h5A,  7, 7);   // E0 5A

      // ---- regression: ordinary keys must be untouched ------------------
      check_key("A",        1'b0, 8'h1C,  2, 6);
      check_key("Z",        1'b0, 8'h1A,  5, 7);
      check_key("Space",    1'b0, 8'h29,  8, 0);
      check_key("RET",      1'b0, 8'h5A,  7, 7);
      check_key("main /",   1'b0, 8'h4A,  2, 4);
      check_key("STOP",     1'b1, 8'h7C,  7, 4);   // E0 7C -- PrtScr, NOT keypad *

      if (errors == 0) begin
         $display("PASS: keypad rows 9/10 reachable, no regression");
         $finish;
      end else begin
         $display("FAILURES: %0d", errors);
         $fatal(1, "keypad checks failed");
      end
   end

endmodule
