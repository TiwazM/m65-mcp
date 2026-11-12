-- mcp_fpu: the arithmetic core of the M65-MCP (src/mcp/MCP1.md, MCP2.md):
-- IEEE 754 binary32, bit-exact against src/mcp/model/mcp_model.c's mcp_core
-- and mcp_fma (Berkeley SoftFloat 3e, ARM-VFPv2-defaultNaN, tininess after
-- rounding).
--
-- Three units side by side (MCP-2 stage 3a), which one by the operation
-- (mcp_fpu_pkg.fpu_unit):
--   the multiply-add pipeline: add, subtract, reverse subtract, multiply and
--     the fused multiply-add (a x b + c, one rounding; add and subtract as
--     a x 1 + b, multiply as a x b with no addend). Five stages: unpack;
--     special cases and the one 24 x 24 multiplier; the exact product and
--     the aligned addend in a 76-bit frame with sticky, one add; normalise;
--     round. An operation a clock; its result 4 clocks after start.
--   the short unit: moves, compares, min and max, sign changes, classes and
--     constants, its result in the clock of start.
--   the iterative unit: divide, reverse divide, reciprocal and square root
--     (a result bit a clock), rounding to an integer, conversions to and
--     from integers. One operation at a time (it_busy): divide and square
--     root 33 clocks, the rest 7.
--
-- The caller holds op, a, b, c, rm and tag in registers for the clock of
-- start; each result comes back with its tag. Results can come back in any
-- order and in the same clock (at most one a unit): the caller's scoreboard
-- sees to the order (src/vhdl/mcp.vhdl).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package mcp_fpu_pkg is
  constant U_FMA   : natural := 0;
  constant U_SHORT : natural := 1;
  constant U_ITER  : natural := 2;
  function fpu_unit(op : unsigned(4 downto 0)) return natural;
end package;

package body mcp_fpu_pkg is
  function fpu_unit(op : unsigned(4 downto 0)) return natural is
  begin
    case to_integer(op) is
      when 16#01# | 16#02# | 16#03# | 16#04# | 16#1E# =>
        return U_FMA;
      when 16#05# | 16#06# | 16#0A# | 16#0D# | 16#0E# | 16#10# | 16#11# | 16#12# | 16#13#
         | 16#1C# | 16#1D# =>
        return U_ITER;
      when others =>
        return U_SHORT;                         -- (and anything else: nothing written)
    end case;
  end function;
end package body;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mcp_fpu_pkg.all;

entity mcp_fpu is
  port (
    clock    : in  std_logic;
    abort    : in  std_logic := '0';               -- everything in progress dropped (MRESET)
    start    : in  std_logic;                      -- this clock: op, a, b, c, rm, tag
    op       : in  unsigned(4 downto 0);
    a, b     : in  std_logic_vector(31 downto 0);
    c        : in  std_logic_vector(31 downto 0) := (others => '0');  -- FMA's addend
    rm       : in  unsigned(1 downto 0);           -- 0 nearest-even, 1 down, 2 up, 3 toward 0
    tag      : in  unsigned(7 downto 0) := (others => '0');
    it_busy  : out std_logic;                      -- the iterative unit taken: start none of its operations
    -- the results (flags: invalid, divide by 0, overflow, underflow, inexact; bit 0 first)
    fm_done  : out std_logic;                      -- the multiply-add pipeline: always Fd
    fm_tag   : out unsigned(7 downto 0);
    fm_r     : out std_logic_vector(31 downto 0);
    fm_flags : out std_logic_vector(4 downto 0);
    sh_done  : out std_logic;                      -- the short unit: Fd or MCOND
    sh_tag   : out unsigned(7 downto 0);
    sh_r     : out std_logic_vector(31 downto 0);
    sh_cond  : out std_logic_vector(7 downto 0);
    sh_flags : out std_logic_vector(4 downto 0);
    sh_wf, sh_wc : out std_logic;
    it_done  : out std_logic;                      -- the iterative unit: Fd or MINT
    it_tag   : out unsigned(7 downto 0);
    it_r     : out std_logic_vector(31 downto 0);
    it_mint  : out std_logic_vector(31 downto 0);
    it_flags : out std_logic_vector(4 downto 0);
    it_wf, it_wm : out std_logic
    );
end mcp_fpu;

architecture rtl of mcp_fpu is

  -- the core's operations: the register-form opcodes, and the memory forms' FILD, FXLD
  constant OP_MOVE  : natural := 16#00#;
  constant OP_ADD   : natural := 16#01#;
  constant OP_SUB   : natural := 16#02#;
  constant OP_SUBR  : natural := 16#03#;
  constant OP_MUL   : natural := 16#04#;
  constant OP_DIV   : natural := 16#05#;
  constant OP_DIVR  : natural := 16#06#;
  constant OP_CMP   : natural := 16#07#;
  constant OP_MIN   : natural := 16#08#;
  constant OP_MAX   : natural := 16#09#;
  constant OP_SQRT  : natural := 16#0A#;
  constant OP_ABS   : natural := 16#0B#;
  constant OP_NEG   : natural := 16#0C#;
  constant OP_RINT  : natural := 16#0D#;
  constant OP_TRUNC : natural := 16#0E#;
  constant OP_CLASS : natural := 16#0F#;
  constant OP_TOI   : natural := 16#10#;
  constant OP_TOX   : natural := 16#11#;
  constant OP_TOI16 : natural := 16#12#;
  constant OP_RECIP : natural := 16#13#;
  constant OP_CONST : natural := 16#15#;
  constant OP_ILD   : natural := 16#1C#;
  constant OP_XLD   : natural := 16#1D#;
  constant OP_FMA   : natural := 16#1E#;    -- a x b + c, rounded once (MCP-2)

  constant DNAN : std_logic_vector(31 downto 0) := x"7FC00000";
  constant Z23  : std_logic_vector(22 downto 0) := (others => '0');
  constant O23  : std_logic_vector(22 downto 0) := (others => '1');
  constant Z31  : std_logic_vector(30 downto 0) := (others => '0');

  type const_t is array (0 to 15) of std_logic_vector(31 downto 0);
  constant CONSTS : const_t := (
    x"00000000", x"3F800000", x"40000000", x"3F000000",   -- 0, 1, 2, 0.5
    x"41200000", x"40490FDB", x"3FC90FDB", x"40C90FDB",   -- 10, pi, pi/2, 2pi
    x"402DF854", x"3F317218", x"3FB8AA3B", x"3E9A209B",   -- e, ln 2, log2 e, log10 2
    x"3FB504F3", x"3F3504F3", x"7F800000", x"7FC00000");  -- sqrt 2, 1/sqrt 2, +inf, NaN

  -- an operand taken apart: value = m * 2^(e - 127 - 23), m normalised
  -- (bit 23 set) for every finite non-zero value, subnormals included
  type unp_t is record
    s    : std_logic;
    e    : signed(11 downto 0);
    m    : unsigned(23 downto 0);
    zero, inf, nan, snan, sub : boolean;
  end record;
  constant UNP_ZERO : unp_t := (s => '0', e => (others => '0'), m => (others => '0'),
                                zero => true, inf => false, nan => false, snan => false, sub => false);

  function b2l(v : boolean) return std_logic is
  begin
    if v then return '1'; end if;
    return '0';
  end function;

  function lzc(v : unsigned) return natural is
    variable n : natural := 0;
  begin
    for i in v'high downto v'low loop
      if v(i) = '1' then
        return n;
      end if;
      n := n + 1;
    end loop;
    return n;
  end function;

  function unpack(x : std_logic_vector(31 downto 0)) return unp_t is
    variable u : unp_t;
    variable ex : unsigned(7 downto 0);
    variable fr : unsigned(22 downto 0);
    variable lz : natural;
  begin
    ex := unsigned(x(30 downto 23));
    fr := unsigned(x(22 downto 0));
    u.s := x(31);
    u.zero := false; u.inf := false; u.nan := false; u.snan := false; u.sub := false;
    u.e := (others => '0');
    u.m := (others => '0');
    if ex = 0 then
      if fr = 0 then
        u.zero := true;
      else
        u.sub := true;
        lz := lzc(fr);
        u.m := shift_left(resize(fr, 24), lz + 1);
        u.e := to_signed(-lz, 12);
      end if;
    elsif ex = 255 then
      if fr = 0 then
        u.inf := true;
      else
        u.nan := true;
        u.snan := fr(22) = '0';
      end if;
    else
      u.m := '1' & fr;
      u.e := signed(resize(ex, 12));
    end if;
    return u;
  end function;

  function u1(v : std_logic) return unsigned is
    variable rr : unsigned(0 downto 0);
  begin
    rr(0) := v;
    return rr;
  end function;

  -- the rounding increment: lsb l, guard g, sticky st
  function incr(m : unsigned(1 downto 0); s, l, g, st : std_logic) return std_logic is
  begin
    case to_integer(m) is
      when 0 => return g and (st or l);
      when 1 => return s and (g or st);
      when 2 => return (not s) and (g or st);
      when others => return '0';
    end case;
  end function;

  -- v >> n, the bits shifted out ORed into bit 0
  function shr_sticky(v : unsigned; n : natural) return unsigned is
    variable vv : unsigned(v'length - 1 downto 0) := v;
    variable rr : unsigned(v'length - 1 downto 0);
    variable st : std_logic := '0';
  begin
    if n = 0 then
      return vv;
    elsif n >= v'length then
      rr := (others => '0');
      if vv /= 0 then
        rr(0) := '1';
      end if;
      return rr;
    end if;
    rr := shift_right(vv, n);
    for i in 0 to v'length - 1 loop
      if i < n and vv(i) = '1' then
        st := '1';
      end if;
    end loop;
    rr(0) := rr(0) or st;
    return rr;
  end function;

  -- the rounder: sign, exponent (value = 1.f * 2^(e - 127)), a normalised
  -- 27-bit significand (bit 26 the leading one, 25-3 the fraction, 2 guard,
  -- 1-0 sticky) or 0. Returns the result (36-5) and the flags (4-0).
  function round32(s : std_logic; e : signed(11 downto 0); sig : unsigned(26 downto 0);
                   m : unsigned(1 downto 0)) return std_logic_vector is
    variable g, st, l, inc, carry_u, tiny : std_logic;
    variable m25 : unsigned(24 downto 0);
    variable e2  : signed(11 downto 0);
    variable v   : unsigned(26 downto 0);
    variable fl  : std_logic_vector(4 downto 0) := (others => '0');
    variable rr  : std_logic_vector(31 downto 0);
  begin
    if sig = 0 then
      rr := (others => '0');
      rr(31) := s;
      return rr & fl;
    end if;
    -- tininess after rounding: the result rounded with an unbounded exponent below 2^-126
    g := sig(2); st := sig(1) or sig(0); l := sig(3);
    inc := incr(m, s, l, g, st);
    carry_u := '0';
    if sig(26 downto 3) = x"FFFFFF" then
      carry_u := inc;
    end if;
    tiny := '0';
    if e < 0 or (e = 0 and carry_u = '0') then
      tiny := '1';
    end if;
    if e >= 1 then
      m25 := ('0' & sig(26 downto 3)) + u1(inc);
      e2 := e;
      if m25(24) = '1' then
        e2 := e + 1;
      end if;
      fl(4) := g or st;
      if e2 >= 255 then                         -- overflow: infinity or the largest finite
        fl(2) := '1';
        fl(4) := '1';
        if m = 0 or (m = 1 and s = '1') or (m = 2 and s = '0') then
          rr := s & x"FF" & Z23;
        else
          rr := s & x"FE" & O23;
        end if;
      elsif m25(24) = '1' then
        rr := s & std_logic_vector(e2(7 downto 0)) & Z23;
      else
        rr := s & std_logic_vector(e2(7 downto 0)) & std_logic_vector(m25(22 downto 0));
      end if;
    else                                        -- a subnormal result (or the smallest normal)
      v := shr_sticky(sig, to_integer(1 - e));
      g := v(2); st := v(1) or v(0); l := v(3);
      inc := incr(m, s, l, g, st);
      m25 := ('0' & v(26 downto 3)) + u1(inc);
      rr := s & "0000000" & m25(23) & std_logic_vector(m25(22 downto 0));
      fl(4) := g or st;
      fl(3) := tiny and (g or st);
    end if;
    return rr & fl;
  end function;

  -- the multiply-add pipeline: stage n's registers (v valid, t tag, m the
  -- rounding mode; sp: the result already decided at stage 2, sr, sv its
  -- value and invalid flag)
  signal v1, v2, v3, v4 : std_logic := '0';
  signal t1, t2, t3, t4 : unsigned(7 downto 0) := (others => '0');
  signal m1, m2, m3, m4 : unsigned(1 downto 0) := "00";
  signal x1, y1, z1 : unp_t := UNP_ZERO;                -- 1: x * y + z, z's sign set for a subtract
  signal zraw1 : std_logic_vector(31 downto 0) := (others => '0');  -- z as it came in
  signal na1 : std_logic := '0';                         -- no addend (a multiply)
  signal sp2, sp3, sp4, sv2, sv3, sv4 : std_logic := '0';
  signal sr2, sr3, sr4 : std_logic_vector(31 downto 0) := (others => '0');
  signal prod2 : unsigned(47 downto 0) := (others => '0');   -- 2: the exact product,
  signal fpe2, fze2 : signed(11 downto 0) := (others => '0'); -- its and z's lowest bits' exponents
  signal fsg2, na2, zs2 : std_logic := '0';
  signal zm2 : unsigned(23 downto 0) := (others => '0');
  signal fsum3 : unsigned(76 downto 0) := (others => '0');   -- 3: the frame's sum,
  signal fbase3 : signed(11 downto 0) := (others => '0');    -- its lowest bit's exponent, its sign
  signal fsign3 : std_logic := '0';
  signal qs4 : std_logic := '0';                             -- 4: the rounder's input
  signal qe4 : signed(11 downto 0) := (others => '0');
  signal qsig4 : unsigned(26 downto 0) := (others => '0');

  -- the iterative unit
  type state_t is (S_IDLE, S_UNPACK, S_SPECIAL, S_DIV, S_SQRT, S_CVT, S_CVT2, S_ILD, S_ROUND, S_DONE);
  signal st : state_t := S_IDLE;
  signal rop : natural range 0 to 31 := 0;
  signal rrm : unsigned(1 downto 0) := "00";
  signal rtag : unsigned(7 downto 0) := (others => '0');
  signal ra, rb : std_logic_vector(31 downto 0) := (others => '0');
  signal ux, uy : unp_t := UNP_ZERO;
  signal qs : std_logic := '0';
  signal qe : signed(11 downto 0) := (others => '0');
  signal qsig : unsigned(26 downto 0) := (others => '0');
  signal dq : unsigned(25 downto 0) := (others => '0');           -- quotient / root bits
  signal drem : unsigned(28 downto 0) := (others => '0');         -- remainder
  signal ddiv : unsigned(23 downto 0) := (others => '0');         -- divisor
  signal dopd : unsigned(51 downto 0) := (others => '0');         -- the radicand, two bits a step
  signal dk : natural range 0 to 26 := 0;
  signal ci : unsigned(31 downto 0) := (others => '0');
  signal cg, cst, cbig : std_logic := '0';
  signal o_r, o_mint : std_logic_vector(31 downto 0) := (others => '0');
  signal o_fl : std_logic_vector(4 downto 0) := (others => '0');
  signal o_wf, o_wm, o_done : std_logic := '0';

begin

  ---------------------------------------------------------------------------
  -- the multiply-add pipeline
  ---------------------------------------------------------------------------

  process (clock)
    variable x, y, z : unp_t;
    variable zr : std_logic_vector(31 downto 0);
    variable psg, sp, sv : std_logic;
    variable sr : std_logic_vector(31 downto 0);
    variable pfr, zfr, sin, sout : unsigned(75 downto 0);
    variable pf, zf, bs, amt : signed(11 downto 0);
    variable pbig : boolean;
    variable na : natural range 0 to 127;
    variable sum : unsigned(76 downto 0);
    variable sig : unsigned(26 downto 0);
    variable lz : natural;
    variable k : natural;
  begin
    if rising_edge(clock) then
      -- 1: unpack; the operand order (x * y + z; add and subtract as x * 1 + z)
      v1 <= start and b2l(fpu_unit(op) = U_FMA);
      t1 <= tag;
      m1 <= rm;
      k := to_integer(op);
      na1 <= '0';
      if k = OP_SUBR then
        x := unpack(b); y := unpack(x"3F800000"); zr := a;
      elsif k = OP_MUL then
        x := unpack(a); y := unpack(b); zr := x"00000000";
        na1 <= '1';
      elsif k = OP_FMA then
        x := unpack(a); y := unpack(b); zr := c;
      else                                      -- add, subtract
        x := unpack(a); y := unpack(x"3F800000"); zr := b;
      end if;
      z := unpack(zr);
      if k = OP_SUB or k = OP_SUBR then
        z.s := not z.s;                         -- x - z = x * 1 + (-z)
      end if;
      x1 <= x; y1 <= y; z1 <= z;
      zraw1 <= zr;

      -- 2: SoftFloat's s_mulAddF32 order: a NaN in x or y; an infinite
      -- product (infinity times 0 invalid even beside a quiet NaN); a NaN or
      -- an infinity in z; a zero product; a zero z (the product rounded
      -- alone); else the exact x * y + z, rounded once. And the multiplier.
      psg := x1.s xor y1.s;
      sp := '1'; sv := '0'; sr := DNAN;
      if x1.nan or y1.nan then
        sv := b2l(x1.snan or y1.snan or (na1 = '0' and z1.snan));
      elsif x1.inf or y1.inf then
        if (x1.inf and y1.zero) or (y1.inf and x1.zero) then
          sv := '1';
        elsif na1 = '1' then
          sr := psg & x"FF" & Z23;
        elsif z1.nan then
          sv := b2l(z1.snan);
        elsif z1.inf and z1.s /= psg then
          sv := '1';
        else
          sr := psg & x"FF" & Z23;
        end if;
      elsif na1 = '0' and z1.nan then
        sv := b2l(z1.snan);
      elsif na1 = '0' and z1.inf then
        sr := z1.s & x"FF" & Z23;
      elsif x1.zero or y1.zero then
        if na1 = '1' then
          sr := psg & Z31;
        elsif z1.zero then
          if z1.s = psg then
            sr := psg & Z31;
          elsif m1 = 1 then
            sr := x"80000000";
          else
            sr := x"00000000";
          end if;
        else
          sr := z1.s & zraw1(30 downto 0);      -- z exactly, as it came in (its sign set)
        end if;
      else
        sp := '0';
      end if;
      v2 <= v1; t2 <= t1; m2 <= m1;
      sp2 <= sp; sr2 <= sr; sv2 <= sv;
      prod2 <= x1.m * y1.m;
      fpe2 <= x1.e + y1.e - 300;                -- (the product's lowest bit: 2^((ex-150)+(ey-150)))
      fze2 <= z1.e - 150;
      fsg2 <= psg;
      na2 <= na1 or b2l(z1.zero);               -- a zero z: the product alone
      zs2 <= z1.s;
      zm2 <= z1.m;

      -- 3: a 76-bit frame: the product at bits 75-28, the addend at 75-52,
      -- the one with the lower top shifted right (the bits out ORed into
      -- bit 0); then one add, or a subtract of the smaller magnitude
      pf := fpe2 - 28;
      pfr := shift_left(resize(prod2, 76), 28);
      if na2 = '1' then
        sum := '0' & pfr;
        bs := pf;
        fsign3 <= fsg2;
      else
        -- one shifter: the operand with the lower top goes through it
        zf := fze2 - 52;
        zfr := shift_left(resize(zm2, 76), 52);
        pbig := pf >= zf;
        if pbig then
          bs := pf; amt := pf - zf; sin := zfr;
        else
          bs := zf; amt := zf - pf; sin := pfr;
        end if;
        if amt > 100 then na := 100; else na := to_integer(amt); end if;
        sout := shr_sticky(sin, na);
        if pbig then zfr := sout; else pfr := sout; end if;
        if fsg2 = zs2 then
          sum := ('0' & pfr) + ('0' & zfr);
          fsign3 <= fsg2;
        elsif pfr >= zfr then
          sum := ('0' & pfr) - ('0' & zfr);
          fsign3 <= fsg2;
        else
          sum := ('0' & zfr) - ('0' & pfr);
          fsign3 <= zs2;
        end if;
      end if;
      fsum3 <= sum;
      fbase3 <= bs;
      v3 <= v2; t3 <= t2; m3 <= m2;
      sp3 <= sp2; sr3 <= sr2; sv3 <= sv2;

      -- 4: normalise (an exact cancellation: +0, -0 rounding down)
      v4 <= v3; t4 <= t3; m4 <= m3;
      if sp3 = '1' then
        sp4 <= '1'; sr4 <= sr3; sv4 <= sv3;
      elsif fsum3 = 0 then
        sp4 <= '1'; sv4 <= '0';
        if m3 = 1 then sr4 <= x"80000000"; else sr4 <= x"00000000"; end if;
      else
        sp4 <= '0';
        lz := lzc(fsum3);
        sum := shift_left(fsum3, lz);
        sig := sum(76 downto 50);
        if sum(49 downto 0) /= 0 then sig(0) := '1'; end if;
        qs4 <= fsign3;
        qe4 <= fbase3 + (76 - lz) + 127;
        qsig4 <= sig;
      end if;

      if abort = '1' then
        v1 <= '0'; v2 <= '0'; v3 <= '0'; v4 <= '0';
      end if;
    end if;
  end process;

  -- 5: round (the result in the clock after stage 4)
  process (v4, t4, m4, sp4, sr4, sv4, qs4, qe4, qsig4, abort)
    variable rr : std_logic_vector(36 downto 0);
  begin
    rr := round32(qs4, qe4, qsig4, m4);
    if sp4 = '1' then
      fm_r <= sr4;
      fm_flags <= "0000" & sv4;
    else
      fm_r <= rr(36 downto 5);
      fm_flags <= rr(4 downto 0);
    end if;
    fm_done <= v4 and not abort;
    fm_tag <= t4;
  end process;

  ---------------------------------------------------------------------------
  -- the short unit: in the clock of start
  ---------------------------------------------------------------------------

  process (start, op, a, b, tag, abort)
    variable x, y : unp_t;
    variable k : natural;
    variable inv : std_logic;
    variable alt : boolean;
    variable cls : std_logic_vector(7 downto 0);
    variable r : std_logic_vector(31 downto 0);
    variable cd : std_logic_vector(7 downto 0);
    variable fl : std_logic_vector(4 downto 0);
    variable wf, wc : std_logic;
  begin
    x := unpack(a);
    y := unpack(b);
    k := to_integer(op);
    inv := b2l(x.snan or y.snan);
    r := b; cd := x"00"; fl := "00000"; wf := '0'; wc := '0';
    case k is
      when OP_MOVE =>
        wf := '1';
      when OP_ABS =>
        r := '0' & b(30 downto 0); wf := '1';
      when OP_NEG =>
        r := (not b(31)) & b(30 downto 0); wf := '1';
      when OP_CONST =>
        r := CONSTS(to_integer(unsigned(b(3 downto 0)))); wf := '1';
      when OP_CMP =>
        wc := '1';
        fl(0) := inv;
        if x.nan or y.nan then
          cd := x"08";
        elsif (x.zero and y.zero) or a = b then
          cd := x"02";
        elsif x.s /= y.s then
          if x.s = '1' then cd := x"01"; else cd := x"04"; end if;
        else
          -- same sign: the magnitudes (bit patterns order like values)
          if (unsigned(a(30 downto 0)) < unsigned(b(30 downto 0))) = (x.s = '0') then
            cd := x"01";
          else
            cd := x"04";
          end if;
        end if;
      when OP_MIN | OP_MAX =>
        wf := '1';
        if x.snan or y.snan then
          r := DNAN; fl(0) := '1';
        elsif x.nan and y.nan then
          r := DNAN;
        elsif x.nan then
          r := b;
        elsif y.nan then
          r := a;
        elsif x.zero and y.zero then
          if k = OP_MAX then r := a and b; else r := a or b; end if;
        else
          -- a < b ?
          if x.s /= y.s then
            alt := x.s = '1';
          else
            alt := (unsigned(a(30 downto 0)) < unsigned(b(30 downto 0))) = (x.s = '0') and a /= b;
          end if;
          if alt = (k = OP_MIN) then r := a; else r := b; end if;
        end if;
      when OP_CLASS =>
        wc := '1';
        cls := (others => '0');
        cls(0) := y.s;
        if y.zero then cls(1) := '1';
        elsif y.sub then cls(2) := '1';
        elsif y.inf then cls(4) := '1';
        elsif y.snan then cls(6) := '1';
        elsif y.nan then cls(5) := '1';
        else cls(3) := '1';
        end if;
        cd := cls;
      when others =>
        null;                                   -- (not a core operation: nothing written)
    end case;
    sh_r <= r;
    sh_cond <= cd;
    sh_flags <= fl;
    sh_wf <= wf;
    sh_wc <= wc;
    sh_done <= start and b2l(fpu_unit(op) = U_SHORT) and not abort;
    sh_tag <= tag;
  end process;

  ---------------------------------------------------------------------------
  -- the iterative unit
  ---------------------------------------------------------------------------

  it_busy <= '0' when st = S_IDLE and not (start = '1' and fpu_unit(op) = U_ITER) else '1';
  it_done <= o_done and not abort;
  it_tag <= rtag;
  it_r <= o_r;
  it_mint <= o_mint;
  it_flags <= o_fl;
  it_wf <= o_wf;
  it_wm <= o_wm;

  process (clock)
    variable x, y : unp_t;
    variable sig : unsigned(26 downto 0);
    variable e : signed(11 downto 0);
    variable lz : natural;
    variable rr : std_logic_vector(36 downto 0);
    variable inv : std_logic;
    variable k : integer;
    variable v64 : unsigned(63 downto 0);
    variable n33 : unsigned(32 downto 0);
    variable lim : unsigned(32 downto 0);
    variable mag : unsigned(31 downto 0);
    variable trial : unsigned(28 downto 0);
    variable rem2 : unsigned(28 downto 0);
    variable u : signed(11 downto 0);
    variable mm : unsigned(1 downto 0);
  begin
    if rising_edge(clock) then
      o_done <= '0';
      if abort = '1' then
        st <= S_IDLE;
      else
      case st is

        when S_IDLE =>
          if start = '1' and fpu_unit(op) = U_ITER then
            rop <= to_integer(op);
            rrm <= rm;
            rtag <= tag;
            ra <= a;
            rb <= b;
            st <= S_UNPACK;
          end if;

        when S_UNPACK =>
          if rop = OP_DIVR then
            ux <= unpack(rb);
            uy <= unpack(ra);
          elsif rop = OP_RECIP then
            ux <= unpack(x"3F800000");
            uy <= unpack(rb);
          else
            ux <= unpack(ra);
            uy <= unpack(rb);
          end if;
          o_wf <= '0'; o_wm <= '0';
          o_fl <= (others => '0');
          st <= S_SPECIAL;

        when S_SPECIAL =>
          x := ux;
          y := uy;
          st <= S_DONE;                         -- (unless an operation goes on below)
          inv := '0';
          if (x.snan and (rop /= OP_SQRT and rop < OP_ABS)) or y.snan then
            inv := '1';
          end if;
          case rop is
            when OP_DIV | OP_DIVR | OP_RECIP =>
              o_wf <= '1';
              if x.nan or y.nan then
                o_r <= DNAN; o_fl(0) <= inv;
              elsif (x.inf and y.inf) or (x.zero and y.zero) then
                o_r <= DNAN; o_fl(0) <= '1';
              elsif x.inf then
                o_r <= (x.s xor y.s) & x"FF" & Z23;
              elsif y.inf then
                o_r <= (x.s xor y.s) & Z31;
              elsif y.zero then
                o_r <= (x.s xor y.s) & x"FF" & Z23; o_fl(1) <= '1';
              elsif x.zero then
                o_r <= (x.s xor y.s) & Z31;
              else
                -- the quotient in [1, 2): when x.m < y.m the dividend is doubled
                if x.m < y.m then
                  drem <= resize(x.m & '0', 29);
                  qe <= x.e - y.e + 126;
                else
                  drem <= resize(x.m, 29);
                  qe <= x.e - y.e + 127;
                end if;
                ddiv <= y.m;
                qs <= x.s xor y.s;
                dq <= (others => '0');
                dk <= 26;
                st <= S_DIV;
              end if;

            when OP_SQRT =>
              o_wf <= '1';
              if y.nan then
                o_r <= DNAN; o_fl(0) <= inv;
              elsif y.zero then
                o_r <= rb;
              elsif y.s = '1' then
                o_r <= DNAN; o_fl(0) <= '1';
              elsif y.inf then
                o_r <= rb;
              else
                -- sqrt(m * 2^(u - 23)), u = e - 127 made even; the root's 26 bits
                -- (1 integer, 25 fraction) are isqrt(radicand * 2^27)
                u := y.e - 127;
                if u(0) = '1' then
                  dopd <= shift_left(resize(y.m & '0', 52), 27);
                  u := u - 1;
                else
                  dopd <= shift_left(resize(y.m, 52), 27);
                end if;
                qe <= shift_right(u, 1) + 127;
                qs <= '0';
                drem <= (others => '0');
                dq <= (others => '0');
                dk <= 26;
                st <= S_SQRT;
              end if;

            when OP_RINT | OP_TRUNC =>
              o_wf <= '1';
              if y.nan then
                o_r <= DNAN; o_fl(0) <= inv;
              elsif y.inf or y.zero or y.e >= 150 then
                o_r <= rb;                      -- already an integer
              else
                st <= S_CVT;
              end if;

            when OP_TOI | OP_TOX | OP_TOI16 =>
              o_wm <= '1';
              if y.nan then
                o_mint <= (others => '0'); o_fl(0) <= '1';
              elsif y.zero then
                o_mint <= (others => '0');
              else
                st <= S_CVT;                    -- (infinities saturate there)
              end if;

            when others =>                      -- FILD, FXLD
              o_wf <= '1';
              st <= S_ILD;
          end case;

        when S_DIV =>                           -- a quotient bit a clock
          if dk = 0 then
            sig := dq & '0';
            if drem /= 0 then sig(0) := '1'; end if;
            qsig <= sig;
            st <= S_ROUND;
          else
            if drem >= resize(ddiv, 29) then
              dq <= dq(24 downto 0) & '1';
              drem <= shift_left(drem - resize(ddiv, 29), 1);
            else
              dq <= dq(24 downto 0) & '0';
              drem <= shift_left(drem, 1);
            end if;
            dk <= dk - 1;
          end if;

        when S_SQRT =>                          -- a root bit a clock
          if dk = 0 then
            sig := dq & '0';
            if drem /= 0 then sig(0) := '1'; end if;
            qsig <= sig;
            st <= S_ROUND;
          else
            rem2 := shift_left(drem, 2) or resize(dopd(51 downto 50), 29);
            trial := shift_left(resize(dq, 29), 2) or to_unsigned(1, 29);
            if rem2 >= trial then
              drem <= rem2 - trial;
              dq <= dq(24 downto 0) & '1';
            else
              drem <= rem2;
              dq <= dq(24 downto 0) & '0';
            end if;
            dopd <= shift_left(dopd, 2);
            dk <= dk - 1;
          end if;

        when S_CVT =>
          -- the value as 32.32 fixed point: m * 2^(sh - 23 + 32), sh = e - 127 (+16 for
          -- FTOX): m placed at bits 63-40 and shifted right by 40 - k (one shifter)
          k := to_integer(uy.e) - 127 + 9;
          if rop = OP_TOX then
            k := k + 16;
          end if;
          cbig <= '0';
          if uy.inf or k > 40 then
            cbig <= '1';
            v64 := (others => '0');
          elsif k < -60 then
            v64 := shr_sticky(shift_left(resize(uy.m, 64), 40), 100);
          else
            v64 := shr_sticky(shift_left(resize(uy.m, 64), 40), 40 - k);
          end if;
          ci <= v64(63 downto 32);
          cg <= v64(31);
          if v64(30 downto 0) /= 0 then cst <= '1'; else cst <= '0'; end if;
          st <= S_CVT2;

        when S_CVT2 =>
          if rop = OP_TRUNC then mm := "11"; else mm := rrm; end if;
          n33 := ('0' & ci) + u1(incr(mm, uy.s, ci(0), cg, cst));
          if rop = OP_RINT or rop = OP_TRUNC then
            -- the integer (at most 2^23) back to a float, exactly
            if n33 = 0 then
              o_r <= uy.s & Z31;
            else
              lz := lzc(n33(23 downto 0));
              mag := resize(shift_left(n33(23 downto 0), lz), 32);
              o_r <= uy.s & std_logic_vector(to_unsigned(127 + 23 - lz, 8)) & std_logic_vector(mag(22 downto 0));
            end if;
          else
            if rop = OP_TOI16 then
              lim := to_unsigned(32767, 33);
            else
              lim := to_unsigned(2147483647, 33);
            end if;
            if uy.s = '1' then
              lim := lim + 1;
            end if;
            if cbig = '1' or n33 > lim then     -- saturated, invalid
              o_fl(0) <= '1';
              if rop = OP_TOI16 then
                if uy.s = '1' then o_mint <= x"FFFF8000"; else o_mint <= x"00007FFF"; end if;
              else
                if uy.s = '1' then o_mint <= x"80000000"; else o_mint <= x"7FFFFFFF"; end if;
              end if;
            else
              if uy.s = '1' then
                o_mint <= std_logic_vector(0 - n33(31 downto 0));
              else
                o_mint <= std_logic_vector(n33(31 downto 0));
              end if;
              o_fl(4) <= cg or cst;
            end if;
          end if;
          st <= S_DONE;

        when S_ILD =>
          -- an int32 (FXLD: s15.16) to a float: normalise, then the rounder
          if rb(31) = '1' then
            mag := 0 - unsigned(rb);
          else
            mag := unsigned(rb);
          end if;
          if mag = 0 then
            o_r <= (others => '0');
            st <= S_DONE;
          else
            lz := lzc(mag);
            mag := shift_left(mag, lz);
            sig := mag(31 downto 5);
            if mag(4 downto 0) /= 0 then sig(0) := '1'; end if;
            e := to_signed(127 + 31 - lz, 12);
            if rop = OP_XLD then
              e := e - 16;
            end if;
            qs <= rb(31); qe <= e; qsig <= sig;
            st <= S_ROUND;
          end if;

        when S_ROUND =>
          rr := round32(qs, qe, qsig, rrm);
          o_r <= rr(36 downto 5);
          o_fl <= o_fl or rr(4 downto 0);
          st <= S_DONE;

        when S_DONE =>
          o_done <= '1';
          st <= S_IDLE;
      end case;
      end if;
    end if;
  end process;

end rtl;
