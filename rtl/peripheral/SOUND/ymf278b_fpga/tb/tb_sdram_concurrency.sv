// SDRAM ch2/ch4 concurrency integrity TB.
//
// Drives the REAL rtl/peripheral/sdram.sv with a behavioral SDRAM-chip model
// and hammers ch2 (CPU) + ch4 (PCM) with concurrent reads, checking that ch4
// always returns the data for ITS OWN address (never ch2's / stale).  This is
// the one thing HDRCHK (static, no concurrency) and the clean-memory golden
// sims cannot test: does ch4 read corrupt under ch2 contention on the actual
// SDRAM controller?  The model returns a deterministic hash of the
// reconstructed word address, so any cross-channel contamination is detectable.
`timescale 1ns/1ps
module tb_sdram_concurrency;
    reg clk = 0;
    always #5.82 clk = ~clk;          // 85.909 MHz (clk_sdram)
    reg init = 1;

    // SDRAM chip pins
    wire [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire        SDRAM_DQML, SDRAM_DQMH;
    wire  [1:0] SDRAM_BA;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

    // channel buses
    reg  [26:0] ch2_addr=0, ch4_addr=0;
    reg         ch2_req=0,  ch4_req=0;
    reg         ch2_rnw=1,  ch4_rnw=1;
    reg   [7:0] ch2_din=0,  ch4_din=0;
    wire  [7:0] ch2_dout, ch4_dout;
    wire [15:0] ch4_dout16;
    wire        ch2_ready, ch4_ready;
    // unused channels
    wire [7:0] ch1_dout, ch3_dout;  wire ch1_ready, ch3_ready, ch3_done;

    sdram dut (
        .init(init), .clk(clk), .doRefresh(1'b0),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .ch1_addr(27'd0), .ch1_din(8'd0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_dout(ch1_dout), .ch1_ready(ch1_ready),
        .ch2_addr(ch2_addr), .ch2_din(ch2_din), .ch2_req(ch2_req), .ch2_rnw(ch2_rnw), .ch2_dout(ch2_dout), .ch2_ready(ch2_ready),
        .ch3_addr(27'd0), .ch3_din(8'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_dout(ch3_dout), .ch3_ready(ch3_ready), .ch3_done(ch3_done),
        .ch4_addr(ch4_addr), .ch4_din(ch4_din), .ch4_req(ch4_req), .ch4_rnw(ch4_rnw),
        .ch4_dout(ch4_dout), .ch4_dout16(ch4_dout16), .ch4_ready(ch4_ready)
    );

    // ───────────────────────────────────────────────────────────────────────
    // Behavioral SDRAM chip model.  Decodes ACTIVE/READ, reconstructs the word
    // address the controller encoded, drives DQ = hash(word_addr) CAS_LATENCY
    // cycles after READ.  hash is address-deterministic so contamination shows.
    // ───────────────────────────────────────────────────────────────────────
    localparam CAS = 2;
    wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
    localparam [2:0] C_ACTIVE=3'b011, C_READ=3'b101, C_WRITE=3'b100;

    reg [12:0] m_row [0:3];      // latched row per bank
    reg [24:0] rd_word;          // reconstructed word addr of in-flight read
    reg [15:0] dq_pipe [0:3];    // CAS pipeline of read data
    reg        dq_drv  [0:3];    // drive-enable pipeline
    integer i;

    // reconstruct: ACTIVE latches row+bank; READ col=A[8:0], A9 extra bit.
    //   word_addr[24:1 mapping]:  addr[25]=A9, addr[24:23]=bank, addr[22:10]=row, addr[9:1]=col
    function [24:0] recon(input [12:0] row, input [1:0] bank, input [12:0] a_at_read);
        reg a9; reg [8:0] col;
        begin
            a9  = a_at_read[9];
            col = a_at_read[8:0];
            recon = {a9, bank, row, col};   // = the controller's addr[25:1]
        end
    endfunction
    function [15:0] hash(input [24:0] wa);
        hash = wa[15:0] ^ 16'hA5A5;          // address-deterministic, non-trivial
    endfunction

    always @(posedge clk) begin
        // shift CAS pipeline
        for (i=0;i<3;i=i+1) begin dq_pipe[i]<=dq_pipe[i+1]; dq_drv[i]<=dq_drv[i+1]; end
        dq_drv[3]<=0;
        if (!SDRAM_nCS) begin
            if (cmd==C_ACTIVE) m_row[SDRAM_BA] <= SDRAM_A;
            if (cmd==C_READ) begin
                rd_word = recon(m_row[SDRAM_BA], SDRAM_BA, SDRAM_A);
                dq_pipe[CAS-1] <= hash(rd_word);   // valid CAS cycles later
                dq_drv [CAS-1] <= 1'b1;
            end
            // WRITE ignored (test is read integrity)
        end
    end
    assign SDRAM_DQ = dq_drv[0] ? dq_pipe[0] : 16'bz;

    // ───────────────────────────────────────────────────────────────────────
    // Test
    // ───────────────────────────────────────────────────────────────────────
    integer errors=0, ch4_reads=0;
    task ch4_read(input [26:0] a);
        reg [15:0] exp;
        begin
            @(negedge clk); ch4_addr=a; ch4_req=1; ch4_rnw=1;
            @(posedge ch4_ready);
            @(negedge clk); ch4_req=0;
            exp = hash(a[25:1]);
            ch4_reads = ch4_reads+1;
            if (ch4_dout16 !== exp) begin
                errors=errors+1;
                if (errors<=20) $display("  ch4 MISMATCH @%07h: got %04h exp %04h", a, ch4_dout16, exp);
            end
            @(negedge clk);
        end
    endtask

    // continuous ch2 hammering (CPU contention) running in parallel
    reg ch2_hammer=0;
    integer ch2_a=0;
    always begin
        @(negedge clk);
        if (ch2_hammer) begin
            ch2_addr = 27'h0000000 + (ch2_a<<1); ch2_req=1; ch2_rnw=1;
            @(posedge ch2_ready); @(negedge clk); ch2_req=0;
            ch2_a = (ch2_a+1) & 16'hFFFF;
        end
    end

    integer k;
    initial begin
        repeat(20) @(negedge clk); init=0;
        // wait out SDRAM startup
        repeat(13000) @(posedge clk);
        $display("startup done, ch4_ready=%b", ch4_ready);

        // Phase 1: ch4 alone — sanity (model + reconstruction correct?)
        for (k=0;k<64;k=k+1) ch4_read(27'h0200000 + (k*22'h137));
        $display("PHASE1 (ch4 alone): %0d reads, %0d errors", ch4_reads, errors);

        // Phase 2: ch4 reads under heavy ch2 contention (the real test)
        ch2_hammer=1;
        for (k=0;k<2000;k=k+1)
            ch4_read(27'h0200000 + ((k*22'h2B7) & 27'h01FFFFE));  // spread across custom RAM
        ch2_hammer=0;
        $display("PHASE2 (ch4 + ch2 hammer): %0d total reads, %0d errors", ch4_reads, errors);

        if (errors==0) $display("=== PASS: ch4 read integrity holds under ch2 contention ===");
        else           $display("=== FAIL: %0d ch4 reads corrupted (concurrency bug!) ===", errors);
        $finish;
    end

    initial begin #50ms; $display("TIMEOUT"); $finish; end
endmodule
