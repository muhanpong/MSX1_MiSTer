#!/usr/bin/env bash
#  A ROM cart in slot B must not reach another device's SRAM (tb_slotb_sram.sv).
#      sim/run_slotb_sram.sh
#  PASS needs the bench clean AND the mutant (msx_slots' slot B SRAM rule removed)
#  to FAIL case B1 -- otherwise the bench cannot see the defect it is for.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/slotb_sram_sim}; mkdir -p "$OUT"
GEN=sim/fullsys/gen
[ -s "$GEN/filelist.txt" ] || sim/fullsys/prep.sh >/dev/null || { echo "fullsys prep failed"; exit 2; }

#  port declarations straight from msx_slots.sv, so the bench follows its port list
python3 - rtl/peripheral/slots/msx_slots.sv "$OUT/msx_slots_ports.svh" <<'PY'
import re,sys
src=open(sys.argv[1]).read()
hdr=src[src.index('module msx_slots'):]; hdr=hdr[:hdr.index(');')]
out=[]
for line in hdr.split('\n'):
    line=re.sub(r'//.*','',line).strip().rstrip(',')
    m=re.match(r'(input|output|inout)\s+(.*)$',line)
    if not m: continue
    body=m.group(2).replace('logic','').strip()
    out.append(f"   {body};" if (body.startswith('MSX::') or re.match(r'(mapper_typ_t|dev_typ_t)\b',body)) else f"   logic {body};")
open(sys.argv[2],'w').write('\n'.join(out)+'\n')
PY

#  the machine's file list minus the copies this run substitutes
build() {   # <slots source> <dir>
   local files
   files=$(grep -vE 'rtl/peripheral/sdram\.sv$|rtl/peripheral/slots/msx_slots\.sv$' "$GEN/filelist.txt" | tr '\n' ' ')
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
      -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-BLKSEQ \
      -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK -Wno-TIMESCALEMOD \
      --top-module tb_slotb_sram -o tb -Mdir "$2" "+incdir+$OUT" "+incdir+$GEN" \
      $files "$GEN/sdram_sim.sv" "$1" sim/tb_slotb_sram.sv > "$2.log" 2>&1 \
      || { echo "COMPILE FAILED ($2)"; grep -E '%Error' "$2.log" | head -10; return 2; }
}
build rtl/peripheral/slots/msx_slots.sv "$OUT/v" || exit 2
"$OUT/v/tb" 2>&1 | grep -E '^(PASS|FAIL|  |RESULT)'; rc=${PIPESTATUS[0]}

python3 - <<PY
s=open("rtl/peripheral/slots/msx_slots.sv").read()
a="wire                sram_denied = external & cart_num & (mapper != MAPPER_FMPAC) & (mapper != MAPPER_GM2);"
assert s.count(a)==1, "mutation anchor missing"
open("$OUT/msx_slots_mut.sv","w").write(s.replace(a,"wire                sram_denied = 1'b0;"))
PY
build "$OUT/msx_slots_mut.sv" "$OUT/vm" || exit 2
mut=$("$OUT/vm/tb" 2>&1 | grep -E '^FAIL: B1' | wc -l)
if [ "$rc" -eq 0 ] && [ "$mut" -ge 1 ]; then echo "ok    mutant (rule removed) fails B1"; echo "SLOTB SRAM: PASS"; exit 0; fi
echo "SLOTB SRAM: FAIL (bench rc=$rc, mutant B1 failures=$mut)"; exit 1
