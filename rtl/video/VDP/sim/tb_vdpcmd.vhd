-- Testbench: measure VDP command duration (in scanlines) on the MSX1_MiSTer VDP.
-- Mirrors the GoFigure boot calibration: SCREEN5, display ON, sprites ON,
-- NTSC 192 lines, OFFSET_Y=0 (matches msx.sv which leaves the port unconnected),
-- HMMM SX=20,SY=256 -> DX=30,DY=0, NX=28, NY=220 (3080 bytes).
-- Reference (openMSX/real V9938): 251.5 lines.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY TB_VDPCMD IS
    GENERIC ( DISPOFF : INTEGER := 0 );   -- 1 = run with display disabled (pure blank-phase rate)
END TB_VDPCMD;

ARCHITECTURE SIM OF TB_VDPCMD IS
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
            IF PRAMWE_N = '0' AND DLCLK = '1' THEN
                IF PRAMADR(16) = '0' THEN
                    RAM_LO(A) <= PRAMDBO;
                ELSE
                    RAM_HI(A) <= PRAMDBO;
                END IF;
            END IF;
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
        END PROCEDURE;
        VARIABLE ST : STD_LOGIC_VECTOR(7 DOWNTO 0);
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
        VREG(0, 16#06#);
        IF DISPOFF = 1 THEN VREG(1, 16#22#); ELSE VREG(1, 16#62#); END IF;
        VREG(8, 16#28#);
        VREG(9, 16#00#);
        VREG(2, 16#1F#);
        VREG(5, 16#EF#);
        VREG(6, 16#0F#);

        -- settle 2 fields
        FOR I IN 0 TO 2*262*1368/58 LOOP
            FOR J IN 0 TO 56 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END LOOP;

        ------------------------------------------------------------------
        -- GoFigure boot calibration replica
        ------------------------------------------------------------------
        -- HALT #1: wait vblank INT; ISR: read S#1 (not FH), read S#0 (clear),
        --          R#0 <- 0x16 (IE1 on), R#19 <- 188
        WAIT_INT;
        LINEPOS(STRING'("VBLANK-INT-1"));
        VREG(15, 1);  PRD(1, ST);          -- S#1 (clears FH if any)
        VREG(15, 0);  PRD(1, ST);          -- S#0 (clears vblank INT)
        VREG(0, 16#16#);
        VREG(19, 188);

        -- HALT #2: next vblank
        WAIT_INT;
        LINEPOS(STRING'("INT-2"));
        VREG(15, 1);  PRD(1, ST);
        IF ST(0) = '1' THEN
            LINEPOS(STRING'("  (was FH; wait next vblank)"));
            WAIT_INT;
            VREG(15, 1); PRD(1, ST);
        END IF;
        VREG(15, 0);  PRD(1, ST);
        VREG(0, 16#16#);
        VREG(19, 188);

        -- The real game spends ~10.8 lines between the vblank IRQ and the HMMM
        -- start (two helper calls + EI/HALT wake + 41DA CE-poll + OUTI setup,
        -- measured in openMSX: ISR entry 9.64152s -> CE rise 9.642210s).  This
        -- TB's replica above only takes ~4.5 lines, which understates the
        -- game's margin at the CE check; add the difference so the reported
        -- margin matches what the real code sees.
        FOR I IN 0 TO 8600 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;

        -- start HMMM (like 41DA: R#17=32 indirect; direct reg writes equivalent)
        VREG(32, 20);   VREG(33, 0);
        VREG(34, 0);    VREG(35, 1);
        VREG(36, 30);   VREG(37, 0);
        VREG(38, 0);    VREG(39, 0);
        VREG(40, 28);   VREG(41, 0);
        VREG(42, 220);  VREG(43, 0);
        VREG(44, 0);    VREG(45, 0);
        VREG(46, 16#D0#);
        T0 := CYCLES;
        LINEPOS(STRING'("HMMM-START"));

        -- wait for FH (line-188) interrupt: read S#1 each INT until FH set
        CE_AT_FH := 'X';
        LOOP
            WAIT_INT;
            VREG(15, 1); PRD(1, ST);
            IF ST(0) = '1' THEN
                TFH := CYCLES;
                LINEPOS(STRING'("FH-188"));
                VREG(15, 2); PRD(1, ST);   -- S#2, like the game ISR
                CE_AT_FH := ST(0);
                EXIT;
            ELSE
                VREG(15, 0); PRD(1, ST);   -- vblank: clear S#0
            END IF;
        END LOOP;

        -- then keep polling until CE falls, to get total duration
        VREG(15, 2);
        LOOP
            PRD(1, ST);
            IF ST(0) = '0' THEN T1 := CYCLES; EXIT; END IF;
            IF CYCLES - T0 > 1368*800 THEN
                WRITE(L, STRING'("TIMEOUT")); WRITELINE(OUTPUT, L);
                T1 := CYCLES; EXIT;
            END IF;
        END LOOP;

        WRITE(L, STRING'("RESULT: CE_at_FH188="));
        WRITE(L, STD_LOGIC'IMAGE(CE_AT_FH));
        WRITE(L, STRING'("  (1=calibration PASS, 0=Abnormal-fast FAIL)"));
        WRITELINE(OUTPUT, L);
        WRITE(L, STRING'("HMMM duration: "));
        WRITE(L, REAL(T1 - T0) / 1368.0);
        WRITE(L, STRING'(" lines; start->FH gap: "));
        WRITE(L, REAL(TFH - T0) / 1368.0);
        WRITE(L, STRING'(" lines (openMSX dur ref 251.5)"));
        WRITELINE(OUTPUT, L);
        ASSERT FALSE REPORT "done" SEVERITY FAILURE;
    END PROCESS;
END SIM;
