--
--  T80 architectural-state diff harness.
--
--  T80 exposes its whole register file as REG(211 downto 0) -- IFF2, IFF1, IM,
--  IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A -- and takes it
--  back through DIRSet/DIR.  That makes an exact oracle available for free: run
--  a program, dump the state, change one thing, run it again, diff.  Until now
--  nothing in this repo used it, which is why a CPU change could only be judged
--  on a board.
--
--  The first question it answers.  T80pa hardwires the core's WAIT_n to '1' and
--  implements waiting by withholding CEN entirely (T80pa.vhd:123,170) -- a
--  waited T-state gives the core ZERO clock edges -- and its header says why:
--  "WAIT_n is broken in T80.vhd.  Simulate correct WAIT_n locally."  T80s
--  instead routes the real WAIT_n into that core (T80s.vhd:127) and lets it keep
--  clocking; T80.vhd:1129 freezes only TState/MCycle/BusAck.  Top-level writes
--  that are not gated on TState -- T80.vhd:718 F(7 downto 1) <= F_Out(7 downto
--  1), guarded only by Save_ALU_r, and T80.vhd:788-800 ACC/SP/F <= Save_Mux
--  whose second disjunct has no TState gate -- would then re-execute on every
--  extra edge, with T80_ALU.vhd:147 taking carry-in from F_In(Flag_C).  An
--  operation that reads its own flag output could accumulate.
--
--  Our turbo guard works entirely by inserting waits, and at clk21m/1 nearly
--  every bus cycle takes one, so this is not a corner case for us.
--
--  Method: run the same program with WAIT_n held low for EXTRA_WAIT additional
--  T-states at every TState=2, and print the final REG.  Identical output for
--  every EXTRA_WAIT means the core tolerates being clocked through a wait.
--
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use STD.TEXTIO.all;

entity TB_T80_STATE is
    generic (
        USE_T80S   : integer := 1;   -- 0 = T80pa, 1 = T80s
        DIVN       : integer := 2;   -- clk21m per T-state
        EXTRA_WAIT : integer := 0;   -- extra waited T-states at every TState 2
        TICKS      : integer := 40000
    );
end TB_T80_STATE;

architecture SIM of TB_T80_STATE is
    signal CLK     : std_logic := '0';
    signal RESET_n : std_logic := '0';
    signal WAIT_n  : std_logic := '1';
    signal CEN_p, CEN_n, CEN : std_logic := '0';
    signal M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n : std_logic;
    signal A   : std_logic_vector(15 downto 0);
    signal DI  : std_logic_vector(7 downto 0) := (others => '0');
    signal DO  : std_logic_vector(7 downto 0);
    signal REG : std_logic_vector(211 downto 0);

    type MEM_T is array(0 to 255) of std_logic_vector(7 downto 0);
    --  Flag-carrying arithmetic, chained so that any corruption of F or A
    --  propagates instead of being overwritten: the carry out of each step is
    --  the carry in of the next, and DAA/RLA/CP read flags they also write.
    signal MEM : MEM_T := (
        16#00# => x"3E", 16#01# => x"9C",   -- LD A,9Ch
        16#02# => x"06", 16#03# => x"7F",   -- LD B,7Fh
        16#04# => x"37",                    -- SCF
        16#05# => x"88",                    -- ADC A,B
        16#06# => x"27",                    -- DAA
        16#07# => x"17",                    -- RLA
        16#08# => x"98",                    -- SBC A,B
        16#09# => x"1F",                    -- RRA
        16#0A# => x"B8",                    -- CP B
        16#0B# => x"88",                    -- ADC A,B
        16#0C# => x"27",                    -- DAA
        16#0D# => x"17",                    -- RLA
        16#0E# => x"98",                    -- SBC A,B
        16#0F# => x"1F",                    -- RRA
        16#10# => x"B8",                    -- CP B
        16#11# => x"32", 16#12# => x"80", 16#13# => x"00",  -- LD (0080h),A
        16#14# => x"76",                    -- HALT
        others => x"00" );

    signal dstate : integer := 0;
    signal tstate_seen : std_logic := '0';
    signal wcnt   : integer := 0;
begin
    CLK <= not CLK after 23.28 ns;

    process(CLK) begin
        if rising_edge(CLK) then
            if dstate = DIVN-1 then dstate <= 0; else dstate <= dstate + 1; end if;
        end if;
    end process;
    CEN_p <= '1' when dstate = 0 else '0';
    CEN_n <= '1' when dstate = DIVN/2 and DIVN > 1 else '0';
    CEN   <= '1' when dstate = 0 else '0';

    --  Hold WAIT_n low for EXTRA_WAIT enable edges after each transfer strobe
    --  begins.  Crude on purpose: the point is to add waited T-states, not to
    --  model the real guard.
    process(CLK)
    begin
        if rising_edge(CLK) then
            if RESET_n = '0' then
                wcnt <= 0; WAIT_n <= '1';
            elsif CEN = '1' or (USE_T80S = 0 and CEN_n = '1') then
                if (MREQ_n = '0' or IORQ_n = '0') and wcnt < EXTRA_WAIT then
                    wcnt   <= wcnt + 1;
                    WAIT_n <= '0';
                else
                    WAIT_n <= '1';
                    if MREQ_n = '1' and IORQ_n = '1' then wcnt <= 0; end if;
                end if;
            end if;
        end if;
    end process;

    GEN_PA: if USE_T80S = 0 generate
        U: entity work.T80pa generic map ( Mode => 0 )
            port map ( RESET_n => RESET_n, CLK => CLK, CEN_p => CEN_p, CEN_n => CEN_n,
                       WAIT_n => WAIT_n, INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
                       M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n,
                       WR_n => WR_n, RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
                       A => A, DI => DI, DO => DO, REG => REG );
    end generate;
    GEN_S: if USE_T80S = 1 generate
        U: entity work.T80s generic map ( Mode => 0, T2Write => 1, IOWait => 1 )
            port map ( RESET_n => RESET_n, CLK => CLK, CEN => CEN,
                       WAIT_n => WAIT_n, INT_n => '1', NMI_n => '1', BUSRQ_n => '1',
                       M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n,
                       WR_n => WR_n, RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
                       A => A, DI => DI, DO => DO, REG => REG );
    end generate;

    DI <= MEM(to_integer(unsigned(A(7 downto 0)))) when MREQ_n = '0' and RD_n = '0' else x"FF";

    process(CLK) begin
        if rising_edge(CLK) then
            if MREQ_n = '0' and WR_n = '0' then
                MEM(to_integer(unsigned(A(7 downto 0)))) <= DO;
            end if;
        end if;
    end process;

    process
        variable L : LINE;
        variable n : integer := 0;
        function hex(v : std_logic_vector) return string is
            constant D : string(1 to 16) := "0123456789ABCDEF";
            variable r : string(1 to v'length/4);
            variable s : std_logic_vector(v'length-1 downto 0) := v;
        begin
            for i in r'range loop
                r(i) := D(to_integer(unsigned(s(s'high downto s'high-3))) + 1);
                s := s(s'high-4 downto 0) & "0000";
            end loop;
            return r;
        end function;
    begin
        wait for 500 ns;
        RESET_n <= '1';
        while HALT_n = '1' and n < TICKS loop
            wait until rising_edge(CLK);
            n := n + 1;
        end loop;
        write(L, STRING'("wrapper="));
        if USE_T80S = 1 then write(L, STRING'("T80s ")); else write(L, STRING'("T80pa")); end if;
        write(L, STRING'(" DIVN=")); write(L, DIVN);
        write(L, STRING'(" EXTRA_WAIT=")); write(L, EXTRA_WAIT);
        write(L, STRING'(" halted="));
        if HALT_n = '0' then write(L, STRING'("yes")); else write(L, STRING'("NO ")); end if;
        write(L, STRING'("  mem80=")); write(L, hex(MEM(16#80#)));
        writeline(OUTPUT, L);
        write(L, STRING'("  REG=")); write(L, hex(REG(207 downto 0)));
        writeline(OUTPUT, L);
        assert false report "done" severity failure;
        wait;
    end process;
end SIM;
