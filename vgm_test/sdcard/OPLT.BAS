10 ' OPL Timer-1 continuous-overflow poll test (no interrupts)
20 ' MoonSound FM: addr/status=&HC4, data=&HC5
30 ' Sets up Timer-1 like vgmplay's OPLTimer, then polls status bit6 (T1 flag)
40 ' and acks (reg4 bit7=1) repeatedly.  Counts how many times bit6 sets.
50 '  large count  -> timer flag works continuously  => freeze is in IRQ path (B)
60 '  count = 1    -> flag sets once, never re-arms   => timer overflow broken (A)
70 '  count = 0    -> status bit6 never read          => FM status read path issue
80 OUT &HC4,2:OUT &HC5,&HF5   ' reg2 = timer1 count = -11 (~1130 Hz)
90 OUT &HC4,4:OUT &HC5,&H01   ' reg4 = ST1 (start Timer-1), MT1=0
100 C=0
110 FOR I=1 TO 20000
120  S=INP(&HC4)
130  IF (S AND &H40)<>0 THEN C=C+1:OUT &HC4,4:OUT &HC5,&H80
140 NEXT
150 OUT &HC4,4:OUT &HC5,&H78  ' stop timers (MT1+MT2+reset)
160 PRINT "Timer-1 flag set count =";C
170 PRINT "(big=OK timer, 1=re-arm broken, 0=status read broken)"
