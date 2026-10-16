-- Replay a recorded VDP I/O stream into the VDP RTL and dump VRAM at given
-- clocks, to compare against the recording machine's own VRAM at the same
-- moments (sim/run_vdp_replay.sh; the recording is openMSX's).
--
-- Wiring as rtl/msx.sv: REQ is ONE clk21m per access -- msx.sv `req` is cut
-- after its first cycle by `iack` (msx.sv:1265), and the VDP acts on every cycle
-- REQ is high (a 15-cycle level made one OUT (99h) count as both bytes: the
-- first version of this bench wrote the BIOS logo 96 KB away from openMSX's).
-- VRAM = two 64 KB spram (altsyncram, address registered, output unregistered,
-- read-during-write NEW_DATA), selected by PRAMADR(16), written on ~PRAMWE_N
-- with no DLCLK gate (msx.sv:1245).
--
-- Files (generic PFX):
--   PFX.io     "cycle rw port value"  decimal; rw 1 = write; port 0..3 = 98h..9Bh
--   PFX.snap   "k cycle"              dump VRAM at clk21m cycle `cycle`
--   PFX.init   131072 lines "vv"      initial VRAM, hex, linear 00000-1FFFF
-- Output: PFX.vK.hex, 2048 lines of 64 bytes (hex), linear 00000-1FFFF.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;

ENTITY TB_VDP_REPLAY IS
    GENERIC (
        PFX     : STRING  := "replay";
        STROBE  : INTEGER := 1;                 -- clk21m cycles REQ stays high (msx.sv: 1)
        VDPID   : INTEGER := 2;                 -- V9958 (msx.sv: vdp_id << 1)
        WLO     : INTEGER := -1;                -- report VRAM writes in [WLO, WHI] (linear)
        WHI     : INTEGER := -1
    );
END TB_VDP_REPLAY;

ARCHITECTURE SIM OF TB_VDP_REPLAY IS
    SIGNAL CLK21M   : STD_LOGIC := '0';
    SIGNAL RESET    : STD_LOGIC := '1';
    SIGNAL REQ      : STD_LOGIC := '0';
    SIGNAL WRT      : STD_LOGIC := '0';
    SIGNAL ADR      : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
    SIGNAL DBI      : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL DBO      : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
    SIGNAL INT_N    : STD_LOGIC;
    SIGNAL PRAMWE_N : STD_LOGIC;
    SIGNAL PRAMADR  : STD_LOGIC_VECTOR(16 DOWNTO 0);
    SIGNAL PRAMDBI  : STD_LOGIC_VECTOR(15 DOWNTO 0);
    SIGNAL PRAMDBO  : STD_LOGIC_VECTOR(7 DOWNTO 0);

    TYPE RAM_T IS ARRAY(0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
    SHARED VARIABLE RAM_LO : RAM_T;
    SHARED VARIABLE RAM_HI : RAM_T;
    SIGNAL Q_LO, Q_HI : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    SIGNAL CYCLE    : INTEGER := 0;
    SIGNAL LOADED   : BOOLEAN := FALSE;
    SIGNAL DONE     : BOOLEAN := FALSE;

    CONSTANT CLKP : TIME := 46.56 ns;           -- 21.47727 MHz

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

    FUNCTION HEX2(S : STRING) RETURN INTEGER IS
        VARIABLE V : INTEGER := 0;
        VARIABLE C : INTEGER;
    BEGIN
        FOR I IN S'RANGE LOOP
            C := CHARACTER'POS(S(I));
            IF    C >= 48 AND C <= 57  THEN V := V * 16 + C - 48;
            ELSIF C >= 97 AND C <= 102 THEN V := V * 16 + C - 87;
            ELSIF C >= 65 AND C <= 70  THEN V := V * 16 + C - 55;
            END IF;
        END LOOP;
        RETURN V;
    END FUNCTION;

    FUNCTION TOHEX(V : STD_LOGIC_VECTOR(7 DOWNTO 0)) RETURN STRING IS
        CONSTANT H : STRING(1 TO 16) := "0123456789abcdef";
        VARIABLE N : INTEGER := TO_INTEGER(UNSIGNED(V));
        VARIABLE R : STRING(1 TO 2);
    BEGIN
        R(1) := H(N / 16 + 1); R(2) := H(N MOD 16 + 1);
        RETURN R;
    END FUNCTION;
BEGIN
    CLK21M <= NOT CLK21M AFTER CLKP/2 WHEN NOT DONE ELSE '0';

    PROCESS(CLK21M)
    BEGIN
        IF RISING_EDGE(CLK21M) THEN CYCLE <= CYCLE + 1; END IF;
    END PROCESS;

    -- the two VRAM halves (bram.vhd spram: address in a register, NEW_DATA)
    PROCESS(CLK21M)
        VARIABLE A : INTEGER;
    BEGIN
        IF RISING_EDGE(CLK21M) THEN
            A := TO_INTEGER(UNSIGNED(PRAMADR(15 DOWNTO 0)));
            IF PRAMWE_N = '0' AND TO_INTEGER(UNSIGNED(PRAMADR)) >= WLO AND TO_INTEGER(UNSIGNED(PRAMADR)) <= WHI THEN
                REPORT "VRAMWR " & INTEGER'IMAGE(CYCLE) & " " & INTEGER'IMAGE(TO_INTEGER(UNSIGNED(PRAMADR))) & " " & INTEGER'IMAGE(TO_INTEGER(UNSIGNED(PRAMDBO))) SEVERITY NOTE;
            END IF;
            IF PRAMWE_N = '0' AND PRAMADR(16) = '0' THEN RAM_LO(A) := PRAMDBO; END IF;
            IF PRAMWE_N = '0' AND PRAMADR(16) = '1' THEN RAM_HI(A) := PRAMDBO; END IF;
            Q_LO <= RAM_LO(A);
            Q_HI <= RAM_HI(A);
        END IF;
    END PROCESS;
    PRAMDBI <= Q_HI & Q_LO;

    DUT: VDP PORT MAP(
        CLK21M => CLK21M, RESET => RESET,
        REQ => REQ, ACK => OPEN, WRT => WRT, ADR => ADR, DBI => DBI, DBO => DBO,
        INT_N => INT_N,
        PRAMOE_N => OPEN, PRAMWE_N => PRAMWE_N, PRAMADR => PRAMADR,
        PRAMDBI => PRAMDBI, PRAMDBO => PRAMDBO,
        VDPSPEEDMODE => '0', RATIOMODE => "000", CENTERYJK_R25_N => '0',
        PVIDEOR => OPEN, PVIDEOG => OPEN, PVIDEOB => OPEN, PVIDEODE => OPEN,
        PVIDEOHS_N => OPEN, PVIDEOVS_N => OPEN, PVIDEOCS_N => OPEN,
        PVIDEODHCLK => OPEN, PVIDEODLCLK => OPEN,
        BLANK_O => OPEN, HBLANK => OPEN, VBLANK => OPEN,
        DISPRESO => '0',
        NTSC_PAL_TYPE => '1', FORCED_V_MODE => '0', LEGACY_VGA => '1',
        BORDER => '0',
        VDP_ID => STD_LOGIC_VECTOR(TO_UNSIGNED(VDPID, 5)),
        OFFSET_Y => "0000000"
    );

    -- initial VRAM, then reset release
    PROCESS
        FILE F : TEXT;
        VARIABLE L : LINE;
        VARIABLE S2 : STRING(1 TO 2);
    BEGIN
        FILE_OPEN(F, PFX & ".init", READ_MODE);
        FOR I IN 0 TO 131071 LOOP
            READLINE(F, L); READ(L, S2);
            IF I < 65536 THEN RAM_LO(I) := STD_LOGIC_VECTOR(TO_UNSIGNED(HEX2(S2), 8));
            ELSE RAM_HI(I - 65536) := STD_LOGIC_VECTOR(TO_UNSIGNED(HEX2(S2), 8)); END IF;
        END LOOP;
        FILE_CLOSE(F);
        LOADED <= TRUE;
        WAIT;
    END PROCESS;

    -- the I/O stream
    PROCESS
        FILE F : TEXT;
        VARIABLE L : LINE;
        VARIABLE C, RW, P, V, N : INTEGER;
        VARIABLE OK : BOOLEAN;
    BEGIN
        WAIT UNTIL LOADED;
        FOR I IN 0 TO 15 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
        RESET <= '0';
        FILE_OPEN(F, PFX & ".io", READ_MODE);
        N := 0;
        WHILE NOT ENDFILE(F) LOOP
            READLINE(F, L);
            READ(L, C, OK); NEXT WHEN NOT OK;
            READ(L, RW); READ(L, P); READ(L, V);
            WHILE CYCLE < C LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
            ADR <= STD_LOGIC_VECTOR(TO_UNSIGNED(16#98# + P, 16));
            DBO <= STD_LOGIC_VECTOR(TO_UNSIGNED(V, 8));
            IF RW = 1 THEN WRT <= '1'; ELSE WRT <= '0'; END IF;
            REQ <= '1';
            FOR I IN 1 TO STROBE LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
            REQ <= '0';
            FOR I IN 1 TO 8 LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;   -- bus held a while, as a CPU
            WRT <= '0';
            N := N + 1;
            IF N MOD 50000 = 0 THEN
                REPORT "io " & INTEGER'IMAGE(N) & " at cycle " & INTEGER'IMAGE(CYCLE) SEVERITY NOTE;
            END IF;
        END LOOP;
        FILE_CLOSE(F);
        REPORT "io stream done: " & INTEGER'IMAGE(N) & " events" SEVERITY NOTE;
        WAIT;
    END PROCESS;

    -- VRAM dumps
    PROCESS
        FILE F : TEXT;
        FILE O : TEXT;
        VARIABLE L, LO : LINE;
        VARIABLE K, C : INTEGER;
        VARIABLE OK : BOOLEAN;
    BEGIN
        WAIT UNTIL LOADED;
        FILE_OPEN(F, PFX & ".snap", READ_MODE);
        WHILE NOT ENDFILE(F) LOOP
            READLINE(F, L);
            READ(L, K, OK); NEXT WHEN NOT OK;
            READ(L, C);
            WHILE CYCLE < C LOOP WAIT UNTIL RISING_EDGE(CLK21M); END LOOP;
            FILE_OPEN(O, PFX & ".v" & INTEGER'IMAGE(K) & ".hex", WRITE_MODE);
            FOR R IN 0 TO 2047 LOOP
                FOR B IN 0 TO 63 LOOP
                    IF R < 1024 THEN WRITE(LO, TOHEX(RAM_LO(R * 64 + B)));
                    ELSE WRITE(LO, TOHEX(RAM_HI((R - 1024) * 64 + B))); END IF;
                END LOOP;
                WRITELINE(O, LO);
            END LOOP;
            FILE_CLOSE(O);
            REPORT "snapshot " & INTEGER'IMAGE(K) & " at cycle " & INTEGER'IMAGE(CYCLE) SEVERITY NOTE;
        END LOOP;
        FILE_CLOSE(F);
        DONE <= TRUE;
        WAIT;
    END PROCESS;
END SIM;
