#!/bin/sh
# openMSX checks of vdptools.rom (headless):
#   test_all.tcl: every program from the menu to its end and back (MSX2+, auto mapper)
#   test_pad.tcl: joystick trigger A/B in the menu, VDPVIEW and VRAMSTRS (faked triggers)
# OPENMSX = openMSX binary, OPENMSX_SYSTEM_DATA = its share dir.
set -e
cd "$(dirname "$0")"
OM=${OPENMSX:-$HOME/data/openMSX/derived/x86_64-linux-opt-3rd/bin/openmsx}
export OPENMSX_SYSTEM_DATA=${OPENMSX_SYSTEM_DATA:-$HOME/data/openMSX/share}
export SDL_VIDEODRIVER=dummy
rm -f test_all.txt test_pad.txt
export PAD_TA=$(awk '/^pad_kbd.ta:/{print $3}' vdptools.sym | sed 's/^0x0000/0x/')
export PAD_TB=$(awk '/^pad_kbd.tb:/{print $3}' vdptools.sym | sed 's/^0x0000/0x/')
timeout 3500 "$OM" -machine Panasonic_FS-A1WSX -carta vdptools.rom -script test_all.tcl > /dev/null 2>&1 || true
timeout 900 "$OM" -machine Panasonic_FS-A1GT -carta vdptools.rom -romtype ASCII16 -script test_pad.tcl > /dev/null 2>&1 || true
ok=1
[ "$(grep -c 'menu back OK' test_all.txt)" = 8 ] || { echo "FAIL: test_all: $(grep -c 'menu back OK' test_all.txt)/8 programs came back"; ok=0; }
grep -q "ALL DONE" test_all.txt || { echo "FAIL: test_all did not finish"; ok=0; }
grep -q "VDPVIEW END" test_pad.txt || { echo "FAIL: pad B did not quit VDPVIEW"; ok=0; }
grep -q "ROUNDS DONE: 0 (ESC)" test_pad.txt || { echo "FAIL: pad B did not stop VRAMSTRS"; ok=0; }
[ "$(grep -c '> VRAMSTRS' test_pad.txt)" -ge 1 ] || { echo "FAIL: pad did not return to the menu"; ok=0; }
grep -q "after pad A again t=.* R2=1f" test_pad.txt || { echo "FAIL: pad A did not turn VDPVIEW pages"; ok=0; }
[ $ok = 1 ] && echo "RESULT PASS: vdptools" || { echo "RESULT FAIL: vdptools"; exit 1; }
