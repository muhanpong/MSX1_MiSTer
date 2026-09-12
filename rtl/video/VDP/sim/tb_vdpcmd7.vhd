-- Testbench: every THROTTLED VDP command, timed in scanlines.
--
-- vdp_wait_control.vhd throttles seven opcodes; only HMMM has ever been
-- calibrated against openMSX (tables 602/606, GoFigure boot workload).  This
-- TB runs all seven with the same workloads the openMSX reference harness
-- uses, so the two tables line up row for row.
--
-- Conditions match that reference exactly: G4 (SCREEN5), display ON,
-- sprites ON, NTSC 192 lines -> table 602 inside the display window, 606 in
-- the vertical border.  Sources sit at y=128 (VRAM 0x4000), destinations at
-- y=256 (0x8000); HMMV runs first so the copies have something to read.
--
-- openMSX 21.0-245 reference, same workloads (emulated time / 63.695us):
--   HMMV 256x128   722.18 lines      LMMM 256x64   1744.90
--   HMMM 256x128  1466.82            YMMM 256x128  1204.82
--   LMMV 256x64   1476.01            LINE x32       897.35
--                                    SRCH x32       670.97
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY TB_VDPCMD7 IS
    GENERIC (
        DISPOFF : INTEGER := 0;   -- 1 = display disabled (pure blank-phase rate)
        CMDSEL  : INTEGER := -1;  -- -1 = all seven; 0..6 = that one only, for tuning
        BOARDREGS : INTEGER := 0; -- 1 = replay the board's DOS register state
        DATACHECK : INTEGER := 0  -- 1 = copy-integrity check instead of timing
    );
END TB_VDPCMD7;

ARCHITECTURE SIM OF TB_VDPCMD7 IS
    SIGNAL CLK21M   : STD_LOGIC := '0';
    SIGNAL RESET    : STD_LOGIC := '1';
    SIGNAL REQ      : STD_LOGIC := '0';
    SIGNAL WRT      : STD_LOGIC := '0';
    SIGNAL ADR      : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL DBI      : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL DBO      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL INT_N    : STD_LOGIC;
    SIGNAL PRAMOE_N : STD_LOGIC;
    SIGNAL PRAMWE_N : STD_LOGIC;
    SIGNAL PRAMADR  : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL PRAMDBI  : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL PRAMDBO  : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL DHCLK, DLCLK : STD_LOGIC;

    TYPE RAM_T IS ARRAY(0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL RAM_LO : RAM_T := (OTHERS => X"A5");
    SIGNAL RAM_HI : RAM_T := (OTHERS => X"5A");

    SIGNAL CYCLES : INTEGER := 0;
    SIGNAL DSTWR  : INTEGER := 0;
    SIGNAL ALLWR  : INTEGER := 0;
    SIGNAL PRAMWE_N_Z : STD_LOGIC := '1';   -- edge the write counters
    SIGNAL REG_ECHO_R1 : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL REG_ECHO_R8 : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    CONSTANT CLKP : TIME := 46.56 ns;   -- 21.477 MHz

    COMPONENT VDP
        PORT(
            CLK21M          : IN  STD_LOGIC;
            RESET           : IN  STD_LOGIC;
            REQ             : IN  STD_LOGIC;
            ACK             : OUT STD_LOGIC;
            WRT             : IN  STD_LOGIC;
            ADR             : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
            DBI             : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            DBO             : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
            INT_N           : OUT STD_LOGIC;
            PRAMOE_N        : OUT STD_LOGIC;
            PRAMWE_N        : OUT STD_LOGIC;
            PRAMADR         : OUT STD_LOGIC_VECTOR(16 DOWNTO 0);
            PRAMDBI         : IN  STD_LOGIC_VECTOR(15 DOWNTO 0);
            PRAMDBO         : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
            VDPSPEEDMODE    : IN  STD_LOGIC;
            RATIOMODE       : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
            CENTERYJK_R25_N : IN  STD_LOGIC;
            PVIDEOR         : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
            PVIDEOG         : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
            PVIDEOB         : OUT STD_LOGIC_VECTOR(5 DOWNTO 0);
            PVIDEODE        : OUT STD_LOGIC;
            PVIDEOHS_N      : OUT STD_LOGIC;
            PVIDEOVS_N      : OUT STD_LOGIC;
            PVIDEOCS_N      : OUT STD_LOGIC;
            PVIDEODHCLK     : OUT STD_LOGIC;
            PVIDEODLCLK     : OUT STD_LOGIC;
            BLANK_O         : OUT STD_LOGIC;
            HBLANK          : OUT STD_LOGIC;
            VBLANK          : OUT STD_LOGIC;
            DISPRESO        : IN  STD_LOGIC;
            NTSC_PAL_TYPE   : IN  STD_LOGIC;
            FORCED_V_MODE   : IN  STD_LOGIC;
            LEGACY_VGA      : IN  STD_LOGIC;
            BORDER          : IN  STD_LOGIC;
            VDP_ID          : IN  STD_LOGIC_VECTOR(4 DOWNTO 0);
            OFFSET_Y        : IN  STD_LOGIC_VECTOR(6 DOWNTO 0)
        );
    END COMPONENT;
BEGIN
    CLK21M <= NOT CLK21M AFTER CLKP/2;

    PROCESS(CLK21M)
    BEGIN
        IF RISING_EDGE(CLK21M) THEN
            CYCLES <= CYCLES + 1;
        END IF;
    END PROCESS;

    -- VRAM model: mirrors msx.sv (two 64KB spram, registered q, write gated by DLCLK)
    PROCESS(CLK21M)
        VARIABLE A : INTEGER;
    BEGIN
        IF RISING_EDGE(CLK21M) THEN
            A := TO_INTEGER(UNSIGNED(PRAMADR(15 DOWNTO 0)));
            --  the DLCLK term is the msx.sv:901 write gate.  A command access
            --  granted at DOTSTATE "01" drives PRAMWE_N low during the DLCLK=0
            --  half of the dot, so with the gate in place every such write is
            --  silently dropped while its ACK still toggles -- commands finish
            --  with nothing written.  The fix removes the gate on both sides
            --  (here and msx.sv); a "10"-granted write then lands twice at the
            --  same address, which is harmless, so the counters are edged.
            IF PRAMWE_N = '0' THEN
                IF PRAMADR(16) = '0' THEN
                    RAM_LO(A) <= PRAMDBO;
                    --  count writes landing in the DATACHECK destination band
                    --  (y=256..319 -> 0x8000..0x9FFF).  HMMM 256x64 must write
                    --  exactly 8192 bytes there; fewer means writes are lost.
                    IF A >= 16#8000# AND A <= 16#9FFF# AND PRAMWE_N_Z = '1' THEN
                        DSTWR <= DSTWR + 1;
                    END IF;
                    IF PRAMWE_N_Z = '1' THEN
                        ALLWR <= ALLWR + 1;
                    END IF;
                ELSE
                    RAM_HI(A) <= PRAMDBO;
                END IF;
            END IF;
            PRAMWE_N_Z <= PRAMWE_N;
            PRAMDBI( 7 DOWNTO 0) <= RAM_LO(A);
            PRAMDBI(15 DOWNTO 8) <= RAM_HI(A);
        END IF;
    END PROCESS;

    DUT: VDP PORT MAP(
        CLK21M => CLK21M, RESET => RESET,
        REQ => REQ, ACK => OPEN, WRT => WRT, ADR => ADR, DBI => DBI, DBO => DBO,
        INT_N => INT_N,
        PRAMOE_N => PRAMOE_N, PRAMWE_N => PRAMWE_N, PRAMADR => PRAMADR,
        PRAMDBI => PRAMDBI, PRAMDBO => PRAMDBO,
        VDPSPEEDMODE => '0', RATIOMODE => "000", CENTERYJK_R25_N => '0',
        PVIDEOR => OPEN, PVIDEOG => OPEN, PVIDEOB => OPEN, PVIDEODE => OPEN,
        PVIDEOHS_N => OPEN, PVIDEOVS_N => OPEN, PVIDEOCS_N => OPEN,
        PVIDEODHCLK => DHCLK, PVIDEODLCLK => DLCLK,
        BLANK_O => OPEN, HBLANK => OPEN, VBLANK => OPEN,
        DISPRESO => '0',
        NTSC_PAL_TYPE => '0', FORCED_V_MODE => '0', LEGACY_VGA => '1',
        BORDER => '0',
        VDP_ID => "00000",
        OFFSET_Y => "0000000"       -- matches msx.sv (port left unconnected -> GND)
    );

    STIM: PROCESS
        PROCEDURE PWR(PORTNO : IN INTEGER; VAL : IN INTEGER) IS
        BEGIN
            -- one-clock REQ write pulse, then CPU-realistic gap (~OUT pacing)
            WAIT UNTIL RISING_EDGE(CLK21M);
            ADR <= STD_LOGIC_VECTOR(TO_UNSIGNED(16#98# + PORTNO, 16));
            DBO <= STD_LOGIC_VECTOR(TO_UNSIGNED(VAL MOD 256, 8));
            WRT <= '1';
            REQ <= '1';
            WAIT UNTIL RISING_EDGE(CLK21M);
            REQ <= '0';
            WRT <= '0';
            FOR I IN 0 TO 56 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;  -- ~12 T
        END PROCEDURE;
        PROCEDURE PRD(PORTNO : IN INTEGER; RES : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
        BEGIN
            WAIT UNTIL RISING_EDGE(CLK21M);
            ADR <= STD_LOGIC_VECTOR(TO_UNSIGNED(16#98# + PORTNO, 16));
            WRT <= '0';
            REQ <= '1';
            WAIT UNTIL RISING_EDGE(CLK21M);
            REQ <= '0';
            WAIT UNTIL RISING_EDGE(CLK21M);
            WAIT UNTIL RISING_EDGE(CLK21M);
            RES := DBI;
            FOR I IN 0 TO 52 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END PROCEDURE;
        PROCEDURE VREG(R : IN INTEGER; V : IN INTEGER) IS
        BEGIN
            PWR(1, V);
            PWR(1, 16#80# + R);
            -- echoed back at setup so a dead BOARDREGS generic cannot pass
            -- unnoticed: a run that reports the wrong R1/R8 is not the run
            -- it claims to be.
            IF R = 1 THEN REG_ECHO_R1 <= STD_LOGIC_VECTOR(TO_UNSIGNED(V, 8)); END IF;
            IF R = 8 THEN REG_ECHO_R8 <= STD_LOGIC_VECTOR(TO_UNSIGNED(V, 8)); END IF;
        END PROCEDURE;
        VARIABLE ST : STD_LOGIC_VECTOR(7 DOWNTO 0);
        TYPE BLK_T IS ARRAY(0 TO 14) OF INTEGER;
        VARIABLE BLK : BLK_T;
        VARIABLE REPS, TOTAL : INTEGER;
        VARIABLE ERRS, FIRST_BAD : INTEGER;
        TYPE NAME_T IS ARRAY(0 TO 6) OF STRING(1 TO 12);
        CONSTANT NAMES : NAME_T := ("HMMV 256x128", "HMMM 256x128", "LMMV 256x64 ",
                                    "LMMM 256x64 ", "YMMM 256x128", "LINE x32    ",
                                    "SRCH x32    ");
        TYPE REF_T IS ARRAY(0 TO 6) OF STRING(1 TO 7);
        CONSTANT REFS : REF_T := (" 722.18", "1466.82", "1476.01",
                                  "1744.90", "1204.82", " 897.35", " 670.97");
        VARIABLE T0, T1, TFH : INTEGER;
        VARIABLE CE_AT_FH : STD_LOGIC;
        VARIABLE L : LINE;
        PROCEDURE WAIT_INT IS
        BEGIN
            WAIT UNTIL INT_N = '0' FOR 30 ms;
            ASSERT INT_N = '0' REPORT "no INT within 30ms" SEVERITY FAILURE;
        END PROCEDURE;
        PROCEDURE LINEPOS(TAG : IN STRING) IS
            VARIABLE LL : LINE;
        BEGIN
            WRITE(LL, TAG);
            WRITE(LL, STRING'(" @cycle "));
            WRITE(LL, CYCLES);
            WRITE(LL, STRING'(" rawline "));
            WRITE(LL, (CYCLES / 1368) MOD 262);
            WRITELINE(OUTPUT, LL);
        END PROCEDURE;
    BEGIN
        WAIT FOR CLKP*32;
        RESET <= '0';
        WAIT FOR CLKP*64;

        -- SCREEN5 (GRAPHIC4), display ON+IE0, sprites ON, NTSC 192 lines
        -- BOARDREGS=1 replays the register state MSX-DOS actually leaves when
        -- CMDCMP runs on hardware, read out of openMSX at the first wait_ce:
        --   R#0=06 R#1=60 R#2=06 R#3=80 R#4=00 R#5=36 R#6=07 R#7=07 R#8=08 R#9=00
        -- The differences that could plausibly move VRAM slot demand are R#1
        -- bit1 (SI: 8x8 sprites on the board, 16x16 here) and the sprite table
        -- bases R#5/R#6.  This is the control for the board-vs-sim 5% gap.
        VREG(0, 16#06#);
        IF BOARDREGS = 1 THEN
            VREG(1, 16#60#);
            VREG(8, 16#08#);
            VREG(9, 16#00#);
            VREG(2, 16#06#);
            VREG(3, 16#80#);
            VREG(4, 16#00#);
            VREG(5, 16#36#);
            VREG(6, 16#07#);
            VREG(7, 16#07#);
        ELSE
            IF DISPOFF = 1 THEN VREG(1, 16#22#); ELSE VREG(1, 16#62#); END IF;
            VREG(8, 16#28#);
            VREG(9, 16#00#);
            VREG(2, 16#1F#);
            VREG(5, 16#EF#);
            VREG(6, 16#0F#);
        END IF;

        WRITE(L, STRING'("setup: BOARDREGS="));
        WRITE(L, BOARDREGS);
        WRITE(L, STRING'("  R1="));
        WRITE(L, TO_INTEGER(UNSIGNED(REG_ECHO_R1)));
        WRITE(L, STRING'("  R8="));
        WRITE(L, TO_INTEGER(UNSIGNED(REG_ECHO_R8)));
        WRITELINE(OUTPUT, L);

        -- settle 2 fields
        FOR I IN 0 TO 2*262*1368/58 LOOP
            FOR J IN 0 TO 56 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END LOOP;

        ------------------------------------------------------------------
        -- every throttled opcode, one workload each
        ------------------------------------------------------------------
        -- R#32..R#46 for one command, then poll S#2 CE until it clears.
        -- Duration is CYCLES/1368 = scanlines, the unit the wait tables are
        -- written in.
        -- K=0 (HMMV) always runs: it is what fills y=128, and every copy and
        -- the search read that row back.  SRCH standalone reports 6.9 lines
        -- against 348 in sequence -- it stops on the first matching pixel.
        --  COPY INTEGRITY.  Timing alone cannot see a broken read path: a
        --  command that reads the wrong byte still takes the right number of
        --  cycles, so every row of the timing table stays green while the
        --  copied pixels are garbage.  That is the exact shape of the bug the
        --  "01"-phase read latch had, so the gate checks CONTENT as well.
        --  Two bands of different colours, because a single fill colour also
        --  passes if the read path returns a constant.
        IF DATACHECK = 1 THEN
            BLK := (0, 0, 0, 0,   0, 0, 128, 0,   0, 1, 32, 0,  16#EE#, 0, 16#C0#);
            FOR I IN 0 TO 13 LOOP VREG(32 + I, BLK(I)); END LOOP;
            VREG(46, BLK(14));  VREG(15, 2);
            LOOP PRD(1, ST); EXIT WHEN ST(0) = '0'; END LOOP;

            BLK := (0, 0, 0, 0,   0, 0, 160, 0,   0, 1, 32, 0,  16#33#, 0, 16#C0#);
            FOR I IN 0 TO 13 LOOP VREG(32 + I, BLK(I)); END LOOP;
            VREG(46, BLK(14));  VREG(15, 2);
            LOOP PRD(1, ST); EXIT WHEN ST(0) = '0'; END LOOP;

            BLK := (0, 0, 128, 0, 0, 0, 0, 1,     0, 1, 64, 0,       0, 0, 16#D0#);
            FOR I IN 0 TO 13 LOOP VREG(32 + I, BLK(I)); END LOOP;
            VREG(46, BLK(14));  VREG(15, 2);
            LOOP PRD(1, ST); EXIT WHEN ST(0) = '0'; END LOOP;

            --  G4: byte address = y*128 + x/2, so y=128 is 0x4000 and y=256 is
            --  0x8000; both land in the low bank (bit 16 clear).
            ERRS := 0;  FIRST_BAD := -1;
            FOR I IN 0 TO 64*128-1 LOOP
                IF RAM_LO(16#4000# + I) /= RAM_LO(16#8000# + I) THEN
                    ERRS := ERRS + 1;
                    IF FIRST_BAD < 0 THEN FIRST_BAD := I; END IF;
                END IF;
            END LOOP;
            WRITE(L, STRING'("DATACHECK HMMM 8192 bytes: mismatches "));
            WRITE(L, ERRS);
            WRITE(L, STRING'("  dest writes "));
            WRITE(L, DSTWR);
            WRITE(L, STRING'("/8192  all writes "));
            WRITE(L, ALLWR);
            IF ERRS /= 0 THEN
                WRITE(L, STRING'("  first at +"));
                WRITE(L, FIRST_BAD);
                WRITE(L, STRING'(" src="));
                WRITE(L, TO_INTEGER(UNSIGNED(RAM_LO(16#4000# + FIRST_BAD))));
                WRITE(L, STRING'(" dst="));
                WRITE(L, TO_INTEGER(UNSIGNED(RAM_LO(16#8000# + FIRST_BAD))));
                WRITE(L, STRING'("  FAIL"));
            ELSE
                WRITE(L, STRING'("  PASS"));
            END IF;
            WRITELINE(OUTPUT, L);
            ASSERT FALSE REPORT "done" SEVERITY FAILURE;
        END IF;

        FOR K IN 0 TO 6 LOOP
          IF CMDSEL < 0 OR CMDSEL = K OR K = 0 THEN
            CASE K IS
                --        SX       SY       DX       DY       NX      NY      CLR ARG CMD
                WHEN 0 => BLK := (  0,  0,   0,  0,   0,  0, 128,  0,   0,  1, 128,  0, 238,  0, 16#C0#);
                WHEN 1 => BLK := (  0,  0, 128,  0,   0,  0,   0,  1,   0,  1, 128,  0,   0,  0, 16#D0#);
                WHEN 2 => BLK := (  0,  0,   0,  0,   0,  0, 128,  0,   0,  1,  64,  0,  14,  0, 16#80#);
                WHEN 3 => BLK := (  0,  0, 128,  0,   0,  0,   0,  1,   0,  1,  64,  0,   0,  0, 16#90#);
                WHEN 4 => BLK := (  0,  0, 128,  0,   0,  0,   0,  1,   0,  0, 128,  0,   0,  0, 16#E0#);
                WHEN 5 => BLK := (  0,  0,   0,  0,   0,  0, 200,  0, 255,  0, 100,  0,  15,  0, 16#70#);
                WHEN 6 => BLK := (  0,  0, 128,  0,   0,  0,   0,  0,   0,  0,   0,  0,  10,  0, 16#60#);
            END CASE;
            REPS := 1;
            IF K >= 5 THEN REPS := 32; END IF;   -- LINE/SRCH are one row of work

            TOTAL := 0;
            FOR R IN 1 TO REPS LOOP
                FOR I IN 0 TO 13 LOOP
                    VREG(32 + I, BLK(I));
                END LOOP;
                T0 := CYCLES;
                VREG(46, BLK(14));
                VREG(15, 2);
                LOOP
                    PRD(1, ST);
                    IF ST(0) = '0' THEN T1 := CYCLES; EXIT; END IF;
                    IF CYCLES - T0 > 1368*4000 THEN
                        WRITE(L, STRING'("TIMEOUT ")); WRITE(L, K); WRITELINE(OUTPUT, L);
                        T1 := CYCLES; EXIT;
                    END IF;
                END LOOP;
                TOTAL := TOTAL + (T1 - T0);
            END LOOP;

            WRITE(L, NAMES(K));
            WRITE(L, STRING'(" "));
            WRITE(L, REAL(TOTAL) / 1368.0);
            WRITE(L, STRING'(" lines   (openMSX "));
            WRITE(L, REFS(K));
            WRITE(L, STRING'(")"));
            IF CMDSEL < 0 OR CMDSEL = K THEN
                WRITELINE(OUTPUT, L);
            ELSE
                DEALLOCATE(L);
            END IF;
          END IF;
        END LOOP;

        ASSERT FALSE REPORT "done" SEVERITY FAILURE;
    END PROCESS;
END SIM;
