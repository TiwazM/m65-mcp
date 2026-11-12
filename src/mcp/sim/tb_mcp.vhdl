-- tb_mcp: src/vhdl/mcp.vhdl (with its core) against the model, through the
-- fastio bus: plays mcpgen's script (W writes, R reads compared with the
-- model's values, I waits for the unit), then the overrun test (O): 40
-- divides back to back must fill the queue (MQLEN 16 at most), set MSTATUS
-- bit 2, and a write to MSTATUS must clear it; and (stage 1 on) the MPABORT
-- test (A): an endless program (FADD F0, F0; PEND; 65,536 passes, no
-- MPLIMIT) aborted while it runs - MSTATUS bit 4 while running, then bit 5,
-- MPERR 3, some passes counted.
-- Prints "PASS: MCP-1 identical" or the differences.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_mcp is
  generic (
    SCRIPT  : string := "/tmp/mcp-sim/script.txt";
    FASTBUS : integer := 0      -- 1: every access holds one clock (a byte every two clocks, the DMA's best)
    );
end tb_mcp;

architecture sim of tb_mcp is
  signal clock : std_logic := '0';
  signal cs, rd, wr : std_logic := '0';
  signal addr : unsigned(11 downto 0) := (others => '0');
  signal wdata : unsigned(7 downto 0) := (others => '0');
  signal rdata : std_logic_vector(7 downto 0);
  signal finished : boolean := false;
begin

  clock <= not clock after 12.345 ns when not finished;

  dut : entity work.mcp
    port map (clock => clock, cs => cs, fastio_addr => addr, fastio_read => rd,
              fastio_write => wr, fastio_wdata => wdata, fastio_rdata => rdata);

  process
    file f : text;
    variable ln : line;
    variable c : character;
    variable va : std_logic_vector(11 downto 0);
    variable vd : std_logic_vector(7 downto 0);
    variable v : unsigned(7 downto 0);
    variable errors, nw, nr, ni : integer := 0;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    variable fast : boolean := FASTBUS = 1;

    procedure tick(n : integer) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clock);
      end loop;
    end procedure;

    procedure next_hold(h : out integer) is
    begin
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      h := 1 + to_integer(lfsr(1 downto 0)) mod 3;
      if fast then
        h := 1;
      end if;
    end procedure;

    procedure bus_write(a : integer; d : unsigned(7 downto 0)) is
      variable h : integer;
    begin
      addr <= to_unsigned(a, 12);
      wdata <= d;
      cs <= '1';
      wr <= '1';
      next_hold(h);
      tick(h);
      cs <= '0';
      wr <= '0';
      tick(1);
    end procedure;

    procedure bus_read(a : integer; d : out unsigned(7 downto 0)) is
      variable h : integer;
    begin
      addr <= to_unsigned(a, 12);
      cs <= '1';
      rd <= '1';
      next_hold(h);
      tick(h);
      d := unsigned(rdata);
      cs <= '0';
      rd <= '0';
      tick(1);
    end procedure;

    procedure wait_idle is
      variable s : unsigned(7 downto 0);
      variable k : integer := 0;
    begin
      loop
        bus_read(16#100#, s);
        exit when s(0) = '0';
        k := k + 1;
        -- (the longest wait a script asks for: a few hundred thousand clocks)
        assert k < 1000000 report "the unit never went idle" severity failure;
      end loop;
    end procedure;

  begin
    tick(4);
    file_open(f, SCRIPT, read_mode);
    while not endfile(f) loop
      readline(f, ln);
      next when ln'length = 0;
      read(ln, c);
      if c = 'W' then
        hread(ln, va); hread(ln, vd);
        bus_write(to_integer(unsigned(va)), unsigned(vd));
        nw := nw + 1;
      elsif c = 'R' then
        hread(ln, va); hread(ln, vd);
        bus_read(to_integer(unsigned(va)), v);
        nr := nr + 1;
        if v /= unsigned(vd) then
          if errors < 25 then
            report "read $" & to_hstring(va) & ": " & to_hstring(v) & ", expected " & to_hstring(vd)
              & " (read " & integer'image(nr) & ")" severity error;
          end if;
          errors := errors + 1;
        end if;
      elsif c = 'I' then
        wait_idle;
        ni := ni + 1;
      elsif c = 'O' then
        -- the overrun test: 40 divides at the DMA's best rate fill the queue
        fast := true;
        bus_write(16#107#, x"00");                         -- MRESET
        for i in 0 to 39 loop
          bus_write(16#185#, to_unsigned((i * 37) mod 256, 8));   -- FDIV
        end loop;
        bus_read(16#103#, v);
        if v > 16 or v < 14 then
          report "overrun test: MQLEN " & integer'image(to_integer(v)) & ", expected about 16" severity error;
          errors := errors + 1;
        end if;
        wait_idle;
        bus_read(16#100#, v);
        if v(2) /= '1' then
          report "overrun test: MSTATUS " & to_hstring(v) & ", bit 2 clear" severity error;
          errors := errors + 1;
        end if;
        bus_write(16#100#, x"00");
        bus_read(16#100#, v);
        if v(2) /= '0' or v(3) /= '0' then
          report "overrun test: MSTATUS " & to_hstring(v) & " after the write" severity error;
          errors := errors + 1;
        end if;
        bus_write(16#107#, x"00");
        fast := FASTBUS = 1;
      elsif c = 'A' then
        fast := true;
        bus_write(16#107#, x"00");                         -- MRESET
        bus_write(16#10C#, x"00");                         -- MPPTR 0
        bus_write(16#10D#, x"00");
        bus_write(16#128#, x"01");                         -- FADD F0, F0
        bus_write(16#129#, x"00");
        bus_write(16#12A#, x"19");                         -- PEND
        bus_write(16#12B#, x"00");
        bus_write(16#114#, x"00");                         -- MPLIMIT 0: no limit
        bus_write(16#115#, x"00");
        bus_write(16#116#, x"00");
        for b in 0 to 3 loop                               -- PRUN 0, 65,536 passes
          bus_write(16#780# + b, x"00");
        end loop;
        tick(300);
        bus_read(16#100#, v);
        if v(4) /= '1' or v(0) /= '1' then
          report "MPABORT test: MSTATUS " & to_hstring(v) & " while the program runs" severity error;
          errors := errors + 1;
        end if;
        bus_write(16#12D#, x"00");                         -- MPABORT
        wait_idle;
        bus_read(16#100#, v);
        if v(5) /= '1' or v(4) /= '0' then
          report "MPABORT test: MSTATUS " & to_hstring(v) & " after the abort" severity error;
          errors := errors + 1;
        end if;
        bus_read(16#110#, v);
        if v /= x"03" then
          report "MPABORT test: MPERR " & to_hstring(v) & ", expected 03" severity error;
          errors := errors + 1;
        end if;
        bus_read(16#10E#, v);
        if v = x"00" then
          report "MPABORT test: no passes counted" severity error;
          errors := errors + 1;
        end if;
        bus_write(16#107#, x"00");
        fast := FASTBUS = 1;
      end if;
    end loop;
    file_close(f);
    report integer'image(nw) & " writes, " & integer'image(nr) & " reads compared, "
      & integer'image(ni) & " waits";
    if errors = 0 then
      report "PASS: MCP identical";
    else
      report "FAIL: " & integer'image(errors) & " differences" severity error;
    end if;
    finished <= true;
    wait;
  end process;

end sim;
