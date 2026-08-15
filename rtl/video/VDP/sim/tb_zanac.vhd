-- Testbench: replicate Zanac-EX's per-frame scroll register dance and verify
-- the interrupt chain sustains on this VDP.
--   vblank ISR (real game: writes land ~18 lines after the IRQ):
--       R#23 <- 216 (HUD page), R#2 <- 63, R#19 <- 228   -> arms FH at monitor 12
--   FH ISR (at monitor 12):
--       R#23 <- scroll (243,242,241,...), R#2 <- 31, R#19 <- scroll-44
-- SCREEN5-ish mode regs; NTSC 192; sprites on.  If the FH stops firing (or
-- fires at the wrong line), the scroll chain dies -> "no scroll" symptom.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY TB_ZANAC IS
END TB_ZANAC;

ARCHITECTURE SIM OF TB_ZANAC IS
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

    CONSTANT CLKP : TIME := 46.56 ns;

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
            PRAMWE_N       : OUT STD_LOGIC;
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

    PROCESS(CLK21M)
        VARIABLE A : INTEGER;
    BEGIN
        IF RISING_EDGE(CLK21M) THEN
            A := TO_INTEGER(UNSIGNED(PRAMADR(15 DOWNTO 0)));
            IF PRAMWE_N = '0' AND DLCLK = '1' THEN
                IF PRAMADR(16) = '0' THEN RAM_LO(A) <= PRAMDBO;
                ELSE RAM_HI(A) <= PRAMDBO; END IF;
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
        OFFSET_Y => "0000000"
    );

    STIM: PROCESS
        PROCEDURE PWR(PORTNO : IN INTEGER; VAL : IN INTEGER) IS
        BEGIN
            WAIT UNTIL RISING_EDGE(CLK21M);
            ADR <= STD_LOGIC_VECTOR(TO_UNSIGNED(16#98# + PORTNO, 16));
            DBO <= STD_LOGIC_VECTOR(TO_UNSIGNED(VAL MOD 256, 8));
            WRT <= '1'; REQ <= '1';
            WAIT UNTIL RISING_EDGE(CLK21M);
            REQ <= '0'; WRT <= '0';
            FOR I IN 0 TO 56 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END PROCEDURE;
        PROCEDURE PRD(PORTNO : IN INTEGER; RES : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
        BEGIN
            WAIT UNTIL RISING_EDGE(CLK21M);
            ADR <= STD_LOGIC_VECTOR(TO_UNSIGNED(16#98# + PORTNO, 16));
            WRT <= '0'; REQ <= '1';
            WAIT UNTIL RISING_EDGE(CLK21M);
            REQ <= '0';
            WAIT UNTIL RISING_EDGE(CLK21M);
            WAIT UNTIL RISING_EDGE(CLK21M);
            RES := DBI;
            FOR I IN 0 TO 52 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END PROCEDURE;
        PROCEDURE VREG(R : IN INTEGER; V : IN INTEGER) IS
        BEGIN
            PWR(1, V); PWR(1, 16#80# + R);
        END PROCEDURE;
        VARIABLE ST : STD_LOGIC_VECTOR(7 DOWNTO 0);
        VARIABLE PREV : STD_LOGIC := 'X';
        VARIABLE NEDGE : INTEGER := 0;
        VARIABLE L : LINE;
    BEGIN
        WAIT FOR CLKP*32;
        RESET <= '0';
        WAIT FOR CLKP*64;

        VREG(0, 16#06#);
        VREG(1, 16#62#);
        VREG(8, 16#28#);
        VREG(9, 16#00#);
        VREG(15, 2);          -- select S#2 once

        -- settle 1 field
        FOR I IN 0 TO 262*1368/58 LOOP
            FOR J IN 0 TO 56 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END LOOP;

        -- poll VR (S#2 bit6) and log edges with raw line numbers for 3 fields
        WHILE NEDGE < 7 LOOP
            PRD(1, ST);
            IF PREV /= 'X' AND ST(6) /= PREV THEN
                NEDGE := NEDGE + 1;
                WRITE(L, STRING'("VR "));
                IF ST(6) = '1' THEN WRITE(L, STRING'("RISE")); ELSE WRITE(L, STRING'("FALL")); END IF;
                WRITE(L, STRING'(" at raw "));
                WRITE(L, (CYCLES / 1368) MOD 262);
                WRITELINE(OUTPUT, L);
            END IF;
            PREV := ST(6);
        END LOOP;
        -- reference: also find the vblank INT line for alignment
        VREG(15, 0);
        PRD(1, ST);                    -- clear pending
        WAIT UNTIL INT_N = '0' FOR 30 ms;
        WRITE(L, STRING'("VBLANK-INT at raw "));
        WRITE(L, (CYCLES / 1368) MOD 262);
        WRITELINE(OUTPUT, L);
        ASSERT FALSE REPORT "done" SEVERITY FAILURE;
    END PROCESS;
END SIM;
