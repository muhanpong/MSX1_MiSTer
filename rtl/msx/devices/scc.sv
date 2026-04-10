// SCC device
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

module dev_scc (
    cpu_bus_if.device_mp   cpu_bus,
    clock_bus_if.base_mp   clock_bus,
    device_bus             device_bus,
    input MSX::io_device_t io_device[3],
    output   signed [15:0] sound,
    output           [7:0] data
);

    wire signed [10:0] sound_SCC[0:1];
    wire [7:0] data_SCC[2];

    assign sound = (io_device[0].enable ? { {5{sound_SCC[0][10]}}, sound_SCC[0] } : '0) +
                   (io_device[1].enable ? { {5{sound_SCC[1][10]}}, sound_SCC[1] } : '0);

    assign data = cpu_bus.rd ? data_SCC[0] & data_SCC[1] : 8'hFF;

    genvar i;
    generate
        for (i = 0; i < 2; i++) begin : SCC_INSTANCES
            wire cs_dev_bus   = (io_device[i].enable && io_device[i].device_ref == device_bus.device_ref && device_bus.en);
            IKASCC #(.IMPL_TYPE(1), .RAM_BLOCK(1)) SCC_i (
                .i_EMUCLK(cpu_bus.clk),
                .i_MCLK_PCEN_n(~clock_bus.ce_3m58_n),
                .i_RST_n(~cpu_bus.reset),
                .i_CS_n(~cs_dev_bus),
                .i_RD_n(~cpu_bus.rd),
                .i_WR_n(~cpu_bus.wr),
                .i_ABLO(cpu_bus.addr[7:0]),
                .i_ABHI(cpu_bus.addr[15:11]),
                .i_DB(cpu_bus.data),
                .o_DB(data_SCC[i]),
                .o_SOUND(sound_SCC[i])
            );
        end
    endgenerate

endmodule
