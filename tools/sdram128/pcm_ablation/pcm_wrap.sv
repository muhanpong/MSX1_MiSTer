//  Area ablation wrapper: the engine's functional ports as ymf278b_top uses them; DBG=1 also
//  keeps the dbg taps the core reads (overlay), DBG=0 leaves every dbg output open.
module pcm_wrap #(parameter int DBG = 1, parameter int PF = -1) (
    input  wire clk, rst_n,
    input  wire [7:0] reg_addr, reg_data, input wire reg_wr, reg_rd,
    output logic [7:0] cpu_mem_rd_data, output logic cpu_mem_busy,
    output logic [7:0] reg02_readback, reg_rd_data,
    output logic [21:0] mem_addr, output logic mem_rd_en,
    input  wire [7:0] mem_rd_data, input wire [15:0] mem_rd_data16, input wire mem_rd_valid,
    output logic mem_wr_en, output logic [7:0] mem_wr_data, input wire mem_busy,
    output logic signed [15:0] pcm_left, pcm_right, output logic pcm_valid,
    output logic [2:0] fm_mix_l, fm_mix_r,
    output logic [21:0] d_hs, output logic [15:0] d_pos, output logic [9:0] d_ev,
    output logic [2:0] d_es, output logic [23:0] d_k, d_a, d_l
);
    logic [21:0] hs; logic [15:0] pos; logic [9:0] ev; logic [2:0] es; logic [23:0] k, a, l;
    ymf278_pcm_engine2 #(.CLK_HZ(128863620), .PIPE_FORCE(PF)) u_pcm (
        .clk, .rst_n, .reg_addr, .reg_data, .reg_wr, .reg_rd, .cpu_mem_rd_data, .cpu_mem_busy,
        .reg02_readback, .reg_rd_data, .mem_addr, .mem_rd_en, .mem_rd_data, .mem_rd_data16,
        .mem_rd_valid, .mem_wr_en, .mem_wr_data, .mem_busy, .pcm_vol(2'd0), .pcm_left, .pcm_right,
        .pcm_valid, .fm_mix_l_o(fm_mix_l), .fm_mix_r_o(fm_mix_r),
        .dbg_wavetblhdr(), .dbg_hf_pending(), .dbg_slot0_wave(), .dbg_slot0_fn(), .dbg_slot0_oct(),
        .dbg_slot0_prvb(), .dbg_slot0_keyon(), .dbg_slot0_damp(), .dbg_slot0_pan(), .dbg_slot0_ar(),
        .dbg_slot0_d1r(), .dbg_slot5_wave(), .dbg_slot23_wave(), .dbg_slot0_hdr_loop(),
        .dbg_slot0_hdr_end(), .dbg_slot0_hdr_bits(), .dbg_slot0_dyn_stepPtr(),
        .dbg_stage_b_bytes_done(), .dbg_stage_advance(), .dbg_stage_b_valid(),
        .dbg_slot0_hdr_start(hs), .dbg_slot0_dyn_pos(pos), .dbg_slot0_dyn_env_vol(ev),
        .dbg_slot0_dyn_env_state(es), .dbg_slot_keyon(k), .dbg_slot_active(a), .dbg_slot_envlive(l));
    assign {d_hs, d_pos, d_ev, d_es, d_k, d_a, d_l} = DBG ? {hs, pos, ev, es, k, a, l} : '0;
endmodule
