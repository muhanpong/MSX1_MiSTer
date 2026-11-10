// joymega.sv, 3- and 6-button, against openMSX JoyMega.cc (cycleMask 1 / 7) on
// random pin-8 sequences, with idle gaps longer and shorter than the timeout.
`timescale 1ns/1ps
module tb_kinds;
  localparam TO = 16'd200;
  logic clk=0, reset=1, pin8=0, six=1; logic [11:0] btn=0; wire [5:0] dout;
  joymega #(.TIMEOUT(TO)) dut(.clk(clk),.reset(reset),.pin8(pin8),.six(six),.btn(btn),.dout(dout));
  always #5 clk=~clk;
  function automatic [5:0] omsx(input int cyc, input [11:0] st);
    case (cyc)
      0,2,4: omsx = 6'((st & 12'h00f) | ((st & 12'h060) >> 1));
      1,3:   omsx = 6'((st & 12'h013) | ((st & 12'h080) >> 2));
      5:     omsx = 6'((st & 12'h010) | ((st & 12'h080) >> 2));
      6:     omsx = 6'(((st & 12'h400) >> 10) | ((st & 12'hA00) >> 8) | ((st & 12'h100) >> 6) | ((st & 12'h060) >> 1));
      default: omsx = 6'((st & 12'h010) | ((st & 12'h080) >> 2) | 12'h00f);
    endcase
  endfunction
  int cyc, mask, idle, fails=0, checks=0, k, kind;
  initial begin
    for (kind=0; kind<2; kind++) begin
      six = kind; mask = kind ? 7 : 1;
      reset=1; pin8=0; repeat(3) @(posedge clk); reset=0; cyc=0; idle=0;
      for (k=0; k<4000; k++) begin
        int gap; gap = ($urandom%8==0) ? TO+20 : 1+$urandom%30;
        btn = $urandom;
        repeat(gap) @(posedge clk);
        idle += gap; if (idle > TO) cyc = 0;        // checkTime (edge based)
        checks++; if (dout !== omsx(cyc, ~btn)) begin fails++; if (fails<6) $display("FAIL six=%0d k=%0d cyc=%0d pin8=%0d dout=%06b want=%06b", six,k,cyc,pin8,dout,omsx(cyc,~btn)); end
        if ($urandom%4 != 0) begin                    // an edge (else no change)
          pin8 = ~pin8; @(posedge clk); #1;
          if (pin8 != (cyc & 1)) cyc = (cyc + 1) & mask; // write(): step only on disagreement
          idle = 0;
        end
      end
    end
    $display("%0d checks, %0d failed", checks, fails);
    if (fails) $display("FAILED"); else $display("PASSED"); $finish;
  end
endmodule
