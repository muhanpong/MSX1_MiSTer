//  After a no-reset cart swap, where does the end-of-upload restore write?
//
//  flash_dirtysave (the engine MSX1.sv actually instantiates) restores VD0's <rom>.sav
//  into SDRAM at flash16x_base.  Its LOAD trigger is latched:
//        load_pending <= 1  on  load_req = status[39] | load_sram
//        load_ready    =  load_pending & flash16x_active & ~upload_active & image_size>0
//  and load_sram is memory_upload's END-OF-UPLOAD pulse, so a restore is evaluated at
//  the end of EVERY OSD load, not when the user asks.  The latch is deliberate: the
//  comment at flash_dirtysave.sv:139 records that an unlatched pulse fell inside the
//  stretched machine reset and "loading an ASCII16X ROM never read its .sav".
//
//  Waiting for flash16x_active is what makes a cold load work: the pulse arrives before
//  the CPU has touched the new cart, the request waits, and the first ASCII16X access
//  arms flash16x_active AND flash16x_base together, so the restore lands correctly (F).
//
//  The hazard is the other order.  flash16x_active/base/size (msx_slots.sv:812) are set
//  by one cpu_mreq with an ASCII16X or Yamanooto mapper and cleared only by `reset`.
//  With "Reset on ROM change" = No (status[64] = 1) an OSD load does not reset, so after
//  swapping AWAY from a flash cart to a non-flash one the pair is already armed and
//  STALE: load_ready is true immediately, and the restore writes the departed cart's
//  .sav at the departed cart's address (B).
//
//  Checks are written as the behaviour we want, so a failure is the hazard.  The latch
//  and reset chain are lifted from the RTL by sim/mk_uphold_dut.py.
`timescale 1ns/1ps
import MSX::*;

module tb_staleflash;

   //  two different SDRAM regions, so a wrong target is unambiguous
   localparam [26:0] OLD_BASE = 27'h100000;   // the cart we swap away from
   localparam [26:0] NEW_BASE = 27'h400000;   // where the next cart is staged
   localparam int    BLK      = 65536;        // one dirty block = 64 kB
   localparam [63:0] MAGIC    = 64'h4D_46_58_31_36_58_44_42;  // as in flash_dirtysave

   logic clk = 0;
   always #5 clk = ~clk;

   // ---- the real latch and reset chain -------------------------------------
   logic        RESET = 1'b0, reset_now = 1'b0, reset_rq = 1'b0;
   logic [63:0] status_hi = 64'd0;             // bit 0 = status[64]
   mapper_typ_t mapper = MAPPER_NONE;
   logic        cpu_mreq = 1'b0;
   logic [26:0] base_ram = OLD_BASE;           // the region of whatever cart is current
   logic  [1:0] fx_active;
   logic [26:0] fx_base[2];
   logic [15:0] fx_size[2];
   logic        reset, upload_hold, reset_ms;

   uphold_dut u_up (
      .clk21m(clk), .RESET(RESET), .reset_now(reset_now), .reset_rq(reset_rq),
      .status_hi(status_hi), .mapper(mapper), .cpu_mreq(cpu_mreq), .cart_num(1'b0),
      .base_ram(base_ram), .size(16'd4),        // 64 kB cart
      .flash16x_active(fx_active), .flash16x_base(fx_base), .flash16x_size(fx_size),
      .o_reset(reset), .o_upload_hold(upload_hold), .o_reset_ms(reset_ms)
   );

   // ---- the restore engine, as MSX1.sv instantiates it ---------------------
   logic        save_req = 0, save_req_auto = 0, load_req = 0;
   logic        upload_active = 0, upload_active_q = 0;
   wire         log_clear = upload_active & ~upload_active_q;   // MSX1.sv:1316
   always @(posedge clk) upload_active_q <= upload_active;
   logic        img_mounted = 0, img_readonly = 0;
   logic [63:0] img_size = 64'd0;
   logic [26:0] sdram_addr;
   logic        sdram_req, sdram_rnw;
   logic  [7:0] sdram_din;
   logic        cl_active, cl_save;
   logic [31:0] sd_lba;
   logic        sd_rd, sd_wr, sd_ack = 0, sd_buff_wr = 0;
   logic [13:0] sd_buff_addr = 0;
   logic  [7:0] sd_buff_dout = 0;

   //  +fix models the NARROW candidate: gate only the restore request.
   //
   //  An earlier version of this bench gated the engine's flash16x_active instead, and
   //  that was wrong.  Inside flash_dirtysave that one input gates four things:
   //  save_start (123), auto_start (125), load_ready (128) and the DIRTY CAPTURE at
   //  155.  Gating it would stop recording dirty blocks for a flash cart that is still
   //  inserted while an upload targets another slot, so writes in that window would be
   //  missing from the next save -- data loss, in the case the guard exists to protect.
   //  Cases W and D below exist because that version passed without exercising it.
   //
   //  So the gate goes on the request alone, and only when this upload replaced the
   //  slot the armed cart was in:  stale_req = armed & the upload took that slot.
   //  In a cold load the pair is not armed when load_sram fires, so the request is
   //  captured and still waits (F).  In a swap away from the cart it is armed and the
   //  slot was taken, so nothing is captured (B).  When the upload targets another
   //  slot the cart is still there and its base still valid, so the request stands (W).
   logic fix = 1'b0;
   initial fix = $test$plusargs("fix");
   logic upl_hits_cart = 1'b1;     // does this upload replace cart 0's slot?  (RTL: ioctl index)
   wire  stale_req     = fx_active[0] & upl_hits_cart;
   wire  load_req_eff  = fix ? (load_req & ~stale_req) : load_req;

   //  flash programming, so dirty capture is actually exercised
   logic        prog_we = 1'b0;
   logic [22:0] prog_addr = 23'h1000;

   flash_dirtysave #(.RDWAIT(4)) u_ds (
      .clk(clk), .reset(reset),
      .flash16x_active(fx_active[0]), .flash16x_base(fx_base[0]), .flash16x_size(fx_size[0]),
      .prog_we(prog_we), .prog_addr(prog_addr),
      .save_req(save_req), .save_req_auto(save_req_auto), .load_req(load_req_eff),
      .upload_active(upload_active), .log_clear(log_clear),
      .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
      .sdram_addr(sdram_addr), .sdram_req(sdram_req), .sdram_rnw(sdram_rnw),
      .sdram_din(sdram_din), .sdram_dout(8'h00),
      .cl_active(cl_active), .cl_save(cl_save),
      .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr(sd_buff_addr), .sd_buff_din(), .sd_buff_dout(sd_buff_dout),
      .sd_buff_wr(sd_buff_wr)
   );

   // ---- SD model: sector 0 is a valid header naming block 0 as dirty -------
   function automatic [7:0] sec_byte(input [31:0] lba, input int i);
      if (lba != 0)                 sec_byte = 8'h5A;      // payload
      else if (i < 8)               sec_byte = MAGIC[8*i +: 8];
      else if (i == 8)              sec_byte = 8'h02;      // mode = dirty-block
      else if (i == 16)             sec_byte = 8'h01;      // bitmap: block 0
      else                          sec_byte = 8'h00;
   endfunction

   int  sdi = 0;
   logic sd_busy = 0;
   always @(posedge clk) begin
      sd_buff_wr <= 1'b0;
      if ((sd_rd | sd_wr) & ~sd_busy) begin
         sd_busy <= 1'b1; sd_ack <= 1'b1; sdi <= 0;
      end else if (sd_busy) begin
         if (sd_rd) begin
            sd_buff_addr <= 14'(sdi);
            sd_buff_dout <= sec_byte(sd_lba, sdi);
            sd_buff_wr   <= 1'b1;
         end
         if (sdi == 511) begin sd_ack <= 1'b0; sd_busy <= 1'b0; end
         else sdi <= sdi + 1;
      end
   end

   // ---- watch every SDRAM write -------------------------------------------
   int wr_total, wr_old, wr_new;  logic [26:0] wr_first;  logic seen, seen_save;
   always @(posedge clk) begin
      if (cl_active) seen <= 1'b1;
      if (cl_save)   seen_save <= 1'b1;
      if (sdram_req & ~sdram_rnw) begin
         if (wr_total == 0) wr_first <= sdram_addr;
         wr_total <= wr_total + 1;
         if (sdram_addr >= OLD_BASE && sdram_addr < OLD_BASE + BLK) wr_old <= wr_old + 1;
         if (sdram_addr >= NEW_BASE && sdram_addr < NEW_BASE + BLK) wr_new <= wr_new + 1;
      end
   end
   task automatic watch_clear();
      wr_total = 0; wr_old = 0; wr_new = 0; wr_first = 27'd0; seen = 1'b0; seen_save = 1'b0;
   endtask

   int errors = 0;
   task automatic ck(input string what, input logic ok);
      if (!ok) begin errors++; $display("FAIL  %s", what); end
      else                     $display("ok    %s", what);
   endtask

   task automatic machine_reset();
      @(negedge clk); RESET = 1'b1; repeat (4) @(posedge clk);
      @(negedge clk); RESET = 1'b0; repeat (80) @(posedge clk);
   endtask

   task automatic touch_cart(input mapper_typ_t m);
      @(negedge clk); mapper = m; cpu_mreq = 1'b1; @(posedge clk);
      @(negedge clk); cpu_mreq = 1'b0; mapper = MAPPER_NONE; repeat (2) @(posedge clk);
   endtask

   //  an OSD load: log_clear at staging start, load_sram at the end
   task automatic osd_load();
      @(negedge clk); reset_rq = 1'b1; upload_active = 1'b1;
      repeat (2000) @(posedge clk);
      @(negedge clk); reset_rq = 1'b0; upload_active = 1'b0;
      repeat (4) @(posedge clk);
      @(negedge clk); load_req = 1'b1; repeat (2) @(posedge clk);
      @(negedge clk); load_req = 1'b0;
   endtask
   task automatic flash_write();
      @(negedge clk); prog_we = 1'b1; repeat (2) @(posedge clk);
      @(negedge clk); prog_we = 1'b0; repeat (2) @(posedge clk);
   endtask

   task automatic settle();  repeat (2_000_000) @(posedge clk);  endtask

   //  A latched restore request is NOT cleared by `reset` -- only by log_clear or by
   //  the restore starting.  So one case's leftover request will fire inside the next
   //  as soon as some flash access arms the pair, which is how this bench first read
   //  a restore in case Y that belonged to case S.  Cases are isolated with a bare
   //  log_clear: a fixture, not a sequence the machine produces.
   task automatic clear_pending();
      @(negedge clk); upload_active = 1'b1; repeat (4) @(posedge clk);
      @(negedge clk); upload_active = 1'b0; repeat (4) @(posedge clk);
   endtask

   initial begin
      @(negedge clk); img_size = 64'(BLK); img_readonly = 1'b0; img_mounted = 1'b1;
      repeat (2) @(posedge clk); @(negedge clk); img_mounted = 1'b0;
      machine_reset();
      clear_pending();

      //  ---- F: cold boot, first load of a flash cart -----------------------
      status_hi[0] = 1'b1;                       // Reset on ROM change = No
      base_ram = NEW_BASE;                       // this cart is staged here
      watch_clear();
      osd_load();
      touch_cart(MAPPER_ASCII16X);               // now the cart runs and arms the pair
      settle();
      $display("  F : restore=%0d writes=%0d first=%07x old=%0d new=%0d",
               seen, wr_total, wr_first, wr_old, wr_new);
      ck("F1 a cold first load restores the cart's own .sav", seen);
      ck("F2 it restores into that cart's own region",        wr_new == BLK && wr_old == 0);

      //  ---- B: swap AWAY to a non-flash cart, no reset ---------------------
      machine_reset();
      clear_pending();
      status_hi[0] = 1'b1;
      base_ram = OLD_BASE;
      touch_cart(MAPPER_ASCII16X);               // cart 1 runs: arms OLD_BASE
      watch_clear();
      base_ram = NEW_BASE;                       // the OSD stages cart 2 here
      osd_load();
      touch_cart(MAPPER_NONE);                   // cart 2 is not a flash mapper
      settle();
      $display("  B : restore=%0d writes=%0d first=%07x old=%0d new=%0d (active=%b base=%07x)",
               seen, wr_total, wr_first, wr_old, wr_new, fx_active, fx_base[0]);
      ck("B1 nothing is written to the departed cart's region", wr_old == 0);
      ck("B2 no restore runs with a base no cart refreshed",    !seen);

      //  ---- S: the same swap with a machine reset in between --------------
      machine_reset();
      clear_pending();
      status_hi[0] = 1'b1;
      base_ram = OLD_BASE;
      touch_cart(MAPPER_ASCII16X);
      machine_reset();                           // disarms the pair
      watch_clear();
      base_ram = NEW_BASE;
      osd_load();
      touch_cart(MAPPER_NONE);
      settle();
      $display("  S : restore=%0d writes=%0d old=%0d new=%0d", seen, wr_total, wr_old, wr_new);
      ck("S  a reset between the two carts prevents it", wr_old == 0 && !seen);

      //  ---- Y: "Reset on ROM change" = Yes, the default --------------------
      machine_reset();
      clear_pending();
      status_hi[0] = 1'b0;
      base_ram = OLD_BASE;
      touch_cart(MAPPER_ASCII16X);
      watch_clear();
      base_ram = NEW_BASE;
      osd_load();                                // this load resets the machine
      touch_cart(MAPPER_NONE);
      settle();
      $display("  Y : restore=%0d writes=%0d old=%0d new=%0d (active=%b)",
               seen, wr_total, wr_old, wr_new, fx_active);
      ck("Y  the default toggle prevents it", wr_old == 0 && !seen);

      //  ---- W: the upload targets ANOTHER slot; the flash cart stays ------
      //  Its base is still valid, so a restore must still be allowed to run.
      machine_reset();
      clear_pending();
      status_hi[0] = 1'b1;
      base_ram = OLD_BASE;
      touch_cart(MAPPER_ASCII16X);               // the cart is in, and stays in
      watch_clear();
      upl_hits_cart = 1'b0;                      // e.g. a FW PACK, or the other slot
      osd_load();
      settle();
      $display("  W : restore=%0d writes=%0d old=%0d new=%0d",
               seen, wr_total, wr_old, wr_new);
      ck("W  an upload elsewhere still lets the inserted cart restore",
         seen && wr_old == BLK);
      upl_hits_cart = 1'b1;

      //  ---- D: a flash write in that window must still reach the next save --
      machine_reset();
      clear_pending();
      status_hi[0] = 1'b1;
      base_ram = OLD_BASE;
      touch_cart(MAPPER_ASCII16X);
      upl_hits_cart = 1'b0;
      osd_load();                                // the window opens here
      settle();
      watch_clear();
      flash_write();                             // the program writes flash now
      @(negedge clk); save_req = 1'b1; repeat (4) @(posedge clk);
      @(negedge clk); save_req = 1'b0;
      settle();
      $display("  D : save=%0d (dirty capture survived the window)", seen_save);
      ck("D  a flash write during that window is still saved", seen_save);
      upl_hits_cart = 1'b1;

      $display("RESULT: %0d error(s)", errors);
      $finish;
   end

endmodule
