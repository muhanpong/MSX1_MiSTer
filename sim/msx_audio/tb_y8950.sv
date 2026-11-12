// Bench for y8950_addon: runs a script (see y8950_model.py) and writes the same log format.
`timescale 1ns/1ps
module tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, tick = 0, wr = 0, rd = 0;
    logic [7:0] addr = 0, wdata = 0;
    wire  [7:0] rdata, status;
    wire        busy, irq_n, fm_wr;
    wire  [7:0] fm_addr, fm_data;
    wire [17:0] mem_addr;
    wire        mem_rd, mem_wr;
    wire  [7:0] mem_wdata;
    logic [7:0] mem_rdata;
    logic       mem_done = 0;
    wire signed [15:0] adpcm_out, dac_out;

    y8950_addon dut (.*);

    //  sample RAM: answers MEMLAT clocks after the request rises
    int MEMLAT = 3;
    logic [7:0] ram [0:262143];
    int mcnt = 0;
    always @(posedge clk) begin
        mem_done <= 0;
        if ((mem_rd | mem_wr) && !mem_done) begin
            mcnt <= mcnt + 1;
            if (mcnt == MEMLAT) begin
                if (mem_wr) ram[mem_addr] <= mem_wdata;
                mem_rdata <= ram[mem_addr];
                mem_done  <= 1;
                mcnt      <= 0;
            end
        end
        else mcnt <= 0;
    end

    int fo;
    always @(posedge clk) if (fm_wr) $fdisplay(fo, "F %02x %02x", fm_addr, fm_data);

    task automatic op(input logic w, input [7:0] a, input [7:0] d);
        @(posedge clk); addr <= a; wdata <= d; wr <= w; rd <= ~w;
        @(posedge clk); wr <= 0; rd <= 0;
        @(posedge clk);
        while (busy) @(posedge clk);
    endtask

    string script, logn, cmd;
    int fi, a, d, n, r, lat;
    initial begin
        if (!$value$plusargs("script=%s", script)) $fatal(1, "no +script");
        if (!$value$plusargs("log=%s", logn)) $fatal(1, "no +log");
        if ($value$plusargs("memlat=%d", lat)) MEMLAT = lat;
        for (int i = 0; i < 262144; i++) ram[i] = 8'hFF;
        fi = $fopen(script, "r"); fo = $fopen(logn, "w");
        repeat (4) @(posedge clk); rst_n <= 1; repeat (4) @(posedge clk);
        while (!$feof(fi)) begin
            r = $fscanf(fi, "%s", cmd);
            if (r != 1) break;
            if (cmd == "W") begin
                r = $fscanf(fi, "%h %h", a, d);
                op(1, a[7:0], d[7:0]);
            end
            else if (cmd == "R") begin
                r = $fscanf(fi, "%h", a);
                op(0, a[7:0], 8'h00);
                $fdisplay(fo, "R %02x %02x", a[7:0], rdata);
            end
            else if (cmd == "S") begin
                @(posedge clk);
                $fdisplay(fo, "S %02x", status);
            end
            else if (cmd == "T") begin
                r = $fscanf(fi, "%d", n);
                repeat (n) begin
                    @(posedge clk); tick <= 1;
                    @(posedge clk); tick <= 0;
                    repeat (40 + 2 * MEMLAT) @(posedge clk);
                    $fdisplay(fo, "A %0d %0d %0d", adpcm_out, dac_out, ~irq_n);
                end
            end
        end
        $fclose(fo);
        $finish;
    end
endmodule
