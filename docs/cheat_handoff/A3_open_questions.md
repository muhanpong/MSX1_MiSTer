# A3 — Open Questions & Next Experiments: MSX1 Standard OSD Cheats

Scope: standard MiSTer OSD cheats (`.gg`/zip, ioctl index 255, `"C,Cheats;"` CONF_STR token) on the MSX1 core. NES cheats work on the same board; MSX1 menu does **not** appear in OSD. 6-agent analysis says the HPS path looks correct (`cheats_init` reached for Slot A Load, `use_cheats=1` in worktree build, apply + 255-receive paths OK), yet no menu.

DO NOT decide the answer. Each item below is a concrete, executable diagnostic with expected outcomes and what each result proves.

## Ground facts captured this session
- Worktree `cheat-standard` HEAD = `102c6c1`. CONF_STR (`MSX1.sv`):
  - L254 `"C,Cheats;"` (independent cheats token — correct form)
  - L256 `"F1,MSX,Load ROM PACK,30000000;"` (machine/BIOS slot, store_name now F1 in worktree HEAD)
  - L259 `"H3FS3,ROM,Load,30C00000;"` = **Slot A game Load (store_name=0)** ← games here, this is the path that calls `cheats_init`
  - L264 `"H4F4,ROM,Load,31100000;"` = Slot B Load
  - L510 `.cheat_en_master(1'b1)` — RTL master always on; OSD menu is sole on/off
- RTL loader (`rtl/msx.sv`): `cheat_dl = ioctl_download & (ioctl_index[7:0]==255)`; per-record byte map `case(ioctl_addr[3:0])`: **addr = bytes 0,1; replace(value) committed at byte 8**. Assumes wire record = `{addr32, compare32, replace32, flag32}` LE.
- Deployed RBFs on board include `MSX1_20260625b_cheatStd.rbf` (the booting `C,Cheats;` build the prompt references), plus `20260626_cheatStd3` (F1, boot broke), `20260626b_cheatF1s2`.
- Serial: USB **Mini‑B** internal port = FT232R `0403:6001` = `/dev/ttyUSB0` @115200 (present now). micro‑USB = JTAG (`09fb`). Console printf is suppressed while a core runs (incl. ROM load) on Main 20260611 — `stdbuf -oL` is required to flush.
- JTAG: `jtagconfig` not on PATH in this env (DE‑SoC chain reported visible elsewhere — must be confirmed on board).

---

## PRIORITY 1 — Does the menu appear on a BOOTING build, game loaded via Slot A Load, with serial capturing `cheats_init`?
This is the single decisive test. It separates "build doesn't boot" / "wrong load menu used" / "cheats_init not firing" from "cheats_init fires but menu still absent".

**Pre-req — confirm which booting build actually has `C,Cheats;`.** The prompt says 20260625b is the booting `C,Cheats;` (FC1) build. Verify the deployed RBF identity before trusting the result:
- Action (claude via ssh OR user): `ssh root@<board> "md5sum /media/fat/_*/MSX1_20260625b_cheatStd.rbf"` and compare to the worktree build artifact md5. Confirms the file under test is the intended bitstream.

**Action (user on board):**
1. Select `MSX1_20260625b_cheatStd.rbf` core.
2. Let it boot to MSX BASIC (confirms boot is intact).
3. OSD → **Slot A → "Load"** (the `H3FS3` entry, store_name=0) → pick `twinbee` (the ROM whose `cheats/MSX1/<name>.zip` or CRC zip exists). **Do NOT use "Load ROM PACK"** (that is the machine/BIOS slot, store_name=1 → `cheats_init` never called).
4. After the game starts, open OSD and look for a **Cheats** entry.

**Concurrent serial capture (claude via ssh, run BEFORE step 3):**
```
ssh root@<board> '
  stty -F /dev/ttyUSB0 115200 -echo raw 2>/dev/null
  chmod 666 /dev/ttyUSB0 2>/dev/null
'
# On the host wired to the Mini-B port (claude local, ttyUSB0 present here):
sudo chmod 666 /dev/ttyUSB0
stty -F /dev/ttyUSB0 115200 -echo raw
# robust line-buffered capture that survives device re-enumeration:
( while true; do
    stdbuf -oL cat /dev/ttyUSB0 2>/dev/null
    sleep 0.3
  done ) | stdbuf -oL grep -iE 'cheat|\.zip|crc|miniz|Using cheat|no cheat' \
         | tee /tmp/handoff/cheats_serial.log
```
Note: the **main binary** that emits these printfs is HPS-side `Main_MiSTer`. If serial shows nothing, restart Main with line-buffering so prints flush during core run:
```
ssh root@<board> 'killall MiSTer 2>/dev/null; cd /media/fat; stdbuf -oL ./MiSTer >/dev/ttyUSB0 2>&1 &'
```
(or redirect Main stdout/stderr into the serial TTY / a logfile you `tail -f`). Prior capture attempts failed purely due to fully-buffered stdout — `stdbuf -oL` is the fix.

**Expected outcomes / what each proves:**
- Menu **appears** + serial shows `Using cheat file .../twinbee.zip` and `cheats: N>0` → standard path works; earlier "no menu" was caused by loading via FC1/Load-ROM-PACK or a non-booting F1 build. **Closes the whole investigation** except value-format (see Q5).
- Menu **absent** but serial shows `cheats_init` called + zip opened + `cheats: 0` → zip is found but yields 0 usable entries → go to Q4/Q5 (record format / miniz).
- Menu **absent** + serial shows `no cheat file found` / `cheats_init` not logged → zip naming/CRC mismatch or `cheats_init` not reached on this build → go to Q2/Q3.
- Core **fails to boot** → 20260625b is not actually a booting `C,Cheats;` build; the booting variant must be re-identified before any other test is meaningful.

**Unblocks:** whether the problem is HPS-discovery vs menu-render vs RTL-apply. Everything else branches from this.

---

## Q2 — Is `cheats_init` actually called AND finding the zip? (serial instrumentation)
Refines P1's serial step into an explicit pass/fail on discovery.

**Action (claude via ssh + local serial):** with the capture loop from P1 running, watch specifically for these `cheats.cpp`/`menu.cpp` strings during the Slot A Load:
- `Using cheat file` (open success) vs `no cheat file found` (lookup miss)
- the per-record count print (`cheats: N` / `cheats_available`)

If the stock Main binary's prints are too sparse, temporarily run a Main built with extra `printf` in `cheats_init()` (path: `<board>/media/fat/MiSTer`), or `strace -f -e trace=open,openat ./MiSTer 2>&1 | grep -i cheat` to see exactly which path/filename HPS attempts to open.

**Expected / proves:**
- `openat(.../cheats/MSX1/twinbee.zip)` attempted & success → discovery OK, defect is downstream (menu render or record parse).
- open attempt on **wrong filename** (e.g. CRC form vs literal name mismatch, or `CoreName2` ≠ `MSX1`) → fix zip name / verify `CoreName2` = first CONF_STR token.
- **no open attempt at all** → `cheats_init` not reached on this code path (store_name still 1, or `use_cheats` 0 in the running bitstream — cross-check Q3).

**Unblocks:** file-discovery vs parse vs render localization. Who: claude (ssh/serial/strace).

---

## Q3 — Does the Cheats menu render GRAYED or fully ABSENT?
`menu.cpp:2072 MenuWrite` always draws the entry; the 4th arg is the gray flag. Grayed = entry exists but `cheats_available()==0` (zip/parse issue). Absent = `use_cheats==0` (token not seen → CONF_STR/bitstream issue).

**Action (user on board):** during P1, look carefully: is there a **dimmed/grayed "Cheats"** line, or **no Cheats line at all**?

**Expected / proves:**
- **Grayed** → `use_cheats==1` (token parsed) but 0 cheats loaded → defect is zip discovery/parse → Q2/Q4/Q5.
- **Absent** → `use_cheats==0` → the running bitstream's CONF_STR lacks a valid `"C,Cheats;"` as parsed by HPS, OR HPS `use_cheats` set only on a different menu context → re-verify CONF_STR in the *deployed* RBF (dump CONF_STR from board: `ssh root@<board> 'cat /dev/MiSTer_cmd'`-style or read `cores`’ reported conf), and confirm L254 token survived synthesis into 20260625b.

**Unblocks:** token-parse failure vs content-empty. Who: user (visual) + claude (CONF_STR verify).

---

## Q4 — Is our STORED zip actually openable by miniz on the board?
HPS uses miniz to read `cheats/MSX1/<name>.zip`. A malformed/over-compressed zip (we built STORED) could fail silently.

**Action (claude via ssh):**
1. `ssh root@<board> 'ls -l /media/fat/cheats/MSX1/'` — confirm the zip is present and named to match the ROM (literal `twinbee.zip`) or CRC32 (`<8HEX>.zip`).
2. `ssh root@<board> 'unzip -l /media/fat/cheats/MSX1/twinbee.zip'` (or `python3 -c "import zipfile;print(zipfile.ZipFile('...').namelist())"`) — confirm it opens & lists a `.gg`/cheat entry, STORED method 0.
3. Tie to Q2 serial: success print `Using cheat file` confirms miniz opened it.

**Expected / proves:**
- Opens fine + Q2 shows success → zip is good, defect is record parse/render → Q5/Q3.
- `unzip`/miniz error or 0 entries → rebuild zip (STORED, correct internal filename, no extra dirs) — `cheats.cpp:359` raw-concats all entries.

**Unblocks:** zip-validity vs everything else. Who: claude (ssh).

---

## Q5 — Does the record byte layout matter? (our loader vs the actual HPS `.gg` wire format)
Our RTL assumes wire record `{addr32, compare32, replace32, flag32}` (addr@bytes0‑1, value@byte8). The prompt raises the alternative NES-standard layout `{flags,addr,compare,replace}` with **addr@bytes4‑5, value@byte12**. This is independent of *menu appearance* — it only affects whether an enabled cheat actually applies. But it is also a clue: if the in-zip `.gg` byte order is wrong, `cheats_available()` counting (16‑byte stride) still works yet entries are garbage.

**Action (claude, offline + board):**
1. Read the canonical layout in `Main_MiSTer/cheats.cpp` on the board source: `grep -nA20 'struct.*cheat\|cheats_send\|user_io_file_tx\|16' .../cheats.cpp` to confirm the exact byte order HPS transmits on ioctl 255.
2. Cross-check against a **known-good NES `.gg`** zip (NES cheats work): `python3` dump first 16 bytes of an NES cheat record and compare field positions.
3. If HPS layout ≠ our zip layout, regenerate the MSX1 zip via `mcf2mister.py` to emit records in the HPS-expected order **and** confirm the RTL loader offsets (`ioctl_addr[3:0]` cases in `rtl/msx.sv`) read addr/value from the matching bytes.

**Expected / proves:**
- Layouts match → format is not the cause; menu issue is purely discovery/render.
- Layouts differ → fix zip generator + RTL offsets together; re-test apply with a `0xC050=99`-style freeze on a game with a visible counter.

**Unblocks:** cheat-apply correctness (separate axis from menu visibility). Who: claude (source read + zip regen), user (in-game value confirm).

---

## Q6 — JTAG in-system confirmation that the core actually receives the 255 stream
Confirms RTL side independent of OSD: does `cheat_ram` / the 4-way way-RAM get written when HPS sends ioctl 255? Requires an in-system probe (signal-tap or ISMM read) compiled into the build — the current `cheatStd` RBFs may lack it.

**Action (claude):**
1. `jtagconfig` (find on board/host: `/opt/intelFPGA*/.../jtagconfig` or `which`) — confirm DE‑SoC chain enumerates (micro‑USB = JTAG `09fb`).
2. If a build with In‑System Memory Content Editor instances exists, `quartus_stp`/ISMM read of the cheat way-RAM after a toggle. Else add a Signal‑Tap on `cheat_dl`, `ioctl_wr`, `ioctl_addr[3:0]`, `ld_set`, `cwe` and re-synthesize.

**Expected / proves:**
- Writes observed on toggle → RTL receive path good; any failure is purely HPS-side (menu/discovery). De-prioritizes RTL work.
- No writes → either menu never enables (so HPS never sends) or ioctl index mismatch → ties back to Q1/Q3.

**Unblocks:** RTL-receive vs HPS-send. Lowest priority — only worth the re-synth cost if Q1–Q4 leave RTL-receive genuinely in doubt. Who: claude (build + JTAG).

---

## Priority order
1. **P1** — booting build + Slot A Load + serial `stdbuf -oL` capture of `cheats_init`. Decides everything. (user + claude)
2. **Q3** — grayed vs absent (free observation during P1). (user)
3. **Q2** — serial/strace confirm `cheats_init` + which filename opened. (claude)
4. **Q4** — miniz can open our STORED zip. (claude)
5. **Q5** — wire/zip record layout vs HPS + RTL offsets (apply-correctness, not menu). (claude + user)
6. **Q6** — JTAG/ISMM RTL-receive confirmation (only if P1–Q4 inconclusive). (claude)

## Cross-cutting cautions (from memory)
- **Never** test the game via "Load ROM PACK" (`F1/FC1` machine slot, store_name=1) — `cheats_init` only fires on Slot A/B `Load` (store_name=0, `H3FS3`/`H4F4`). Wasted days came from this confusion.
- **Do not** touch FC1/FC2 to "enable cheats" — that breaks machine/FW auto-load and boot. The cheats token is the independent `"C,Cheats;"`, not the `C` flag inside an `F` option.
- CONF_STR is byte-fragile here: a 1-byte change can shift SDRAM_DQ IOB placement and break boot fit (the F1 `cheatStd3` boot failure). If a CONF_STR edit is needed, re-build with a changed Quartus seed and re-verify 2MB RAM + boot.
- Console printf is suppressed while a core runs; serial requires `stdbuf -oL`. Confirm you are on the Mini‑B FT232R (`0403:6001` = ttyUSB0), not the micro‑USB JTAG port.
