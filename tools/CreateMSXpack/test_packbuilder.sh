#!/usr/bin/env bash
#  packbuilder.html against createMSXpack.py, over the whole ROM store.
#
#    tools/CreateMSXpack/test_packbuilder.sh [page.html] [ROM dir]
#
#  Defaults: packbuilder.html next to this script, ROM/ next to this script.
#  PASS needs all three:
#    - the page's embedded DATA equals packbuilder_extract.py on the current XMLs;
#    - the page's "download all" ZIP holds exactly the files createMSXpack.py writes
#      under MSX/ (same relative paths, firmware packs at the top like the Python);
#    - every one of them is byte-identical (SHA-1).
#  Negative control: run it on a page whose DATA predates an XML change, or edit one
#  byte of a pack table in the page -- it must FAIL.
#  PACK_FW_SUBST=1 also covers the firmware packs (see below).
#  Needs python3, unzip, node + playwright-core and a headless Chromium (see the .js).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PAGE=$(realpath "${1:-$HERE/packbuilder.html}")
ROMS=$(realpath "${2:-$HERE/ROM}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/packcmp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

#  Python side: a private copy of the tool (it writes MSX/ and SRAM.NVR beside itself).
mkdir -p "$WORK/py"
cp -r "$HERE/Computer" "$HERE/Extension" "$HERE/createMSXpack.py" "$HERE/packbuilder_extract.py" "$WORK/py/"
ln -s "$ROMS" "$WORK/py/ROM"
( cd "$WORK/py" && python3 createMSXpack.py > py.log 2>&1 ) || { echo "createMSXpack.py failed"; tail "$WORK/py/py.log"; exit 1; }
( cd "$WORK/py" && python3 packbuilder_extract.py > "$WORK/fresh.json" ) || { echo "extract failed"; exit 1; }

#  PACK_FW_SUBST=1: the firmware packs need ROMs the store may lack (GM2 is a commercial
#  game, the MegaFlashROM SD image is unobtainable, mu-PACK is rare), so neither builder
#  makes them and their path -- bytes AND the folder they land in -- goes untested.
#  This mode repoints each missing firmware hash at a real ROM of similar size, in the
#  private XML copy only, rebuilds the Python side, and tests a copy of the page whose
#  DATA is that same extraction.  The DATA check is then true by construction; the
#  pack bytes and paths are what this mode tests.
if [ "${PACK_FW_SUBST:-0}" = 1 ]; then
  python3 - "$WORK/py" <<'PY' || exit 1
import glob, hashlib, os, re, sys
root = sys.argv[1]
have = {}
for d, _, fs in os.walk(os.path.join(root, 'ROM')):
    for f in fs:
        p = os.path.join(d, f)
        have[hashlib.sha1(open(p, 'rb').read()).hexdigest()] = p
by_size = {}
for h, p in sorted(have.items(), key=lambda x: x[1]):
    by_size.setdefault(os.path.getsize(p), h)
#  wanted size per missing firmware: GM2 128 kB, flash image 2 MB stand-in, mu-PACK 16 kB
size_for = {'GM2': 131072, 'MEGA_FLASH_ROM': 2097152, 'MU_PACK': 16384}
for x in glob.glob(os.path.join(root, 'Extension', '*.xml')):
    t = open(x).read()
    def fix(m):
        body = m.group(2)
        hs = re.findall(r'<SHA1>\s*([0-9a-fA-F]{40})\s*</SHA1>', body)
        if not hs or any(h.lower() in have for h in hs) or m.group(1) not in size_for:
            return m.group(0)
        sub = by_size[size_for[m.group(1)]]
        print(f"  substitute {os.path.basename(x)} {m.group(1)}: {hs[0][:8]} -> {os.path.basename(have[sub])}")
        return m.group(0).replace(hs[0], sub)
    open(x, 'w').write(re.sub(r'<fw name="([^"]+)">(.*?)</fw>', fix, t, flags=re.S))
PY
  rm -rf "$WORK/py/MSX"
  ( cd "$WORK/py" && python3 createMSXpack.py > py.log 2>&1 && python3 packbuilder_extract.py > "$WORK/fresh.json" ) || { echo "rebuild failed"; exit 1; }
  python3 - "$PAGE" "$WORK/fresh.json" "$WORK/page.html" <<'PY' || exit 1
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'const DATA = (\{.*\})\n', s)
open(sys.argv[3], 'w', encoding='utf-8').write(s[:m.start(1)] + open(sys.argv[2], encoding='utf-8').read().strip() + s[m.end(1):])
PY
  PAGE="$WORK/page.html"
fi

#  Page side.
node "$HERE/test_packbuilder.js" "$PAGE" "$ROMS" "$WORK/fresh.json" "$WORK/page.zip"
js=$?
[ -f "$WORK/page.zip" ] || { echo "FAIL: the page offered no ZIP"; exit 1; }
mkdir -p "$WORK/pg" && unzip -q "$WORK/page.zip" -d "$WORK/pg"

python3 - "$WORK/py/MSX" "$WORK/pg" "$js" <<'PY'
import hashlib, os, sys
def tree(root):
    out = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.MSX'):
                p = os.path.join(d, f)
                out[os.path.relpath(p, root)] = hashlib.sha1(open(p, 'rb').read()).hexdigest()
    return out
py, pg, js = tree(sys.argv[1]), tree(sys.argv[2]), int(sys.argv[3])
both = sorted(set(py) & set(pg))
diff = [n for n in both if py[n] != pg[n]]
print(f"python: {len(py)} packs   page ZIP: {len(pg)} packs   identical: {len(both) - len(diff)}")
for title, names in (("only from python:", sorted(set(py) - set(pg))),
                     ("only in the page ZIP:", sorted(set(pg) - set(py))),
                     ("DIFFERENT bytes:", diff)):
    if names:
        print(title)
        for n in names: print("  " + n)
ok = js == 0 and py and set(py) == set(pg) and not diff
print("RESULT " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
