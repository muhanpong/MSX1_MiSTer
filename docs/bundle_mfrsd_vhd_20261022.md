# Bundle: MFRSD SD-card VHD for the MiSTer MSX1 core (2026-10-22)

Self-contained brief for a fresh session.  Everything needed is in this file; nothing
depends on the session that wrote it.

## 0. Prompt to paste into the new session

> Work in `~/data/MiSTer_build/MSX1_MiSTer` (read-only for RTL; this is a tooling/doc task).
> Read `~/data/MiSTer_build/sdram128/docs/bundle_mfrsd_vhd_20261022.md` first.
> Report to me in Korean.  Do not push, do not touch the board, do not run Quartus.
> Deliverables:
> 1. `tools/mkvhd/mkmfrsd_vhd.sh` -- builds an MFRSD SD-card VHD from the recipe in §2
>    (size and partition count as arguments, optional files to copy in), with the checks in §3.
> 2. `docs/mfrsd_vhd.html` -- a one-page Korean guide (offline, no network requests,
>    system fonts) covering §1-§5: what the VHD is, how to make it (script + manual
>    commands), how to mount it in the core, first-boot steps, pitfalls, what is unverified.
> 3. Prove the script works on this machine: build a small (e.g. 64 MB, 1 partition) and a
>    large (8 GB, 2 partitions) image; show `fsck.fat -n -v` output (FAT16, data clusters
>    <= 65524) and an `mdir` listing of a copied file.  Negative control: run mkfs.fat
>    without `-a` on a full-size 4 GiB partition and show it is refused or not FAT16.
> 4. Verify with the oracle in §7: Nextor in openMSX must see the files on every partition
>    of both images; the negative controls in §7 must fail.  Put the oracle run into
>    `tools/mkvhd/check_nextor.sh` so it can be re-run.
> When done, send me the HTML and the script with SendUserFile (load it with
> ToolSearch "select:SendUserFile").  If sudo/losetup is not available, use mtools with
> `@@offset` instead of loop devices and say so.

## 1. What the VHD is (core side, read from MSX1.sv)

- OSD row `SC4,VHD,Load SD card;` -> image slot 4 (`img_mounted[4]`).  Mounting a non-empty
  image switches the MFRSD cartridge's SPI SD card from the IO board's physical slot to
  MiSTer's `sd_card` emulation (`vsd_sel`, MSX1.sv `sd_card sd_card (...)`).
- So the file is a **raw SD-card image**: 512-byte sectors, MBR + FAT partitions.  No VHD
  footer is needed; the `.vhd` extension is only the OSD filter.  Sparse files work.
- `img_size` is 64-bit (MSX1.sv): images > 4 GiB mount (22 GB and 24 GiB in use on the board).
- The cartridge must be MFRSD in slot A: CFG byte2 bits 1-3 = 4 (0x08); leave the slot-A
  mapper nibble on auto (0).  A stale Konami mapper left from a previous test broke it once.
- Board files in use: `games/MSX1/msxsd_2x2GB_4x4GB.vhd` (22,020,096,000 B),
  `msxsd_24GiB.vhd`, and `BURAI_6956347.vhd` (16 MB, no MBR, see §4).
- The core remembers the last image in `config/MSX1.s4`; MGL form:
  `<file type="s" index="4" path=".../x.vhd"/>`.

## 2. Recipe (hardware-verified 2026-06-27 by the MiSTer expert session: a 4 GB FAT16 in an 8 GB image read fine by Nextor)

```
truncate -s 8G sd.vhd
parted -s sd.vhd mklabel msdos
parted -s sd.vhd mkpart primary fat16 1MiB 4097MiB
parted -s sd.vhd set 1 boot on
parted -s sd.vhd mkpart extended 4097MiB 100%
parted -s sd.vhd mkpart logical fat16 4098MiB 100%
sfdisk --part-type sd.vhd 1 e ; sfdisk --part-type sd.vhd 5 e      # type 0x0E FAT16 LBA
LO=$(sudo losetup -fP --show sd.vhd)
sudo mkfs.fat -F 16 -s 128 -a ${LO}p1     # 4 GB -> -s 128 (64 KB clusters); 2 GB -> -s 64; ~520 MB -> -s 32
sudo mkfs.fat -F 16 -s 128 -a ${LO}p5
sudo fsck.fat -n -v ${LO}p1               # must say FAT16, data clusters <= 65524
MTOOLS_SKIP_CHECK=1 mcopy -i ${LO}p1 FILE ::/     # or mount
sudo losetup -d $LO
```

Layout rules: MBR (msdos label), one primary with the boot flag, then extended + logical;
partition type 0x0E; at most 4 GB per FAT16 partition (Nextor FDISK `partit.h` MAX_FAT16
4096 MB; FAT12 limit 32 MB).

## 3. Pitfalls (all observed)

- FAT16 holds at most 65,524 clusters.  A partition sized to the full 4 GiB makes mkfs.fat
  refuse ("too many clusters").  1 MiB alignment brings it under the limit; `-a` keeps
  reserved = 1 so the count fills exactly like the FDISK-made `msxsd_24GiB.vhd`.
  `-R 1` alone does not do it; `-a` is what works.
- The old note "Linux mkfs cannot make a 4 GB FAT16, FDISK is mandatory" is wrong: the
  cause was a call that let mkfs.fat auto-pick FAT12/FAT32.  `-F 16 -s 128` works.
- Nextor reads by cluster geometry; BPB differences from an FDISK-made volume (reserved,
  root entries, media F8/F0, OEM name) do not matter.
- Board busybox `losetup -P` does not create partition nodes: on the board mount with
  `offset=LBA*512`.  Board ssh is ~6 MB/s: build big images on the PC and send them zipped
  (an empty FS is zeros and compresses very well).
- Never change or write a VHD the core has open (`ls -l /proc/$(pidof MiSTer)/fd`); drop to
  the menu core first.

## 4. Drives and the image without an MBR

- Stock MFRSD driver: one drive per SD slot; only the active partition auto-mounts, the
  rest via MAPDRV.  The patched driver (SD_PARTS=6) mounts B:..G: at once (A: = ROM disk,
  H: = FDC), hardware-verified 2026-06-07.  **Unknown:** whether the mfrsd.rom in the
  current packs is the patched one.
- No-MBR form also works on the board: `BURAI_6956347.vhd` (16 MB) starts with an MSX-DOS2
  boot sector at sector 0 (OEM "BURAI-CR", 512 B/sector, 16 sectors/cluster, media F0,
  no 55AA signature), FAT12.  A PC-mkfs image without an MBR has **not** been verified.

## 5. First boot

- No need to re-partition with Nextor FDISK (CALL FDISK).
- When MFRSD boots, the ROM disk's MM file manager comes up: press `q`, wait for `A:\>`,
  then type.  Typing earlier sends keys to MM, which tries to write to A: (ROM disk) and
  gives "Write error" (seen twice).

## 6. Unverified (say so in the guide)

- PC-mkfs image without an MBR.
- Small FAT12 partitions made with mkfs.fat.
- Whether the shipped pack's mfrsd.rom is the multi-partition patched driver.

## 7. Self-verification harness (oracle: openMSX + MegaFlashROM SCC+ SD)

Host checks (fsck/mdir) only show the FAT is well-formed.  Whether **Nextor** accepts the
image is decided by Nextor itself, so run it:

- Emulator: `~/data/openmsx457/derived/x86_64-linux-opt-3rd/bin/openmsx` (openMSX 21.0-457),
  system data `OPENMSX_SYSTEM_DATA=~/data/openmsx457/derived/x86_64-linux-opt-3rd/bindist/install/share`.
  Run headless: `SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy`, `-script x.tcl`, `set throttle off`.
  Use your own `OPENMSX_USER_DATA` / `OPENMSX_HOME` directory and a settings file with
  `save_settings_on_exit false` (openMSX writes settings on exit; keep ~/.openMSX clean).
  Symlink `~/.openMSX/share/systemroms` into your user-data dir for the machine ROMs.
- Extension: `share/extensions/MegaFlashROM_SCC+_SD.xml`.  Copy it into your user-data
  `extensions/` under a new name and point `<sdcard1><filename>` at the image under test
  (the SD image is a raw sector image, exactly what the script makes; openMSX's SdCard is
  backed by its HD class).  Machine: an MSX2 with a disk drive, e.g. `Panasonic_FS-A1F`;
  `-ext <your extension>`.
- ROM caveat: the extension's ROM is sha1 `1621f623...` (`~/.openMSX/share/systemroms/extensions/mfrsd.rom.gz`),
  an older Nextor than the packs' `mfrsd_nextor214.rom` (sha1 `411c6d8c...`, Nextor 2.1.4,
  see `~/data/MiSTer_build/MSX1_MiSTer/docs/mfrsd_kernel_nextor214_20260923.md`).  That
  file is not on this machine (the ROM store is per-machine).  Use 1621f623 and **state in
  the report and the HTML that the oracle kernel differs from the pack's**; if the user
  can supply mfrsd_nextor214.rom, re-run with it (put its sha1 in the copied XML).
- Procedure: boot, wait for the MM file manager / `A:\>` (§5: press `q` first), then type
  commands with `type_via_keyboard` (e.g. `DIR B:\r`, `DIR C:\r`) and read the screen
  text with the `get_screen` Tcl command; assert the copied file names appear.  Log the
  screens to a file; take a `screenshot -raw` at the end (set `throttle on` and wait a
  real-time second before the screenshot, or it may show a stale frame).
- Positive: both images (64 MB 1 partition; 8 GB with primary + logical), a known file on
  each partition listed by DIR.  Note how many drives the stock driver mounts (§4: one
  per slot unless MAPDRV) and test MAPDRV for the second partition if needed.
- Negative controls (must FAIL, i.e. Nextor shows no drive / "Not a DOS disk" / an error):
  (a) the same image with partition type 0x0C (FAT32 LBA) and a FAT32 filesystem;
  (b) the 4 GB partition formatted without `-F 16` (mkfs picks FAT32);
  (c) an image whose MBR signature 55AA is zeroed.
  If a control passes, the harness is not looking at the right thing -- fix that first.
- Not covered by the oracle: the MiSTer core's SD path (`sd_card` emulation + MFRSD SPI in
  the RTL).  The board facts in §1-§5 cover that; say so in the report.

Source of §1-§5: a reply from the `mister-super-expert` session (2026-10-22), marked by it
as hardware-verified except the items in §6; §1 core facts re-read from MSX1.sv in the
v9968_v9990 worktree the same day.
