#!/usr/bin/env bash
# Turbo R CPU contexts, mixed rule (msx.sv), 2026-10-31.
#   build the tb as ../run.sh does (GHDL T80s + Verilator), then:
#   python3 mkprog.py      -> indeptest.hex   bare S1990 writes only
#   python3 mkprog.py wb   -> wbtest.hex      CHGCPU stub to R800 first, then the game's OTIR switch
#   Vtb +prog=<hex> +mode=3 +intper=0 +indep   -> indeptest ZRZ x5,  wbtest R + ZRZ x5
#   Vtb +prog=<hex> +mode=3 +intper=0          -> ZZZ x5 / R + ZZZ x5 (state copy: the board
#   symptom of Wonder Boy in Monster World; the negative control)
# CPU log: awk '$1=="O" && $2=="01"{printf "%s", ($3=="52")?"R":"Z"}' <log>
