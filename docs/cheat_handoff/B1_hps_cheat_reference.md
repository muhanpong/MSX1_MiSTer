# B1 — MiSTer HPS Standard-Cheat Flow: Technical Reference

Authoritative map of the standard (non-arcade, non-MRA) cheat path in MiSTer Main.
All citations are from the board's actual Main version at
`/run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/MiSTer_build/Main_MiSTer/`.
No judgement — documentation only.

---

## 0. End-to-end summary

1. Core CONF_STR contains a `C` token -> `use_cheats=1` (parse_config).
2. An `F`/`S` option's optional `C` flag (after optional `S`) sets `store_name`.
   `store_name=1` means "remember filename to .cfg, do NOT load/tx"; `store_name=0` is a real load.
3. On a real ROM load (`!store_name`) with `use_cheats`, `cheats_init()` is called with the ROM path + file CRC.
4. `cheats_init()` resolves the cheat zip via `findGameAsset()` (filename-match first, CRC fallback), enumerates zip entries into the `cheats` vector.
5. The menu renderer draws a "Cheats" entry whenever the option char is `C` (grayed if no cheats available).
6. Selecting/toggling cheats eventually calls `cheats_send()`, which raw-`memcpy`s enabled cheat `.gg` bytes and tx's them at ioctl index 255 in 16-byte units.

---

## 1. CONF_STR `C` token -> `use_cheats=1`

`user_io.cpp` `parse_config()`:

```
905	if (p[0] == 'C')
906	{
907		use_cheats = 1;
908	}
```

- Backing global: `user_io.cpp:664  static int use_cheats = 0;`
- Public accessor: `user_io.cpp:2580 int user_io_use_cheats()` -> `return use_cheats;` (`:2582`).

---

## 2. F/S option parsing: `store_name` set by `C` flag (after optional `S`)

`menu.cpp` — declaration: `menu.cpp:1142  static int store_name;`

### `F` options (`menu.cpp:2349-2392`)
```
2349	if (p[0] == 'F' && (select || recent))
2350	{
2351		store_name = 0;
2352		opensave = 0;
2353		ioctl_index = menusub + 1;
2354		int idx = 1;
2355
2356		if (p[idx] == 'S')        // optional Save flag, consumes one char
2357		{
2358			opensave = 1;
2359			idx++;
2360		}
2361
2362		if (p[idx] == 'C')        // Cfg/store-name flag
2363		{
2364			store_name = 1;
2365			idx++;
2366		}
2367
2368		if (p[idx] >= '0' && p[idx] <= '9') ioctl_index = p[idx] - '0';
```
- `FS3` -> `S` consumed (opensave=1), `3` is the index, **`store_name=0`** (no `C` present).
- `FC1` -> no `S`, `C` consumed (**`store_name=1`**), `1` is the index.
- `store_name` also feeds `SCANO_CLEAR` in `fs_Options` at `menu.cpp:2373`.

### `S` options (`menu.cpp:2393-2405`)
```
2393	else if (p[0] == 'S' && (select || recent))
2394	{
2395		store_name = 0;
2396		int idx = 1;
2397
2398		if (p[idx] == 'C')
2399		{
2400			store_name = 1;
2401			idx++;
2402		}
2403
2404		ioctl_index = 0;
2405		if ((p[idx] >= '0' && p[idx] <= '9') || is_x86() || is_pcxt()) ioctl_index = p[idx] - '0';
```
(`S` option has no `S`-subflag; `C` is the first optional flag.)

---

## 3. `cheats_init` call site for generic file load

`menu.cpp`, MENU_GENERIC_FILE_SELECTED handler, generic (`else`) branch:
```
2682	else
2683	{
2684		user_io_file_tx(selPath, idx, opensave, 0, 0, load_addr);
2685		if (!store_name)
2686		{
2687			game_docs_init(selPath, user_io_get_file_crc());
2688			if (user_io_use_cheats()) cheats_init(selPath, user_io_get_file_crc());
2689		}
2690	}
```
- Gated by **`!store_name` (line 2685) AND `user_io_use_cheats()` (line 2688)**.
- `store_name=1` writes the filename to `<core>.f<idx>` cfg at `menu.cpp:2609-2614` and skips both file_tx-cheat and `user_io_store_filename`.

### Other `cheats_init` call sites (for completeness)
- N64 path: `menu.cpp:2643  if (user_io_use_cheats()) cheats_init(selPath, n64_crc);` (also gated `!store_name`, `:2640`).
- No-file / re-init: `user_io.cpp:1615  if (user_io_use_cheats()) cheats_init("", user_io_get_file_crc());`
- Direct (savestate/other) call: `user_io.cpp:978  cheats_init(str, 0);`
- MGL/other generic spots: `menu.cpp:2755`, `menu.cpp:2761  cheats_init(selPath, 0);`

---

## 4. `cheats_init`: asset lookup, zip open, entry enumeration

`cheats.cpp:137-197`:
```
137	void cheats_init(const char *rom_path, uint32_t romcrc)
138	{
139		cheats.clear();
140		loaded = 0;
141		cheat_unit_size = 16;
142		cheat_max_active = 128;
143		cheat_zip[0] = 0;
144
145		// reset cheats  (see §7)
146		if (!is_n64())
147		{
148			user_io_set_index(255);
149			user_io_set_download(1);
150			user_io_file_tx_data((const uint8_t*)&loaded, 2);
151			user_io_set_download(0);
152		}
153
154		char core_dir[1024];
155		snprintf(core_dir, sizeof(core_dir), "%s/cheats/%s", getRootDir(), CoreName2);
156
157		const char *pcecd_dir = NULL;
158		char pcecd_cheats_dir[1024];
159		if (pcecd_using_cd())
160		{
161			snprintf(pcecd_cheats_dir, sizeof(pcecd_cheats_dir), "%s/cheats/%sCD", getRootDir(), CoreName2);
162			pcecd_dir = pcecd_cheats_dir;
163		}
164
165		mz_zip_archive _z = {};
166		gameAssetValidator validator = { cheat_zip_validator, &_z };
167
168		if (!findGameAsset(cheat_zip, sizeof(cheat_zip), rom_path, romcrc, ".zip", core_dir, pcecd_dir, &validator))
169		{
170			printf("no cheat file found\n");
171			return;
172		}
173
174		printf("Using cheat file: %s\n", cheat_zip);
175
176		mz_zip_archive *z = new mz_zip_archive(_z);
177		for (size_t i = 0; i < mz_zip_reader_get_num_files(z); i++)
178		{
179			cheat_rec_t ch = {};
180			mz_zip_reader_get_filename(z, i, ch.name, sizeof(ch.name));
181
182			if (mz_zip_reader_is_file_a_directory(z, i))
183			{
184				continue;
185		}
186
187			cheats.push_back(ch);
188		}
189
190		mz_zip_reader_end(z);
191		delete z;
192
193		std::sort(cheats.begin(), cheats.end(), CheatComp());
194
195		printf("cheats: %d\n", cheats_available());
196		cheats_scan(SCANF_INIT);
197	}
```
- Cheat dir: `<RootDir>/cheats/<CoreName2>` (line 155). PC-Engine CD variant adds `CD` suffix (line 161).
- Each non-directory zip entry becomes a `cheat_rec_t` in the `cheats` vector (its actual `.gg` data is loaded lazily/on enable elsewhere; `cheatData` is null here).
- Entries are sorted by `CheatComp()` (line 193).

---

## 5. `findGameAsset`: filename-match-first, CRC fallback; validator

`file_io.cpp:2240-2299`:
```
2240	int findGameAsset(char *path, size_t path_len, const char *rom_path, uint32_t romcrc, const char *ext, const char *core_dir, const char *pcecd_dir, gameAssetValidator *validator)
2241	{
2242		path[0] = 0;
2243
2244		if (!strcasestr(rom_path, ext))          // build "<rompath-without-ext>.zip"
2245		{
2246			snprintf(path, path_len, "%s", getFullPath(rom_path));
2247			char *p = strrchr(path, '.');
2248			if (p) *p = 0;
2249			strcat(path, ext);
2250		}
2251
2252		if (validAsset(path, validator)) {       // 1) sidecar next to the ROM
2253			return 1;
2254		}
2255		else if (is_psx())
2256		{
2257			if (!findPsxAsset(path, path_len, rom_path, ext, core_dir, validator))
2258				return 0;
2259		}
2260		else
2261		{
2262			if (pcecd_using_cd() || is_megacd())
2263	... findAssetInSameDir + validAsset ...
2272		const char *rom_name = strrchr(rom_path, '/');
2273		if (rom_name)
2274		{
2275			snprintf(path, path_len, "%s%s", pcecd_using_cd() ? pcecd_dir : core_dir, rom_name);
2276			char *p = strrchr(path, '.');
2277			if (p) *p = 0;
2278			if (pcecd_using_cd() || is_megacd()) strcat(path, " []");
2279			strcat(path, ext);
2280
2281			if (!validAsset(path, validator))     // 2) cheats/<core>/<romname>.zip by NAME
2282			{
2283				if (!findAssetByCrc(path, path_len, romcrc, ext, core_dir) || !validAsset(path, validator))
2284					return 0;                         // 3) CRC fallback
2285			}
2286		}
2287		else
2288		{
2289			if (!findAssetByCrc(path, path_len, romcrc, ext, core_dir) || !validAsset(path, validator))
2290				return 0;
2291		}
2298	return 1;
2299	}
```
Resolution order: (a) ROM-sidecar `.zip`, (b) `cheats/<CoreName2>/<rom-basename>.zip` by name, (c) `findAssetByCrc(...)` CRC-named fallback. Each candidate must pass `validAsset` -> the validator.

Validator used for cheats (`cheats.cpp:92-97`):
```
92	static int cheat_zip_validator(const char *path, void *ctx)
93	{
94		mz_zip_archive *z = (mz_zip_archive *)ctx;
95		memset(z, 0, sizeof(mz_zip_archive));
96		return mz_zip_reader_init_file(z, path, 0);   // valid == openable zip
97	}
```
Wrapped as `gameAssetValidator validator = { cheat_zip_validator, &_z };` (`cheats.cpp:166`); the opened archive `_z` is reused by `cheats_init` after a successful find.

---

## 6. Menu render of the Cheats entry

Render is inside the option loop that starts at `menu.cpp:1883 (int i = 2; do { p = user_io_get_confstr(i++); ...})` — i.e. confstr index starts at **2** (skips name + the first config token).

The Cheats entry is drawn only when the current option char is `C`, and is **always drawn** (grayed when `!cheats_available()`):
```
2048	// check for 'C'heats
2049	if (p[0] == 'C')
2050	{
2051		if (game_docs_manual_available())     // optional "Manual" sub-entry first
2052		{
2053			manual_submenu = selentry;
2054			MenuWrite(entry, " Manual", menusub == selentry, 0);
2056			menumask = (menumask << 1) | 1;
2057			entry++;  selentry++;
2060		}
2061
2062		substrcpy(s, p, 1);                   // custom label from confstr field 1
2063		if (strlen(s)) { strcpy(s, " "); substrcpy(s + 1, p, 1); }
2068		else           { strcpy(s, " Cheats"); }
2072		MenuWrite(entry, s, menusub == selentry, !cheats_available() || d);
2074		menumask = (menumask << 1) | 1;
2076		entry++;  selentry++;
2078	}
```
- Grayed-out condition: `!cheats_available() || d` (`menu.cpp:2072`).
- `cheats_available()` def: `cheats.cpp:199` (returns `cheats.size()`).

Selection handling for this entry is at `menu.cpp:2458  else if (p[0] == 'C' && cheats_available() && select)` (opens the cheats submenu via `cheats.cpp` UI, which on toggle calls `cheats_send()`).

---

## 7. `cheats_send`: raw `.gg` bytes, ioctl index 255, 16-byte units

Initial reset tx (2 bytes) at the top of `cheats_init` (`cheats.cpp:146-152`, quoted in §4): sends `loaded` (==0) as a 2-byte payload at index 255 to clear the FPGA cheat engine.

`cheats.cpp:348-385`:
```
348	static void cheats_send()
349	{
350		static uint8_t buff[CHEAT_SIZE];
351		int pos = 0;
352
353		for (int i = 0; i < cheats_available(); i++)
354		{
355			if (cheats[i].enabled)
356			{
357				if (cheats[i].cheatData)
358				{
359					memcpy(&buff[pos], cheats[i].cheatData, cheats[i].cheatSize);  // raw .gg bytes
360					pos += cheats[i].cheatSize;
361				}
362				else
363				{
364					printf("Consistency error, memory for cheat not allocated, but cheat was enabled -> disable.\n");
365					cheats[i].cheatSize = 0;
366					cheats[i].enabled = false;
367				}
368			}
369		}
370
371		loaded = pos / cheat_unit_size;          // cheat_unit_size == 16
372		printf("Cheat codes: %d\n", loaded);
373
374		if (is_n64())
375		{
376			n64_cheats_send(buff, loaded);
377		}
378		else
379		{
380			user_io_set_index(255);              // ioctl download index 255
381			user_io_set_download(1);
382			user_io_file_tx_data(buff, pos ? pos : 2);
383			user_io_set_download(0);
384		}
385	}
```
- Enabled cheats are concatenated raw into `buff`; no transform.
- `cheat_unit_size` is fixed at 16 for the standard path (`cheats.cpp:141`), so `loaded = pos/16`.
- Transmitted as an HPS download at index 255; minimum tx is 2 bytes (`pos ? pos : 2`).

---

## 8. `load_addr` DDR path (>=0x20000000): shmem copy + CRC gated by `use_cheats`

`user_io.cpp` (`user_io_file_tx`), high-memory DDR load:
```
2849	if (dosend && load_addr >= 0x20000000 && (load_addr + bytes2send) <= 0x40000000)
2850	{
2851		uint32_t map_size = bytes2send + ((is_snes() && load_addr < 0x22000000) ? 0x800000 : 0);
2852		uint8_t *mem = (uint8_t *)shmem_map(fpga_mem(load_addr), map_size);
2853		if (mem)
2854		{
2855			while (bytes2send)
2856			{
2857				... gap calc ...
2859				uint32_t chunk = (bytes2send > (256 * 1024)) ? (256 * 1024) : bytes2send;
2860				FileReadAdv(&f, mem + size - bytes2send + gap, chunk);
2861
2862				if(!is_snes() && use_cheats) file_crc = crc32(file_crc, mem + skip + size - bytes2send, chunk - skip);
2863				skip = 0;
2865				if (use_progress) ProgressMessage("Loading", f.name, size - bytes2send, size);
2866				bytes2send -= chunk;
2867			}
2869			shmem_unmap(mem, map_size);
2870		}
2871	}
```
- DDR load addresses in `[0x20000000, 0x40000000)` are mapped via `shmem_map` and written in 256 KiB chunks.
- The running file CRC is only accumulated when `use_cheats` is set (and not SNES): `user_io.cpp:2862`. This is the CRC later passed to `cheats_init` via `user_io_get_file_crc()`.
- CRC plumbing: global `file_crc` (`user_io.cpp:2525`), accessor `user_io_get_file_crc()` (`:2526-2528`), reset at `:2710`, normal-path accumulation at `:2888`, final print `printf("CRC32: %08X\n", file_crc)` at `:2898`.

---

## 9. `CoreName2` derivation

- Macro: `user_io.h:300  #define CoreName2 user_io_get_core_name2()`
- Function (`user_io.cpp:189-192`):
```
189	char *user_io_get_core_name2()
190	{
191		return (ovr_name[0] && ovr_samedir) ? orig_name : core_name;
192	}
```
- Returns `orig_name` when an override name is set and is same-dir; otherwise the plain `core_name`. Used to build the cheat directory `cheats/<CoreName2>` (`cheats.cpp:155`, `:161`).

---

## 10. Serial-log strings (for matching boot/serial output)

| String (printf) | File:line | Emitted when |
|---|---|---|
| `Using cheat file: %s` | `cheats.cpp:174` | `findGameAsset` succeeded |
| `no cheat file found` | `cheats.cpp:170` | `findGameAsset` returned 0 |
| `cheats: %d` | `cheats.cpp:195` | end of `cheats_init` (entry count) |
| `Cheat codes: %d` | `cheats.cpp:372` | inside `cheats_send` (`loaded` count tx'd) |
| `MRA cheats: %d` | `cheats.cpp:132` | arcade-only `cheats_finalize_arcade` (not the standard path) |
| `Consistency error, memory for cheat not allocated...` | `cheats.cpp:364` | enabled cheat with null data in `cheats_send` |
| `File selected: %s` | `menu.cpp:2604` | just before the generic load/cheats_init branch |
| `CRC32: %08X` | `user_io.cpp:2898` | after file tx CRC computed |

Typical healthy standard-cheat boot sequence in serial:
`File selected: ...` -> (`CRC32: ...`) -> `Using cheat file: ...` -> `cheats: N` -> (on toggle) `Cheat codes: M`.
Absence path: `... -> no cheat file found` (and no `cheats:`/`Cheat codes:` lines).

---

## Quick file:line index

| Item | Location |
|---|---|
| `use_cheats` global / set / accessor | `user_io.cpp:664` / `:905-908` / `:2580-2582` |
| `store_name` decl | `menu.cpp:1142` |
| F-option flag parse (S then C) | `menu.cpp:2349-2368` |
| S-option flag parse (C) | `menu.cpp:2393-2405` |
| store_name cfg-save (no load) | `menu.cpp:2609-2614` |
| Generic cheats_init call (gated) | `menu.cpp:2685-2688` |
| N64 cheats_init call | `menu.cpp:2643` |
| No-file cheats_init | `user_io.cpp:1615` |
| `cheats_init` body | `cheats.cpp:137-197` |
| cheat reset tx (2 bytes, idx 255) | `cheats.cpp:146-152` |
| `cheat_zip_validator` | `cheats.cpp:92-97` |
| `findGameAsset` | `file_io.cpp:2240-2299` |
| Menu render loop start (i=2) | `menu.cpp:1883-1888` |
| Cheats menu entry render | `menu.cpp:2049-2078` |
| Cheats entry select | `menu.cpp:2458` |
| `cheats_available` | `cheats.cpp:199` |
| `cheats_send` | `cheats.cpp:348-385` |
| DDR shmem load + CRC gate | `user_io.cpp:2849-2871` (`:2862`) |
| `file_crc` accessor | `user_io.cpp:2525-2528` |
| `CoreName2` macro / func | `user_io.h:300` / `user_io.cpp:189-192` |
