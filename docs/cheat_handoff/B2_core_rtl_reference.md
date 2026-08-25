# B2 — MSX1 Core Cheat Engines: Technical Reference (two implementations)

Documents the two cheat implementations side by side. No judgement; both are recorded with exact `file:line`.

- **MAIN REPO (custom `.CHT`, merged):** `/home/muhanpong/Documents/github/MSX1_MiSTer/{MSX1.sv, rtl/msx.sv}`
- **WORKTREE (standard `.gg`/index 255, unmerged):** `/home/muhanpong/Documents/github/MSX1_MiSTer/.claude/worktrees/cheat-standard/{MSX1.sv, rtl/msx.sv}`

Both share the same 4-way set-associative BRAM lookup core (rtl/msx.sv lines 280–313 are byte-identical). They differ only in the **CONF_STR menu tokens**, the **master-enable wiring**, and the **loader** (ioctl index + record layout). See section C for the diff.

---

## A) MAIN REPO — custom `.CHT` engine

### A.1 CONF_STR tokens — `MSX1.sv`
```
253:   "MSX1;",
255:   "FC1,MSX,Load ROM PACK,30000000;",
...
294:   "F6,CHT,Load Cheats;",
295:   "O[51],Cheats,Off,On;",
```
- Cheat file loaded via a dedicated **`F6,CHT`** file-browser entry (line 294).
- Master on/off via **`O[51]`** (line 295).

### A.2 Master-enable wiring — `MSX1.sv`
```
511:   .cheat_en_master(status[51]),
```
Drives `msx` instance port from OSD bit 51.

### A.3 4-way set-assoc BRAM structure — `rtl/msx.sv`
```
285:(* ramstyle = "M10K" *) logic [17:0] cheat_ram0 [512];
286:(* ramstyle = "M10K" *) logic [17:0] cheat_ram1 [512];
287:(* ramstyle = "M10K" *) logic [17:0] cheat_ram2 [512];
288:(* ramstyle = "M10K" *) logic [17:0] cheat_ram3 [512];
289:logic [17:0] cq0, cq1, cq2, cq3;       // registered reads at set index a[8:0]
290:logic [15:0] a_q;                      // address aligned with the registered read
305:logic [2:0] cur_gen;                   // current generation (1..7, never 0)
```

### A.4 Loader (custom `.CHT`, 4-byte record) — `rtl/msx.sv`
```
315:// loader (ioctl "F9,CHT"): generation invalidate + next-way placement
316:logic       cheat_dl_q;
317:logic [7:0] ld_lo, ld_hi, ld_val;
318:logic [1:0] nextway [512];
320:wire        cheat_dl = ioctl_download & (ioctl_index[5:0]==6'd6);  // CHT moved F9→F6 (F9 entry didn't show in OSD)
321:wire [8:0]  ld_set   = {ld_hi[0], ld_lo};   // index = addr[8:0]
322:wire [6:0]  ld_tag   = ld_hi[7:1];          // tag   = addr[15:9]
324:initial cur_gen = 3'd1;
325:always @(posedge clk21m) begin
326:   cheat_dl_q <= cheat_dl;
327:   cwe <= 4'b0000;
328:   if (cheat_dl & ~cheat_dl_q) begin                       // new download: bump gen, reset way ptrs
329:      cur_gen <= (cur_gen==3'd7) ? 3'd1 : cur_gen + 3'd1;
330:      for (ni=0; ni<512; ni=ni+1) nextway[ni] <= 2'd0;
331:   end
332:   if (cheat_dl & ioctl_wr) begin
333:      case (ioctl_addr[1:0])
334:         2'd0: ld_lo  <= ioctl_dout;
335:         2'd1: ld_hi  <= ioctl_dout;
336:         2'd2: ld_val <= ioctl_dout;
337:         2'd3: if (ioctl_dout[0]) begin                    // enable -> insert into next way of the set
338:                  cwe             <= (4'b0001 << nextway[ld_set]);
339:                  cwaddr          <= ld_set;
340:                  cwdata          <= {cur_gen, ld_tag, ld_val};
341:                  nextway[ld_set] <= nextway[ld_set] + 2'd1;
342:               end
343:      endcase
344:   end
345:end
```
- ioctl index matched at **`ioctl_index[5:0]==6'd6`** (line 320). (Header comment still says "F9,CHT"; the active match is index 6 = `F6`.)
- **4-byte record**, addressed by `ioctl_addr[1:0]`: byte0=`addr_lo`, byte1=`addr_hi`, byte2=`value`, byte3=`flags` (bit0 = enable; commit only when set).
- Block comment (lines 280–284) documents the record as `{addr_lo,addr_hi,value,flags(bit0=enable)}`, master `O[51]`.

### A.5 d_to_cpu injection — `rtl/msx.sv`
```
347:assign d_to_cpu = rd_n              ? 8'hFF           :
348:                  vdp_en            ? d_to_cpu_vdp    :
349:                  rtc_en            ? d_from_rtc      :
350:                  ~psg_n            ? d_from_psg      :
351:                  ~ppi_n            ? d_from_8255     :
352:                  (ms_wave_cs | ms_fm_cs) ? ms_dout   :
353:                  cheat_act         ? cheat_value     :   // cheat freeze/POKE override
354:                                    d_from_slots    ;
```
Cheat override leg sits **below all IO legs**, above the default `d_from_slots`.

---

## B) WORKTREE — standard MiSTer cheat engine

### B.1 CONF_STR tokens — `.claude/worktrees/cheat-standard/MSX1.sv`
```
253:   "MSX1;",
254:   "C,Cheats;",
255:   "-;",
256:   "F1,MSX,Load ROM PACK,30000000;",
257:   "FC2,MSX,Load FW  PACK,32000000;",
```
- Standard **`C,Cheats;`** menu entry (line 254) — this is the stock MiSTer cheat menu, no dedicated file token and no `O[51]`.
- Note ROM-load token here is **`F1`** (line 256) vs **`FC1`** in main repo (see C).

### B.2 Master-enable wiring — `.claude/worktrees/cheat-standard/MSX1.sv`
```
510:   .cheat_en_master(1'b1),   // standard MiSTer OSD cheat menu is the sole on/off control
```
Hard-tied to **`1'b1`**; the stock `C,Cheats;` menu is the only on/off control (HPS sends only enabled cheats).

### B.3 Loader (standard `.gg`, 16-byte record, index 255) — `rtl/msx.sv`
```
315:// MiSTer STANDARD cheat path: HPS sends ONLY the enabled cheats on ioctl index 255,
316:// as concatenated 16-byte .gg records {addr32, compare32, replace32, flag32} LE.
317:// We use addr[15:0] (bytes 0,1) and replace[7:0] (byte 8). Every received record is
318:// inserted (HPS already filtered to enabled). HPS re-sends the whole set on each toggle,
319:// so the generation bump on download start invalidates the previous set.
320:logic       cheat_dl_q;
321:logic [7:0] ld_lo, ld_hi;
324:wire        cheat_dl = ioctl_download & (ioctl_index[7:0]==8'd255);
325:wire [8:0]  ld_set   = {ld_hi[0], ld_lo};   // index = addr[8:0]
326:wire [6:0]  ld_tag   = ld_hi[7:1];          // tag   = addr[15:9]
328:initial cur_gen = 3'd1;
329:always @(posedge clk21m) begin
330:   cheat_dl_q <= cheat_dl;
331:   cwe <= 4'b0000;
332:   if (cheat_dl & ~cheat_dl_q) begin                       // new download: bump gen, reset way ptrs
333:      cur_gen <= (cur_gen==3'd7) ? 3'd1 : cur_gen + 3'd1;
334:      for (ni=0; ni<512; ni=ni+1) nextway[ni] <= 2'd0;
335:   end
336:   if (cheat_dl & ioctl_wr) begin
337:      case (ioctl_addr[3:0])                               // byte position within the 16-byte record
338:         4'd0: ld_lo <= ioctl_dout;                        // addr[7:0]
339:         4'd1: ld_hi <= ioctl_dout;                        // addr[15:8]
340:         4'd8: begin                                       // replace[7:0] = freeze value -> commit
341:                  cwe             <= (4'b0001 << nextway[ld_set]);
342:                  cwaddr          <= ld_set;
343:                  cwdata          <= {cur_gen, ld_tag, ioctl_dout};
344:                  nextway[ld_set] <= nextway[ld_set] + 2'd1;
345:               end
346:         default: ;
347:      endcase
348:   end
349:end
```
- ioctl index matched at **`ioctl_index[7:0]==8'd255`** (line 324) — MiSTer's reserved cheat-download index.
- **16-byte record**, addressed by `ioctl_addr[3:0]`: byte0=`addr_lo` (line 338), byte1=`addr_hi` (line 339), **byte8=`value`** = commit point (line 340).
- No `flags`/enable gate in the loader: every received record is inserted (HPS pre-filters to enabled cheats). The generation bump at download start (line 333) invalidates the prior set, so a menu toggle re-sends the whole set.
- d_to_cpu injection is identical to main repo, shifted by +4 lines: `cheat_act` leg at **line 357**, mux at 351–358.

### B.4 ioctl_index plumbing — `.claude/worktrees/cheat-standard/MSX1.sv`
```
213:wire      [15:0] ioctl_index;
328:   .ioctl_index(ioctl_index),     // hps_io
724:    .ioctl_index(ioctl_index),    // msx core
```

---

## C) Diff summary — main-repo loader vs worktree loader

| Aspect | MAIN REPO (custom `.CHT`) | WORKTREE (standard) |
|---|---|---|
| Menu token | `F6,CHT,Load Cheats;` (MSX1.sv:294) + `O[51],Cheats,Off,On;` (MSX1.sv:295) | `C,Cheats;` (MSX1.sv:254) — stock MiSTer cheat menu |
| ioctl index match | `ioctl_index[5:0]==6'd6` (msx.sv:320) | `ioctl_index[7:0]==8'd255` (msx.sv:324) |
| Record size | 4 bytes, `ioctl_addr[1:0]` (msx.sv:333) | 16 bytes, `ioctl_addr[3:0]` (msx.sv:337) |
| Field layout | b0=addr_lo, b1=addr_hi, b2=value, b3=flags(bit0=en) (msx.sv:334–337) | b0=addr_lo, b1=addr_hi, b8=value (msx.sv:338–340) |
| Commit gate | byte3 with `ioctl_dout[0]` enable (msx.sv:337) | byte8 unconditional commit (msx.sv:340) |
| Master enable | `status[51]` (MSX1.sv:511) | `1'b1` hard-tied (MSX1.sv:510) |
| ROM-load token | `FC1,MSX,Load ROM PACK` (MSX1.sv:255) | `F1,MSX,Load ROM PACK` (MSX1.sv:256) |

Notes:
- **FC1 vs F1:** main repo loads the ROM pack via `FC1` (file with explicit core-index nibble); worktree uses `F1`. This is a CONF_STR difference adjacent to the cheat change, recorded for completeness — both still load `MSX` pack to `30000000`.
- **F6/O51 vs C,Cheats:** main repo exposes its own file loader + explicit Off/On bit; worktree relies entirely on MiSTer's built-in `C` cheat menu (HPS owns enable/parse and streams via index 255).
- The lookup core (msx.sv:280–313) and the d_to_cpu mux structure are unchanged between the two.

---

## D) 4-way lookup mechanics (shared — identical in both, `rtl/msx.sv`)

Slot encoding (18 bits): `{gen[2:0], tag[6:0], value[7:0]}`. 512 sets × 4 ways = capacity 2048.
```
280://  ----- Cheat engine: 4-way set-associative BRAM, 1-cycle parallel lookup -----
281://  512 sets x 4 ways (capacity 2048). slot = {gen[2:0], tag[6:0], value[7:0]} (18b).
282://  index = a[8:0], tag = a[15:9]. gen = generation -> invalidate-on-reload (no sweep/race).
```
Index / tag derivation (loader side):
```
321:wire [8:0]  ld_set   = {ld_hi[0], ld_lo};   // index = addr[8:0]
322:wire [6:0]  ld_tag   = ld_hi[7:1];          // tag   = addr[15:9]
```
Registered parallel reads `cq0..cq3` at set index `a[8:0]`, with `a_q` holding the aligned address:
```
295:always @(posedge clk21m) begin
296:   cq0 <= cheat_ram0[a[8:0]]; cq1 <= cheat_ram1[a[8:0]];
297:   cq2 <= cheat_ram2[a[8:0]]; cq3 <= cheat_ram3[a[8:0]];
298:   a_q <= a;
```
Per-way hit = generation match AND tag match; OR-reduce; priority-mux the value:
```
307:assign chit[0] = (cq0[17:15]==cur_gen) & (cq0[14:8]==a_q[15:9]);
308:assign chit[1] = (cq1[17:15]==cur_gen) & (cq1[14:8]==a_q[15:9]);
309:assign chit[2] = (cq2[17:15]==cur_gen) & (cq2[14:8]==a_q[15:9]);
310:assign chit[3] = (cq3[17:15]==cur_gen) & (cq3[14:8]==a_q[15:9]);
311:wire        cheat_hit   = |chit;
312:wire [7:0]  cheat_value = chit[0]?cq0[7:0] : chit[1]?cq1[7:0] : chit[2]?cq2[7:0] : cq3[7:0];
313:wire        cheat_act   = cheat_en_master & cheat_hit & (a==a_q) & ~mreq_n & rfrsh_n;
```
Activation guards (line 313): master enable, a hit, **`(a==a_q)`** (address stable through the pipeline register — kills mid-fetch false hits), memory request `~mreq_n`, and not-refresh `rfrsh_n`.

Override is applied as a `d_to_cpu` mux leg placed **below all IO decode legs**, above the default `d_from_slots`:
- MAIN: `rtl/msx.sv:353` (`cheat_act ? cheat_value :`), mux 347–354.
- WORKTREE: `rtl/msx.sv:357` (`cheat_act ? cheat_value :`), mux 351–358.

Generation invalidate-on-reload: each download start bumps `cur_gen` (1→7 wrap, never 0) and resets all `nextway` pointers, so a reload logically clears the table with no per-cell sweep (msx.sv:328–331 main / 332–335 worktree). `nextway[ld_set]` round-robins way placement within a set on each insert.

---

## E) The `.gg` byte-offset question (worktree only)

**Current worktree loader offsets** (`rtl/msx.sv:337–340`):
- address low byte @ **byte 0** (`ioctl_addr[3:0]==4'd0`, line 338)
- address high byte @ **byte 1** (`ioctl_addr[3:0]==4'd1`, line 339)
- value (freeze) @ **byte 8** (`ioctl_addr[3:0]==4'd8`, line 340 — commit point)

The header comment (msx.sv:316) describes the 16-byte record as `{addr32, compare32, replace32, flag32}` little-endian, and states it uses `addr[15:0]` (bytes 0,1) and `replace[7:0]` (byte 8).

**Open finding — NES-standard `.gg` layout differs.** The canonical MiSTer NES `.gg`/Game Genie 16-byte record is `{flags32, addr32, compare32, replace32}` LE, which places:
- address low byte @ **byte 4** (addr field starts at offset 4)
- value/replace low byte @ **byte 12** (replace field starts at offset 12)

So the worktree's byte0/byte1/byte8 offsets do **not** match the NES-standard byte4-5/byte12 layout.

**Self-consistency note:** the worktree's converter (the tool that produces the `.gg`/cheat blob fed to ioctl index 255) and this loader are self-consistent — the converter emits addr at bytes 0–1 and value at byte 8 to match the loader. The mismatch is only against the upstream NES Game Genie field order; it is not a runtime bug within this project's own toolchain. Recorded here so the next session can decide whether to realign to the NES-standard offsets (and update the converter in lockstep) or keep the current self-consistent custom packing.
