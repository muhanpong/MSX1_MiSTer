//  v9968_link -- the V9968's VRAM port onto sdram_tdm's V slot (2026-10-21, sdram128-study).
//
//  The V9968 (rtl/video/v9968, unmodified) runs on clk_vdp = 85.909 MHz and expects
//  vram_rdata_en exactly 8 of its clocks after vram_valid (ip_sdram on the cartridge;
//  its screen fetch samples the word a clock or so later, there is no ready).  One
//  TDM frame of sdram_tdm is 12 clk_sdram = 8 clk_vdp, and its V slot answers a
//  request seen on a frame boundary on the next boundary.  Both clocks come from one
//  PLL and share an edge every 23.28 ns (3 clk_sdram = 2 clk_vdp).  If
//    (a) every frame boundary is the clk_sdram edge 7.76 ns after a shared edge, and
//    (b) the V9968 issues its requests on shared edges, one clk_sdram before a boundary,
//  then the boundary samples vram_valid 7.76 ns after it was launched, and v_rvalid,
//  launched 12 clk_sdram later, is sampled by the V9968 on its edge 3.88 ns after
//  that -- the same edge on which it sampled ip_sdram's rdata_en.  No added latency,
//  no handshake: v_req = vram_valid, vram_rdata_en = v_rvalid.
//
//  (a) v_go: t_vdp toggles on every clk_vdp edge; sampled on clk_sdram it repeats
//      its previous sample exactly on a shared edge (the sample there is the
//      pre-edge value).  v_go = "the previous clk_sdram edge was shared"; sdram_tdm
//      starts its first frame on an edge where v_go is high.
//  (b) the V9968's reset is released on a fixed TDM cycle, RELEASE_PH, after the
//      frames run; its timing generator then keeps the phase for ever (16-clock VRAM
//      slot period = 2 frames).  RELEASE_PH is found by sim/v9968_vram (exactly one
//      value of 12 must pass; the other 11 are the negative controls).
//
//  Monitors (clk_sdram): mon_drop counts frame boundaries where v_req was up and the
//  V slot did not take it (refresh owned the slot); mon_mis counts boundaries where
//  v_req was not up but was up on the edge before or after (a request off the frame
//  grid).  Both must stay 0 in a working system.
module v9968_link #(
    parameter int RELEASE_PH = 0
) (
    input  wire        clk_sdram,
    input  wire        clk_vdp,
    input  wire        rst,            // core reset, any domain (held for many clocks)
    input  wire        sdram_run,      // sdram_tdm's frames are running (clk_sdram)
    input  wire  [3:0] tdm_ph,
    output logic       v_go,
    output logic       vdp_reset_n,    // clk_vdp domain

    //  V9968 side (clk_vdp)
    input  wire [17:2] vram_address,
    input  wire        vram_write,
    input  wire        vram_valid,
    input  wire [31:0] vram_wdata,
    input  wire  [3:0] vram_wdata_mask,   // 1 = do not write that byte
    output logic [31:0] vram_rdata,
    output logic       vram_rdata_en,

    //  sdram_tdm V port (clk_sdram)
    output logic       v_req,
    output logic       v_we,
    output logic [15:0] v_addr,
    output logic [31:0] v_wdata,
    output logic [3:0] v_be,              // 1 = write that byte
    input  wire        v_grant,
    input  wire [31:0] v_rdata,
    input  wire        v_rvalid,

    output logic [15:0] mon_drop,
    output logic [15:0] mon_mis
);
    //  ── (a) the shared edge ───────────────────────────────────────────────
    logic t_vdp = 1'b0;
    always_ff @(posedge clk_vdp) t_vdp <= ~t_vdp;
    logic s1 = 1'b0, s2 = 1'b0;
    always_ff @(posedge clk_sdram) begin s1 <= t_vdp; s2 <= s1; end
    //  s1/s2 are the samples of this edge and the one before: equal = this edge was shared
    assign v_go = (s1 == s2);

    //  ── (b) the V9968's reset ─────────────────────────────────────────────
    logic rel = 1'b0;
    always_ff @(posedge clk_sdram) begin
        if (rst || !sdram_run) rel <= 1'b0;
        else if (tdm_ph == 4'(RELEASE_PH)) rel <= 1'b1;
    end
    always_ff @(posedge clk_vdp) vdp_reset_n <= rel;

    //  ── the port: wires both ways ─────────────────────────────────────────
    assign v_req   = vram_valid;
    assign v_we    = vram_write;
    assign v_addr  = vram_address;
    assign v_wdata = vram_wdata;
    assign v_be    = ~vram_wdata_mask;
    assign vram_rdata    = v_rdata;
    assign vram_rdata_en = v_rvalid;

    //  ── monitors ──────────────────────────────────────────────────────────
    logic req_d = 1'b0, req_dd = 1'b0, bnd_d = 1'b0;
    wire  bnd = (tdm_ph == 4'd11);          // this edge ends cycle 11: the V decision
    always_ff @(posedge clk_sdram) begin
        req_d <= v_req; req_dd <= req_d; bnd_d <= bnd;
        if (rst || !sdram_run) begin mon_drop <= '0; mon_mis <= '0; end
        else begin
            //  v_grant is registered on the boundary edge: look one edge later
            if (bnd_d && req_d && !v_grant && mon_drop != '1) mon_drop <= mon_drop + 1'b1;
            if (bnd_d && !req_d && (req_dd || v_req) && mon_mis != '1) mon_mis <= mon_mis + 1'b1;
        end
    end
endmodule
