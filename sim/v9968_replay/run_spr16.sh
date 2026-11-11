#!/usr/bin/env bash
#  The 16th sprite of a line (sprite mode 3).  Before upstream 1df063f the mixer took the
#  16th plane as the first plane of the NEXT dot: one dot to the right and on top of the
#  others (WBML V9968: the right wall under a 12-column text box).  N = 13, 15, 16, 17.
#  Negative control: the same with rtl/video/v9968/vdp_sprite_makeup_pixel.v of 419d1ff
#  fails N = 16 and 17 (run 213:13 226:16 instead of 213:14 227:14).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); O=${OUT:-/tmp/v9968_spr16}; mkdir -p "$O"; rc=0
for n in 13 15 16 17; do
    python3 "$HERE/spr16.py" "$O/s$n.io" $n a
    REBUILD=$([ $n = 13 ] && echo 1) bash "$HERE/run.sh" "$O/s$n.io" 2 "$O" > "$O/run$n.txt" 2>&1
    python3 "$HERE/spr16_check.py" "$O/frame_2.ppm" $n || rc=1
done
exit $rc
