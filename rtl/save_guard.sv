// Keeps a reset or a ROM load from landing in the middle of a .sav write.
//
// nvram_backup and flash_dirtysave both take the machine `reset`, and SDRAM ch1
// gives a ROM upload priority over the save engine, so either event arriving
// mid-DMA truncates the file being written -- the one case where a stray button
// press destroys data instead of just interrupting play.
//
// Both are DEFERRED, not dropped: the user asked for them and the request is
// honoured as soon as the DMA finishes.  A ROM load can wait indefinitely (the
// file is already staged in DDR3), but a reset cannot: if a save engine ever
// wedged, an unresettable core would be worse than a lost .sav, so the button
// wins after GUARD_BITS worth of clocks (2^24 / 21.48 MHz ~ 0.78 s by default).
`default_nettype none

module save_guard #(
    parameter GUARD_BITS = 25            // 2^(GUARD_BITS-1) clocks before the button wins
) (
    input  wire clk,
    input  wire saving,                  // nvbak_dma_active | dump_active
    input  wire reset_btn,               // OSD Reset / Reset & Detach (NOT power-on)
    output wire reset_now,               // gated reset request
    output wire hold_load                // stall memory_upload's staging FSM
);

reg                  reset_held  = 1'b0;
reg [GUARD_BITS-1:0] save_guard  = '0;
wire                 guard_expired = save_guard[GUARD_BITS-1];

always @(posedge clk) begin
    if (!saving) begin
        save_guard <= '0;
        reset_held <= 1'b0;              // released with the DMA; the press below fires this cycle
    end else begin
        if (!guard_expired) save_guard <= save_guard + 1'b1;
        if (reset_btn)      reset_held <= 1'b1;
    end
end

assign reset_now = (reset_btn | reset_held) & (~saving | guard_expired);
assign hold_load = saving;

endmodule

`default_nettype wire
