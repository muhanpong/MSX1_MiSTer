# MFRSD pack kernel: it is Nextor 2.1.4 — a correction (2026-09-23)

**Fact.** The MegaFlashROM SCC+ SD firmware the packs build with carries
**Nextor 2.1.4**:

| file (untracked ROM store `tools/CreateMSXpack/ROM/`) | sha1 | since 2026-09-23 named |
|---|---|---|
| `mfrsd.rom` | `411c6d8c…` | `mfrsd_nextor214.rom` |
| `mfrsd_2slot.rom` | `95cfb188…` | `mfrsd_2slot_nextor214.rom` |

The CART_FW pack XMLs reference these by sha1 (createMSXpack looks ROMs up by
hash, so the rename is cosmetic).  Nothing about the kernel needed changing.

**What went wrong.** During the Illusion City / SD Snatcher work a peer session
reported the MFRSD kernel as "Nextor 2.10 alpha 2" that failed both games.  That
test had loaded **`releases/CreateMSXpack/ROM/mfrsd.rom` (sha1 `1621f623…`)** — a
stale copy under `releases/` that is not what the packs are built from.  The
conclusion, and the "update the MFRSD kernel" item derived from it, are
withdrawn.  The stale copy is left in place (nothing under `releases/` is
deleted); do not measure with it.

**Rule.** Before judging any pack ingredient, take the file from
`tools/CreateMSXpack/ROM/` and check its sha1 against the pack XML.  A ROM with
the right *name* elsewhere in the tree is not evidence.

Related: `docs/turbor_diskrom_20260923.md` §2.4 and §7; the kernel-replacement
procedure (Normal 128 kB image at 0x700000, never the Recovery build) remains in
the project memory should a real update ever be wanted.
