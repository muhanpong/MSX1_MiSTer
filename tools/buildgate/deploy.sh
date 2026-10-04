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
# After the RBF it uploads the build's CONF_STR as a misterclaw sidecar
# (/media/fat/config/confstr/<name>.txt) when that provably matches -- see below.
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

# CONF_STR sidecar for misterclaw (2026-10-05, user-approved): the menu string of
# THIS build, so an OSD tool reads/writes MSX1.CFG with the right bit layout
# instead of upstream MSX1's.  Taken from map.rpt (quartus_map runs on every
# build), and uploaded only when it provably belongs to this RBF: map.rpt newer
# than the build start and not newer than MSX1.rbf, and its V,v<YYMMDD> equal to
# the date in the RBF name.  Otherwise it is SKIPPED, not shipped: with no sidecar
# misterclaw refuses to write or navigate for that build, a wrong one would write
# wrong bits.  The RBF deploy above stands either way.
SIDE_DIR=/media/fat/config/confstr
SIDE="${NAME%.rbf}.txt"
MAP=output_files/MSX1.map.rpt
side_skip() { echo "SIDECAR-SKIP: $1 -- no $SIDE_DIR/$SIDE for this build"; }
MAP_T=$(stat -c %Y "$MAP" 2>/dev/null || echo 0)
CONF=$(grep -m1 '^; CONF_STR ' "$MAP" 2>/dev/null | sed -e 's/^; CONF_STR *; //' -e 's/ *; String *;[[:space:]]*$//')
CDATE=$(printf '%s' "$CONF" | grep -o ';V,v[0-9]\{6\}' | tail -1 | cut -c5-)
NDATE=$(printf '%s' "$NAME" | grep -o '^MSX1_[0-9]\{8\}' | cut -c8-13)
if   [ "$MAP_T" -lt "$START" ];          then side_skip "map.rpt ($(date -d @$MAP_T +%T)) is older than the build start"
elif [ "$MAP_T" -gt "$RBF_T" ];          then side_skip "map.rpt is newer than MSX1.rbf"
elif [ "${CONF%%;*}" != "MSX1" ];        then side_skip "CONF_STR not found or does not start with MSX1"
elif [ -z "$CDATE" ] || [ "$CDATE" != "$NDATE" ]; then side_skip "CONF_STR date v$CDATE does not match the name ($NDATE)"
else
  TMP=$(mktemp); printf '%s\n' "$CONF" > "$TMP"
  ssh_q "mkdir -p $SIDE_DIR" >/dev/null
  scp -q "$TMP" "$BOARD:$SIDE_DIR/$SIDE" 2>&1 | grep -v 'post-quantum\|store now\|upgraded'
  SL=$(md5sum "$TMP" | cut -c1-12); SR=$(ssh_q md5sum "$SIDE_DIR/$SIDE" | cut -c1-12); rm -f "$TMP"
  echo "sidecar $SIDE_DIR/$SIDE local=$SL board=$SR ($(printf '%s' "$CONF" | wc -c) bytes, v$CDATE)"
  [ "$SL" = "$SR" ] || echo "SIDECAR-FAIL: md5 mismatch (the RBF deploy itself is fine)"
fi
if [ "$LOAD" = "--load" ]; then
  ssh_q "echo 'load_core /media/fat/_Computer/$NAME' > /dev/MiSTer_cmd"
  sleep 20; echo "board core: $(ssh_q cat /tmp/CORENAME)"
fi
