/*******************************************************************************
#   +html+<pre>
#
#   FILENAME: clk_div.sv
#   AUTHOR: Greg Taylor     CREATION DATE: 13 Oct 2014
#
#   DESCRIPTION:
#   Generates a clk enable pulse based on the frequency specified by
#   OUTPUT_CLK_EN_FREQ.
#
#   CHANGE HISTORY:
#   13 Oct 2014        Greg Taylor
#       Initial version
#
#   Copyright (C) 2014 Greg Taylor <gtaylor@sonic.net>
#
#   This file is part of OPL3 FPGA.
#
#   OPL3 FPGA is free software: you can redistribute it and/or modify
#   it under the terms of the GNU Lesser General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   OPL3 FPGA is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU Lesser General Public License for more details.
#
#   You should have received a copy of the GNU Lesser General Public License
#   along with OPL3 FPGA.  If not, see <http://www.gnu.org/licenses/>.
#
#   Original Java Code:
#   Copyright (C) 2008 Robson Cozendey <robson@cozendey.com>
#
#   Original C++ Code:
#   Copyright (C) 2012  Steffen Ohrendorf <steffen.ohrendorf@gmx.de>
#
#   Some code based on forum posts in:
#   http://forums.submarine.org.uk/phpBB/viewforum.php?f=9,
#   Copyright (C) 2010-2013 by carbon14 and opl3
#
#******************************************************************************/
`timescale 1ns / 1ps
`default_nettype none

module clk_div #(
    parameter CLK_DIV_COUNT = 0,
    // MSX1_MiSTer: fractional mode.  NUM != 0 gives one clk_en per NUM/DEN clk
    // cycles on average (accumulate DEN, wrap at NUM); CLK_DIV_COUNT is then unused.
    parameter NUM = 0,
    parameter DEN = 1
)(
    input wire clk,
    output logic clk_en = 0
);
    generate
    if (NUM == 0) begin : int_div
        logic [$clog2(CLK_DIV_COUNT)-1:0] counter = 0;

        always_ff @(posedge clk)
            if (counter == CLK_DIV_COUNT - 1)
                counter <= 0;
            else
                counter <= counter + 1;

        always_ff @(posedge clk)
            clk_en <= (counter == CLK_DIV_COUNT - 1);
    end else begin : frac_div
        localparam W = $clog2(NUM + DEN);
        logic [W-1:0] acc = 0;

        always_ff @(posedge clk)
            if (acc + W'(DEN) >= W'(NUM)) begin
                acc    <= acc + W'(DEN) - W'(NUM);
                clk_en <= 1'b1;
            end else begin
                acc    <= acc + W'(DEN);
                clk_en <= 1'b0;
            end
    end
    endgenerate
endmodule
`default_nettype wire
