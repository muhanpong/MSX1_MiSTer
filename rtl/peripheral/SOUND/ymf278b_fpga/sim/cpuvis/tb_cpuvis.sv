// CPU-visible lockstep bench: drives ymf278b_top through the MoonSound I/O ports
// the way rtl/msx.sv does, from an op script, and logs every access and every
// change of the status bits 1:0.  cpuvis_check.py replays the same accesses at
// the same clock cycles through an openMSX YMF278B model and compares.
//
// plusargs:
//   +ops=<file>   one op per line: <kind> <port_hex> <data_hex> <gap>
//                   W  bridge write (msx.sv: one io_wr pulse, CPU held until io_ack)
//                   R  bridge read  (io_rd pulse, data taken with io_ack)
//                   S  direct status read (msx.sv: status_export sampled, then
//                      status_rd_notify consumes the NEW2 one-shot; no bridge)
//                   P  poll: S every <gap> cycles until (status & data) == 0
//                   X  warm reset: rst_n low for <data> cycles
//                 gap = clk cycles between the previous op's completion and this op
//   +mem=<file>   $readmemh byte file (the sample memory)
//   +lat=<n>      SDRAM read latency in cycles (default 6)
//   +wlat=<n>     SDRAM write latency: mem_busy stays up n cycles after a write
//                 request and the byte lands at the end (default 0: at once)
//   +log=<file>
`timescale 1ns/1ps

module tb_cpuvis #(
    parameter int CLK_HZ = 128863620
);
    localparam real HALF = 1.0e9 / (2.0 * CLK_HZ);
    logic clk = 0;
    always #(HALF) clk = ~clk;
    logic clk_opl3 = 0;
    always #(34.92) clk_opl3 = ~clk_opl3;
    logic rst_n = 0;

    logic [7:0] io_port = 0, io_data_in = 0;
    logic       io_wr = 0, io_rd = 0;
    wire  [7:0] io_data_out;
    wire        io_ack;
    wire  [7:0] status_export;
    logic       status_rd_notify = 0;

    wire [21:0] mem_addr;
    wire        mem_rd_req, mem_wr_req;
    wire [7:0]  mem_wr_data;
    logic [7:0]  mem_rd_data;
    logic [15:0] mem_rd_data16;
    logic [15:0] mem_rd_data16b;    // the pair's other word (engine3)
    logic        mem_rd_valid;

    //  sample memory: same model as tb_golden_pcm (latency, mem_busy while a read waits),
    //  plus an optional write latency (mem_busy while a write waits, as the ch4 bridge)
    logic [7:0] mem [0:4194303];
    int          LAT = 6, WLAT = 0;
    logic        rd_pend = 1'b0, wr_pend = 1'b0;
    int          rd_cnt  = 0, wr_cnt = 0;
    logic [21:0] rd_addr, wr_addr;
    logic [7:0]  wr_byte;
    always_ff @(posedge clk) begin
        mem_rd_valid <= 1'b0;
        if (mem_wr_req && WLAT > 0) begin
            wr_pend <= 1'b1;
            wr_cnt  <= WLAT;
            wr_addr <= mem_addr;
            wr_byte <= mem_wr_data;
        end else if (wr_pend) begin
            if (wr_cnt <= 1) begin
                mem[wr_addr] <= wr_byte;
                wr_pend      <= 1'b0;
            end else wr_cnt <= wr_cnt - 1;
        end
        if (mem_rd_req && !rd_pend) begin
            rd_pend <= 1'b1;
            rd_cnt  <= LAT - 1;
            rd_addr <= mem_addr;
        end else if (rd_pend) begin
            if (rd_cnt <= 1) begin
                mem_rd_data   <= mem[rd_addr];
                mem_rd_data16 <= {mem[{rd_addr[21:1], 1'b1}], mem[{rd_addr[21:1], 1'b0}]};
`ifdef TB_W1_MUT
                mem_rd_data16b <= {mem[{rd_addr[21:1], 1'b1}], mem[{rd_addr[21:1], 1'b0}]};
`else
                mem_rd_data16b <= {mem[{rd_addr[21:1] ^ 21'd1, 1'b1}], mem[{rd_addr[21:1] ^ 21'd1, 1'b0}]};
`endif
                mem_rd_valid  <= 1'b1;
                rd_pend       <= 1'b0;
            end else rd_cnt <= rd_cnt - 1;
        end
        if (mem_wr_req && WLAT == 0) mem[mem_addr] <= mem_wr_data;
    end

    ymf278b_top #(.CLK_HZ(CLK_HZ), .CLK_OPL3(14318182)) dut (
        .clk, .clk_opl3, .rst_n,
        .io_port, .io_data_in, .io_wr, .io_rd, .io_data_out, .io_ack,
        .status_export, .status_rd_notify,
        .mem_addr, .mem_rd_req, .mem_rd_data, .mem_rd_data16, .mem_rd_data16b, .mem_rd_valid,
        .mem_wr_req, .mem_wr_data, .mem_busy(rd_pend | wr_pend),
        .audio_left(), .audio_right(), .audio_valid(), .irq_n(),
        .pcm_mute(1'b0), .fm_mute(1'b0), .pcm_vol(4'd0), .fm_vol(4'd0),
        .dbg_pcm_valid(), .dbg_opl3_valid(), .dbg_pcm_level(), .dbg_new2(),
        .dbg_keyon_count(), .dbg_accum_cnt(), .dbg_env_min(), .dbg_mem_nonzero(),
        .dbg_pcm_base_set(), .dbg_slot_keyon(), .dbg_slot_active(), .dbg_slot_envlive(),
        .dbg_slot0_hdr_start(), .dbg_slot0_dyn_pos(), .dbg_slot0_dyn_env_vol(),
        .dbg_slot0_dyn_env_state(), .dbg_ack_stopped()
    );

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    int fd;
    logic [1:0] st_prev = 2'bxx;
    always @(posedge clk) if (fd != 0 && status_export[1:0] !== st_prev) begin
        $fdisplay(fd, "st %0d %0d", cyc, status_export[1:0]);
        st_prev <= status_export[1:0];
    end

    //  msx.sv's WAIT timeout is 4000 clk21m (~186 us); past that the CPU runs on
    localparam int ACK_TIMEOUT = 24000;

    task automatic bridge(input bit rd, input [7:0] port, input [7:0] din,
                          output longint t_req, output longint t_ack, output [7:0] dout);
        int t;
        @(negedge clk);
        io_port = port; io_data_in = din;
        if (rd) io_rd = 1; else io_wr = 1;
        t_req = cyc;
        @(negedge clk);
        io_rd = 0; io_wr = 0;
        t = 0;
        while (!io_ack && t < ACK_TIMEOUT) begin @(negedge clk); t++; end
        t_ack = io_ack ? cyc : -1;
        dout  = io_data_out;
    endtask

    task automatic status_read(output longint t_req, output [7:0] dout);
        @(negedge clk);
        dout  = status_export;
        t_req = cyc;
        status_rd_notify = 1;
        @(negedge clk);
        status_rd_notify = 0;
    endtask

    initial begin
        string ops_f, mem_f, log_f, ln, kind;
        int fo, code, n;
        int port, data, gap;
        longint t_req, t_ack;
        logic [7:0] dout;
        if (!$value$plusargs("ops=%s", ops_f)) ops_f = "ops.txt";
        if (!$value$plusargs("mem=%s", mem_f)) mem_f = "mem.hex";
        if (!$value$plusargs("log=%s", log_f)) log_f = "cpuvis.log";
        void'($value$plusargs("lat=%d", LAT));
        void'($value$plusargs("wlat=%d", WLAT));
        $readmemh(mem_f, mem);
        for (int a = 0; a < 4194304; a++) if (mem[a] === 8'hxx) mem[a] = 8'h00;
        fd = $fopen(log_f, "w");
        $fdisplay(fd, "clk_hz %0d", CLK_HZ);
        $fdisplay(fd, "cpf %0d", dut.u_pcm.CYCLES_PER_FRAME);
        fo = $fopen(ops_f, "r");
        if (fo == 0) begin $display("FATAL: no ops file"); $finish; end

        repeat (300) @(negedge clk);
        rst_n = 1;
        repeat (50) @(negedge clk);

        n = 0;
        while ($fgets(ln, fo)) begin
            code = $sscanf(ln, "%s %h %h %d", kind, port, data, gap);
            if (code < 4 || kind[0] == "#") continue;
            repeat (gap) @(negedge clk);
            case (kind)
                "W", "R": begin
                    bridge(kind == "R", port[7:0], data[7:0], t_req, t_ack, dout);
                    $fdisplay(fd, "op %0d %s %02x %02x %0d %0d %02x", n, kind, port[7:0], data[7:0],
                              t_req, t_ack, (kind == "R") ? dout : 8'h00);
                end
                "S": begin
                    status_read(t_req, dout);
                    $fdisplay(fd, "op %0d S %02x %02x %0d %0d %02x", n, port[7:0], data[7:0], t_req, t_req, dout);
                end
                "P": begin
                    int polls;
                    polls = 0;
                    do begin
                        if (polls > 0) repeat (gap) @(negedge clk);
                        status_read(t_req, dout);
                        $fdisplay(fd, "op %0d S %02x %02x %0d %0d %02x", n, port[7:0], data[7:0], t_req, t_req, dout);
                        n++;
                        polls++;
                    end while ((dout & data[7:0]) != 0 && polls < 100000);
                    n--;
                end
                "X": begin
                    @(negedge clk);
                    rst_n = 0;
                    t_req = cyc;
                    repeat (data) @(negedge clk);
                    rst_n = 1;
                    $fdisplay(fd, "op %0d X %02x %02x %0d %0d 00", n, port[7:0], data[7:0], t_req, cyc);
                    repeat (50) @(negedge clk);
                end
                default: $display("bad op line: %s", ln);
            endcase
            n++;
        end
        repeat (4000) @(negedge clk);
        $fdisplay(fd, "end %0d", cyc);
        $fclose(fd);
        $display("cpuvis: %0d ops", n);
        $finish;
    end
endmodule
