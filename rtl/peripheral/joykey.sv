//  ---------------------------------------------------------------------------
//  Joystick "extra button" -> MSX key matrix
//
//  The MSX joystick port carries two triggers.  A 6-button pad has more, so the
//  buttons past the second press keys instead.  Order follows the CONF_STR "J"
//  token, which puts name n on joystick bit 4+n; this module takes bits 10:6:
//
//     btn[0] Space   row 8 bit 0
//     btn[1] Return  row 7 bit 7
//     btn[2] F1      row 6 bit 5
//     btn[3] Esc     row 7 bit 2
//     btn[4] Stop    row 7 bit 4
//
//  Positions were read back out of kbd.mif, not from a datasheet: PS/2 0x29 ->
//  0x80, 0x5A -> 0x77, 0x05 -> 0x65, 0x76 -> 0x72, 0x17C -> 0x74.
//
//  The matrix is active low, so `mask` marks bits to CLEAR in the row the PPI
//  is currently selecting.
//  ---------------------------------------------------------------------------
module joykey
(
   input        [4:0] btn,
   input        [3:0] kb_row,
   output logic [7:0] mask
);

always_comb begin
   mask = 8'b0;
   case (kb_row)
      4'd8: mask[0] = btn[0];   // Space
      4'd7: begin
               mask[7] = btn[1];   // Return
               mask[2] = btn[3];   // Esc
               mask[4] = btn[4];   // Stop
            end
      4'd6: mask[5] = btn[2];   // F1
      default: ;
   endcase
end

endmodule
