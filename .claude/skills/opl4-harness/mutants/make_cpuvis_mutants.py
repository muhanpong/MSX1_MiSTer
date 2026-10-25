#!/usr/bin/env python3
"""Generate the cpuvis-gate mutants: one CPU-visible edit each, in the engine,
ymf278b_regs.sv or ymf278b_top.sv.

    make_cpuvis_mutants.py <engine2.sv|engine3.sv> <regs.sv> <top.sv> <out_dir>

Output: <out_dir>/mut_<name>__<engine|regs|top>.sv, a full copy of that one file.
Every one must make sim/cpuvis/run_cpuvis.sh FAIL.  An edit whose anchor does
not occur exactly once stops generation (a mutant that did not apply proves
nothing either way).
"""
import sys, os

MUTANTS = [
    # name, target, what it breaks, old, new
    ("id_bits", "engine", "reg 2 device ID 010 instead of 001",
     "assign reg02_readback  = {3'b001,", "assign reg02_readback  = {3'b010,"),
    ("tblhdr_bits", "engine", "reg 2 bits 4:2 stored from the wrong bits",
     "wavetblhdr <= reg_data[4:2];", "wavetblhdr <= reg_data[3:1];"),
    ("rd6_noinc", "engine", "reg 6 read does not advance the memory address",
     "if (cpu_rd_06 && !cpu_adr_set_l)       cpu_mem_adr <= cpu_mem_adr + 24'd1;",
     "if (cpu_rd_06 && !cpu_adr_set_l)       cpu_mem_adr <= cpu_mem_adr + 24'd0;"),
    ("reg3_nomask", "engine", "reg 3 reads back its two upper bits",
     "(reg_addr == 8'h03) ? {2'b00, reg_data[5:0]} : reg_data", "reg_data"),
    ("f4_enc", "engine", "field 4 read-back returns the stored (bit 5 inverted) byte",
     "reg_rd_data <= enc_byte(4'd4, frc[4]);", "reg_rd_data <= frc[4];"),
    ("hdr_nobackfill", "engine", "header bytes 7-11 never reach fields 5-9 (read-back)",
     "if (hf_store_now) bf_we[9:5] = ~dly;", "if (hf_store_now) bf_we[9:5] = 5'h00;"),
    ("sig_noclear", "regs", "the NEW2 one-shot is not consumed by a status read",
     "else if (status_rd_notify) new2_signature_pending <= 1'b0;",
     "else if (1'b0) new2_signature_pending <= 1'b0;"),
    ("wr_busy_short", "regs", "wave register write BUSY 44 instead of 88",
     "localparam int WAVE_REG_WRITE_DELAY   = 88;", "localparam int WAVE_REG_WRITE_DELAY   = 44;"),
    ("new2_gate", "regs", "wave port writes accepted with NEW2=0",
     "            if (new2) begin", "            if (1'b1) begin"),
    ("ld_none", "regs", "no LD after a wave-number write",
     "load_cnt <= DELAY_W'(LOAD_DELAY);", "load_cnt <= '0;"),
    ("memw_nohold", "regs", "wave-memory write acked at once instead of held to BUSY end",
     "pcm_wr_wait <= 1'b1;", "io_ack <= 1'b1;"),
    ("fm_rd_remap", "regs", "FM read-back uses the OPL2-remapped address instead of the latch",
     "io_data_out <= fm_shadow[opl3latch];", "io_data_out <= fm_shadow[fm_wr_addr];"),
    ("st_noload", "regs", "LD missing from the status byte",
     "assign status_live = opl3_status | {6'd0, load_busy, busy}",
     "assign status_live = opl3_status | {6'd0, 1'b0, busy}"),
    ("latch_rd", "regs", "7Eh read returns the latch instead of FFh",
     "io_data_out <= 8'hFF;  // latch not readable", "io_data_out <= opl4latch;  // latch not readable"),
    ("memrd_nobusy", "regs", "a wave-memory read (latch 3..6) raises no BUSY counter (the engine op alone)",
     "                    busy_cnt    <= DELAY_W'(MEM_READ_DELAY);",
     "                    busy_cnt    <= '0;"),
    ("new2_keep", "top", "a warm reset keeps NEW2 (as openMSX does; the RTL clears it on purpose)",
     "        opl3_reg_shadow[0] <= 8'h00;", "        opl3_reg_shadow[0] <= opl3_reg_shadow[0];"),
]


# engine3 (from-scratch engine, P2 skeleton): its own anchors for the engine edits; the
# regs/top mutants above apply to both engines.
ENGINE3 = [
    ("id_bits", "engine", "reg 2 device ID 010 instead of 001",
     "assign reg02_readback = {3'b001,", "assign reg02_readback = {3'b010,"),
    ("tblhdr_bits", "engine", "reg 2 bits 4:2 stored from the wrong bits",
     "wavetblhdr            <= reg_data[4:2];", "wavetblhdr            <= reg_data[3:1];"),
    ("rd6_noinc", "engine", "reg 6 read does not advance the memory address",
     "if ((cpu_rd_06 || cpu_wr_issue) && !cpu_adr_set_l)", "if ((cpu_wr_issue) && !cpu_adr_set_l)"),
    ("wr6_noinc", "engine", "reg 6 write does not advance the memory address",
     "if ((cpu_rd_06 || cpu_wr_issue) && !cpu_adr_set_l)", "if ((cpu_rd_06) && !cpu_adr_set_l)"),
    ("reg3_nomask", "engine", "reg 3 reads back its two upper bits",
     "(reg_addr == 8'h03) ? {2'b00, reg_data[5:0]} : reg_data", "reg_data"),
    ("prefetch_none", "engine", "a reg 5 write does not prefetch (the next reg 6 read is stale)",
     "if (cpu_adr_set_l || cpu_rd_06) cpu_rd_pend <= 1'b1;", "if (cpu_rd_06) cpu_rd_pend <= 1'b1;"),
    ("hdr_nobackfill", "engine", "header bytes 7-11 never reach fields 5-9",
     "bf_be   = ~bf_dirty[hf_slot];", "bf_be   = 5'h00;"),
    ("dirty_ignored", "engine", "the backfill overwrites fields the CPU wrote after the wave number",
     "bf_be   = ~bf_dirty[hf_slot];", "bf_be   = 5'h1F;"),
    ("lane_hi_lost", "engine", "fields 5-9 written into the slot's fields 0-4 word",
     "wq_word <= {wr_snum, wr_field >= 4'd5};", "wq_word <= {wr_snum, 1'b0};"),
    ("reset_nosweep", "engine", "the reset sweep writes nothing (register file keeps its bytes)",
     "rb_we = 1'b1; rb_be = '1; rb_addr = clr_idx;", "rb_we = 1'b1; rb_be = '0; rb_addr = clr_idx;"),
    ("reset_nohdr", "engine", "no wave-0 header fetch after reset (engine2's D11)",
     "hf_pending <= '1;", "hf_pending <= '0;"),
    ("again_none", "engine", "a wave number rewritten during its header fetch does not fetch again",
     "if (hf_busy && wr_snum == hf_slot) hf_again <= 1'b1;", "if (1'b0) hf_again <= 1'b1;"),
]


def main():
    files = dict(engine=sys.argv[1], regs=sys.argv[2], top=sys.argv[3])
    out = sys.argv[4]
    src = {k: open(v).read() for k, v in files.items()}
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith('.sv'):
            os.remove(os.path.join(out, f))
    with open(os.path.join(out, 'MUTANTS.txt'), 'w') as idx:
        muts = MUTANTS
        if 'module ymf278_pcm_engine3' in src['engine']:
            muts = [m for m in MUTANTS if m[1] != 'engine'] + ENGINE3
        for name, tgt, what, old, new in muts:
            n = src[tgt].count(old)
            if n != 1:
                sys.exit(f"mutant {name}: anchor occurs {n}x in {files[tgt]}")
            open(os.path.join(out, f"mut_{name}__{tgt}.sv"), 'w').write(src[tgt].replace(old, new))
            idx.write(f"mut_{name}\t{tgt}\t{what}\n")
    print(f"{len(muts)} mutants -> {out}")


if __name__ == '__main__':
    main()
