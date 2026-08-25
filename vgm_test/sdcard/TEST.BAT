REM === MoonSound OPL4 freeze test ===
REM use vgmplay-noopl.com (renamed VGMPLAY.COM)
REM ESC skips a song that plays OK -> advances to next
REM --- 1 small yrw801 (baseline) ---
vgmplay /L1 MD03.VGZ
REM --- 2 large yrw801 (streaming) ---
vgmplay /L1 MD06.VGZ
REM --- 3 small custom-PCM (upload) ---
vgmplay /L1 ST02.VGZ
REM --- 4 large custom-PCM (DDP/Ketsui) ---
vgmplay /L1 ST04.VGZ
