#!/usr/bin/env python3
"""Generate the golden-gate mutants of ymf278_pcm_engine2.sv.

    make_engine2_mutants.py <engine2.sv> <out_dir>

Each mutant is the engine with ONE small edit (old -> new, which must occur in
the engine exactly as many times as `count` says, or generation fails: a mutant
that silently did not apply would look "caught" or "not caught" for nothing).
They are generated from the engine file under test, so they never drift from it.
Every mutant must FAIL `harness.sh mutants`; one that passes marks behaviour no
golden scenario covers (add a scenario, do not delete the mutant).

The edits target the PIPE datapath (the 128.86 MHz build) where the two paths
differ.
"""
import sys, os

MUTANTS = [
    # name, category, what it breaks, old, new, count
    ("interp_frac8", "interpolation", "interpolation fraction truncated to 8 bits",
     "w_iprod  <= w_idiff * $signed({1'b0, w_ptr2});",
     "w_iprod  <= w_idiff * $signed({1'b0, w_ptr2 & 16'hFF00});", 1),
    ("interp_off", "interpolation", "no interpolation (sample A only)",
     "w_interp <= w_sa + w_iprod[32:16];",
     "w_interp <= w_sa;", 1),
    ("eg_rel_d2r", "EG", "release runs at D2R instead of RR",
     "EG_REL: return calc_decay_rate(r.rr,",
     "EG_REL: return calc_decay_rate(r.d2r,", 1),
    ("eg_dl_gt", "EG", "decay->sustain transition at > DL instead of >= DL",
     ">= (PIPE ? eg_dl_r : dl_tab_rom(w_regs.dl_idx))) begin",
     "> (PIPE ? eg_dl_r : dl_tab_rom(w_regs.dl_idx))) begin", 1),
    ("eg_nodamp", "EG", "DAMP (field 4 bit 6) ignored by the decay rate",
     "r.damp       = f[4][6];", "r.damp       = 1'b0;", 1),
    ("eg_noprvb", "EG", "pseudo-reverb (field 2 bit 3) ignored",
     "r.prvb       = f[2][3];", "r.prvb       = 1'b0;", 1),
    ("eg_tlramp2", "EG/TL", "TL interpolation steps up by 2",
     "if (cur < tgt)   return {1'b1, cur + 8'd1};",
     "if (cur < tgt)   return {1'b1, cur + 8'd2};", 1),
    ("lfo_speed", "LFO", "LFO period taken from the neighbouring speed",
     "((w_dyn.lfo_cnt + {12'd0, lfo_period_rom(w_regs.lfo_speed)}) & 18'h3FFFF)",
     "((w_dyn.lfo_cnt + {12'd0, lfo_period_rom(w_regs.lfo_speed ^ 3'd1)}) & 18'h3FFFF)", 1),
    ("lfo_noreset", "LFO", "LFO counter not cleared while the LFO is held in reset (field 4 bit 5)",
     "                       : 18'd0;\nend\nalways_ff @(posedge clk) if (dyn_we)",
     "                       : w_dyn.lfo_cnt;\nend\nalways_ff @(posedge clk) if (dyn_we)", 1),
    ("pan_right7", "pan", "right pan gain ignores pan bit 3",
     "pr_gq <= pan_att_right(w_regs.pan);",
     "pr_gq <= pan_att_right(w_regs.pan & 4'h7);", 1),
    ("pan_do1", "pan", "field 4 bit 4 (output to DO1 = muted on MoonSound) ignored",
     "r.pan        = f[4][4] ? 4'd8 : f[4][3:0];",
     "r.pan        = f[4][3:0];", 1),
    ("hdr_nodirty", "header backfill", "backfill overwrites fields the CPU wrote after the wave number",
     "if (hf_store_now) bf_we[9:5] = ~dly;",
     "if (hf_store_now) bf_we[9:5] = 5'h1F;", 1),
    ("hdr_nobackfill", "header backfill", "header bytes 7-11 never backfilled into fields 5-9",
     "if (hf_store_now) bf_we[9:5] = ~dly;",
     "if (hf_store_now) bf_we[9:5] = 5'h00;", 1),
    ("hdr_tblhdr", "header backfill", "wave-table header base (reg 2 bits 4:2) ignored for waves >= 384",
     "(hf_cur_wave < 9'd384 || wavetblhdr == 3'd0)",
     "(1'b1)", 1),
    ("loop_end_gt", "loop", "end-of-sample wrap one sample late (> instead of >=)",
     "if (({1'b0, p2[15:0]} + {1'b0, endAddr}) >= 17'h10000)",
     "if (({1'b0, p2[15:0]} + {1'b0, endAddr}) > 17'h10000)", 1),
    ("loop_to_zero", "loop", "wrap restarts at 0 instead of the loop address",
     "p2 = p2 + {1'b0, endAddr} + {1'b0, loopAddr};",
     "p2 = p2 + {1'b0, endAddr};", 1),
    ("wave_noposrst", "key/wave", "wave write while not keyed keeps the old position",
     "            pos_rst[wr_snum] <= 1'b1;                              // set wins",
     "            pos_rst[wr_snum] <= 1'b0;                              // set wins", 1),
    ("mix_f9", "mix", "reg F9h PCM mix level ignored",
     "osl = pcm_mix_gain(pcm_mix_l, accum_l >>> sh);",
     "osl = pcm_mix_gain(3'd0, accum_l >>> sh);", 1),
    ("out_lsb1", "output", "left output +1 LSB (invisible to a +-1 tolerant comparator)",
     "pcm_left  <= sat16(out_gl);",
     "pcm_left  <= sat16(out_gl + 24'sd1);", 1),
]


def main():
    src_f, out = sys.argv[1], sys.argv[2]
    src = open(src_f).read()
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        if f.endswith('.sv'):
            os.remove(os.path.join(out, f))
    with open(os.path.join(out, 'MUTANTS.txt'), 'w') as idx:
        for name, cat, what, old, new, count in MUTANTS:
            n = src.count(old)
            if n != count:
                sys.exit(f"mutant {name}: '{old[:60]}' occurs {n}x in {src_f}, expected {count}")
            open(os.path.join(out, f"mut_{name}.sv"), 'w').write(src.replace(old, new))
            idx.write(f"mut_{name}\t{cat}\t{what}\n")
    print(f"{len(MUTANTS)} mutants -> {out}")


if __name__ == '__main__':
    main()
