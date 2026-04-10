// PPI device and Keyboard mapper
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

module dev_ppi (
    cpu_bus_if.device_mp    cpu_bus,
    input  MSX::io_device_t io_device[3],
    input  MSX::kb_memory_t kb_upload_memory,
    input            [10:0] ps2_key,
    output            [7:0] data,
    output            [7:0] slot_config,
    output                  tape_motor_on,
    output                  keybeep
);

    
    wire [7:0] q;
    wire [7:0] ppi_out_a, ppi_out_c;
    wire       io_en       = cpu_bus.iorq && ~cpu_bus.m1;
    wire       cs_io_match = (cpu_bus.addr[7:0] & io_device[0].mask) == io_device[0].port;
    wire       cs_enable   = io_device[0].enable && cs_io_match && io_en;

    assign data          = cs_enable ? q : '1;
    assign tape_motor_on = ppi_out_c[4];
    assign keybeep       = ppi_out_c[7];
    assign slot_config   = ppi_out_a;

    jt8255 PPI
    (
        .rst(cpu_bus.reset),
        .clk(cpu_bus.clk),
        .addr(cpu_bus.addr[1:0]),
        .din(cpu_bus.data),
        .dout(q),
        .rdn(~cpu_bus.rd),
        .wrn(~cpu_bus.wr),
        .csn(~cs_enable),
        .porta_din(8'h0),
        .portb_din(d_from_kb),
        .portc_din(8'h0),
        .porta_dout(ppi_out_a),
        .portb_dout(),
        .portc_dout(ppi_out_c),
        .porta_reset_default(io_device[0].param[0] ? 8'hFF : 8'h00),
        .control_reset_default(io_device[0].param[0] ? 7'h0b : 7'h1b)
    );

    //  -----------------------------------------------------------------------------
    //  -- Keyboard decoder
    //  -----------------------------------------------------------------------------
    wire [7:0] d_from_kb;
    keyboard msx_key
    (
        .reset(cpu_bus.reset),
        .clk(cpu_bus.clk),
        .ps2_key(ps2_key),
        .kb_row(ppi_out_c[3:0]),
        .kb_data(d_from_kb),
        .upload_memory(kb_upload_memory)
    );

endmodule

