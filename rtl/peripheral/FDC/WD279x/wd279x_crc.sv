// WD279x FDC
//
// Copyright (c) 2024-2025 Molekula
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Redistributions in synthesized form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// * Neither the name of the author nor the names of other contributors may
//   be used to endorse or promote products derived from this software without
//   specific prior written agreement from the author.
//
// * License is granted for non-commercial use only.  A fee may not be charged
//   for redistributions as source code or in synthesized/hardware form without
//   specific prior written agreement from the author.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//

module wd279x_crc #( 
    parameter int CRC_WIDTH = 16,
    parameter logic [CRC_WIDTH-1:0] POLYNOM = 16'h1021
)(
    input  logic                  clk,
    input  logic [7:0]            data_in,
    input  logic                  valid,
    input  logic                  we,
    output logic [CRC_WIDTH-1:0]  crc
);

    logic [CRC_WIDTH-1:0] crc_reg;
    logic last_valid;

    initial begin
        crc_reg =  {CRC_WIDTH{1'b1}};
    end

    always @(posedge clk) begin
        if (valid) begin
            if (we) begin
                crc_reg <= crc_next(crc_reg, data_in);
            end
        end else begin
            if (last_valid) begin
                crc_reg <=  {CRC_WIDTH{1'b1}};
                crc     <= crc_reg;    
            end
        end
        last_valid <= valid;
    end

    function logic [CRC_WIDTH-1:0] crc_next(logic [CRC_WIDTH-1:0] crc, logic [7:0] data);
        logic [CRC_WIDTH-1:0] new_crc;
        int i;
        
        new_crc = crc ^ ({{CRC_WIDTH-8{1'b0}}, data} << (CRC_WIDTH - 8));
        
        for (i = 0; i < 8; i = i + 1) begin
            if (new_crc[CRC_WIDTH-1]) begin
                new_crc = (new_crc << 1) ^ POLYNOM;
            end else begin
                new_crc = (new_crc << 1);
            end
        end
        
        return new_crc;
    endfunction

endmodule
