//  Launch-to-capture distance of the V9968 -> sdram_tdm crossing (2026-10-24).
//  For every frame-boundary edge (ps[11], where sdram_tdm takes v_req / v_addr / v_we /
//  v_wdata / v_be), the time since each source register last changed.  A set_max_delay
//  of 7.76 ns on these paths is valid only if no source ever changes closer than 7.76 ns
//  before a boundary edge that reads it (and none changes between that edge and the
//  previous one's 3.88 ns pair).  Bound into tb; observation only.
module edge_probe;
    realtime t_valid = -1e9, t_addr = -1e9, t_we = -1e9, t_wd = -1e9, t_mask = -1e9;
    realtime dmin_valid = 1e9, dmin_addr = 1e9, dmin_we = 1e9, dmin_wd = 1e9, dmin_mask = 1e9;
    longint  n_bound = 0, n_req = 0, n_launch_off = 0, n_launch = 0;
    logic        p_valid; logic [17:0] p_addr; logic p_we; logic [31:0] p_wd; logic [3:0] p_mask;
    `define VI tb.vdp9968.u_vram_interface
    always @(posedge tb.clk_vdp) begin
        #1;
        if (`VI.ff_vram_valid      !== p_valid) t_valid = $realtime;
        if (`VI.ff_vram_address    !== p_addr)  t_addr  = $realtime;
        if (`VI.ff_vram_write      !== p_we)    t_we    = $realtime;
        if (`VI.ff_vram_wdata      !== p_wd)    t_wd    = $realtime;
        if (`VI.ff_vram_wdata_mask !== p_mask)  t_mask  = $realtime;
        if (`VI.ff_vram_valid && !p_valid) begin
            n_launch++;
            //  shared edge: t mod 23.28 ns == 0 (both clocks rise at t = 0 in this bench)
            if ((longint'($realtime - 1) % 64'd23280) != 0) n_launch_off++;
        end
        p_valid = `VI.ff_vram_valid; p_addr = `VI.ff_vram_address; p_we = `VI.ff_vram_write;
        p_wd = `VI.ff_vram_wdata; p_mask = `VI.ff_vram_wdata_mask;
    end
    function automatic void upd(inout realtime m, input realtime t);
        realtime d = $realtime - t;
        if (d < m) m = d;
    endfunction
    always @(posedge tb.clk_sdram) if (tb.dut.ps[11]) begin
        //  sampled before this edge's own updates: the value the boundary flops take
        n_bound++;
        if (`VI.ff_vram_valid) begin
            n_req++;
            upd(dmin_valid, t_valid); upd(dmin_addr, t_addr); upd(dmin_we, t_we);
            upd(dmin_wd, t_wd); upd(dmin_mask, t_mask);
        end else upd(dmin_valid, t_valid);
    end
    final $display("EDGE boundaries %0d with-request %0d launches %0d off-shared-edge %0d | min launch->capture ns: valid %.2f addr %.2f we %.2f wdata %.2f mask %.2f",
        n_bound, n_req, n_launch, n_launch_off, dmin_valid/1000.0, dmin_addr/1000.0, dmin_we/1000.0, dmin_wd/1000.0, dmin_mask/1000.0);
endmodule
bind tb edge_probe u_edge_probe();
