#!/usr/bin/env python3
"""Generate the cpuvis-gate mutants: one CPU-visible edit each, in the engine,
ymf278b_regs.sv or ymf278b_top.sv.

    make_cpuvis_mutants.py <engine2.sv> <regs.sv> <top.sv> <out_dir>

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


def main():
    files = dict(engine=sys.argv[1], regs=sys.argv[2], top=sys.argv[3])
    out = sys.argv[4]
    src = {k: open(v).read() for k, v in files.items()}
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith('.sv'):
            os.remove(os.path.join(out, f))
    with open(os.path.join(out, 'MUTANTS.txt'), 'w') as idx:
        for name, tgt, what, old, new in MUTANTS:
            n = src[tgt].count(old)
            if n != 1:
                sys.exit(f"mutant {name}: anchor occurs {n}x in {files[tgt]}")
            open(os.path.join(out, f"mut_{name}__{tgt}.sv"), 'w').write(src[tgt].replace(old, new))
            idx.write(f"mut_{name}\t{tgt}\t{what}\n")
    print(f"{len(MUTANTS)} mutants -> {out}")


if __name__ == '__main__':
    main()
