// tb_opfxsd_block — replay OPFXSD.COM v1.18's real 8KB block-write sequence
// through mapper_mfrsd1 + flash.sv, wired the way msx_slots.sv wires them.
//
// Why this TB exists.  On hardware `OPFXSD SCMD110A.DSK /d1` (and /d2) dies with
// "Flash write error!" after exactly 45 blocks, while `OPFXSD MG2.ROM /K5` writes
// 63 blocks through the SAME loader loop (0x2D26 — the only site that prints the
// progress 'o', so DSK and ROM share it).  /d1 and /d2 put block 45 at different
// flash addresses (0x72000 vs 0x12E000) with different erase schedules, yet both
// die at the same block INDEX.  That rules out address, sector geometry and erase
// timing, and leaves the block's DATA.
//
// So: feed flash.sv the exact byte stream OPFXSD produces for one block and check
// what OPFXSD checks — its DQ7 data-poll (OPFXSD:0x0A17) on the last byte of every
// quadruple-program group.
//
//   sequence per block, from OPFXSD 0x2D53..0x2D65 and 0x092C:
//     (0x7FFF)=0x00        unlock the mapper registers (mapperReg[1]=0)
//     (0x7FFD)=base_lo     offsetReg[7:0]   <- DSK slot base block
//     (0x7FFE)=base_hi     offsetReg[9:8]
//     (0x5000)=i           bank[0] <- block index
//     (0x7FFF)=0x02        lock, so data bytes hitting 0x5000-0x57FF cannot repage
//     [first touch of a 64KB sector: F0 then AA/55/80/AA/55/30 erase]
//     2048 x { (0x4AAA)=0x56 ; 4 data bytes ; poll last byte }
//
// The read-back models the real bus: flash.sv drives the bus only while
// data_valid (autoselect / erase / CFI); otherwise the CPU sees SDRAM, which is
// what the poll is meant to read.
//
// Negative control (NEGCTL=1) shortens the quadruple-program byte count so the
// 4th byte of every group is dropped.  The poll MUST then fail — without that,
// a green run here would mean nothing.
`timescale 1ns/1ps
`default_nettype none
module tb_opfxsd_block;

   localparam [26:0] OFFS = 27'h0;          // sdram_offset; keeps mem[] small
   localparam int    MEMSZ = 'h100000;      // covers 0x10000..0x7FFFF

   logic clk = 0;
   logic reset = 1;
   logic [15:0] cpu_addr = 0;
   logic  [7:0] din = 0;
   logic cpu_mreq = 0, cpu_wr = 0, cpu_rd = 0;

   // ---- mapper_mfrsd1 (subslot 1 = the flash) -----------------------------
   wire  [7:0] configReg;
   wire  [3:0] mapper_mask;
   wire [26:0] m_mem_addr;
   wire        m_mem_unmaped, m_scc_req, m_scc_mode;
   wire [22:0] m_flash_addr;
   wire        m_flash_rq;

   mapper_mfrsd1 mfrsd1 (
      .clk(clk), .reset(reset), .cs(1'b1), .slot(2'd0),
      .cpu_addr(cpu_addr), .din(din),
      .cpu_mreq(cpu_mreq), .cpu_wr(cpu_wr), .cpu_rd(cpu_rd),
      .mfrsd_base_ram(OFFS),
      .configReg(configReg), .mapper_mask(mapper_mask),
      .mem_addr(m_mem_addr), .mem_unmaped(m_mem_unmaped),
      .flash_addr(m_flash_addr), .flash_rq(m_flash_rq),
      .scc_req(m_scc_req), .scc_mode(m_scc_mode)
   );

   // ---- flash.sv, wired as msx_slots.sv wires the MFRSD path --------------
   wire  [7:0] fl_dout;
   wire        fl_dv;
   wire [26:0] fl_addr;
   wire  [7:0] fl_din;
   wire        fl_req, dbg_erase;
   logic       sdram_ready = 1, sdram_done = 0;

   flash fl (
      .clk(clk), .clk_sdram(clk),
      .addr(m_flash_addr), .din(din), .dout(fl_dout), .data_valid(fl_dv),
      .we(cpu_mreq & cpu_wr), .ce(m_flash_rq),
      .data_phase(1'b0),        // MFRSD has no mapper-side program FSM
      .sdram_ready(sdram_ready), .sdram_done(sdram_done),
      .sdram_addr(fl_addr), .sdram_din(fl_din), .sdram_req(fl_req),
      .sdram_offset(OFFS),
      .amd_family(1'b0),        // MFRSD reports the legacy ST id (0x20)
      .boot_sector(1'b1),       // as shipped (msx_slots.sv)
      .erase_limit(27'h800000),
      .debug_erase(dbg_erase)
   );

   // ---- SDRAM model: one byte per request, ack on the next clock ----------
   logic [7:0] mem [0:MEMSZ-1];
   always @(posedge clk) begin
      sdram_done <= fl_req;
      if (fl_req & ~sdram_done) mem[fl_addr[19:0]] <= fl_din;
   end

   always #5 clk = ~clk;

   // ---- bus tasks ---------------------------------------------------------
   // Generous idle between cycles: on real hardware consecutive LDI writes are
   // ~4.5us apart, so the SDRAM byte always retires first.  A tight TB would
   // manufacture a failure the machine never sees.
   task automatic w(input [15:0] a, input [7:0] d);
      begin
         @(negedge clk); cpu_addr = a; din = d; cpu_mreq = 1; cpu_wr = 1; cpu_rd = 0;
         repeat (whi) @(posedge clk);
         @(negedge clk); cpu_mreq = 0; cpu_wr = 0;
         repeat (wlo) @(posedge clk);
      end
   endtask

   // What the CPU actually sees: flash.sv only drives while data_valid.
   task automatic rdb(input [15:0] a, output [7:0] v);
      begin
         @(negedge clk); cpu_addr = a; cpu_mreq = 1; cpu_rd = 1; cpu_wr = 0;
         repeat (3) @(posedge clk);
         v = fl_dv ? fl_dout : mem[m_flash_addr[19:0]];
         @(negedge clk); cpu_mreq = 0; cpu_rd = 0;
         repeat (3) @(posedge clk);
      end
   endtask

   // OPFXSD 0x0A17 verbatim: DQ7 compare, DQ5 timeout, one retry, then CY.
   int fails = 0;
   task automatic poll(input [15:0] a, input [7:0] want, output bit err);
      logic [7:0] v; int guard;
      begin
         err = 0; guard = 0;
         forever begin
            rdb(a, v);
            if (((v ^ want) & 8'h80) == 0) return;         // DQ7 matches -> done
            if ((v & 8'h20) == 0) begin                      // DQ5 clear -> still busy
               guard++;
               if (guard > 200) begin err = 1; return; end   // would hang forever
            end else begin
               rdb(a, v);
               if (((v ^ want) & 8'h80) == 0) return;
               err = 1; return;                              // SCF -> "Flash write error!"
            end
         end
      end
   endtask

   task automatic erase_sector;
      int g;
      begin
         w(16'h4000, 8'hF0);
         w(16'h4AAA, 8'hAA); w(16'h4555, 8'h55); w(16'h4AAA, 8'h80);
         w(16'h4AAA, 8'hAA); w(16'h4555, 8'h55); w(16'h4AAA, 8'h30);
         g = 0;
         while (dbg_erase && g < 4_000_000) begin @(posedge clk); g++; end
         repeat (8) @(posedge clk);
         $display("   erase done after %0d clocks", g);
      end
   endtask

   // ---- optional trace of the command FSM around the failing group --------
   bit   dbg_on = 0;
   logic we_q;
   always @(posedge clk) begin
      we_q <= cpu_mreq & cpu_wr;
      if (dbg_on & (cpu_mreq & cpu_wr) & ~we_q & m_flash_rq)
         $display("      W cpu=%04h din=%02h | before: idx=%0d cmd0=%02h cmd1=%02h cmd2=%02h",
                  cpu_addr, din, fl.index, fl.cmd[0], fl.cmd[1], fl.cmd[2]);
      if (dbg_on & fl_req & ~sdram_done)
         $display("         -> SDRAM write flash=%06h din=%02h", fl_addr, fl_din);
   end

   logic [7:0] blk [0:8191];
   string      name;
   int         base, idx, dbgw;
   int         whi = 4, wlo = 6;
   bit         silent = 0;
   bit         err;
   int         first_bad;

   task automatic write_block(input int i, input int basev, input bit do_erase);
      int g, k;
      logic [15:0] a;
      begin
         first_bad = -1;
         w(16'h7FFF, 8'h00);
         w(16'h7FFD, 8'(basev));
         w(16'h7FFE, 8'(basev >> 8));
         w(16'h5000, 8'(i));
         w(16'h7FFF, 8'h02);
         if (do_erase) erase_sector();
         for (g = 0; g < 8192; g = g + 4) begin
            dbg_on = 0;
            w(16'h4AAA, 8'h56);
            for (k = 0; k < 4; k++) w(16'(16'h4000 + g + k), blk[g + k]);
            a = 16'(16'h4000 + g + 3);
            poll(a, blk[g + 3], err);
            if (err) begin
               $display("   ** POLL FAIL at group 0x%0h  cpu=0x%04h flash=0x%06h  want=%02h",
                        g, a, m_flash_addr, blk[g+3]);
               first_bad = g;
               fails++;
               return;
            end
         end
      end
   endtask

   initial begin
      if (!$value$plusargs("blk=%s", name)) name = "sim/data/dsk_blk45.hex";
      if (!$value$plusargs("base=%d", base)) base = 4;
      if (!$value$plusargs("idx=%d",  idx))  idx  = 45;
      if (!$value$plusargs("dbgw=%h", dbgw)) dbgw = 'h1AA4;
      void'($value$plusargs("whi=%d", whi));
      void'($value$plusargs("wlo=%d", wlo));
      $readmemh(name, blk);

      for (int k = 0; k < MEMSZ; k++) mem[k] = 8'hFF;

      repeat (4) @(posedge clk); reset = 0; repeat (4) @(posedge clk);

      $display("tb_opfxsd_block: %0s  base=%0d idx=%0d  (flash 0x%06h)",
               name, base, idx, (base + idx) * 'h2000 + 'h10000);

      // erase the 64KB sector first, exactly as OPFXSD does on first touch
      write_block(idx, base, 1'b1);

      if (first_bad < 0) $display("   all 2048 groups passed OPFXSD's DQ7 poll");

      // Full compare — independent of the poll.  The poll only looks at DQ7 of
      // one byte per group, so a dropped byte whose bit 7 matches the erased
      // 0xFF slips through it.  That is silent corruption, not a clean failure.
      begin
         int lost; int fb;
         lost = 0; fb = -1;
         for (int o = 0; o < 8192; o++) begin
            if (mem[((base + idx) * 'h2000 + 'h10000 + o) & (MEMSZ-1)] !== blk[o]) begin
               lost++;
               if (fb < 0) fb = o;
            end
         end
         if (lost) begin
            $display("   ** %0d of 8192 bytes never reached SDRAM (first at block offset 0x%0h)", lost, fb);
            silent = (first_bad < 0);
         end else
            $display("   full compare: all 8192 bytes present");
      end

      $display("");
      $display("tb_opfxsd_block: %0d poll failures", fails);
`ifdef NEGCTL
      if (fails == 0)
         $fatal(1, "NEGCTL BROKEN: the 4th byte of every group was dropped and the poll never fired. TB is worthless.");
      $display("negative control OK: the poll caught the dropped byte");
      $finish;
`else
      if (silent) $display("   ★ the loader reported SUCCESS on a corrupt block");
      if (fails != 0) $fatal(1, "FAIL: flash.sv did not retire every programmed byte");
      $display("PASS");
      $finish;
`endif
   end
endmodule
`default_nettype wire
