# Handoff 2026-11-10: MSX Pack Forge, V9990 mode check, JoyMega review

Session msx1-handoff (2026-11-08 .. 11-10). Everything below is committed locally only;
nothing was pushed. Report to the user in Korean; commits and docs stay English.

## 1. MSX Pack Forge (`tools/CreateMSXpack/packbuilder.html` = `releases/MSX_Pack_Forge.html`)

The two files are byte-identical on every branch that carries them. Four local commits on
each of four branches, same content everywhere:

| Branch | i18n | first run | working screen | fresh DATA + test |
|---|---|---|---|---|
| nextz80 (`MSX1_MiSTer`) | 2fd09cc | b60b3be | c9ab9ff | 3837523 |
| nextz80_v9990 | e4d35a2 | b2e4610 | 96717c7 | 4b7cdd0 |
| V9968_Geo3D (`sdram128`) | 9f264a5 | 530a8ab | 51bd860 | 5942ed9 |
| opl4_scratch | 5792cf8 | e332289 | 83df077 | 41ed202 |

`archive/v9968_cmdcache_fast` also carries the old page and was left alone (archive).

What changed:
- **Languages:** Korean / English / Japanese, three visible buttons next to the theme button
  (the user rejected a dropdown). First visit follows the browser (ko, ja, else en); choice in
  localStorage. All strings in the `I18N` table after `DATA`; markup uses `data-i18n*`,
  script text `t(key, ...)`. Skip reasons are stored as functions so they re-translate.
- **First run** (nothing read yet, `.wrap.first`): big drop zone, three steps, supported
  machine list with per-machine "show missing"; rail, bulk buttons and per-row downloads
  hidden. Step 3 "unzip into games/MSX1/MSX/" was confirmed right by the user.
- **Working screen:** drop-result summary (checked / new / unused / unreadable, already-in-
  store, skip reasons, folded log); synthesized turbo R disk ROMs below the missing list;
  "Put it on the board" section (unzip target, blank SRAM.NVR button moved out of the
  toolbar, overwrite warning); blocked rows get "Show N missing" instead of a disabled
  download; row downloads are outline buttons.
- **DATA was stale since 10-23:** re-extracted. The old page still offered the nine DOS1
  turbo R packs retired in 0295165 and lacked the two MoonSound packs of 29a829b
  (103 -> 96 machines). "Download all" now puts CART_FW_* at the ZIP top, like
  createMSXpack.py's MSX/ (was Extension/).
- **`test_packbuilder.sh` / `.js`** (new): Python build of the store vs the page driven in
  headless Chromium through its own file input and "download all" button; checks DATA ==
  fresh extraction, identical paths, identical SHA-1. `PACK_FW_SUBST=1` covers the firmware
  packs with stand-in ROMs. Needs node + playwright-core; this machine:
  `NODE_PATH=/data/_claude/tmp/4091ee2a/pw/node_modules TMPDIR=/data/_claude/tmp/4091ee2a`.
  2026-11-08 results (567-file store): 79/79 identical; with PACK_FW_SUBST=1 83/83.
  Controls: stale page fails on DATA (103 vs 96), one header byte fails 79/79, firmware packs
  back under Extension/ fail on 4 paths (only visible with PACK_FW_SUBST=1).
- Not done (user decisions): "star my machines" -- reviewed, recommended against (small gain,
  localStorage on file://, splits progress/bulk download). The canvas design's other items
  (red-free missing lines, "replace with another file..." link) were not ported.
- Design canvas (private): https://claude.ai/artifact/NYFjwhCKXre7sgV3ZHpvdJ (3 boards:
  working screen ko, first run en dark, phone ja).

Answered, no action: a file-hunter "System ROMs" link -- recommended against (copyright /
GitHub DMCA risk); alternatives C-BIOS (BSD-2, our 5 C-BIOS files match the pack table, can be
embedded, ~150 KB) and openMSX's system-ROM docs. There is no turbo R C-BIOS anywhere here
(blueMSX+ "MSXturboR - C-BIOS FDD" is Hesoten's, not ours, not on this machine).

## 2. V9990 on nextz80_v9990 (rampa069 core, BSD-3, 36170c5)

- **All display modes pass in the core:** 33 render tests (B0-B7 incl. B5/B6 high scan, all
  colour modes, P1/P2 + sprites, cursors, PAL, EO, display off, CPU writes) with OUR
  `v9990_vram_cache.vhd` and the measured ch5 latency distribution. Bench copy:
  `/data/_claude/tmp/msx1-handoff/v9990/modes` (`make test PYTHON=../../rampa/.venv/bin/python
  T=v9990_display`, env `V9990_VRAM_CACHE=4 V9990_VRAM_LAT=7 V9990_VRAM_GAP=5`, ~20 min).
  Control `modesneg` (wrong word on line fill): b3_bp6 and p1_sprites FAIL.
- **What reaches the MiSTer output** (wrapper samples every 4 core clocks, 10.74 MHz):
  P1/B1/B0/P2/B3 100 %, B2 100 % but uneven pixel widths, B4 75 % (earlier "half" was wrong),
  B7 50 %, B5 50 % and B6 43 % -- and B5/B6 are 25/31 kHz lines the wrapper does not handle
  (`hscan_o`, `interlace_o` unconnected). Fix = a pixel path at 2-3 core clocks + a high-scan
  video path; not started.
- **Not in the RTL at all:** CMMK (kanji ROM; no interface), ADVN (no-op) and PSET not moving
  DX/DY, Ys superimpose (stored in the palette, no output). Different from hardware: mid-line
  register changes apply from the next line; no command timing model (LMMV 9.2 ms vs openMSX
  ~6.4); TR set when the engine is ready. Missing guard: uploads can overwrite the V9990 VRAM
  in the top 512 KB of SDRAM.
- **Licence:** source headers kept (condition 1). The rbf release (condition 2) should carry
  the full BSD-3 text: the Readme names the core but not the text -- add a third-party licence
  section. Credit "uses rampa069's V9990 core" is fine; nothing that reads as his endorsement.

## 3. JoyMega (`rtl/peripheral/joymega.sv`, identical on V9968_Geo3D and nextz80_v9990)

- Phase table == openMSX JoyMega.cc read(); `sim/run_joymega.sh` 136/136, an X/Y-swap mutant
  fails 2. Pin-8 polarity matches the real adapter (it inverts pin 8 into TH; badcoffee
  joymega-en), openMSX and all three games. Button mapping (CONF_STR names -> status order)
  is right. The core is always a 6-button pad (openMSX too, in effect).
- **Defect 1 (core):** after the 1.5 ms timeout with pin 8 high the core re-aligns at once
  (cycle 1), so the next falling edge lands in cycle 2, not 0 (openMSX 0). Only a scan within
  1.5 ms of that edge misreads (WBML: one frame classified 3-button). Prototype fix: step only on
  a pin-8 edge that disagrees with the cycle, plus a `six` input (cycleMask 7 / 1) for an OSD
  "3-button / 6-button" choice: `/data/_claude/tmp/4091ee2a/jm/fix/` (rtl + `sim/tb_kinds.sv`:
  8000/8000 vs the openMSX rule, controls 747 and 1251 failures; `tb_joymega.sv` 136/136 with
  `.six(1'b1)`). NOT applied: needs a status bit, msx.sv wiring, rbfs.
- **Defect 2 (core, inherited 2022, edfb510 line):** `joyA = joy_a & {psg_iob[0], psg_iob[1], ...}`
  ANDs the triggers with the R#15 pin 6/7 outputs with the two bits crossed (pin 6 output gates
  trigger B). openMSX disables that AND (#if 0, breaks NinjaTap). The games write bits 0-3 = 1,
  so unaffected. User to choose: drop the AND (openMSX) or uncross it.
- **Games:** WBML V9968 (`~/data/wbml_msx_v9968`, opt.asm jm_scan / rt3 read_joy), WBML ko V9990
  (`~/data/wbmlb_ko_v9990`, rt3 read_joy) and Knightmare (bank4 chr_go) are all right for the
  core and for a real MSX + adapter + 6-button pad; no change needed. knightmare-v2 confirmed
  WBML V9968 writes R#15 only in those two routines.
- **MODE glitch on WBML V9968** (user: works on the V9990 build): openMSX probe on
  `out/wbml_v9968_jm.rom` (source 988f5bc): with MODE held one P1 read per arcade tick, right /
  left alternating exactly 300/300 in 600 ticks (control without MODE: 600 x none); with a
  JoyMega plugged, detected 6-button on the title and scanned once per tick in play. Scripts:
  `/data/_claude/tmp/4091ee2a/jmw/{mode,scan}.tcl`. One difference from the V9990 port: V9968
  applies MODE also on the title / menus (V9990 only in a game). Not yet told to knightmare-v2.

## 4. Still open from before this session

- Board checks: V9968 rbf `msx1v_20261106a_up419_877d03b` (WBML base ROM to the title,
  GT / KM224 / ASO / Zanac / GoFigure) and nextz80_v9990 1102a (V9990 Video Out). Then release
  and push both branches. Geo3D fill decision (upstream engine vs our OSD option).
- V9968P estimate given (6-12 months; 4-6 to a prototype); offered measurements: V9990 block
  ALM / RAM blocks and SDRAM TDM slack.
- WBML ending tally investigation: stopped by the user; do not resume.
