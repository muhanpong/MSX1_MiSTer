10 ' MFRSD SCC+ UNLOCK  --  mapperReg <- 0
20 ' slot ID = 128 + subslot*4 + primary   (133 = slot1-1 = MFRSD SCC+ on HB-F1XV)
30 SL=133
40 ' value: 0 = Konami-SCC & unlocked  (SCC+ reachable)
50 VL=0
60 CLEAR 200,&HCFFF
70 FOR I=0 TO 12: READ A: POKE &HD000+I,A: NEXT
80 DATA 243,62,0,33,255,127,30,0,205,20,0,251,201
90 ' patch slot id and value into the stub
100 POKE &HD002,SL: POKE &HD007,VL
110 DEFUSR=&HD000: A=USR(0)
120 PRINT "slot";SL;"  addr &H7FFF <-";VL
130 PRINT "done. now run SC from DOS."
