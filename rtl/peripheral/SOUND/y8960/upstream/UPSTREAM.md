# Y8960 Cartridge RTL

Source: https://github.com/hra1129/Y8960_Cartridge  
Commit: a83d8074f2cd34574e3ac0fee5fa6a050e2bf5e3  
Imported by tools/y8960/import.py -- do not edit here.  Patched there (PATCHES):
msx_timer / msx_timer_core take HALF_CLK (the core clocks the timer at half
the cartridge's 42.95 MHz).

Licences: see the header of each file and the LICENSE / README.txt in each
directory (IKAOPM: BSD 2-Clause; the remaining files: the terms in their
headers, (C) Takayuki Hara).

Modules renamed with the Y89_ prefix (the core has its own copies): none
