-- tb_mcp_fpu: src/vhdl/mcp_fpu.vhdl against mcpvec's vectors (the model's
-- results: TestFloat's cases in every rounding mode, and random operands for
-- every core operation). The vectors go in as fast as the core takes them:
-- one a clock, the iterative unit's only when it is free, with an idle clock
-- now and then (GAPS) so the pipeline sees every mix of full and empty
-- stages. Each result is matched to its operation by its tag: every written
-- output, every flag and the write enables are compared, and the unit it
-- came from. Prints each unit's latency (start to result) and "PASS: core
-- identical" or the differences.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mcp_fpu_pkg.all;

entity tb_mcp_fpu is
  generic (
    VECTORS : string := "/tmp/mcp-sim/vectors.txt";
    GAPS    : integer := 1          -- 1: an idle clock about one in four
    );
end tb_mcp_fpu;

architecture sim of tb_mcp_fpu is
  signal clock : std_logic := '0';
  signal start : std_logic := '0';
  signal op : unsigned(4 downto 0) := (others => '0');
  signal a, b, c : std_logic_vector(31 downto 0) := (others => '0');
  signal rm : unsigned(1 downto 0) := "00";
  signal tag : unsigned(7 downto 0) := (others => '0');
  signal it_busy : std_logic;
  signal fm_done, sh_done, it_done : std_logic;
  signal fm_tag, sh_tag, it_tag : unsigned(7 downto 0);
  signal fm_r, sh_r, it_r, it_mint : std_logic_vector(31 downto 0);
  signal sh_cond : std_logic_vector(7 downto 0);
  signal fm_flags, sh_flags, it_flags : std_logic_vector(4 downto 0);
  signal sh_wf, sh_wc, it_wf, it_wm : std_logic;
  signal finished : boolean := false;
begin

  clock <= not clock after 12.345 ns when not finished;

  dut : entity work.mcp_fpu
    port map (clock => clock, start => start, op => op, a => a, b => b, c => c, rm => rm, tag => tag,
              it_busy => it_busy,
              fm_done => fm_done, fm_tag => fm_tag, fm_r => fm_r, fm_flags => fm_flags,
              sh_done => sh_done, sh_tag => sh_tag, sh_r => sh_r, sh_cond => sh_cond,
              sh_flags => sh_flags, sh_wf => sh_wf, sh_wc => sh_wc,
              it_done => it_done, it_tag => it_tag, it_r => it_r, it_mint => it_mint,
              it_flags => it_flags, it_wf => it_wf, it_wm => it_wm);

  process
    file f : text;
    variable ln : line;
    variable v_op, v_cond, v_fl : std_logic_vector(7 downto 0);
    variable v_rm, v_wr : std_logic_vector(3 downto 0);
    variable v_a, v_b, v_c, v_r, v_mint : std_logic_vector(31 downto 0);
    variable have : boolean := false;
    variable n, nres, errors, clk, outstanding, last : integer := 0;
    variable ntag : integer := 0;
    variable iter_out : boolean := false;
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    variable go : boolean;
    -- what each tag's operation must give
    type tags_b is array (0 to 63) of boolean;
    type tags_i is array (0 to 63) of integer;
    type tags_8 is array (0 to 63) of std_logic_vector(7 downto 0);
    type tags_4 is array (0 to 63) of std_logic_vector(3 downto 0);
    type tags_32 is array (0 to 63) of std_logic_vector(31 downto 0);
    variable pend : tags_b := (others => false);
    variable e_clk : tags_i;
    variable e_op, e_cond, e_fl : tags_8;
    variable e_rm, e_wr : tags_4;
    variable e_a, e_b, e_c, e_r, e_mint : tags_32;
    type lat_t is array (0 to 2) of integer;
    variable lat_min : lat_t := (others => 1000);
    variable lat_max : lat_t := (others => 0);
    variable l : line;

    procedure result(unit : natural; tg8 : unsigned(7 downto 0); r, mint : std_logic_vector(31 downto 0);
                     cond : std_logic_vector(7 downto 0); fl : std_logic_vector(4 downto 0);
                     wf, wm, wc : std_logic) is
      variable tg, lt : integer;
      variable bad : boolean;
    begin
      tg := to_integer(tg8(5 downto 0));
      nres := nres + 1;
      if not pend(tg) then
        report "a result (unit " & integer'image(unit) & ", tag " & integer'image(tg)
          & ") with no operation in flight" severity error;
        errors := errors + 1;
        return;
      end if;
      pend(tg) := false;
      outstanding := outstanding - 1;
      last := clk;
      lt := clk - e_clk(tg);
      if lt < lat_min(unit) then lat_min(unit) := lt; end if;
      if lt > lat_max(unit) then lat_max(unit) := lt; end if;
      bad := fpu_unit(unsigned(e_op(tg)(4 downto 0))) /= unit
             or wf /= e_wr(tg)(0) or wm /= e_wr(tg)(1) or wc /= e_wr(tg)(2)
             or fl /= e_fl(tg)(4 downto 0)
             or (wf = '1' and r /= e_r(tg))
             or (wm = '1' and mint /= e_mint(tg))
             or (wc = '1' and cond /= e_cond(tg));
      if bad then
        if errors < 25 then
          report "op " & to_hstring(e_op(tg)) & " rm " & to_hstring(e_rm(tg)) & " a " & to_hstring(e_a(tg))
            & " b " & to_hstring(e_b(tg)) & " c " & to_hstring(e_c(tg)) & ": unit " & integer'image(unit)
            & " r " & to_hstring(r) & " mint " & to_hstring(mint)
            & " cond " & to_hstring(cond) & " flags " & to_hstring(fl)
            & " wr " & std_logic'image(wf) & std_logic'image(wm) & std_logic'image(wc)
            & "; expected r " & to_hstring(e_r(tg)) & " mint " & to_hstring(e_mint(tg)) & " cond "
            & to_hstring(e_cond(tg)) & " flags " & to_hstring(e_fl(tg)) & " wr " & to_hstring(e_wr(tg))
            severity error;
        end if;
        errors := errors + 1;
      end if;
    end procedure;

  begin
    file_open(f, VECTORS, read_mode);
    wait until rising_edge(clock);
    loop
      -- the next vector, if there is one
      if not have and not endfile(f) then
        readline(f, ln);
        if ln'length > 0 then
          hread(ln, v_op); hread(ln, v_rm); hread(ln, v_a); hread(ln, v_b); hread(ln, v_c);
          hread(ln, v_r); hread(ln, v_mint); hread(ln, v_cond); hread(ln, v_fl); hread(ln, v_wr);
          have := true;
        end if;
      end if;
      exit when not have and endfile(f) and outstanding = 0;
      -- into the core this clock?
      lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
      go := have and not pend(ntag) and (GAPS = 0 or lfsr(1 downto 0) /= "00");
      if go and fpu_unit(unsigned(v_op(4 downto 0))) = U_ITER and iter_out then
        go := false;
      end if;
      if go then
        start <= '1';
        op <= unsigned(v_op(4 downto 0));
        rm <= unsigned(v_rm(1 downto 0));
        a <= v_a; b <= v_b; c <= v_c;
        tag <= to_unsigned(ntag, 8);
        pend(ntag) := true;
        e_clk(ntag) := clk;
        e_op(ntag) := v_op; e_rm(ntag) := v_rm; e_a(ntag) := v_a; e_b(ntag) := v_b; e_c(ntag) := v_c;
        e_r(ntag) := v_r; e_mint(ntag) := v_mint; e_cond(ntag) := v_cond; e_fl(ntag) := v_fl;
        e_wr(ntag) := v_wr;
        if fpu_unit(unsigned(v_op(4 downto 0))) = U_ITER then
          iter_out := true;
        end if;
        if outstanding = 0 then
          last := clk;
        end if;
        outstanding := outstanding + 1;
        ntag := (ntag + 1) mod 64;
        n := n + 1;
        have := false;
      else
        start <= '0';
        a <= (others => 'X'); b <= (others => 'X'); c <= (others => 'X');
      end if;
      wait until rising_edge(clock);
      -- the results of the clock just ended
      if fm_done = '1' then
        result(U_FMA, fm_tag, fm_r, x"00000000", x"00", fm_flags, '1', '0', '0');
      end if;
      if sh_done = '1' then
        result(U_SHORT, sh_tag, sh_r, x"00000000", sh_cond, sh_flags, sh_wf, '0', sh_wc);
      end if;
      if it_done = '1' then
        result(U_ITER, it_tag, it_r, it_mint, x"00", it_flags, it_wf, it_wm, '0');
        iter_out := false;
      end if;
      clk := clk + 1;
      assert outstanding = 0 or clk - last < 1000
        report "no result for 1000 clocks, " & integer'image(outstanding) & " operations in flight"
        severity failure;
    end loop;
    file_close(f);
    for k in 0 to 2 loop
      if lat_min(k) <= lat_max(k) then
        if k = U_FMA then write(l, string'("multiply-add pipeline"));
        elsif k = U_SHORT then write(l, string'("short unit"));
        else write(l, string'("iterative unit")); end if;
        write(l, string'(": "));
        write(l, lat_min(k));
        write(l, string'("-"));
        write(l, lat_max(k));
        write(l, string'(" clocks from start to its result (0: in the clock of start)"));
        writeline(output, l);
      end if;
    end loop;
    write(l, string'("vectors: "));
    write(l, n);
    write(l, string'(" in "));
    write(l, clk);
    write(l, string'(" clocks"));
    writeline(output, l);
    if errors = 0 and nres = n then
      report "PASS: core identical (" & integer'image(n) & " vectors)";
    else
      report "FAIL: " & integer'image(errors) & " of " & integer'image(n) & " vectors differ ("
        & integer'image(nres) & " results)" severity error;
    end if;
    finished <= true;
    wait;
  end process;

end sim;
