//
// vdp_wait_control.vhd
//   VDP wait controller for VDP command
//   Revision 1.00
//
// Copyright (c) 2008 Takayuki Hara
// All rights reserved.
//
// Redistribution and use of this source code or any derivative works, are
// permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. Redistributions may not be sold, nor may they be used in a commercial
//    product or activity without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
// OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
// WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Revision History
//
// 2nd,Jun,2021 modified by KdL
//  - LMMV is reverted to previous speed in accordance with current VDP module
//
// 9th,Jan,2020 modified by KdL
//  - LMMV fix which improves the Sunrise logo a bit (temporary solution?)
//    Some glitches appear to be unrelated to the VDP_COMMAND entity and
//    the correct speed is not yet reached
//
// 20th,May,2019 modified by KdL
//  - Optimization of speed parameters for greater game compatibility
//
// 14th,May,2018 modified by KdL
//  - Improved the speed accuracy of SRCH, LINE, LMMV, LMMM, HMMV, HMMM and YMMM
//  - Guidelines at http://map.grauw.nl/articles/vdp_commands_speed.php
//
//  - Some evaluation tests:
//    - overall duration of the SPACE MANBOW game intro at 3.58MHz
//    - uncorrupted music in the FRAY game intro at 3.58MHz, 5.37MHz and 8.06MHz
//    - amount of artifacts in the BREAKER game at 5.37MHz
//

module VDP_WAIT_CONTROL (
    input logic RESET,
    input logic CLK21M,

    input logic [7:4] VDP_COMMAND,

    input logic VDPR9PALMODE,      // 0=60Hz (NTSC), 1=50Hz (PAL)
    input logic REG_R1_DISP_ON,    // 0=Display Off, 1=Display On
    input logic REG_R8_SP_OFF,     // 0=Sprite On, 1=Sprite Off
    input logic REG_R9_Y_DOTS,     // 0=192 Lines, 1=212 Lines

    input logic VDPSPEEDMODE,
    input logic DRIVE,

    output logic ACTIVE
);

    logic [15:0] FF_WAIT_CNT;

    // Define WAIT_TABLE_T array for the different command wait times
    typedef logic [15:0] wait_table_t [0:15];
    //-------------------------------------------------------------------------
    //   "STOP",  "XXXX",  "XXXX",  "XXXX", "POINT",  "PSET",  "SRCH",  "LINE",
    //   "LMMV",  "LMMM",  "LMCM",  "LMMC",  "HMMV",  "HMMM",  "YMMM",  "HMMC"
    //-------------------------------------------------------------------------
    // Sprite On, 212 Lines, 50Hz
    const wait_table_t C_WAIT_TABLE_501 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h19E4, 16'h0F30,
        16'h10F8, 16'h1288, 16'h8000, 16'h8000, 16'h119C, 16'h1964, 16'h1590, 16'h8000
    };
    // Sprite On, 192 Lines, 50Hz
    const wait_table_t C_WAIT_TABLE_502 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h18C8, 16'h0E80,
        16'h1018, 16'h11B4, 16'h8000, 16'h8000, 16'h10B0, 16'h1848, 16'h1514, 16'h8000
    };
    // Sprite Off, 212 Lines, 50Hz
    const wait_table_t C_WAIT_TABLE_503 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h1678, 16'h0A10,
        16'h0CE4, 16'h10AC, 16'h8000, 16'h8000, 16'h0CA8, 16'h15F8, 16'h1520, 16'h8000
    };
    // Sprite Off, 192 Lines, 50Hz
    const wait_table_t C_WAIT_TABLE_504 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h15B8, 16'h0A00,
        16'h0C78, 16'h0FFC, 16'h8000, 16'h8000, 16'h0C5C, 16'h1538, 16'h144C, 16'h8000
    };
    // Blank, 50Hz (Test: Sprite On, 212 Lines)
    const wait_table_t C_WAIT_TABLE_505 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h13C4, 16'h08D4,
        16'h0CC4, 16'h0E68, 16'h8000, 16'h8000, 16'h0CAC, 16'h1384, 16'h12DC, 16'h8000
    };
    //-------------------------------------------------------------------------
    //   "STOP",  "XXXX",  "XXXX",  "XXXX", "POINT",  "PSET",  "SRCH",  "LINE",
    //   "LMMV",  "LMMM",  "LMCM",  "LMMC",  "HMMV",  "HMMM",  "YMMM",  "HMMC"
    //-------------------------------------------------------------------------
    // Sprite On, 212 Lines, 60Hz
    const wait_table_t C_WAIT_TABLE_601 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h1AC4, 16'h10F0,
        16'h13DC, 16'h15B4, 16'h8000, 16'h8000, 16'h14CC, 16'h1A44, 16'h182C, 16'h8000
    };
    // Sprite On, 192 Lines, 60Hz
    const wait_table_t C_WAIT_TABLE_602 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h18E4, 16'h0FC0,
        16'h1274, 16'h1424, 16'h8000, 16'h8000, 16'h1318, 16'h1864, 16'h16FC, 16'h8000
    };
    // Sprite Off, 212 Lines, 60Hz
    const wait_table_t C_WAIT_TABLE_603 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h1674, 16'h0AB0,
        16'h0E24, 16'h12B4, 16'h8000, 16'h8000, 16'h0DFC, 16'h15F4, 16'h17B4, 16'h8000
    };
    // Sprite Off, 192 Lines, 60Hz
    const wait_table_t C_WAIT_TABLE_604 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h1564, 16'h0A40,
        16'h0D7C, 16'h11AC, 16'h8000, 16'h8000, 16'h0D58, 16'h14E4, 16'h167C, 16'h8000
    };
    // Blank, 60Hz (Test: Sprite On, 212 Lines)
    const wait_table_t C_WAIT_TABLE_605 = '{
        16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h8000, 16'h1278, 16'h08F0,
        16'h0D58, 16'h0EFC, 16'h8000, 16'h8000, 16'h0D38, 16'h11F8, 16'h13D4, 16'h8000
    };

    always_ff @(posedge CLK21M) begin
        if (RESET) begin
            FF_WAIT_CNT <= '0;
        end else if (DRIVE) begin
            // 50Hz (PAL)
            if (VDPR9PALMODE) begin
                if (REG_R1_DISP_ON) begin
                    // Display On
                    if (!REG_R8_SP_OFF) begin
                        // Sprite On
                        if (REG_R9_Y_DOTS) begin
                            // 212 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_501[VDP_COMMAND];
                        end else begin
                            // 192 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_502[VDP_COMMAND];
                        end
                    end else begin
                        // Sprite Off
                        if (REG_R9_Y_DOTS) begin
                            // 212 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_503[VDP_COMMAND];
                        end else begin
                            // 192 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_504[VDP_COMMAND];
                        end
                    end
                end else begin
                    // Display Off (Blank)
                    FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_505[VDP_COMMAND];
                end
            end else begin
                // 60Hz (NTSC)
                if (REG_R1_DISP_ON) begin
                    // Display On
                    if (!REG_R8_SP_OFF) begin
                        // Sprite On
                        if (REG_R9_Y_DOTS) begin
                            // 212 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_601[VDP_COMMAND];
                        end else begin
                            // 192 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_602[VDP_COMMAND];
                        end
                    end else begin
                        // Sprite Off
                        if (REG_R9_Y_DOTS) begin
                            // 212 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_603[VDP_COMMAND];
                        end else begin
                            // 192 Lines
                            FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_604[VDP_COMMAND];
                        end
                    end
                end else begin
                    // Display Off (Blank)
                    FF_WAIT_CNT <= {1'b0,FF_WAIT_CNT[14:0]} + C_WAIT_TABLE_605[VDP_COMMAND];
                end
            end
        end
    end

    assign ACTIVE = FF_WAIT_CNT[15] | VDPSPEEDMODE;

endmodule
