# Board captures (parsed `tools/parse_evtrace.py` output, gzipped)

All: Panasonic FS-A1ST 1 MB pack, OSD Z80 speed 3.58 MHz, turbo R features on.

| file | core | what it shows |
|---|---|---|
| `evt_p2.txt.gz` | 20260920q_loopfold | A boot.  n=1900-1906: `E5<-40 -> SWAP R800`, 0.7 us, `E5<-60 -> SWAP Z80` at PC 1296-1299 -- the BIOS init OTIR `[40,60]` BOUNCING under the register-copy hand-over.  Misread at the time as "a BIOS probe".  Ends in the RAM-size search at 7D60 (wedge trigger, >5 s where the reference takes 0.5456 s). |
| `evt_p5.txt.gz` | 20260921a_fffffix | Illusion City disk 1, 679 ms.  Nine sector transfers at 765D, all exactly 512 bytes, all leaving through `RET P`; eight pop 7669, the ninth (n=3550) pops **0000** with SP EAE8 -> EAEA.  No CPU hand-over anywhere near it.  From there a garbage cycle through the BIOS jump table (0187 = the overlay's C9), then FFh at 206F. |
| `evt_p6.txt.gz` | 20260922a_mwatch | NOT a game: an intermittent BOOT failure.  n=8027-8034: the firmware's 7900 routine calls CHGCPU(0) on the R800 -> stub `OUT (E5),00` -> SWAP Z80 at 0182 -> RET 7916 -> RET 790D -> RET **F3C9** (reference: **F392**; C9h is the RET opcode just fetched = a stale read of the low byte), three RETs 0.7 us apart = T80s still clocked at 21.5 MHz.  Then the +2 crawl C9CA, C9CC... = RAM fill pattern 4 (FFh/00h alternating) executed as RST 38h / NOP. |

Reading traps: `tools/evtrace/README.md`.  `CALL 0038` is normal in Illusion City's ISR
(reference ED2B / ED3D = `CD 38 00`), so an 0038 fetch without an INTA is not by itself a runaway.
