// flash_dirtysave autosave gating: an OSD-open pulse saves ONLY when something
// was programmed since the last completed save (dirty_new), while the manual
// button keeps its always-saves semantics.  SD and SDRAM are crude stubs -- the
// FSM's own paths were proven on hardware; what is under test is the entry
// gating and the dirty_new lifecycle.
`timescale 1ns/1ps

module tb_flash_autosave;

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1;
reg         active = 0, prog_we = 0;
reg  [22:0] prog_addr = 0;
reg         save_req = 0, save_auto = 0, load_req = 0;
reg         img_mounted = 0, img_readonly = 0;
reg  [63:0] img_size = 64'd0;
wire [31:0] sd_lba;
wire        sd_rd, sd_wr;
reg         sd_ack = 0;
reg  [13:0] sd_buff_addr = 0;
reg  [7:0]  sd_buff_dout = 0;
reg         sd_buff_wr = 0;
wire [7:0]  sd_buff_din;
wire [26:0] sdram_addr;
wire        sdram_req, sdram_rnw;
wire [7:0]  sdram_din;
reg  [7:0]  sdram_dout = 8'hA5;
wire        cl_active;

flash_dirtysave #(.RDWAIT(2)) dut (
    .clk(clk), .reset(reset),
    .flash16x_active(active), .flash16x_base(27'h0), .flash16x_size(16'd512), // 8MB
    .prog_we(prog_we), .prog_addr(prog_addr),
    .save_req(save_req), .save_req_auto(save_auto),
    .load_req(load_req), .upload_active(1'b0), .log_clear(1'b0),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sdram_addr(sdram_addr), .sdram_req(sdram_req), .sdram_rnw(sdram_rnw),
    .sdram_din(sdram_din), .sdram_dout(sdram_dout),
    .cl_active(cl_active),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din),
    .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr)
);

// ---- SD stub: ack every rd/wr; feed 512 zero bytes on a read (bad magic) ----
integer sdk;
always begin
    @(posedge clk);
    if (sd_rd | sd_wr) begin
        repeat (4) @(posedge clk);
        if (sd_rd) begin
            for (sdk = 0; sdk < 512; sdk = sdk + 1) begin
                @(negedge clk);
                sd_ack = 1; sd_buff_addr = 14'(sdk); sd_buff_dout = 8'h00; sd_buff_wr = 1;
                @(negedge clk); sd_buff_wr = 0;
            end
        end else begin
            @(negedge clk); sd_ack = 1;
            repeat (8) @(posedge clk);
        end
        @(negedge clk); sd_ack = 0;
        @(posedge clk);
    end
end

integer errors = 0, save_count = 0;
reg sdwr_q = 0;
always @(posedge clk) begin
    sdwr_q <= sd_wr;
    if (sd_wr & ~sdwr_q & sd_lba == 0) save_count = save_count + 1;  // header write = one save
end

task check(input cond, input [200*8-1:0] name);
begin
    if (cond) $display("PASS: %0s", name);
    else begin $display("FAIL: %0s", name); errors = errors + 1; end
end
endtask

task pulse_auto;  begin @(negedge clk); save_auto = 1; repeat(3) @(posedge clk); @(negedge clk); save_auto = 0; end endtask
task pulse_save;  begin @(negedge clk); save_req  = 1; repeat(3) @(posedge clk); @(negedge clk); save_req  = 0; end endtask
task program_one(input [22:0] a);
begin
    @(negedge clk); prog_addr = a; prog_we = 1;
    repeat (2) @(posedge clk);
    @(negedge clk); prog_we = 0; @(posedge clk);
end
endtask
task wait_idle;
integer w;
begin
    w = 0;
    while (dut.st != 0 && w < 3_000_000) begin @(posedge clk); w = w + 1; end
    check(w < 3_000_000, "engine returned to IDLE");
end
endtask

initial begin
    repeat (4) @(posedge clk); reset = 0;
    @(negedge clk); active = 1; img_mounted = 1; img_size = 64'd8388608;
    repeat (4) @(posedge clk);

    // T1: autosave with nothing programmed -> no save at all
    pulse_auto; repeat (50) @(posedge clk);
    check(save_count == 0 && dut.st == 0, "T1 auto with clean cart does nothing");

    // T2: program one byte -> autosave runs one save, then dirty_new is clear
    program_one(23'h012345);
    check(dut.dirty_new[1] === 1'b1, "T2 program sets dirty_new");
    pulse_auto; wait_idle;
    check(save_count == 1, "T2 autosave ran one save");
    check(dut.dirty_new === 128'd0, "T2 completed save cleared dirty_new");
    check(dut.dirty[1] === 1'b1, "T2 dirty (UNION) kept the block");

    // T3: autosave again without new programs -> suppressed
    pulse_auto; repeat (200) @(posedge clk);
    check(save_count == 1 && dut.st == 0, "T3 second auto suppressed (nothing new)");

    // T4: manual save still always saves (rewrites the union)
    pulse_save; wait_idle;
    check(save_count == 2, "T4 manual save unconditionally saves");

    // T5: new program in another block re-arms the autosave
    program_one(23'h100000);
    pulse_auto; wait_idle;
    check(save_count == 3, "T5 new program re-arms the autosave");
    check(dut.dirty_new === 128'd0, "T5 cleared again after the save");

    $display("RESULT: %0d error(s)", errors);
    if (errors) $fatal(1, "tb_flash_autosave FAILED");
    $finish;
end

endmodule
