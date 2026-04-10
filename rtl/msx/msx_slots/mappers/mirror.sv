// Mirror mapper
//
// Copyright (c) 2024 Molekula
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

module mapper_mirror (
    cpu_bus_if.device_mp    cpu_bus,
    block_info              block_info,
    mapper_out              out
);

    wire cs = (block_info.typ == MAPPER_MIRROR) && cpu_bus.mreq && (cpu_bus.rd || cpu_bus.wr);

    wire [16:0] size = 17'(block_info.rom_size[15:0]);
    wire  [3:0] block_count = 4'((size + 17'd8191) >> 13);

    logic [3:0]  prefix;
    logic [15:0] ram_addr;
    
    assign prefix   = (cpu_bus.addr[15:13] + {1'b0, block_info.offset_ram, 1'b0}) % block_count;
    assign ram_addr = {prefix[2:0], cpu_bus.addr[12:0]};
   
    assign out.ram_cs = cs;
    assign out.addr   = cs ? {11'b0, ram_addr} : {27{1'b1}};
    assign out.rnw    = ~(cs && cpu_bus.wr);

endmodule
