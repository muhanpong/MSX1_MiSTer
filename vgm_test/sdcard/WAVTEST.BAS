10 ' MoonSound wave-RAM write/read isolation test
20 ' Goal: confirm whether CPU reg06 uploads to HIGH custom-RAM
30 '       addresses (>0x200000) physically land.  Independent of vgmplay.
40 WP=&H7E:WD=&H7F
50 ' --- enable NEW + NEW2 (needed for wave/PCM part access) ---
60 OUT &HC6,5:OUT &HC7,3
70 '
80 ' === TEST 0: ROM read sanity @0x000000 (expect 40 ...) ===
90 E=0:H=0:L=0
100 PRINT "ROM @000000:";:GOSUB 800:PRINT
110 '
120 ' === TEST 1: write+read custom RAM @0x200100 (mid) ===
130 E=&H20:H=&H01:L=&H00
140 GOSUB 700:PRINT "RAM @200100:";:GOSUB 800:PRINT
150 '
160 ' === TEST 2: write+read custom RAM @0x352E34 (high = sample) ===
170 E=&H35:H=&H2E:L=&H34
180 GOSUB 700:PRINT "RAM @352E34:";:GOSUB 800:PRINT
190 PRINT "EXPECT both RAM lines: B0 B1 B2 B3 B4 B5 B6 B7"
200 END
700 ' write 8 bytes pattern B0..B7 via reg06 auto-increment @E:H:L
710 OUT WP,3:OUT WD,E:OUT WP,4:OUT WD,H:OUT WP,5:OUT WD,L
720 OUT WP,2:OUT WD,&H11
730 FOR I=0 TO 7:OUT WP,6:OUT WD,&HB0+I:NEXT
740 OUT WP,2:OUT WD,&H10
750 RETURN
800 ' read 8 bytes @E:H:L, re-setting address each byte (robust)
810 FOR I=0 TO 7:OUT WP,3:OUT WD,E:OUT WP,4:OUT WD,H:OUT WP,5:OUT WD,L+I
820 OUT WP,2:OUT WD,&H11:OUT WP,6:V=INP(WD):OUT WP,2:OUT WD,&H10
830 PRINT " ";HEX$(V);:NEXT:RETURN
