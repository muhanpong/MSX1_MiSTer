# packbuilder.html — createMSXpack in one offline page

`packbuilder.html` builds the same `.MSX` packs as `createMSXpack.py`, in a browser,
with no server and no install. Open the file, drop the ROM folder or a collection
`.zip` on it, download the packs. Everything stays on the machine: the page makes **no network request at all**,
so it works with the network off. Type is set in system fonts for that reason.

## Why it can be one file

The XML machine definitions are the only input the tool needs besides the ROMs, and
they are small once the parts the builder never reads are dropped:

| | |
|---|---|
| `Computer/` + `Extension/` XML | 363 KB |
| after extraction to JSON | 76 KB |
| the page, data embedded | 104 KB |

`kbd_layout` is 66 KB of base64 across 99 files and is **the same layout in every
one**, so it is stored once and referenced by index.

## Regenerating after an XML or ROM-table change

    cd tools/CreateMSXpack
    python3 packbuilder_extract.py > /tmp/packdata.json   # XML -> compact JSON
    # paste it in place of the DATA literal at the top of packbuilder.html's <script>

The block tables (`BLOCK_TYPES`, `MAPPER_TYPES`, `CONFIG_TYPES`, …) are duplicated in
the page and must track `createMSXpack.py`. They are ordered lists whose index *is* the
value written to the pack, so entries are only ever appended — the same rule as
`mapper_typ_t` in `rtl/package.sv`.

## Verified against the Python

Both builders were run over the whole ROM store and compared byte for byte:

    86 machines/firmware packs built by both, 0 differences.

The firmware path was checked separately, because the store lacks two of the five ROMs
the `CART_FW_*` packs want (`GM2.ROM` is a commercial game; `mfrsd_nextor214.rom` is the
MegaFlashROM SCC+ SD flash image, which the open Nextor source does not produce). With
substitutes of comparable size standing in for those two, all four packs matched byte
for byte at 4,407,376 bytes.

Archive reading is covered by its own test: one `.zip` holding a deflated ROM, a stored
ROM, a `.gz` member and a nested `.zip`, all four recovered with the right SHA-1.

The 17 remaining XMLs are ones `createMSXpack.py` cannot build here either, because
their ROMs are not in the store.

One behaviour is easy to get wrong and is covered: a missing **device** ROM (a kanji
font, say) is not an error — the pack is written with that device's size 0 and no
payload, exactly as the Python does. Only a missing **block** ROM aborts a pack.

## The turbo R disk ROM is synthesized in the page

The ten `FS-A1ST / FS-A1GT … DOS2` packs need `fs-a1{st,gt}_diskrom_wd2793.rom`, which
no one has a dump of: it is built by `tools/turbor_diskrom/synth_diskrom.py` from the
machine's own firmware and the Sony HB-F1XD disk ROM. Requiring that script first would
have left those ten packs out of reach of anyone using the page on its own, so the same
34 patches are ported into it.

When the firmware (or an already cut 64 kB disk ROM) and the HB-F1XD disk ROM are both
in the store, the page builds the disk ROM, checks it against the known SHA-1, and puts
it in the store under that hash. The DOS2 packs then turn buildable on their own, and
the ROM itself can be downloaded from the sidebar.

Like the Python, the page carries **no ROM content** — only addresses and the few
jump/call bytes it writes — and every patch asserts the original bytes before writing.
A result whose SHA-1 does not match is discarded rather than offered.

Checked from the stock dumps with the two pre-built copies removed from the store: both
ROMs come out byte-identical to the Python's, and all ten DOS2 packs then build
byte-identical to `createMSXpack.py`.

## Finding out what to fetch next

A pack that cannot be built used to say only how many ROMs it wanted, which left the
question of *which* ones unanswered. Clicking any row now unfolds the list of every ROM
that pack uses: filename, the slots it sits in, the first eight hex digits of its SHA-1,
and a dot that is green when the store has it, red when it blocks the pack, amber when
it is an optional device ROM. Clicking a red or amber line marks that ROM in the
sidebar's missing list and outlines every other pack waiting on the same file.

The sidebar list carries a count per ROM and is sorted by it, so the file that unblocks
the most machines is at the top. Clicking an entry there scrolls to the first pack that
needs it.

## Notes

- ROMs are matched by SHA-1, never by filename, so a renamed dump still resolves.
  `crypto.subtle` does the hashing, with a pure-JS SHA-1 fallback for contexts that
  do not expose it.
- Archives can be dropped in as they are, because collections are usually
  distributed as one `.zip`. The reader is hand-written against the central
  directory, so entries written with a data descriptor still give the right sizes,
  and it understands ZIP64. Stored and deflated members are both read, `.gz`
  members are gunzipped, and a `.zip` inside a `.zip` is followed two levels deep.
  Decompression is the browser's own `DecompressionStream`, so there is still no
  library and still no network request. Encrypted members and compression methods
  other than store and deflate are listed in the log and skipped.
- A hash that no pack uses is **counted and dropped, never retained**. A full system
  set is a few hundred files and over a hundred megabytes unpacked; holding all of it
  would put the page out of reach on a phone. The "쓸모 있는 ROM" meter is therefore
  the number of files kept, not the number read.
- The ZIP writer is store-only (no compression) and hand-written; its output was
  checked with `unzip -t`.
- Published as a Claude Artifact, the page routes saves through the `downloads`
  capability, which does not accept a `.MSX` extension — there the packs come out
  inside a `.zip`. Opened from disk, single packs download as plain `.MSX`.
