-- tb_vdp_ovs -- sprites in an OVERSCAN frame (R#9 LN switched 1->0 past the
-- end line, so the display never ends; km224.rom, ASO).  Run by
-- sim/run_vdp_overscan_sprite.sh, which scores the VCD.
--   * a sprite at R23+D for D in a list: it must be drawn on every top-border
--     line it covers, from the first one (openMSX 21.0-545 draws from the first
--     top-border row; before 2026-10-07 this core left the first 3 lines empty)
--   * a sprite at R23+195 across the LN switch (line 200): all 16 lines drawn
--     (before 2026-10-07 every sprite stopped at line 201).
-- Each frame: wait FH at display line 200, R#9 = 00h, 30 lines later R#9 = 80h.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY TB_VDP_OVS IS
END TB_VDP_OVS;

ARCHITECTURE SIM OF TB_VDP_OVS IS
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
    SIGNAL DVAL   : INTEGER := 0;
    SIGNAL PHASE  : INTEGER := 0;

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
        PROCEDURE VADDR(A : IN INTEGER) IS
        BEGIN
            VREG(14, A / 16384);
            PWR(1, A MOD 256); PWR(1, ((A / 256) MOD 64) + 64);
        END PROCEDURE;
        PROCEDURE WAITLINES(N : IN INTEGER) IS
        BEGIN
            FOR I IN 0 TO N*1368 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        END PROCEDURE;
        CONSTANT R23 : INTEGER := 16#6D#;
        TYPE DLIST IS ARRAY(NATURAL RANGE <>) OF INTEGER;
        CONSTANT DS : DLIST := (16#20#, 16#E2#, 16#E4#, 16#F0#, 16#F1#);
        VARIABLE ST : STD_LOGIC_VECTOR(7 DOWNTO 0);
        PROCEDURE LNFRAME IS   -- one frame of the overscan trick: LN 1->0 at line ~200, back to 1 ~30 lines later
            VARIABLE S1 : STD_LOGIC_VECTOR(7 DOWNTO 0);
        BEGIN
            VREG(15, 1); PRD(1, S1);                -- clear FH
            LOOP PRD(1, S1); EXIT WHEN S1(0) = '1'; END LOOP;
            VREG(9, 16#00#);
            WAITLINES(30);
            VREG(9, 16#80#);
        END PROCEDURE;
    BEGIN
        WAIT FOR CLKP*32;
        RESET <= '0';
        WAIT FOR CLKP*64;
        VREG(0, 16#12#);      -- G2, IE1 on (FH only sets with IE1, as on the chip)
        VREG(1, 16#42#);      -- BL on, 16x16, no IRQ
        VREG(2, 16#0E#); VREG(3, 16#FF#); VREG(4, 16#03#);
        VREG(5, 16#36#); VREG(11, 0);      -- SAT 1B00h
        VREG(6, 16#07#);                   -- SPG 3800h
        VREG(7, 16#01#);
        VREG(8, 16#08#);                   -- sprites on
        VREG(9, 16#80#);                   -- LN=1, NTSC
        VREG(23, R23);
        VREG(19, (R23 + 200) MOD 256);     -- FH at display line 200
        VADDR(16#3800#);
        FOR I IN 0 TO 31 LOOP PWR(0, 16#FF#); END LOOP;
        FOR K IN DS'RANGE LOOP
            VADDR(16#1B00#);
            PWR(0, (R23 + DS(K)) MOD 256); PWR(0, 16#60#); PWR(0, 0); PWR(0, 16#0F#);
            PWR(0, (R23 + 195) MOD 256); PWR(0, 16#A0#); PWR(0, 0); PWR(0, 16#0F#);
            PWR(0, 16#D0#);
            DVAL <= DS(K);
            PHASE <= 1; LNFRAME; PHASE <= 2; LNFRAME; LNFRAME; PHASE <= 0;
        END LOOP;
        WAIT FOR CLKP*64;     -- let the last PHASE change reach the VCD before stopping
        ASSERT FALSE REPORT "done" SEVERITY FAILURE;
    END PROCESS;
END SIM;
