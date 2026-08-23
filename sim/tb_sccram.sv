// tb_sccram — SCC+ RAM mode must actually WRITE, not just stop banking
//
// openMSX MSXSCCPlusCart::writeMem is the reference:
//
//     int region = (address >> 13) - 2;
//     if (isRamSegment[region]) {
//         if (isMapped[region]) internalMemoryBank[region][address & 0x1FFF] = value;
//         return;                       // <- and NOT a bank switch
//     }
//     if ((address & 0x1800) == 0x1000) setMapper(region, value);
//
// Two obligations. We already met the second one -- `en_ram` keeps a RAM-mode
// write out of the bank registers, and tb_sccdetect's D5/D6 pin that down. The
// first one was NOT met: `konami_scc.sv` clears `mem_unmaped` for the write, but
// `msx_slots.sv` then gates the SDRAM write on `~ram_ro`, and `ram_ro` is 1 for
// every cart image (`memory_upload.sv` only clears it for ROM_RAM). So the byte
// was silently discarded and a 128KB SCC+ sound cartridge could not be detected
// by the usual write-then-read-back probe.
//
// This bench reproduces msx_slots' write-enable expression around the real
// mapper, so it fails if either half regresses.
//
// Negative control (NEGCTL=1) drops the new ram_we term, restoring the discard.
`timescale 1ns/1ps
`default_nettype none

module tb_sccram;
   logic clk = 0, reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0, cs = 1, cart_num = 0, sccDevice = 1;
   logic [24:0] mem_size = 25'(128*1024);

   wire mem_unmaped, scc_req, ram_we;
   wire [20:0] mem_addr;
   wire  [1:0] scc_mode;

   cart_konami_scc dut(
      .clk(clk), .reset(reset), .mem_size(mem_size), .cpu_addr(cpu_addr),
      .din(din), .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .cs(cs), .cart_num(cart_num), .sccDevice(sccDevice),
      .mem_unmaped(mem_unmaped), .mem_addr(mem_addr),
      .scc_req(scc_req), .scc_mode(scc_mode), .ram_we(ram_we));

   always #5 clk = ~clk;

   // msx_slots.sv's write enable, verbatim in shape:
   //   sdram_ce = ... (cpu_wr & ~ram_ro) & ~mem_unmaped ... | <mapper ram_we>
   // ram_ro is 1 for a cart image, which is exactly why the ram_we term is needed.
   localparam bit RAM_RO = 1'b1;
`ifdef NEGCTL
   wire write_lands = cpu_mreq & cpu_wr & ~RAM_RO & ~mem_unmaped;
`else
   wire write_lands = (cpu_mreq & cpu_wr & ~RAM_RO & ~mem_unmaped) | ram_we;
`endif

   logic [7:0] mem [0:131071];
   initial for (int i = 0; i < 131072; i++) mem[i] = 8'h00;
   always @(posedge clk) if (write_lands) mem[mem_addr[16:0]] <= din;

   int errors = 0, checks = 0;
   task automatic chk(input string n, input bit c);
      begin checks++; if (!c) begin errors++; $display("  FAIL: %s", n); end
            else $display("  ok  : %s", n); end
   endtask

   task automatic w(input [15:0] a, input [7:0] d);
      begin @(negedge clk); cpu_addr=a; din=d; cpu_mreq=1; cpu_wr=1; cpu_rd=0;
            repeat(2) @(posedge clk);
            @(negedge clk); cpu_mreq=0; cpu_wr=0; @(posedge clk); end
   endtask

   initial begin
      repeat(4) @(posedge clk); reset = 0; repeat(4) @(posedge clk);

      // ---- SCC+ mode, all four segments to RAM (mode bit 4) ---------------
      w(16'hBFFE, 8'h30);                    // bit5 = SCC+, bit4 = RAM everywhere

      // ---- a write into each segment must land ----------------------------
      w(16'h4000, 8'h11);  chk("seg0 (0x4000) RAM write lands", mem[mem_addr[16:0]] === 8'h11);
      w(16'h6000, 8'h22);  chk("seg1 (0x6000) RAM write lands", mem[mem_addr[16:0]] === 8'h22);
      w(16'h8000, 8'h33);  chk("seg2 (0x8000) RAM write lands", mem[mem_addr[16:0]] === 8'h33);
      w(16'hA000, 8'h44);  chk("seg3 (0xA000) RAM write lands", mem[mem_addr[16:0]] === 8'h44);

      // ---- the bank-register addresses are RAM too while in RAM mode ------
      // openMSX returns before setMapper, so 0x5000 is a plain RAM byte here.
      w(16'h5000, 8'h55);  chk("0x5000 is RAM, not a bank register", mem[mem_addr[16:0]] === 8'h55);

      // ---- leaving RAM mode: writes must stop landing ---------------------
      w(16'hBFFE, 8'h20);                    // SCC+ on, RAM off
      mem[16'h0100] = 8'h00;
      w(16'h4100, 8'hEE);
      chk("with RAM mode off the write is discarded", mem[mem_addr[16:0]] !== 8'hEE);

      $display("");
      $display("tb_sccram: %0d checks, %0d errors", checks, errors);
`ifdef NEGCTL
      if (errors == 0) $fatal(1, "NEGCTL BROKEN: ram_we removed and writes still landed.");
      $display("negative control OK: %0d failed as required", errors);
      $finish;
`else
      if (errors) $fatal(1, "tb_sccram: %0d of %0d FAILED", errors, checks);
      $finish;
`endif
   end
endmodule
`default_nettype wire
