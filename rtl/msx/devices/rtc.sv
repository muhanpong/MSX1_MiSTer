// RTC device
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

module dev_rtc (
    cpu_bus_if.device_mp    cpu_bus,
    clock_bus_if.base_mp    clock_bus,
    input  MSX::io_device_t io_device[3],
    input            [64:0] rtc_time,
    output            [7:0] data
);

    
    wire [7:0] q;
    wire       io_en       = cpu_bus.iorq && ~cpu_bus.m1;
    wire       cs_io_match = (cpu_bus.addr[7:0] & io_device[0].mask) == io_device[0].port;
    wire       cs_enable   = io_device[0].enable && cs_io_match && io_en;

    assign data      = cs_enable ? q : '1;

    rtc rtc_i
    (
        .clk21m(cpu_bus.clk),
        .reset(cpu_bus.reset),
        .setup(cpu_bus.reset),
        .rt(rtc_time),
        .clkena(clock_bus.ce_10hz),
        .req(cs_enable & cpu_bus.req),
        .ack(),
        .wrt(cpu_bus.wr),
        .adr(cpu_bus.addr),
        .dbi(q),
        .dbo(cpu_bus.data)
    );

endmodule

