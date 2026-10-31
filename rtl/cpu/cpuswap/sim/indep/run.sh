#!/usr/bin/env bash
# Real turbo R contexts (cpuswap_ctl `indep`), 2026-10-31.
#   build the tb as ../run.sh does (GHDL T80s + Verilator), then:
#   python3 mkprog.py && Vtb +prog=indeptest.hex +mode=3 +intper=0 +indep      -> CPU log ZRZ x5
#                        Vtb +prog=indeptest.hex +mode=3 +intper=0              -> ZZZ x5 (state copy:
#   the R800 inherits the Z80's OTIR and writes the Z80 value right back -- the negative control,
#   and the behaviour Wonder Boy in Monster World saw on the board).
# CPU log: awk '$1=="O" && $2=="01"{printf "%s", ($3=="52")?"R":"Z"}' <log>
