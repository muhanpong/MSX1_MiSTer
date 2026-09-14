#!/usr/bin/env bash
# Deploy the just-built RBF under a new name, refusing anything that is not
# provably the product of a passing buildgate run.
#
#   tools/buildgate/deploy.sh <name.rbf> <build-start-epoch> [--load]
#
# Refuses if: the name already exists (locally or on the board -- RBFs are never
# overwritten or deleted), buildgate's last log does not end in BUILDGATE: PASS,
# or output_files/MSX1.rbf is older than the build start.  The last check exists
# because 20260915c_osdcore was deployed from a KILLED fit: the deploy step ran
# anyway and shipped the previous bitstream under the new name (same md5 as b).
set -u
cd "$(dirname "$0")/../.."
NAME=$1; START=$2; LOAD=${3:-}
LOG=${BUILDGATE_LOG:-/tmp/buildgate}
BOARD=root@192.168.1.86
ssh_q() { ssh "$BOARD" "$@" 2>&1 | grep -v 'post-quantum\|store now\|upgraded'; }
[ -e "output_files/$NAME" ] && { echo "DEPLOY-REFUSE: output_files/$NAME exists"; exit 2; }
[ -n "$(ssh_q ls /media/fat/_Computer/$NAME 2>/dev/null | grep -v 'No such')" ] && { echo "DEPLOY-REFUSE: $NAME already on the board"; exit 2; }
grep -q '^BUILDGATE: PASS' "$LOG/buildgate.out" 2>/dev/null || { echo "DEPLOY-REFUSE: last buildgate did not PASS ($LOG/buildgate.out)"; exit 2; }
RBF_T=$(stat -c %Y output_files/MSX1.rbf)
[ "$RBF_T" -gt "$START" ] || { echo "DEPLOY-REFUSE: MSX1.rbf ($(date -d @$RBF_T +%T)) is older than the build start ($(date -d @$START +%T))"; exit 2; }
cp output_files/MSX1.rbf "output_files/$NAME"
MAIN=/home/muhanpong/Documents/github/MSX1_MiSTer/output_files
[ -e "$MAIN/$NAME" ] || cp "output_files/$NAME" "$MAIN/$NAME"
scp -q "output_files/$NAME" "$BOARD:/media/fat/_Computer/" 2>&1 | grep -v 'post-quantum\|store now\|upgraded'
L=$(md5sum "output_files/$NAME" | cut -c1-12); R=$(ssh_q md5sum /media/fat/_Computer/$NAME | cut -c1-12)
echo "deployed $NAME local=$L board=$R"
[ "$L" = "$R" ] || { echo "DEPLOY-FAIL: md5 mismatch"; exit 1; }
if [ "$LOAD" = "--load" ]; then
  ssh_q "echo 'load_core /media/fat/_Computer/$NAME' > /dev/MiSTer_cmd"
  sleep 20; echo "board core: $(ssh_q cat /tmp/CORENAME)"
fi
