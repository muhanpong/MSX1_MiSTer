--
--  T80pa vs T80s -- the bus contract, side by side, cycle for cycle.
--
--  The CPU ceiling is structural: T80pa advances one T-state per CEN_p/CEN_n
--  PAIR (T80pa.vhd:153,168), so it cannot pass clk21m/2.  T80s takes a single
--  CEN and can run at clk21m/1.  Swapping them changes where the bus strobes
--  land, and msx.sv's guard layer has five derivations nailed to T80pa's
--  internal line numbers (msx.sv:332, :381, :411-417, :500, :1123).  Those have
--  to be re-derived, and this is where the facts come from -- a waveform, not a
--  reading of the VHDL.
--
--  Both wrappers get the same program, the same memory model and the same
--  T-state rate (T80pa: CEN_p/CEN_n alternating; T80s: one CEN in the same
--  place as CEN_p).  The trace prints one line per clk21m tick so the two can
--  be diffed directly.
--
--  What to look for, in the order it matters:
--    1. how many clk21m ticks each strobe stays low  (msx.sv:1123 assumes ~6)
--    2. the tick on which DI is captured relative to the address going out
--       (T80pa: TState 3.  T80s: TState 2.  This is the window that halves.)
--    3. whether MREQ_n and IORQ_n are both high between M-cycles
--       (msx.sv:909-922 `iack` counts bus cycles on exactly that)
--    4. the IACK cycle: IORQ_n alone, RD_n and WR_n staying high
--
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use STD.TEXTIO.all;

entity TB_T80_CONTRACT is
    generic (
        --  0 = T80pa (today), 1 = T80s (the candidate)
        USE_T80S : integer := 0;
        --  clk21m ticks per T-state.  6 = 3.58 MHz, 2 = 10.74, 1 = 21.48.
        --  T80pa cannot do 1: it needs two enables per T-state.
        DIVN     : integer := 6;
        TICKS    : integer := 1200
    );
end TB_T80_CONTRACT;

architecture SIM of TB_T80_CONTRACT is

    signal CLK      : std_logic := '0';
    signal RESET_n  : std_logic := '0';
    signal WAIT_n   : std_logic := '1';
    signal INT_n    : std_logic;
    signal NMI_n    : std_logic := '1';

    signal CEN_p, CEN_n, CEN : std_logic := '0';

    signal M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n : std_logic;
    signal A        : std_logic_vector(15 downto 0);
    signal DI       : std_logic_vector(7 downto 0) := (others => '0');
    signal DO       : std_logic_vector(7 downto 0);

    type MEM_T is array(0 to 255) of std_logic_vector(7 downto 0);
    --  LD HL,0080h / LD B,3 / XOR A / loop: ADD A,B / DJNZ loop
    --  LD (HL),A / LD A,(HL) / OUT (10h),A / IN A,(10h) / HALT
    --  Covers: M1 fetch, immediate operand read, memory read, memory write,
    --  an I/O write and an I/O read -- every strobe shape the guard cares about.
    signal MEM : MEM_T := (
        16#00# => x"FB",                      -- EI (so the IACK cycle can happen)
        16#01# => x"21", 16#02# => x"80", 16#03# => x"00",
        16#04# => x"06", 16#05# => x"03",
        16#06# => x"AF",
        16#07# => x"80",
        16#08# => x"10", 16#09# => x"FD",
        16#0A# => x"77",
        16#0B# => x"7E",
        16#0C# => x"D3", 16#0D# => x"10",
        16#0E# => x"DB", 16#0F# => x"10",
        16#10# => x"76",
        --  IM 0 vector: the byte the CPU reads during IACK is 0xC9 (RET), so
        --  the interrupt returns immediately and the trace continues.
        16#38# => x"C9",
        others => x"00" );

    signal tick     : integer := 0;
    signal dstate   : integer := 0;   -- position inside the T-state, 0..DIVN-1
    signal INT_ARM  : std_logic := '0';

begin

    CLK <= not CLK after 23.28 ns;    -- 21.477 MHz

    --  Clock enables.  T80pa needs the p/n pair; T80s takes one enable in the
    --  same position as CEN_p so the two runs are directly comparable.
    process(CLK)
    begin
        if rising_edge(CLK) then
            if dstate = DIVN-1 then dstate <= 0; else dstate <= dstate + 1; end if;
            tick <= tick + 1;
        end if;
    end process;

    CEN_p <= '1' when dstate = 0                        else '0';
    CEN_n <= '1' when dstate = DIVN/2 and DIVN > 1      else '0';
    CEN   <= '1' when dstate = 0                        else '0';

    GEN_PA: if USE_T80S = 0 generate
        U: entity work.T80pa
            generic map ( Mode => 0 )
            port map ( RESET_n => RESET_n, CLK => CLK, CEN_p => CEN_p, CEN_n => CEN_n,
                       WAIT_n => WAIT_n, INT_n => INT_n, NMI_n => NMI_n, BUSRQ_n => '1',
                       M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n,
                       WR_n => WR_n, RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
                       A => A, DI => DI, DO => DO );
    end generate;

    GEN_S: if USE_T80S = 1 generate
        U: entity work.T80s
            generic map ( Mode => 0, T2Write => 1, IOWait => 1 )
            port map ( RESET_n => RESET_n, CLK => CLK, CEN => CEN,
                       WAIT_n => WAIT_n, INT_n => INT_n, NMI_n => NMI_n, BUSRQ_n => '1',
                       M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n,
                       WR_n => WR_n, RFSH_n => RFSH_n, HALT_n => HALT_n, BUSAK_n => BUSAK_n,
                       A => A, DI => DI, DO => DO );
    end generate;

    --  Memory model: ASYNCHRONOUS on purpose.  The point of this bench is the
    --  CPU's own strobe geometry; putting a registered-q memory in the way
    --  would fold the memory's latency into the picture and hide it.  The real
    --  core's registered BRAM is a separate question, measured elsewhere.
    --  Hold INT_n low from the arm point until the CPU acknowledges.
    INT_n <= '0' when INT_ARM = '1' and tick > 120 and tick < 400 else '1';

    DI <= x"C9"                                    when IORQ_n = '0' and M1_n = '0' else
          MEM(to_integer(unsigned(A(7 downto 0)))) when MREQ_n = '0' and RD_n = '0' else
          x"00"                                    when IORQ_n = '0' and RD_n = '0' else
          x"FF";

    process(CLK)
    begin
        if rising_edge(CLK) then
            if MREQ_n = '0' and WR_n = '0' then
                MEM(to_integer(unsigned(A(7 downto 0)))) <= DO;
            end if;
        end if;
    end process;

    process
        variable L : LINE;
    begin
        write(L, STRING'("# wrapper="));
        if USE_T80S = 1 then write(L, STRING'("T80s ")); else write(L, STRING'("T80pa")); end if;
        write(L, STRING'("  DIVN=")); write(L, DIVN);
        writeline(OUTPUT, L);
        write(L, STRING'("# tick ds A    M1 MREQ RD WR IORQ RFSH DI DO"));
        writeline(OUTPUT, L);

        wait for 500 ns;
        RESET_n <= '1';
        --  Fire an interrupt part-way in.  The IACK cycle is one of the five
        --  guard derivations (msx.sv:411-417 identifies it as "IORQ_n low while
        --  RD_n and WR_n both stay high") and it is the one whose failure mode
        --  is a hang, so it has to be on the trace rather than assumed.
        INT_ARM <= '1';

        for i in 0 to TICKS loop
            wait until rising_edge(CLK);
            write(L, STRING'("  "));
            write(L, tick);       write(L, STRING'(" "));
            write(L, dstate);     write(L, STRING'(" "));
            for b in 15 downto 0 loop
                if A(b) = '1' then write(L, STRING'("1")); else write(L, STRING'("0")); end if;
            end loop;
            write(L, STRING'(" "));
            if M1_n   = '0' then write(L, STRING'("M1 ")); else write(L, STRING'(".  ")); end if;
            if MREQ_n = '0' then write(L, STRING'("MREQ ")); else write(L, STRING'(".    ")); end if;
            if RD_n   = '0' then write(L, STRING'("RD ")); else write(L, STRING'(".  ")); end if;
            if WR_n   = '0' then write(L, STRING'("WR ")); else write(L, STRING'(".  ")); end if;
            if IORQ_n = '0' then write(L, STRING'("IORQ ")); else write(L, STRING'(".    ")); end if;
            if RFSH_n = '0' then write(L, STRING'("RFSH ")); else write(L, STRING'(".    ")); end if;
            writeline(OUTPUT, L);
            exit when HALT_n = '0';
        end loop;

        write(L, STRING'("# done"));
        writeline(OUTPUT, L);
        assert false report "done" severity failure;
        wait;
    end process;

end SIM;
