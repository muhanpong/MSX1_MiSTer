//  tb_slotb_sram -- a ROM cart in slot B must not reach another device's SRAM.
//
//  memory_upload gives an SRAM only to slot A's ROM cart (bank 0) and does not
//  assign slot B's ROM a ref_sram at all, so slot B's blocks carry whatever the
//  previous record left there: slot A's FM-PAC (bank 1) or the machine's own SRAM
//  (bank 3).  An ASCII8/16 game in slot B that enables "its" SRAM then reads and
//  writes that device's -- harmless while SRAM was lost at power-off, permanent
//  once it is saved to SD.  msx_slots now gives a slot B cart an SRAM only for
//  FM-PAC and GameMaster2.
//
//  Cases, all from msx_slots' own outputs (bram_ce, ram_addr):
//    B1  slot B, ASCII16, ref_sram left at 1 (slot A's FM-PAC, 8 kB): write 10h
//        to 6000h (the SRAM-enable value) and read 4000h -> NO BRAM access
//    A1  slot A, ASCII16, ref_sram 0 (its own 8 kB): same writes -> BRAM at bank 0
//        (control: the rule must not take SRAM away from slot A's cart)
//    F1  slot B, FM-PAC, ref_sram 2: unlock with 4Dh/69h at 5FFEh/5FFFh, read
//        4000h -> BRAM at bank 2 (control: slot B's FM-PAC keeps its SRAM)
//
//  The port declarations are generated from msx_slots.sv by run_slotb_sram.sh.
`timescale 1ns/1ps
import MSX::*;
module tb_slotb_sram;

`include "msx_slots_ports.svh"

msx_slots dut (.*);

initial clk = 0;       always #23.3 clk = ~clk;
initial clk_sdram = 0; always #5.8  clk_sdram = ~clk_sdram;

int errors = 0;
task check(input bit cond, input string name);
   if (cond) $display("PASS: %s", name); else begin $display("FAIL: %s", name); errors++; end
endtask

task automatic idle_bus;
   cpu_mreq = 0; cpu_wr = 0; cpu_rd = 0; cpu_iorq = 0; cpu_m1 = 0;
endtask
task automatic mem_write(input [15:0] a, input [7:0] d);
   @(negedge clk); cpu_addr = a; cpu_dout = d; cpu_mreq = 1; cpu_wr = 1;
   @(negedge clk); @(negedge clk);
   idle_bus(); @(negedge clk);
endtask
//  drive a read and sample the combinational result on the same cycle
task automatic mem_read(input [15:0] a, output logic bce, output logic [26:0] ra);
   @(negedge clk); cpu_addr = a; cpu_mreq = 1; cpu_rd = 1;
   #1; bce = bram_ce; ra = ram_addr;
   @(negedge clk); idle_bus(); @(negedge clk);
endtask

function automatic block_t blk(input mapper_typ_t m, input bit cart, input [1:0] rs, input [1:0] off);
   block_t b;
   b.ref_ram = 4'd0; b.ref_sram = rs; b.offset_ram = off; b.mapper = m;
   b.device = DEVICE_NONE; b.cart_num = cart; b.external = 1'b1;
   return b;
endfunction

task automatic reset_dut;
   reset = 1; repeat (4) @(negedge clk); reset = 0; repeat (2) @(negedge clk);
endtask

initial begin
   logic bce; logic [26:0] ra;
   //  everything quiet and empty
   clk_en = 1; clk_en_cpu = 1; reset = 1; cpu_addr = 0; cpu_dout = 0; idle_bus();
   active_slot = 0; opll_vol = 0; scc_vol = 0; scc_en = 0; scc_ch_en = 0; opll_mute = 1;
   ram_dout = 8'h00; sdram_size = 2'd2; flash_ready = 1; flash_done = 0;
   img_mounted = 0; img_size = 0; img_readonly = 0; sd_ack = 0; sd_buff_addr = 0;
   sd_buff_dout = 0; sd_buff_wr = 0; d_from_sd = 0; sd_ready = 0; midi_rx = 1;
   cpu_turbo = 0; midi_io_en = 0;
   for (int i = 0; i < 64; i++) slot_layout[i] = blk(MAPPER_UNUSED, 1'b0, 2'd0, 2'd0);
   for (int i = 0; i < 16; i++) lookup_RAM[i] = '{addr: 27'd0, size: 16'd0, ro: 1'b1};
   for (int i = 0; i < 4; i++)  lookup_SRAM[i] = '{addr: 18'd0, size: 16'd0, kind: SRAM_KIND_RAW};
   for (int i = 0; i < 8; i++)  msx_dev_ref_ram[i] = 4'd0;
   bios_config = '{default: '0};
   selected_mapper[0] = MAPPER_UNUSED; selected_mapper[1] = MAPPER_UNUSED;
   cart_device[0] = DEV_NONE; cart_device[1] = DEV_NONE; msx_device = DEV_NONE;

   //  a 64 kB ROM for both carts, three SRAMs at distinct BRAM bases
   lookup_RAM[0]  = '{addr: 27'h0100000, size: 16'd4, ro: 1'b1};
   lookup_SRAM[0] = '{addr: 18'h00000, size: 16'd8, kind: SRAM_KIND_RAW};     // slot A cart
   lookup_SRAM[1] = '{addr: 18'h02000, size: 16'd8, kind: SRAM_KIND_FMPAC};   // slot A FM-PAC
   lookup_SRAM[2] = '{addr: 18'h04000, size: 16'd8, kind: SRAM_KIND_FMPAC};   // slot B FM-PAC

   //  B1: slot B (primary 2), pages 1-2, ASCII16, ref_sram inherited = 1
   slot_layout[{2'd2, 2'd0, 2'd1}] = blk(MAPPER_ASCII16, 1'b1, 2'd1, 2'd1);
   slot_layout[{2'd2, 2'd0, 2'd2}] = blk(MAPPER_ASCII16, 1'b1, 2'd1, 2'd2);
   selected_mapper[1] = MAPPER_ASCII16;
   reset_dut(); active_slot = 2'd2;
   mem_write(16'h6000, 8'h10);
   mem_read(16'h4000, bce, ra);
   $display("  B1: bram_ce=%0d ram_addr=%h", bce, ra);
   check(!bce, "B1 slot B ASCII16 with 10h at 6000h: no BRAM (SRAM) access");

   //  A1: slot A (primary 1), ASCII16, own SRAM on bank 0
   slot_layout[{2'd1, 2'd0, 2'd1}] = blk(MAPPER_ASCII16, 1'b0, 2'd0, 2'd1);
   slot_layout[{2'd1, 2'd0, 2'd2}] = blk(MAPPER_ASCII16, 1'b0, 2'd0, 2'd2);
   selected_mapper[0] = MAPPER_ASCII16;
   reset_dut(); active_slot = 2'd1;
   mem_write(16'h6000, 8'h10);
   mem_read(16'h4000, bce, ra);
   $display("  A1: bram_ce=%0d ram_addr=%h", bce, ra);
   check(bce && ra[17:0] == 18'h00000, "A1 slot A ASCII16: SRAM on its own bank 0 (control)");

   //  F1: slot B FM-PAC on bank 2
   slot_layout[{2'd2, 2'd0, 2'd1}] = blk(MAPPER_FMPAC, 1'b1, 2'd2, 2'd0);
   slot_layout[{2'd2, 2'd0, 2'd2}] = blk(MAPPER_UNUSED, 1'b1, 2'd2, 2'd0);
   selected_mapper[1] = MAPPER_UNUSED;
   reset_dut(); active_slot = 2'd2;
   mem_write(16'h5FFE, 8'h4D);
   mem_write(16'h5FFF, 8'h69);
   mem_read(16'h4000, bce, ra);
   $display("  F1: bram_ce=%0d ram_addr=%h", bce, ra);
   check(bce && ra[17:0] == 18'h04000, "F1 slot B FM-PAC: SRAM on bank 2 (control)");

   $display("RESULT: %0d error(s)", errors);
   if (errors) $fatal(1, "tb_slotb_sram FAILED");
   $finish;
end
endmodule
