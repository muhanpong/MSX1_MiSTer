--
--  vdp_access_slots.vhd
--    VRAM access-slot gate for the VDP command engine.
--
--  Drop-in replacement for VDP_WAIT_CONTROL: same ACTIVE output, same
--  consumer (vdp.vhd's VRAM access arbiter).  Two extra inputs (H_CNT and
--  PREWINDOW_Y) carry the line position and the vertical display window.
--
--  WHY THIS EXISTS
--  ---------------
--  VDP_WAIT_CONTROL models command speed as an AVERAGE RATE: a phase
--  accumulator adds a per-(command, phase) constant and grants a slot on
--  overflow.  That can be made to match a command's TOTAL duration, but it
--  cannot place the command's write front correctly inside a scanline,
--  because the real chip's free cycles are not evenly spaced.
--
--  The real V9938 statically assigns every one of the 1368 cycles in a line
--  to a display fetch, a sprite fetch, a DRAM refresh, or "free"; the command
--  engine only ever gets the free ones.  Those positions were measured with a
--  logic analyser by the openMSX team in 2013 and live in vdp_slot_pack.vhd.
--
--  THE RULE (openMSX VDPAccessSlots.cc CycleTable)
--      from the last access, wait at least DELTA cycles for this command,
--      then take the next free slot.
--  Validated against openMSX before this module was written: replaying that
--  rule over the measured tables reproduces the reference HMMV 256x128
--  duration (722.18 lines) to within 1.0%.
--
--  DELTA values are openMSX's per-command figures.  The end-of-row variants
--  (D104/D120/D128/D136) are deliberately NOT implemented: adding them moved
--  the modelled HMMV from 1.0% to 1.7% away from the reference, so whatever
--  they key off is not "last unit of a rectangle row".
--
--  ALIGNMENT.  openMSX cycle 0 is its own convention; the common reference is
--  the start of the display cycle -- 258 there (V9938 Technical Data Book),
--  219 here (PREWINDOW_X rises at H_CNT 218, and 219+1024-1 = 1242 gives
--  exactly the 1024-cycle display window the data book specifies).  Hence
--  SLOT_OFFSET = 258 - 219 = 39.
--

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
USE WORK.VDP_SLOT_PACK.ALL;

ENTITY VDP_ACCESS_SLOTS IS
    PORT(
        RESET           : IN    STD_LOGIC;
        CLK21M          : IN    STD_LOGIC;

        VDP_COMMAND     : IN    STD_LOGIC_VECTOR(  7 DOWNTO 4 );

        REG_R1_DISP_ON  : IN    STD_LOGIC;      -- 0=Display Off, 1=Display On
        REG_R8_SP_OFF   : IN    STD_LOGIC;      -- 0=Sprite On, 1=Sprite Off
        PREWINDOW_Y     : IN    STD_LOGIC;      -- scan inside vertical display window
        H_CNT           : IN    STD_LOGIC_VECTOR( 10 DOWNTO 0 );

        VDPSPEEDMODE    : IN    STD_LOGIC;
        DRIVE           : IN    STD_LOGIC;
        XFER            : IN    STD_LOGIC;   -- a real VDPW/VDPR cycle happened
        XFER_WR         : IN    STD_LOGIC;   -- ...and it was the write
        WRPEND          : IN    STD_LOGIC;   -- the engine's next access is a write

        ACTIVE          : OUT   STD_LOGIC
    );
END VDP_ACCESS_SLOTS;

ARCHITECTURE RTL OF VDP_ACCESS_SLOTS IS

    CONSTANT SLOT_OFFSET : INTEGER := 39;

    --  Minimum cycles before the engine's NEXT access, from the per-step
    --  calculator.next(Delta::Dxx) calls in openMSX VDPCmdEngine.cc.  A first
    --  version applied one figure per command to every access; commands with
    --  two or three accesses per unit came out 1.7x-2.2x too slow, in exact
    --  proportion to their access count.  The real rule is per step:
    --
    --              before WRITE    before READ     before READ
    --                              (after write)   (after read)
    --      HMMV       48              -               -
    --      HMMM       24              64              -
    --      YMMM       24              40              -
    --      LMMV       24              72              -
    --      LMMM       24              64 (src)        32 (dst)
    --      LINE       24              88              -
    --      SRCH        -              88              88
    --
    --  "after read/after write" distinguishes LMMM's two reads without
    --  needing the engine's state: the source read always follows the write
    --  of the previous pixel, the destination read always follows the source
    --  read.  Index is the command opcode's high nibble.  0 = not throttled
    --  (POINT/PSET and the CPU-paced LMCM/LMMC/HMMC, which VDP_WAIT_TABLE
    --  also left at full speed).  The end-of-row variants (D104/D120/D128/
    --  D136) are still deliberately absent, as before.
    TYPE DELTA_T IS ARRAY(0 TO 15) OF INTEGER RANGE 0 TO 255;
    CONSTANT WR_DELTA : DELTA_T := (
    --  STOP  ----  ----  ----  POINT PSET  SRCH  LINE
         0,    0,    0,    0,    0,    0,    0,   24,
    --  LMMV  LMMM  LMCM  LMMC  HMMV  HMMM  YMMM  HMMC
        24,   24,    0,    0,   48,   24,   24,    0
    );
    CONSTANT RD_DELTA_AFTER_WR : DELTA_T := (
         0,    0,    0,    0,    0,    0,   88,   88,
        72,   64,    0,    0,    0,   64,   40,    0
    );
    CONSTANT RD_DELTA_AFTER_RD : DELTA_T := (
         0,    0,    0,    0,    0,    0,   88,   88,
        72,   32,    0,    0,    0,   64,   40,    0
    );

    SIGNAL FF_SINCE     : STD_LOGIC_VECTOR( 7 DOWNTO 0 );
    SIGNAL FF_LAST_WR   : STD_LOGIC;
    SIGNAL W_SLOT_IDX   : INTEGER RANGE 0 TO 1367;
    SIGNAL W_SLOT_BITS  : STD_LOGIC_VECTOR( 2 DOWNTO 0 );
    SIGNAL W_SLOT_NOW   : STD_LOGIC;
    SIGNAL W_DELTA      : INTEGER RANGE 0 TO 255;
    SIGNAL W_DELTA_MET  : STD_LOGIC;
    SIGNAL W_GRANT      : STD_LOGIC;
    SIGNAL W_HPOS       : INTEGER RANGE 0 TO 2734;

BEGIN

    --  line position translated into openMSX's slot-table coordinates
    W_HPOS      <= CONV_INTEGER( H_CNT ) + SLOT_OFFSET;
    W_SLOT_IDX  <= W_HPOS - 1368 WHEN W_HPOS >= 1368 ELSE W_HPOS;
    W_SLOT_BITS <= SLOT_MAP( W_SLOT_IDX );

    --  bit 0 display off / vertical border, bit 1 sprites on, bit 2 sprites off
    W_SLOT_NOW  <=  W_SLOT_BITS(0) WHEN( REG_R1_DISP_ON = '0' OR PREWINDOW_Y = '0' )ELSE
                    W_SLOT_BITS(1) WHEN( REG_R8_SP_OFF  = '0' )ELSE
                    W_SLOT_BITS(2);

    W_DELTA     <=  WR_DELTA          ( CONV_INTEGER( VDP_COMMAND ) ) WHEN( WRPEND = '1' )ELSE
                    RD_DELTA_AFTER_WR ( CONV_INTEGER( VDP_COMMAND ) ) WHEN( FF_LAST_WR = '1' )ELSE
                    RD_DELTA_AFTER_RD ( CONV_INTEGER( VDP_COMMAND ) );
    W_DELTA_MET <= '1' WHEN( CONV_INTEGER( FF_SINCE ) >= W_DELTA )ELSE '0';

    W_GRANT     <= W_SLOT_NOW AND W_DELTA_MET;

    --  An unthrottled command (DELTA = 0) keeps the old behaviour of never
    --  being held back, exactly like VDP_WAIT_TABLE's 0x8000 entries.
    ACTIVE      <= '1' WHEN( VDPSPEEDMODE = '1' OR W_DELTA = 0 )ELSE W_GRANT;

    --  FF_SINCE counts cycles since the command engine's last REAL VRAM
    --  cycle.  Two wrong versions were measured first, and both are worth
    --  keeping written down:
    --
    --    reset on (DRIVE and W_GRANT)  -- DRIVE is a registered arbiter output,
    --      so it reports the access a cycle late, by which time W_GRANT is long
    --      gone (slots are >= 6 cycles apart).  The reset never fired, FF_SINCE
    --      saturated, DELTA was permanently satisfied and the engine took every
    --      slot in the map: HMMV 256x128 came out at 262.34 lines against a
    --      722.18 reference -- exactly 16384 bytes / 63.9 slots per line.
    --
    --    reset on W_GRANT alone -- correct for a saturated engine, but it also
    --      restarts the wait when the engine had nothing to send, so every
    --      stall costs a further DELTA-plus-slot.  802.76 lines, only 0.5%
    --      better than the accumulator it replaced.
    --
    --  XFER is the arbiter's VDPW/VDPR cycle and excludes VDPS.  The reset
    --  value is 2 because there are TWO registers between the grant and this
    --  counter, not one: the arbiter registers VDP_CMD_XFER at the edge that
    --  ends the granted cycle g, so XFER is high during g+1, and this process
    --  then registers the reset at the edge ending g+1, so the value lands in
    --  g+2.  Seeding it with 1 made FF_SINCE(g+k) = k-1, one short, so
    --  W_DELTA_MET went true a cycle late and the engine's effective wait was
    --  DELTA+1.  That sounds harmless and is not: every slot in the vertical
    --  border sits on an 8-cycle grid and every DELTA is a multiple of 8, so
    --  one cycle threw away a whole slot on every border access; and in the
    --  display window LMMM's 32 and 64 are exact slot distances, so both of
    --  its reads missed and it ran at 228 cycles/pixel instead of 152.
    --  Measured over the real table: HMMV +4.5%, HMMM +4.0%, LMMV +5.5%,
    --  YMMM +9.1%, LMMM +36.5% -- all of it from this one cycle.
    PROCESS( RESET, CLK21M )
    BEGIN
        IF( CLK21M'EVENT AND CLK21M = '1' )THEN
            IF( RESET = '1' )THEN
                FF_SINCE <= (OTHERS => '1');
                FF_LAST_WR <= '1';
            ELSIF( XFER = '1' )THEN
                FF_SINCE <= X"02";
                FF_LAST_WR <= XFER_WR;
            ELSIF( FF_SINCE /= X"FF" )THEN
                FF_SINCE <= FF_SINCE + 1;
            END IF;
        END IF;
    END PROCESS;

END RTL;
