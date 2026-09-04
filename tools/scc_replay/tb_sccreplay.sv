// Replay a captured SCC+ register write stream (openMSX watchpoint log) into
// scc_sound and dump the rendered wave_A at 3.58 MHz for offline comparison
// against the same-run openMSX solo recording.
`timescale 1ns/1ps
module tb_sccreplay;

reg clk = 0;
always #23.28 clk = ~clk;
reg [2:0] ce_cnt = 0;
reg clk_en = 0;
always @(posedge clk) begin
   ce_cnt <= (ce_cnt == 3'd5) ? 3'd0 : ce_cnt + 3'd1;
   clk_en <= (ce_cnt == 3'd5);
end

reg         reset    = 1;
reg         cs       = 0;
reg         cpu_wr   = 0;
reg         cpu_mreq = 0;
reg  [15:0] cpu_addr = 16'hB800;
reg  [7:0]  din      = 8'h00;
wire signed [15:0] wave;

scc_sound dut (
   .clk(clk), .clk_en(clk_en), .reset(reset),
   .cart_num(1'b0), .cs(cs), .oe(2'b01),
   .cpu_rd(1'b0), .cpu_wr(cpu_wr), .cpu_mreq(cpu_mreq),
   .cpu_addr(cpu_addr), .din(din), .scc_dout(), .wave(wave),
   .sccPlusChip(2'b01), .sccPlusMode(2'b01), .debug_scc_wr()
);

integer tick = 0;
always @(posedge clk) if (clk_en) tick = tick + 1;

// sample dump: 16-bit LE binary at clk_en rate
integer sfd;
initial sfd = $fopen("/home/muhanpong/.claude/jobs/e9af5670/tmp/replay_samples.s16", "wb");
always @(posedge clk) if (clk_en) begin
   $fwrite(sfd, "%c%c", wave & 8'hFF, (wave >> 8) & 8'hFF);
end

// event feed
integer efd, n_ev, r;
reg [31:0] ev_t [0:400000];
reg [7:0]  ev_a [0:400000];
reg [7:0]  ev_d [0:400000];
integer i;
initial begin
   efd = $fopen("/home/muhanpong/.claude/jobs/e9af5670/tmp/replay_events.txt", "r");
   if (efd == 0) begin $display("no events file"); $finish; end
   n_ev = 0;
   while ($fscanf(efd, "%d %h %h\n", ev_t[n_ev], ev_a[n_ev], ev_d[n_ev]) == 3) n_ev = n_ev + 1;
   $display("loaded %0d events", n_ev);

   repeat (60) @(posedge clk); @(negedge clk); reset = 0;

   for (i = 0; i < n_ev; i = i + 1) begin
      while (tick < ev_t[i]) begin @(posedge clk); while (!clk_en) @(posedge clk); end
      @(negedge clk);
      cpu_addr = {8'hB8, ev_a[i]}; din = ev_d[i];
      cs = 1; cpu_mreq = 1; cpu_wr = 1;
      repeat (9) @(posedge clk);
      @(negedge clk);
      cs = 0; cpu_mreq = 0; cpu_wr = 0;
      @(posedge clk);
   end
   // run out to 5.0s
   while (tick < 17897700) begin @(posedge clk); while (!clk_en) @(posedge clk); end
   $display("DONE ticks=%0d", tick);
   $fclose(sfd);
   $finish;
end
endmodule
