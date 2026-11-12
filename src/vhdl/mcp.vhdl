-- mcp: the M65-MCP on the fastio bus at $FFDF100-$FFDF7FF (the rest of the
-- $FFDF000 slot is unused). MCP-1 (src/mcp/MCP1.md):
-- registers F0-F15 (FP32), the command queue (16) fed by the register forms
-- ($180 + opcode), the memory forms (a 32-bit write to $400 + m * 64 + d * 4,
-- Weitek-style) and the stream port ($120-$123), the control registers, and
-- the arithmetic core mcp_fpu. MCP-2 stage 1 (src/mcp/MCP2.md, "Build
-- order"): programs - 512 commands in a block RAM, loaded through MPLOAD
-- ($128-$12B), read back through MPREAD ($130-$137), run by PRUN (memory
-- form 14) with PEND, PEXIT, MPCNT, MPLIMIT, MPABORT, MPERR. Stage 2: the
-- wide forms FADD3, FSUB3, FMUL3, FMA, FMS (the window $200-$2FF, the
-- stream's $90 prefix, programs) on the core's fused multiply-add path.
-- Stage 3a: the core's three units side by side (the multiply-add pipeline,
-- the short unit, the iterative unit) and a scoreboard: a command issues,
-- in order, once nothing it reads or writes (F0-F15, MCOND, MINT; SETFLAGS:
-- everything) has a result still to come; results land as they come, and
-- a command issued in the clock a result lands gets it. Programs fetch a
-- command a clock. Stage 3b: vectors (V0-V3 over F0-F15) and the matrix
-- bank M0-M15: VMOVE, MLOAD and MSTORE copy in the clock they issue; the
-- rest run as sequences of micro-operations from a ROM (UCODE) on the same
-- units, into temporaries T0-T15 with their own scoreboard, and land in F
-- or M in one clock when the last has come back. A sequence holds the
-- issue until then. Command by command bit-exact against
-- src/mcp/model/mcp_model.c (stage 4): the order of the results is the
-- scoreboard's business, never visible. MCP-3 stage 1 (src/mcp/MCP3.md):
-- the vertex array (VINDATA, $000-$003; 4 x 4 KB of block RAM) and the
-- result buffer (4 x 8 KB, read through the window at $800-$FFF); VIN as a
-- sequence of loads into T0-T3, VOUT through the core's converter, VOUTC
-- and VPASS as sequences of stores and copies, VNEXT and VEND at once.
-- Stage 2: VCLIP (the clip codes into MCOND and the entry's byte 30) and
-- PSKIP (in a program, a skip forward on MCOND).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mcp_fpu_pkg.all;

entity mcp is
  port (
    clock        : in  std_logic;               -- fastio (CPU) clock
    cs           : in  std_logic;               -- $FFDF100-$FFDF7FF
    fastio_addr  : in  unsigned(11 downto 0);
    fastio_read  : in  std_logic;
    fastio_write : in  std_logic;
    fastio_wdata : in  unsigned(7 downto 0);
    fastio_rdata : out std_logic_vector(7 downto 0)
    );
end mcp;

architecture rtl of mcp is

  constant ID_VALUE  : unsigned(7 downto 0) := x"4D";   -- "M"
  constant VER_VALUE : unsigned(7 downto 0) := x"03";   -- MCP-3
  constant QN : integer := 16;
  constant LIMIT_RESET : unsigned(23 downto 0) := x"100000";

  constant C_FXCHG    : integer := 16#14#;
  constant C_FCONST   : integer := 16#15#;
  constant C_SETCTRL  : integer := 16#16#;
  constant C_SETFLAGS : integer := 16#17#;
  constant C_PEXIT    : integer := 16#18#;
  constant C_PEND     : integer := 16#19#;
  constant C_NREGOPS  : integer := 16#1A#;
  constant C_VNEXT    : integer := 16#1A#;     -- MCP-3
  constant C_VPASS    : integer := 16#1B#;
  constant C_VEND     : integer := 16#1E#;
  constant C_VCLIP    : integer := 16#1C#;
  constant C_CORE_FMA : integer := 16#1E#;     -- the core's a x b + c

  -- what a command did (dispatch)
  constant X_OK   : integer := 0;
  constant X_EXIT : integer := 1;               -- PEXIT taken (in a program)
  constant X_END  : integer := 2;               -- PEND (in a program)
  constant X_BAD  : integer := 3;               -- a reserved command
  constant X_WAIT : integer := 4;               -- not yet: a result it needs is still to come
  constant X_SKIP : integer := 5;               -- PSKIP taken (in a program): skip the next skipn

  -- the core's operations the scoreboard needs to know
  constant C_CORE_CMP   : integer := 16#07#;
  constant C_CORE_CLASS : integer := 16#0F#;
  constant C_CORE_TOI   : integer := 16#10#;
  constant C_CORE_TOI16 : integer := 16#12#;
  constant C_CORE_ADD   : integer := 16#01#;
  constant C_CORE_SUB   : integer := 16#02#;
  constant C_CORE_MUL   : integer := 16#04#;
  constant C_CORE_DIV   : integer := 16#05#;
  constant C_CORE_SQRT  : integer := 16#0A#;
  constant C_CORE_MOVE  : integer := 16#00#;
  constant C_CORE_CONST : integer := 16#15#;

  -- the wide forms of stage 3b
  constant W_VMOVE  : integer := 16#10#;
  constant W_VSCALE : integer := 16#14#;
  constant W_VDOT3  : integer := 16#15#;
  constant W_VDOT4  : integer := 16#16#;
  constant W_VCROSS : integer := 16#17#;
  constant W_VNORM3 : integer := 16#18#;
  constant W_MLOAD  : integer := 16#20#;
  constant W_MSTORE : integer := 16#21#;
  constant W_MXV    : integer := 16#22#;
  constant W_MTXV   : integer := 16#23#;
  constant W_MMUL   : integer := 16#24#;
  constant W_VIN    : integer := 16#25#;
  constant W_VOUT   : integer := 16#26#;
  constant W_VOUTC  : integer := 16#27#;
  constant W_PSKIP  : integer := 16#28#;
  constant SEQ_VPASS : integer := 16#41#;       -- (VPASS's sequence: not a wide form)

  -- the core's converter (MCP-3): b as it is, 12.4, u16 x 2^16, s16, 16.16, u8 x 2^8
  constant CV_RAW : integer := 16#16#;
  constant CV_124 : integer := 16#17#;
  constant CV_U16 : integer := 16#18#;
  constant CV_S16 : integer := 16#19#;
  constant CV_S32 : integer := 16#1A#;
  constant CV_U8  : integer := 16#1B#;

  -- a micro-operation: the core's op, its operands a and b (a kind and an
  -- index: Vs's, Vt's component, F[t], an F, an M, 1.0, a T, 0), its addend
  -- c (none, a T, a T negated), the T it writes; the last of its sequence
  constant K_VS  : natural := 0;
  constant K_VT  : natural := 1;
  constant K_FT  : natural := 2;
  constant K_F   : natural := 3;
  constant K_M   : natural := 4;
  constant K_ONE : natural := 5;
  constant K_T   : natural := 6;
  constant K_ZERO : natural := 7;
  constant CK_NONE : natural := 0;
  constant CK_T    : natural := 1;
  constant CK_NEGT : natural := 2;
  -- kinds: a core operation; VLD, a vertex field's component into T[dst]
  -- (field fld, its word wd, converted by cvc: 0 as it is, 1-2 s16 low and
  -- high x 2^-VPOSEXP, 4-7 s8 byte n x 2^-7, 8-11 u8 byte n x 2^-8); VST, the
  -- converter's result (op, operand b) into the entry at byte 2 x seq_off +
  -- sk; VCOPY, the vertex's attribute word wd into the entry's word
  -- seq_off + wd
  constant UK_CORE  : natural := 0;
  constant UK_VLD   : natural := 1;
  constant UK_VST   : natural := 2;
  constant UK_VCOPY : natural := 3;
  type uop_t is record
    op           : natural range 0 to 31;
    ak, bk, ck   : natural range 0 to 7;
    ai, bi, ci   : natural range 0 to 15;
    dst          : natural range 0 to 15;
    last         : boolean;
    vk           : natural range 0 to 3;
    fld, wd, sk  : natural range 0 to 3;
    cvc          : natural range 0 to 15;
  end record;
  constant NUOPS : natural := 162;
  type ucode_t is array (0 to NUOPS - 1) of uop_t;

  function uo(op, ak, ai, bk, bi, ck, ci, dst : natural; last : boolean) return uop_t is
    variable r : uop_t;
  begin
    r.op := op; r.ak := ak; r.ai := ai; r.bk := bk; r.bi := bi; r.ck := ck; r.ci := ci;
    r.dst := dst; r.last := last;
    r.vk := UK_CORE; r.fld := 0; r.wd := 0; r.sk := 0; r.cvc := 0;
    return r;
  end function;

  -- a vertex micro-operation (VLD, VCOPY)
  function uv(vk, fld, wd, cvc, dst : natural; last : boolean) return uop_t is
    variable r : uop_t;
  begin
    r := uo(0, K_ONE, 0, K_ONE, 0, CK_NONE, 0, dst, last);
    r.vk := vk; r.fld := fld; r.wd := wd; r.cvc := cvc;
    return r;
  end function;

  -- the sequences, as MCP2.md's "Arithmetic" defines each operation (the
  -- order of the steps chosen so independent ones follow each other)
  function build_ucode return ucode_t is
    variable u : ucode_t := (others => uo(0, 0, 0, 0, 0, 0, 0, 0, true));
    variable n, o, r, c : natural := 0;
  begin
    for v in 0 to 2 loop                          -- VADD, VSUB, VMUL (0, 4, 8): Tk = Vs.k op Vt.k
      if v = 0 then o := C_CORE_ADD; elsif v = 1 then o := C_CORE_SUB; else o := C_CORE_MUL; end if;
      for k in 0 to 3 loop
        u(n) := uo(o, K_VS, k, K_VT, k, CK_NONE, 0, k, k = 3); n := n + 1;
      end loop;
    end loop;
    for k in 0 to 3 loop                          -- VSCALE (12): Tk = Vs.k x Ft
      u(n) := uo(C_CORE_MUL, K_VS, k, K_FT, 0, CK_NONE, 0, k, k = 3); n := n + 1;
    end loop;
    for l in 3 to 4 loop                          -- VDOT3 (16), VDOT4 (19): T0, a product then fused
      u(n) := uo(C_CORE_MUL, K_VS, 0, K_VT, 0, CK_NONE, 0, 0, false); n := n + 1;
      for k in 1 to l - 1 loop
        u(n) := uo(C_CORE_FMA, K_VS, k, K_VT, k, CK_T, 0, 0, k = l - 1); n := n + 1;
      end loop;
    end loop;
    -- VCROSS (23): T3 = +0 (FCONST 0), the products T4-T6, then T0-T2 = fma(.., .., -T)
    u(n) := uo(C_CORE_CONST, K_ONE, 0, K_ZERO, 0, CK_NONE, 0, 3, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 2, K_VT, 1, CK_NONE, 0, 4, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 0, K_VT, 2, CK_NONE, 0, 5, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 1, K_VT, 0, CK_NONE, 0, 6, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 1, K_VT, 2, CK_NEGT, 4, 0, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 2, K_VT, 0, CK_NEGT, 5, 1, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 0, K_VT, 1, CK_NEGT, 6, 2, true); n := n + 1;
    -- VNORM3 (30): T3 = Vs.w (a move), T4 = Vs.xyz . Vs.xyz, T5 = sqrt T4,
    -- T6 = 1 / T5, Tk = Vs.k x T6
    u(n) := uo(C_CORE_MOVE, K_ONE, 0, K_VS, 3, CK_NONE, 0, 3, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 0, K_VS, 0, CK_NONE, 0, 4, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 1, K_VS, 1, CK_T, 4, 4, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 2, K_VS, 2, CK_T, 4, 4, false); n := n + 1;
    u(n) := uo(C_CORE_SQRT, K_ONE, 0, K_T, 4, CK_NONE, 0, 5, false); n := n + 1;
    u(n) := uo(C_CORE_DIV, K_ONE, 0, K_T, 5, CK_NONE, 0, 6, false); n := n + 1;
    for k in 0 to 2 loop
      u(n) := uo(C_CORE_MUL, K_VS, k, K_T, 6, CK_NONE, 0, k, k = 2); n := n + 1;
    end loop;
    -- MXV (39), MTXV (55): Tr = row (column) r of M . Vs, the four rows interleaved
    for tr in 0 to 1 loop
      for k in 0 to 3 loop
        for rr in 0 to 3 loop
          if tr = 0 then o := 4 * rr + k; else o := rr + 4 * k; end if;
          if k = 0 then
            u(n) := uo(C_CORE_MUL, K_M, o, K_VS, k, CK_NONE, 0, rr, false);
          else
            u(n) := uo(C_CORE_FMA, K_M, o, K_VS, k, CK_T, rr, rr, k = 3 and rr = 3);
          end if;
          n := n + 1;
        end loop;
      end loop;
    end loop;
    -- MMUL (71): T(4r + c) = row r of M . column c of F, the sixteen interleaved
    for k in 0 to 3 loop
      for e in 0 to 15 loop
        r := e / 4; c := e mod 4;
        if k = 0 then
          u(n) := uo(C_CORE_MUL, K_M, 4 * r, K_F, c, CK_NONE, 0, e, false);
        else
          u(n) := uo(C_CORE_FMA, K_M, 4 * r + k, K_F, c + 4 * k, CK_T, e, e, k = 3 and e = 15);
        end if;
        n := n + 1;
      end loop;
    end loop;
    for k in 0 to 3 loop                          -- VMOVE (135): Tk = Vs.k (moves)
      u(n) := uo(C_CORE_MOVE, K_ONE, 0, K_VS, k, CK_NONE, 0, k, k = 3); n := n + 1;
    end loop;
    -- VIN (139: s16 position, 143: FP32 position, 147: normal, 151: colour):
    -- T0-T3, then Vd = T0-T3 as any vector result
    u(n) := uv(UK_VLD, 0, 0, 1, 0, false); n := n + 1;
    u(n) := uv(UK_VLD, 0, 0, 2, 1, false); n := n + 1;
    u(n) := uv(UK_VLD, 0, 1, 1, 2, false); n := n + 1;
    u(n) := uo(C_CORE_MOVE, K_ONE, 0, K_ONE, 0, CK_NONE, 0, 3, true); n := n + 1;
    for k in 0 to 2 loop
      u(n) := uv(UK_VLD, 0, k, 0, k, false); n := n + 1;
    end loop;
    u(n) := uo(C_CORE_MOVE, K_ONE, 0, K_ONE, 0, CK_NONE, 0, 3, true); n := n + 1;
    for k in 0 to 2 loop
      u(n) := uv(UK_VLD, 1, 0, 4 + k, k, false); n := n + 1;
    end loop;
    u(n) := uo(C_CORE_MOVE, K_ONE, 0, K_ZERO, 0, CK_NONE, 0, 3, true); n := n + 1;
    for k in 0 to 3 loop
      u(n) := uv(UK_VLD, 2, 0, 8 + k, k, k = 3); n := n + 1;
    end loop;
    for k in 0 to 3 loop                          -- VOUTC (155): Vs.k as a byte
      u(n) := uo(CV_U8, K_ONE, 0, K_VS, k, CK_NONE, 0, 0, k = 3);
      u(n).vk := UK_VST; u(n).sk := k; n := n + 1;
    end loop;
    for k in 2 downto 0 loop                      -- VPASS (159): the attribute words, from 162 - n
      u(n) := uv(UK_VCOPY, 3, k, 0, 0, k = 0); n := n + 1;
    end loop;
    assert n = NUOPS report "UCODE: " & integer'image(n) & " entries" severity failure;
    return u;
  end function;
  constant UCODE : ucode_t := build_ucode;

  -- where each sequence starts
  function ustart(op : integer) return natural is
  begin
    case op is
      when 16#11# => return 0;                    -- VADD
      when 16#12# => return 4;                    -- VSUB
      when 16#13# => return 8;                    -- VMUL
      when 16#14# => return 12;                   -- VSCALE
      when 16#15# => return 16;                   -- VDOT3
      when 16#16# => return 19;                   -- VDOT4
      when 16#17# => return 23;                   -- VCROSS
      when 16#18# => return 30;                   -- VNORM3
      when 16#22# => return 39;                   -- MXV
      when 16#23# => return 55;                   -- MTXV
      when 16#10# => return 135;                  -- VMOVE
      when 16#27# => return 155;                  -- VOUTC
      when others => return 71;                   -- MMUL
    end case;
  end function;

  function b2l(b : boolean) return std_logic is
  begin
    if b then return '1'; end if;
    return '0';
  end function;

  -- a command: its form (0 register, 1 memory, 2 wide, 3 reserved), opcode,
  -- regs (or data) byte, the memory operand (a wide form's t byte in bits 0-7)
  type cmd_t is record
    form : unsigned(1 downto 0);
    op   : unsigned(7 downto 0);
    regs : unsigned(7 downto 0);
    v    : std_logic_vector(31 downto 0);
  end record;
  constant CMD_ZERO : cmd_t := (form => "00", op => (others => '0'), regs => (others => '0'), v => (others => '0'));
  type queue_t is array (0 to QN - 1) of cmd_t;
  type fregs_t is array (0 to 15) of std_logic_vector(31 downto 0);
  type u8x6_t is array (0 to 5) of unsigned(7 downto 0);

  -- the stream's format: a command's length from its first byte
  function cmd_len(first : unsigned(7 downto 0)) return integer is
  begin
    if first >= x"80" and first <= x"8F" then
      return 6;
    elsif first = x"90" then
      return 4;
    end if;
    return 2;
  end function;

  -- a command from its bytes (b0 the first, b1-b5 as collected, last the final byte)
  function cmd_of(buf : u8x6_t; n : integer; last : unsigned(7 downto 0)) return cmd_t is
    variable c : cmd_t := CMD_ZERO;
  begin
    c.op := buf(0);
    if n = 6 then
      c.form := "01";
      c.regs := buf(1);
      c.v := std_logic_vector(last) & std_logic_vector(buf(4)) & std_logic_vector(buf(3))
             & std_logic_vector(buf(2));
    elsif n = 4 then
      c.form := "10";
      c.op := buf(1);
      c.regs := buf(2);
      c.v(7 downto 0) := std_logic_vector(last);
    else
      if buf(0) < x"80" then c.form := "00"; else c.form := "11"; end if;
      c.regs := last;
    end if;
    return c;
  end function;

  function pack(c : cmd_t) return std_logic_vector is
  begin
    return std_logic_vector(c.form) & std_logic_vector(c.op) & std_logic_vector(c.regs) & c.v;
  end function;

  function unpack(w : std_logic_vector(49 downto 0)) return cmd_t is
    variable c : cmd_t;
  begin
    c.form := unsigned(w(49 downto 48));
    c.op := unsigned(w(47 downto 40));
    c.regs := unsigned(w(39 downto 32));
    c.v := w(31 downto 0);
    return c;
  end function;

  -- the fastio side
  constant Z31V : std_logic_vector(30 downto 0) := (others => '0');
  constant Z23V : std_logic_vector(22 downto 0) := (others => '0');

  -- the vertex format (MCP3.md, in words): the position's 2 (s16) or 3
  -- (FP32), a field's offset (0 position, 1 normal, 2 colour, 3 the
  -- attributes), the vertex's size
  function vf_pos(f : unsigned(4 downto 0)) return natural is
  begin
    if f(0) = '1' then return 3; end if;
    return 2;
  end function;
  function vf_off(f : unsigned(4 downto 0); fld : natural) return natural is
    variable o : natural;
  begin
    o := vf_pos(f);
    if fld = 0 then return 0; end if;
    if fld = 1 then return o; end if;
    if f(1) = '1' then o := o + 1; end if;
    if fld = 2 then return o; end if;
    if f(2) = '1' then o := o + 1; end if;
    return o;
  end function;
  function vf_size(f : unsigned(4 downto 0)) return natural is
  begin
    return vf_off(f, 3) + to_integer(f(4 downto 3));
  end function;

  -- an integer, sign and 16-bit magnitude, times 2^-sc as FP32: exact
  function i2f(neg : std_logic; mag : unsigned(15 downto 0); sc : natural) return std_logic_vector is
    variable lz : natural := 0;
    variable m : unsigned(15 downto 0);
  begin
    if mag = 0 then
      return x"00000000";
    end if;
    for i in 15 downto 0 loop
      if mag(i) = '1' then exit; end if;
      lz := lz + 1;
    end loop;
    m := shift_left(mag, lz);
    return neg & std_logic_vector(to_unsigned(127 + 15 - lz - sc, 8)) & std_logic_vector(m(14 downto 0))
           & x"00";
  end function;

  -- a VLD's conversion of the vertex array's word w (cvc: as for uop_t)
  function vconv(w : std_logic_vector(31 downto 0); cvc : natural; pexp : unsigned(3 downto 0))
    return std_logic_vector is
    variable h : signed(15 downto 0);
    variable b : std_logic_vector(7 downto 0);
    variable a17 : signed(16 downto 0);
    variable n : natural;
  begin
    case cvc is
      when 1 | 2 =>                                   -- s16 x 2^-VPOSEXP
        if cvc = 1 then h := signed(w(15 downto 0)); else h := signed(w(31 downto 16)); end if;
        a17 := abs(resize(h, 17));
        return i2f(h(15), unsigned(a17(15 downto 0)), to_integer(pexp));
      when 4 to 7 =>                                  -- s8 x 2^-7
        n := cvc - 4;
        b := w(8 * n + 7 downto 8 * n);
        a17 := abs(resize(signed(b), 17));
        return i2f(b(7), unsigned(a17(15 downto 0)), 7);
      when 8 to 11 =>                                 -- u8 x 2^-8
        n := cvc - 8;
        return i2f('0', resize(unsigned(w(8 * n + 7 downto 8 * n)), 16), 8);
      when others =>
        return w;
    end case;
  end function;

  -- a < b for two FP32 values, neither a NaN (+0 = -0)
  function flt_lt(a, b : std_logic_vector(31 downto 0)) return boolean is
  begin
    if a(30 downto 0) = Z31V and b(30 downto 0) = Z31V then
      return false;
    elsif a(31) /= b(31) then
      return a(31) = '1';
    elsif a(31) = '0' then
      return unsigned(a(30 downto 0)) < unsigned(b(30 downto 0));
    else
      return unsigned(a(30 downto 0)) > unsigned(b(30 downto 0));
    end if;
  end function;

  -- VCLIP's codes for (x, y, z, w) (MCP3.md): x < -w, x > w, y < -w, y > w,
  -- z < 0, z > w, w <= 0; a NaN anywhere: bit 7 alone
  function clip_codes(x, y, z, w : std_logic_vector(31 downto 0)) return std_logic_vector is
    variable c : std_logic_vector(7 downto 0) := x"00";
    variable nw : std_logic_vector(31 downto 0);
    function isnan(v : std_logic_vector(31 downto 0)) return boolean is
    begin
      return v(30 downto 23) = x"FF" and v(22 downto 0) /= Z23V;
    end function;
  begin
    if isnan(x) or isnan(y) or isnan(z) or isnan(w) then
      return x"80";
    end if;
    nw := (not w(31)) & w(30 downto 0);
    if flt_lt(x, nw) then c(0) := '1'; end if;
    if flt_lt(w, x) then c(1) := '1'; end if;
    if flt_lt(y, nw) then c(2) := '1'; end if;
    if flt_lt(w, y) then c(3) := '1'; end if;
    if flt_lt(z, x"00000000") then c(4) := '1'; end if;
    if flt_lt(w, z) then c(5) := '1'; end if;
    if not flt_lt(x"00000000", w) then c(6) := '1'; end if;
    return c;
  end function;

  signal last_rd, last_wr : std_logic := '0';
  signal last_addr        : unsigned(11 downto 0) := (others => '0');
  signal rd_new, wr_new   : std_logic;
  signal port_latch       : unsigned(7 downto 0) := (others => '0');
  signal flatch, mlatch   : std_logic_vector(31 downto 0) := (others => '0');   -- 4-byte reads
  signal plat             : std_logic_vector(49 downto 0) := (others => '0');   -- MPREAD's entry
  signal cntlatch         : unsigned(7 downto 0) := (others => '0');            -- MPCNT's high byte
  signal mbuf             : std_logic_vector(23 downto 0) := (others => '0');   -- a memory form's bytes 0-2
  signal wbuf             : unsigned(7 downto 0) := (others => '0');            -- a wide form's first byte
  signal sbuf, lbuf       : u8x6_t := (others => (others => '0'));              -- stream, MPLOAD
  signal sn, ln           : integer range 0 to 5 := 0;

  -- the queue
  signal q : queue_t := (others => CMD_ZERO);
  signal qhead, qtail : unsigned(3 downto 0) := (others => '0');
  signal qcount : integer range 0 to QN := 0;

  -- the unit's state
  signal f : fregs_t := (others => (others => '0'));
  signal mint_r : std_logic_vector(31 downto 0) := (others => '0');
  signal mcond_r : std_logic_vector(7 downto 0) := (others => '0');
  signal mflags_r : std_logic_vector(4 downto 0) := (others => '0');
  signal mctrl_x : unsigned(1 downto 0) := "00";                                -- MCTRL as executed
  signal overrun, badop, aborted : std_logic := '0';
  -- the scoreboard: a result still to come for F0-F15, MCOND, MINT
  signal pendf : std_logic_vector(15 downto 0) := (others => '0');
  signal pend_cond, pend_mint : std_logic := '0';
  -- vectors and matrices: the M bank; the temporaries and their scoreboard;
  -- the sequence running (its command, the next step, all steps issued)
  signal mreg, treg : fregs_t := (others => (others => '0'));
  signal pendt : std_logic_vector(15 downto 0) := (others => '0');
  signal seq_active, seq_issued : std_logic := '0';
  signal upc : natural range 0 to NUOPS - 1 := 0;
  signal seq_op : natural range 0 to 127 := 0;
  signal seq_vs, seq_vt, seq_vd : natural range 0 to 3 := 0;
  signal seq_t, seq_d : natural range 0 to 15 := 0;
  -- FXCHG's second half: Fd and Fs written with each other's values a clock
  -- after it issues (xa: Fd's value then, xb: Fs's)
  signal xw : std_logic := '0';
  signal xd, xs : natural range 0 to 15 := 0;
  signal xa, xb : std_logic_vector(31 downto 0) := (others => '0');
  signal seq_off : natural range 0 to 15 := 0;               -- VOUTC's t, VPASS's word

  -- the vertex path (MCP-3): the registers
  signal vinptr : unsigned(13 downto 0) := (others => '0');   -- VINDATA's byte address
  signal vinidx : unsigned(11 downto 0) := (others => '0');   -- the vertex VIN reads, a word address
  signal vfmt : unsigned(4 downto 0) := (others => '0');
  signal vposexp : unsigned(3 downto 0) := (others => '0');
  signal vtxidx : unsigned(9 downto 0) := (others => '0');
  signal vbank : unsigned(3 downto 0) := (others => '0');
  -- the vertex array and the result buffer: four byte lanes each
  type lane8_t is array (0 to 3) of std_logic_vector(7 downto 0);
  signal va_we, rb_we : std_logic_vector(3 downto 0) := (others => '0');
  signal va_waddr, va_raddr : unsigned(11 downto 0) := (others => '0');
  signal va_wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal va_rd, rb_wd, rb_rd : lane8_t;
  signal rb_waddr, rb_raddr : unsigned(12 downto 0) := (others => '0');
  -- the stores and copies into the result buffer, two clocks from issue
  -- to their data (the converter's result, or the vertex array's word)
  type sd_t is record
    valid, copy, hi, isimm : std_logic;              -- (data: the converter's, a copy's, or imm)
    imm : std_logic_vector(7 downto 0);
    entry : unsigned(9 downto 0);
    boff : unsigned(4 downto 0);
    width : natural range 1 to 4;
  end record;
  constant SD_NONE : sd_t := (valid => '0', copy => '0', hi => '0', isimm => '0', imm => (others => '0'),
                              entry => (others => '0'), boff => (others => '0'), width => 1);
  signal sd_a, sd_b : sd_t := SD_NONE;
  -- the loads into T, two clocks from issue to the vertex array's word
  type vd_t is record
    valid : std_logic;
    dst : natural range 0 to 15;
    cvc : natural range 0 to 15;
  end record;
  signal vd_a, vd_b : vd_t := (valid => '0', dst => 0, cvc => 0);

  -- programs
  signal pm_we : std_logic := '0';
  signal pm_waddr, pm_raddr : unsigned(8 downto 0) := (others => '0');
  signal pm_wdata, pm_rdata : std_logic_vector(49 downto 0);
  signal mpptr : unsigned(8 downto 0) := (others => '0');
  signal mpcnt : unsigned(15 downto 0) := (others => '0');
  signal mperr : unsigned(2 downto 0) := (others => '0');
  signal mplimit : unsigned(23 downto 0) := LIMIT_RESET;
  signal prog : std_logic := '0';                                               -- a program running
  signal pc, pstart : unsigned(8 downto 0) := (others => '0');
  signal ptotal, ppass : unsigned(16 downto 0) := (others => '0');
  signal pexec, plimit : unsigned(23 downto 0) := (others => '0');
  -- the fetch: fp is the address being read (pc + 1 while running on, so
  -- pm_rdata is the entry at pc); after a jump, a clock to refill; ir holds
  -- the entry at pc while it waits
  signal fp : unsigned(8 downto 0) := (others => '0');
  signal refill, ir_valid : std_logic := '0';
  signal ir : std_logic_vector(49 downto 0) := (others => '0');
  signal abort_req : std_logic := '0';

  -- the core: what goes in (a command issued, for the clock after), what comes back
  signal c_start, c_abort : std_logic := '0';
  signal c_op : unsigned(4 downto 0) := (others => '0');
  signal c_a, c_b, c_c : std_logic_vector(31 downto 0) := (others => '0');
  signal c_rm : unsigned(1 downto 0) := "00";
  signal c_tag : unsigned(7 downto 0) := (others => '0');
  signal it_busy, fm_done, sh_done, it_done : std_logic;
  signal fm_tag, sh_tag, it_tag : unsigned(7 downto 0);
  signal fm_r, sh_r, it_r, it_mint : std_logic_vector(31 downto 0);
  signal sh_cond : std_logic_vector(7 downto 0);
  signal fm_flags, sh_flags, it_flags : std_logic_vector(4 downto 0);
  signal sh_wf, sh_wc, it_wf, it_wm : std_logic;
  signal cv_done : std_logic;
  signal cv_tag : unsigned(7 downto 0);
  signal cv_r : std_logic_vector(31 downto 0);
  signal cv_flags : std_logic_vector(4 downto 0);

  signal busy : std_logic;
  signal rbyte : unsigned(7 downto 0);

begin

  core : entity work.mcp_fpu
    port map (clock => clock, abort => c_abort, start => c_start, op => c_op, a => c_a, b => c_b, c => c_c,
              rm => c_rm, tag => c_tag, it_busy => it_busy,
              fm_done => fm_done, fm_tag => fm_tag, fm_r => fm_r, fm_flags => fm_flags,
              sh_done => sh_done, sh_tag => sh_tag, sh_r => sh_r, sh_cond => sh_cond,
              sh_flags => sh_flags, sh_wf => sh_wf, sh_wc => sh_wc,
              it_done => it_done, it_tag => it_tag, it_r => it_r, it_mint => it_mint,
              it_flags => it_flags, it_wf => it_wf, it_wm => it_wm,
              cv_done => cv_done, cv_tag => cv_tag, cv_r => cv_r, cv_flags => cv_flags);

  -- the program memory: written by MPLOAD; read by the program (at pc) or by
  -- MPREAD (at MPPTR) when no program runs
  progmem : entity work.mcp_ram generic map (AW => 9, DW => 50)
    port map (clock => clock, we => pm_we, waddr => pm_waddr, wdata => pm_wdata,
              raddr => pm_raddr, rdata => pm_rdata);
  pm_raddr <= fp when prog = '1' else mpptr;

  -- the vertex array (written by VINDATA, read by VLD and VCOPY) and the
  -- result buffer (written by stores and copies, read through the window:
  -- its address follows the bus's, the CPU's wait state covers the clock)
  lanes : for j in 0 to 3 generate
    va_ram : entity work.mcp_ram generic map (AW => 12, DW => 8)
      port map (clock => clock, we => va_we(j), waddr => va_waddr, wdata => va_wdata,
                raddr => va_raddr, rdata => va_rd(j));
    rb_ram : entity work.mcp_ram generic map (AW => 13, DW => 8)
      port map (clock => clock, we => rb_we(j), waddr => rb_waddr, wdata => rb_wd(j),
                raddr => rb_raddr, rdata => rb_rd(j));
  end generate;
  rb_raddr <= vbank & fastio_addr(10 downto 2);

  rd_new <= cs and fastio_read and ((not last_rd) or b2l(fastio_addr /= last_addr));
  wr_new <= cs and fastio_write and ((not last_wr) or b2l(fastio_addr /= last_addr));
  busy <= b2l(qcount /= 0) or prog or b2l(pendf /= x"0000") or pend_cond or pend_mint or seq_active
          or sd_a.valid or sd_b.valid or b2l(rb_we /= "0000");

  process (clock)
    variable cmd : cmd_t;
    variable enq, deq : boolean;
    variable sa : unsigned(7 downto 0);
    variable k, n : integer;
    variable qc : integer range 0 to QN + 1;
    variable res : integer;
    variable cnt : unsigned(16 downto 0);
    -- the unit's state as this clock's results leave it: what gets written
    -- back at the end of the clock
    variable fv : fregs_t;
    variable pv : std_logic_vector(15 downto 0);
    variable pcd, pmt : std_logic;
    variable mcv : std_logic_vector(7 downto 0);
    variable miv : std_logic_vector(31 downto 0);
    variable flv : std_logic_vector(4 downto 0);
    variable stall : boolean;
    variable tv, mv : fregs_t;                           -- T0-T15, M0-M15 as this clock leaves them
    variable tp : std_logic_vector(15 downto 0);
    variable u : uop_t;
    variable ua, ub, uc : std_logic_vector(31 downto 0);
    variable ready : boolean;
    -- the clock's reads: the command (or step) in line picks the indices
    -- first, then each port reads one register, a result landing now taking
    -- its place (three F ports, two T ports, one M port)
    variable cand : cmd_t;
    variable cd, cs_i, ct : natural range 0 to 15;
    variable fa_i, fb_i, fc_i : natural range 0 to 15;
    variable ra, rb, rc, rtb, rtc, rma : std_logic_vector(31 downto 0);
    variable wv : std_logic_vector(31 downto 0);
    variable skipn : natural range 0 to 15;
    variable cc : std_logic_vector(7 downto 0);
    variable target : unsigned(9 downto 0);

    function bit_of(i : integer) return std_logic_vector is
      variable v : std_logic_vector(15 downto 0) := (others => '0');
    begin
      v(i) := '1';
      return v;
    end function;

    -- V0-V3's F registers
    function vmask(i : integer) return std_logic_vector is
      variable v : std_logic_vector(15 downto 0) := (others => '0');
    begin
      v(4 * (i mod 4) + 3 downto 4 * (i mod 4)) := "1111";
      return v;
    end function;

    -- an F register as a command issued now sees it
    impure function rdf(i : natural) return std_logic_vector is
      variable v : std_logic_vector(31 downto 0);
    begin
      v := f(i);
      if fm_done = '1' and fm_tag(4) = '0' and to_integer(fm_tag(3 downto 0)) = i then
        v := fm_r;
      elsif sh_done = '1' and sh_wf = '1' and sh_tag(4) = '0' and to_integer(sh_tag(3 downto 0)) = i then
        v := sh_r;
      elsif it_done = '1' and it_wf = '1' and it_tag(4) = '0' and to_integer(it_tag(3 downto 0)) = i then
        v := it_r;
      elsif xw = '1' and xd = i then
        v := xb;
      elsif xw = '1' and xs = i then
        v := xa;
      end if;
      return v;
    end function;

    -- a T register as a step issued now sees it
    impure function rdt(i : natural) return std_logic_vector is
      variable v : std_logic_vector(31 downto 0);
    begin
      v := treg(i);
      if fm_done = '1' and fm_tag(4) = '1' and to_integer(fm_tag(3 downto 0)) = i then
        v := fm_r;
      elsif sh_done = '1' and sh_wf = '1' and sh_tag(4) = '1' and to_integer(sh_tag(3 downto 0)) = i then
        v := sh_r;
      elsif it_done = '1' and it_wf = '1' and it_tag(4) = '1' and to_integer(it_tag(3 downto 0)) = i then
        v := it_r;
      end if;
      return v;
    end function;

    -- a micro-operation's F operand: its register
    impure function fidx(k, i : natural) return natural is
    begin
      case k is
        when K_VS => return 4 * seq_vs + i mod 4;
        when K_VT => return 4 * seq_vt + i mod 4;
        when K_FT => return seq_t;
        when others => return i;
      end case;
    end function;

    -- a core operation into the core, once nothing it reads or writes (the
    -- F registers in need; MCOND or MINT if it writes them) has a result
    -- still to come, and its unit can take it; else stall
    procedure issue(cop : integer; need : std_logic_vector(15 downto 0);
                    va, vb, vc : std_logic_vector(31 downto 0); d : integer) is
      variable un : natural;
      variable wc, wm, wn : boolean;
    begin
      un := fpu_unit(to_unsigned(cop, 5));
      wc := cop = C_CORE_CMP or cop = C_CORE_CLASS;
      wm := cop >= C_CORE_TOI and cop <= C_CORE_TOI16;
      wn := un = U_CV;                                   -- (the converter: into the result buffer)
      if (pv and need) /= x"0000" or (wc and pcd = '1') or (wm and pmt = '1')
         or (un = U_ITER and it_busy = '1') then
        stall := true;
      else
        c_start <= '1';
        c_op <= to_unsigned(cop, 5);
        c_a <= va;
        c_b <= vb;
        c_c <= vc;
        c_rm <= mctrl_x;                                 -- (the mode in effect, taken now)
        c_tag <= to_unsigned(d, 8);
        if wc then
          pcd := '1';
        elsif wm then
          pmt := '1';
        elsif not wn then
          pv(d) := '1';
        end if;
      end if;
    end procedure;

    -- a command, from the queue or a program: into the core, or done at once
    -- (control, flags, PEXIT, PEND, a reserved command); X_WAIT if it must
    -- wait for a result. Its operands are this clock's reads: ra = F[d]
    -- (a wide form's F[s]), rb = F[s] (a wide form's F[t]), rc = a wide
    -- form's F[d]
    procedure dispatch(cm : cmd_t; in_prog : boolean; r : out integer) is
      variable d, s, mf, t, cop : integer;
      variable rv : integer;              -- (an out parameter can't be read in Vivado)
    begin
      rv := X_OK;
      stall := false;
      d := to_integer(cm.regs(7 downto 4));
      s := to_integer(cm.regs(3 downto 0));
      if cm.form = "00" then
        if cm.op = C_SETCTRL then
          mctrl_x <= cm.regs(1 downto 0);
        elsif cm.op = C_SETFLAGS then                    -- after every flag still to come (the
          if pv /= x"0000" or pcd = '1' or pmt = '1'     --  converter's too: stores mark nothing)
             or sd_a.valid = '1' or sd_b.valid = '1' then
            stall := true;
          else
            flv := std_logic_vector(cm.regs(4 downto 0));
          end if;
        elsif cm.op = C_FXCHG then                       -- written back next clock (xw)
          if pv(d) = '1' or pv(s) = '1' then
            stall := true;
          else
            xw <= '1';
            xd <= d;
            xs <= s;
            xa <= ra;
            xb <= rb;
            pv(d) := '1';
            pv(s) := '1';
          end if;
        elsif cm.op = C_PEXIT then
          if in_prog then
            if pcd = '1' then                            -- (the FCMP before it still to come)
              stall := true;
            elsif (unsigned(mcv) and cm.regs) /= 0 then
              rv := X_EXIT;
            end if;
          end if;
        elsif cm.op = C_PEND then
          if in_prog then
            rv := X_END;
          end if;
        elsif cm.op = C_VNEXT then                       -- the next vertex
          vinidx <= vinidx + vf_size(vfmt);
        elsif cm.op = C_VEND then                        -- the next entry
          vtxidx <= vtxidx + 1;
        elsif cm.op = C_VCLIP then                       -- Vs's clip codes, from the settled registers
          if (pendf and vmask(s)) /= x"0000" or (pv and vmask(s)) /= x"0000" or pcd = '1' then
            stall := true;
          else
            cc := clip_codes(f(4 * (s mod 4)), f(4 * (s mod 4) + 1), f(4 * (s mod 4) + 2),
                             f(4 * (s mod 4) + 3));
            mcv := cc;
            sd_a.valid <= '1';
            sd_a.copy <= '0';
            sd_a.hi <= '0';
            sd_a.isimm <= '1';
            sd_a.imm <= cc;
            sd_a.entry <= vtxidx;
            sd_a.boff <= to_unsigned(30, 5);
            sd_a.width <= 1;
          end if;
        elsif cm.op = C_VPASS then                       -- the attribute words, a sequence of copies
          if vfmt(4 downto 3) /= "00" then
            seq_active <= '1';
            seq_issued <= '0';
            upc <= 162 - to_integer(vfmt(4 downto 3));
            seq_op <= SEQ_VPASS;
            seq_off <= to_integer(cm.regs(2 downto 0));
          end if;
        elsif cm.op >= C_NREGOPS then
          rv := X_BAD;
        elsif cm.op = C_FCONST then
          issue(C_FCONST, bit_of(d), ra, std_logic_vector(resize(cm.regs(3 downto 0), 32)),
                x"00000000", d);
        else
          issue(to_integer(cm.op), bit_of(d) or bit_of(s), ra, rb, x"00000000", d);
        end if;
      elsif cm.form = "01" then
        mf := to_integer(cm.op(3 downto 0));
        if mf >= 14 then                                 -- (PRUN in a program, form 15)
          rv := X_BAD;
        else
          case mf is
            when 11 => cop := 16#13#;                    -- FRECIP
            when 12 => cop := 16#1C#;                    -- FILD
            when 13 => cop := 16#1D#;                    -- FXLD
            when others => cop := mf;                    -- forms 0-10: the register forms' 0-10
          end case;
          issue(cop, bit_of(d), ra, cm.v, x"00000000", d);
        end if;
      elsif cm.form = "10" then                          -- wide forms: Fd = Fs op Ft
        t := to_integer(unsigned(cm.v(7 downto 4)));
        case to_integer(cm.op) is
          when W_VMOVE to W_VNORM3 | W_MXV | W_MTXV =>   -- a sequence, once its registers are settled
            if (pv and (vmask(s) or vmask(t) or vmask(d) or bit_of(t) or bit_of(d))) /= x"0000" then
              stall := true;
            else
              seq_active <= '1';
              seq_issued <= '0';
              upc <= ustart(to_integer(cm.op));
              seq_op <= to_integer(cm.op);
              seq_vs <= s mod 4;
              seq_vt <= t mod 4;
              seq_vd <= d mod 4;
              seq_t <= t;
              seq_d <= d;
            end if;
          when W_MLOAD | W_MSTORE =>                     -- every F register, settled (nothing landing now)
            if pendf /= x"0000" or pv /= x"0000" then
              stall := true;
            elsif cm.op = W_MLOAD then
              mv := f;
            else
              fv := mreg;
            end if;
          when W_MMUL =>
            if pv /= x"0000" then
              stall := true;
            else
              seq_active <= '1';
              seq_issued <= '0';
              upc <= ustart(W_MMUL);
              seq_op <= W_MMUL;
            end if;
          when W_PSKIP =>                                -- in a program: skip t on MCOND and (d << 4 | s)
            if in_prog then
              if pcd = '1' then
                stall := true;
              elsif (unsigned(mcv) and cm.regs) /= 0 then
                rv := X_SKIP;
                skipn := t;
              end if;
            end if;
          when W_VIN =>                                  -- Vd = a vertex field: a sequence of loads
            if t > 2 or (t = 1 and vfmt(1) = '0') or (t = 2 and vfmt(2) = '0') then
              rv := X_BAD;
            elsif (pv and vmask(d)) /= x"0000" then
              stall := true;
            else
              seq_active <= '1';
              seq_issued <= '0';
              if t = 0 and vfmt(0) = '1' then
                upc <= 143;
              elsif t = 0 then
                upc <= 139;
              elsif t = 1 then
                upc <= 147;
              else
                upc <= 151;
              end if;
              seq_op <= W_VIN;
              seq_vd <= d mod 4;
            end if;
          when W_VOUT =>                                 -- Fs in format d at byte 2t: the converter
            if d > 5 or ((d = 0 or d = 5) and t mod 2 = 1) then
              rv := X_BAD;
            else
              case d is
                when 0 | 1 => cop := CV_RAW;
                when 2 => cop := CV_124;
                when 3 => cop := CV_U16;
                when 4 => cop := CV_S16;
                when others => cop := CV_S32;
              end case;
              issue(cop, bit_of(s), x"00000000", ra, x"00000000", 0);
              if not stall then
                sd_a.valid <= '1';
                sd_a.copy <= '0';
                sd_a.hi <= b2l(d = 1);
                sd_a.entry <= vtxidx;
                sd_a.boff <= to_unsigned(2 * t, 5);
                if d = 0 or d = 5 then sd_a.width <= 4; else sd_a.width <= 2; end if;
              end if;
            end if;
          when W_VOUTC =>                                -- Vs as four bytes: a sequence of stores
            if t mod 2 = 1 then
              rv := X_BAD;
            elsif (pv and vmask(s)) /= x"0000" then
              stall := true;
            else
              seq_active <= '1';
              seq_issued <= '0';
              upc <= 155;
              seq_op <= W_VOUTC;
              seq_vs <= s mod 4;
              seq_off <= t;
            end if;
          when 0 => issue(16#01#, bit_of(d) or bit_of(s) or bit_of(t), ra, rb, rc, d);  -- FADD3
          when 1 => issue(16#02#, bit_of(d) or bit_of(s) or bit_of(t), ra, rb, rc, d);  -- FSUB3
          when 2 => issue(16#04#, bit_of(d) or bit_of(s) or bit_of(t), ra, rb, rc, d);  -- FMUL3
          when 3 =>                                                                      -- FMA: Fs x Ft + Fd
            issue(C_CORE_FMA, bit_of(d) or bit_of(s) or bit_of(t), ra, rb, rc, d);
          when 4 =>                                                                      -- FMS: -Fs x Ft + Fd
            issue(C_CORE_FMA, bit_of(d) or bit_of(s) or bit_of(t), (not ra(31)) & ra(30 downto 0),
                  rb, rc, d);
          when others => rv := X_BAD;
        end case;
      else
        rv := X_BAD;                                     -- (a reserved stream command)
      end if;
      if stall then
        rv := X_WAIT;
      end if;
      r := rv;
    end procedure;

  begin
    if rising_edge(clock) then
      last_rd <= cs and fastio_read;
      last_wr <= cs and fastio_write;
      last_addr <= fastio_addr;
      c_start <= '0';
      c_abort <= '0';
      pm_we <= '0';
      va_we <= "0000";
      rb_we <= "0000";
      sd_b <= sd_a;
      sd_a <= SD_NONE;
      vd_b <= vd_a;
      vd_a.valid <= '0';

      -- the commands the bus brings (one access a clock: at most one command)
      enq := false;
      cmd := CMD_ZERO;
      if wr_new = '1' then
        sa := fastio_addr(7 downto 0);
        if fastio_addr(11 downto 8) = "0000" then          -- the vertex page, $0xx (written now)
          if sa(7 downto 2) = "000000" then                -- VINDATA, $000-$003: all one port
            va_we(to_integer(vinptr(1 downto 0))) <= '1';
            va_waddr <= vinptr(13 downto 2);
            va_wdata <= std_logic_vector(fastio_wdata);
            vinptr <= vinptr + 1;
          elsif sa = x"04" then
            vinptr(7 downto 0) <= fastio_wdata;
          elsif sa = x"05" then
            vinptr(13 downto 8) <= fastio_wdata(5 downto 0);
          elsif sa = x"06" then                            -- (VINIDX: a word address)
            vinidx(5 downto 0) <= fastio_wdata(7 downto 2);
          elsif sa = x"07" then
            vinidx(11 downto 6) <= fastio_wdata(5 downto 0);
          elsif sa = x"08" then
            vfmt <= fastio_wdata(4 downto 0);
          elsif sa = x"09" then
            vposexp <= fastio_wdata(3 downto 0);
          elsif sa = x"0C" then
            vtxidx(7 downto 0) <= fastio_wdata;
          elsif sa = x"0D" then
            vtxidx(9 downto 8) <= fastio_wdata(1 downto 0);
          elsif sa = x"0E" then
            vbank <= fastio_wdata(3 downto 0);
          end if;
        elsif fastio_addr(11 downto 8) = "0001" then       -- the control page, $1xx
          if sa >= x"80" then                              -- register forms, $180 + opcode
            cmd.op := '0' & sa(6 downto 0);
            cmd.regs := fastio_wdata;
            enq := true;
          elsif sa = x"00" then                            -- MSTATUS: the sticky bits cleared
            overrun <= '0';
            badop <= '0';
            aborted <= '0';
          elsif sa = x"04" then                            -- MCTRL: queued (SETCTRL)
            cmd.op := to_unsigned(C_SETCTRL, 8);
            cmd.regs := fastio_wdata;
            enq := true;
          elsif sa = x"05" then                            -- MFLAGS: queued (SETFLAGS)
            cmd.op := to_unsigned(C_SETFLAGS, 8);
            cmd.regs := fastio_wdata;
            enq := true;
          elsif sa = x"0C" then                            -- MPPTR
            mpptr(7 downto 0) <= fastio_wdata;
          elsif sa = x"0D" then
            mpptr(8) <= fastio_wdata(0);
          elsif sa = x"14" then                            -- MPLIMIT
            mplimit(7 downto 0) <= fastio_wdata;
          elsif sa = x"15" then
            mplimit(15 downto 8) <= fastio_wdata;
          elsif sa = x"16" then
            mplimit(23 downto 16) <= fastio_wdata;
          elsif sa(7 downto 2) = "001000" then             -- MSTREAM, $120-$123: all one port
            sbuf(sn) <= fastio_wdata;
            if sn = 0 then n := cmd_len(fastio_wdata); else n := cmd_len(sbuf(0)); end if;
            if sn = n - 1 then                             -- the command's last byte
              if sn = 0 then
                cmd := cmd_of((fastio_wdata, others => x"00"), n, fastio_wdata);
              else
                cmd := cmd_of(sbuf, n, fastio_wdata);
              end if;
              enq := true;
              sn <= 0;
            else
              sn <= sn + 1;
            end if;
          elsif sa = x"24" then                            -- MSTREAMRST
            sn <= 0;
          elsif sa(7 downto 2) = "001010" then             -- MPLOAD, $128-$12B: all one port
            lbuf(ln) <= fastio_wdata;
            if ln = 0 then n := cmd_len(fastio_wdata); else n := cmd_len(lbuf(0)); end if;
            if ln = n - 1 then                             -- into the program memory at MPPTR
              pm_we <= '1';
              pm_waddr <= mpptr;
              pm_wdata <= pack(cmd_of(lbuf, n, fastio_wdata));
              mpptr <= mpptr + 1;
              ln <= 0;
            else
              ln <= ln + 1;
            end if;
          elsif sa = x"2C" then                            -- MPLOADRST
            ln <= 0;
          elsif sa = x"2D" then                            -- MPABORT
            abort_req <= prog;
          end if;
        elsif fastio_addr(11 downto 8) = "0010" then       -- wide forms, $200 + op * 2: the
          if fastio_addr(0) = '0' then                     -- second byte issues
            wbuf <= fastio_wdata;
          else
            cmd.form := "10";
            cmd.op := '0' & fastio_addr(7 downto 1);
            cmd.regs := wbuf;
            cmd.v(7 downto 0) := std_logic_vector(fastio_wdata);
            enq := true;
          end if;
        elsif fastio_addr(11 downto 10) = "01" then        -- memory forms, $400-$7FF
          k := to_integer(fastio_addr(1 downto 0));
          if k = 3 then                                    -- the last byte issues the command
            cmd.form := "01";
            cmd.op := "1000" & fastio_addr(9 downto 6);
            cmd.regs := fastio_addr(5 downto 2) & "0000";
            cmd.v := std_logic_vector(fastio_wdata) & mbuf;
            enq := true;
          else
            mbuf(8 * k + 7 downto 8 * k) <= std_logic_vector(fastio_wdata);
          end if;
        end if;
      end if;

      -- the core's results land (each unit's in the clock it gives it), and
      -- FXCHG's second half
      fv := f;
      pv := pendf;
      pcd := pend_cond;
      pmt := pend_mint;
      mcv := mcond_r;
      miv := mint_r;
      flv := mflags_r;
      tv := treg;
      tp := pendt;
      mv := mreg;
      if fm_done = '1' then                              -- (tags 16-31: T0-T15)
        k := to_integer(fm_tag(3 downto 0));
        if fm_tag(4) = '1' then
          tv(k) := fm_r;
          tp(k) := '0';
        else
          fv(k) := fm_r;
          pv(k) := '0';
        end if;
        flv := flv or fm_flags;
      end if;
      if sh_done = '1' then
        k := to_integer(sh_tag(3 downto 0));
        if sh_wf = '1' and sh_tag(4) = '1' then
          tv(k) := sh_r;
          tp(k) := '0';
        elsif sh_wf = '1' then
          fv(k) := sh_r;
          pv(k) := '0';
        end if;
        if sh_wc = '1' then mcv := sh_cond; pcd := '0'; end if;
        flv := flv or sh_flags;
      end if;
      if it_done = '1' then
        k := to_integer(it_tag(3 downto 0));
        if it_wf = '1' and it_tag(4) = '1' then
          tv(k) := it_r;
          tp(k) := '0';
        elsif it_wf = '1' then
          fv(k) := it_r;
          pv(k) := '0';
        end if;
        if it_wm = '1' then miv := it_mint; pmt := '0'; end if;
        flv := flv or it_flags;
      end if;
      if xw = '1' then
        fv(xd) := xb;
        fv(xs) := xa;
        pv(xd) := '0';
        pv(xs) := '0';
      end if;
      xw <= '0';
      if cv_done = '1' then
        flv := flv or cv_flags;
      end if;
      -- a store or copy into the result buffer (its data now: the
      -- converter's result, or the vertex array's word)
      if sd_b.valid = '1' then
        if sd_b.isimm = '1' then
          wv := x"000000" & sd_b.imm;
        elsif sd_b.copy = '1' then
          wv := va_rd(3) & va_rd(2) & va_rd(1) & va_rd(0);
        else
          wv := cv_r;
        end if;
        rb_waddr <= sd_b.entry & sd_b.boff(4 downto 2);
        if sd_b.width = 4 then
          rb_we <= "1111";
          for j in 0 to 3 loop
            rb_wd(j) <= wv(8 * j + 7 downto 8 * j);
          end loop;
        elsif sd_b.width = 2 then
          if sd_b.hi = '1' then wv(15 downto 0) := wv(31 downto 16); end if;
          if sd_b.boff(1) = '0' then
            rb_we <= "0011";
            rb_wd(0) <= wv(7 downto 0);
            rb_wd(1) <= wv(15 downto 8);
          else
            rb_we <= "1100";
            rb_wd(2) <= wv(7 downto 0);
            rb_wd(3) <= wv(15 downto 8);
          end if;
        else
          rb_we(to_integer(sd_b.boff(1 downto 0))) <= '1';
          rb_wd(to_integer(sd_b.boff(1 downto 0))) <= wv(7 downto 0);
        end if;
      end if;
      -- a load into T (VIN)
      if vd_b.valid = '1' then
        tv(vd_b.dst) := vconv(va_rd(3) & va_rd(2) & va_rd(1) & va_rd(0), vd_b.cvc, vposexp);
        tp(vd_b.dst) := '0';
      end if;

      -- the command in line (a program's, or the queue's head) or the
      -- sequence's next step, its read indices, and the reads
      if prog = '1' and ir_valid = '1' then
        cand := unpack(ir);
      elsif prog = '1' then
        cand := unpack(pm_rdata);
      else
        cand := q(to_integer(qhead));
      end if;
      u := UCODE(upc);
      cd := to_integer(cand.regs(7 downto 4));
      cs_i := to_integer(cand.regs(3 downto 0));
      ct := to_integer(unsigned(cand.v(7 downto 4)));
      if seq_active = '1' then
        fa_i := fidx(u.ak, u.ai);
        fb_i := fidx(u.bk, u.bi);
        fc_i := 0;
      elsif cand.form = "10" then
        fa_i := cs_i;
        fb_i := ct;
        fc_i := cd;
      else
        fa_i := cd;
        fb_i := cs_i;
        fc_i := 0;
      end if;
      ra := rdf(fa_i);
      rb := rdf(fb_i);
      rc := rdf(fc_i);
      rtb := rdt(u.bi);
      rtc := rdt(u.ci);
      rma := mreg(u.ai);

      -- a command a clock, in order: a sequence's next step, a program's next
      -- command, or the queue's head
      deq := false;
      if seq_active = '1' then
        if seq_issued = '0' then                         -- the next step, once its T operands are in
          case u.ak is
            when K_M => ua := rma;
            when K_ONE => ua := x"3F800000";
            when others => ua := ra;
          end case;
          case u.bk is
            when K_T => ub := rtb;
            when K_ONE => ub := x"3F800000";
            when K_ZERO => ub := x"00000000";
            when others => ub := rb;
          end case;
          if u.ck = CK_NONE then
            uc := x"00000000";
          elsif u.ck = CK_T then
            uc := rtc;
          else
            uc := (not rtc(31)) & rtc(30 downto 0);
          end if;
          if u.vk = UK_VST or u.vk = UK_VCOPY then
            ready := true;
          else
            ready := tp(u.dst) = '0' and (u.bk /= K_T or tp(u.bi) = '0')
                     and (u.ck = CK_NONE or tp(u.ci) = '0')
                     and not (fpu_unit(to_unsigned(u.op, 5)) = U_ITER and it_busy = '1');
          end if;
          if ready then
            if u.vk = UK_VLD then                        -- the vertex array's word, into T[dst] in two clocks
              va_raddr <= vinidx + vf_off(vfmt, u.fld) + u.wd;
              vd_a.valid <= '1';
              vd_a.dst <= u.dst;
              vd_a.cvc <= u.cvc;
              tp(u.dst) := '1';
            elsif u.vk = UK_VCOPY then                   -- an attribute word into the entry
              va_raddr <= vinidx + vf_off(vfmt, 3) + u.wd;
              sd_a.valid <= '1';
              sd_a.copy <= '1';
              sd_a.hi <= '0';
              sd_a.entry <= vtxidx;
              sd_a.boff <= to_unsigned(4 * ((seq_off + u.wd) mod 8), 5);
              sd_a.width <= 4;
            else
              c_start <= '1';
              c_op <= to_unsigned(u.op, 5);
              c_a <= ua;
              c_b <= ub;
              c_c <= uc;
              c_rm <= mctrl_x;
              if u.vk = UK_VST then                      -- the converter's result into the entry
                c_tag <= (others => '0');
                sd_a.valid <= '1';
                sd_a.copy <= '0';
                sd_a.hi <= '0';
                sd_a.entry <= vtxidx;
                sd_a.boff <= to_unsigned(2 * seq_off + u.sk, 5);
                sd_a.width <= 1;
              else
                c_tag <= to_unsigned(16 + u.dst, 8);
                tp(u.dst) := '1';
              end if;
            end if;
            if u.last then
              seq_issued <= '1';
            else
              upc <= upc + 1;
            end if;
          end if;
        elsif pendt = x"0000" then                       -- every step back and settled: the result into place
          case seq_op is
            when W_VDOT3 | W_VDOT4 =>
              fv(seq_d) := treg(0);
            when W_MMUL =>
              mv := treg;
            when W_VOUTC | SEQ_VPASS =>                  -- (stores: nothing to put in place)
              null;
            when others =>                               -- Vd = T0-T3 (VIN too)
              for j in 0 to 3 loop
                fv(4 * seq_vd + j) := treg(j);
              end loop;
          end case;
          seq_active <= '0';
        end if;
        -- (a program keeps the entry it has fetched)
        if prog = '1' then
          if refill = '1' then
            refill <= '0';
            fp <= fp + 1;
          elsif ir_valid = '0' then
            ir <= pm_rdata;
            ir_valid <= '1';
          end if;
        end if;
      elsif prog = '1' then
        if refill = '1' then                               -- (after a jump: the entry at pc next clock)
          refill <= '0';
          fp <= fp + 1;
        else
          cnt := ppass;
          if abort_req = '1' then                          -- MPABORT
            prog <= '0'; mperr <= "011"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
          elsif plimit /= 0 and pexec = plimit then        -- MPLIMIT
            prog <= '0'; mperr <= "010"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
          else
            dispatch(cand, true, res);
            if res = X_WAIT then
              if ir_valid = '0' then                       -- (pm_rdata moves on to pc + 1)
                ir <= pm_rdata;
                ir_valid <= '1';
              end if;
            else
              ir_valid <= '0';
              pexec <= pexec + 1;
              if res = X_BAD then
                prog <= '0'; mperr <= "100"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
              elsif res = X_EXIT then
                prog <= '0'; mpcnt <= cnt(15 downto 0);
              elsif res = X_SKIP then                      -- a jump over skipn commands
                target := ('0' & pc) + 1 + skipn;
                if target > 511 then                       -- past the last entry
                  prog <= '0'; mperr <= "001"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
                else
                  pc <= target(8 downto 0);
                  fp <= target(8 downto 0);
                  refill <= '1';
                end if;
              elsif res = X_END then
                cnt := ppass + 1;
                if cnt = ptotal then
                  prog <= '0'; mpcnt <= cnt(15 downto 0);
                else
                  ppass <= cnt;
                  pc <= pstart;
                  fp <= pstart;
                  refill <= '1';
                end if;
              elsif pc = 511 then                          -- past the last entry, no PEND
                prog <= '0'; mperr <= "001"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
              else
                pc <= pc + 1;
                fp <= fp + 1;
              end if;
            end if;
          end if;
        end if;
      -- else the queue's head: a PRUN starts a program
      elsif qcount /= 0 then
        if cand.form = "01" and cand.op(3 downto 0) = "1110" then
          deq := true;
          prog <= '1';
          pc <= unsigned(cand.v(8 downto 0));
          fp <= unsigned(cand.v(8 downto 0));
          refill <= '1';
          ir_valid <= '0';
          pstart <= unsigned(cand.v(8 downto 0));
          if cand.v(31 downto 16) = x"0000" then
            ptotal <= '1' & x"0000";
          else
            ptotal <= '0' & unsigned(cand.v(31 downto 16));
          end if;
          ppass <= (others => '0');
          pexec <= (others => '0');
          plimit <= mplimit;
          mperr <= "000";
          abort_req <= '0';
        else
          dispatch(cand, false, res);
          if res /= X_WAIT then
            deq := true;
            if res = X_BAD then
              badop <= '1';
            end if;
          end if;
        end if;
      end if;
      if deq then
        qhead <= qhead + 1;
      end if;

      f <= fv;
      pendf <= pv;
      pend_cond <= pcd;
      pend_mint <= pmt;
      mcond_r <= mcv;
      mint_r <= miv;
      mflags_r <= flv;
      treg <= tv;
      pendt <= tp;
      mreg <= mv;

      -- into the queue, or dropped when it is full
      qc := qcount;
      if deq then
        qc := qc - 1;
      end if;
      if enq then
        if qc < QN then
          q(to_integer(qtail)) <= cmd;
          qtail <= qtail + 1;
          qc := qc + 1;
        else
          overrun <= '1';
        end if;
      end if;
      qcount <= qc;

      -- the reads: the byte is latched for the rest of the access; byte 0 of
      -- F, MINT or MPREAD and MPCNT's low byte latch the rest; reading
      -- MPREAD's last byte advances MPPTR
      if rd_new = '1' then
        port_latch <= rbyte;
        if fastio_addr(11 downto 6) = "010000" and fastio_addr(1 downto 0) = "00" then
          flatch <= f(to_integer(fastio_addr(5 downto 2)));
        end if;
        if fastio_addr = x"108" then
          mlatch <= mint_r;
        end if;
        if fastio_addr = x"10E" then
          cntlatch <= mpcnt(15 downto 8);
        end if;
        if fastio_addr = x"130" then
          plat <= pm_rdata;
        end if;
        if fastio_addr = x"137" and prog = '0' then
          mpptr <= mpptr + 1;
        end if;
      end if;

      -- MRESET: everything back to its start but the program memory's contents
      if wr_new = '1' and fastio_addr = x"107" then
        f <= (others => (others => '0'));
        mint_r <= (others => '0');
        mcond_r <= (others => '0');
        mflags_r <= (others => '0');
        mctrl_x <= "00";
        overrun <= '0';
        badop <= '0';
        aborted <= '0';
        qhead <= (others => '0');
        qtail <= (others => '0');
        qcount <= 0;
        sn <= 0;
        ln <= 0;
        pendf <= (others => '0');
        pend_cond <= '0';
        pend_mint <= '0';
        pendt <= (others => '0');
        mreg <= (others => (others => '0'));
        seq_active <= '0';
        seq_issued <= '0';
        xw <= '0';
        vinptr <= (others => '0');
        vinidx <= (others => '0');
        vfmt <= (others => '0');
        vposexp <= (others => '0');
        vtxidx <= (others => '0');
        vbank <= (others => '0');
        sd_a <= SD_NONE;
        sd_b <= SD_NONE;
        vd_a.valid <= '0';
        vd_b.valid <= '0';
        rb_we <= "0000";
        c_start <= '0';
        c_abort <= '1';                                  -- (the core drops what is in flight)
        prog <= '0';
        refill <= '0';
        ir_valid <= '0';
        abort_req <= '0';
        mpptr <= (others => '0');
        mpcnt <= (others => '0');
        mperr <= "000";
        mplimit <= LIMIT_RESET;
      end if;
    end if;
  end process;

  -- the byte at the address being read
  process (fastio_addr, f, flatch, mint_r, mlatch, mflags_r, mcond_r, mctrl_x, qcount,
           overrun, badop, aborted, prog, busy, mpptr, mpcnt, cntlatch, mperr, mplimit,
           pm_rdata, plat, rb_rd, vinptr, vinidx, vfmt, vposexp, vtxidx, vbank)
    variable v : unsigned(7 downto 0);
    variable k : integer;
    variable fv : std_logic_vector(31 downto 0);
  begin
    v := x"00";
    if fastio_addr(11) = '1' then                           -- the window: the result buffer
      v := unsigned(rb_rd(to_integer(fastio_addr(1 downto 0))));
    elsif fastio_addr(11 downto 8) = "0000" then           -- the vertex page
      case fastio_addr(7 downto 0) is
        when x"04" => v := vinptr(7 downto 0);
        when x"05" => v := "00" & vinptr(13 downto 8);
        when x"06" => v := vinidx(5 downto 0) & "00";
        when x"07" => v := "00" & vinidx(11 downto 6);
        when x"08" => v := "000" & vfmt;
        when x"09" => v := "0000" & vposexp;
        when x"0C" => v := vtxidx(7 downto 0);
        when x"0D" => v := "000000" & vtxidx(9 downto 8);
        when x"0E" => v := "0000" & vbank;
        when others => v := x"00";
      end case;
    elsif fastio_addr(11 downto 8) = "0001" then
      case fastio_addr(7 downto 0) is
        when x"00" =>
          v := b2l(mflags_r /= "00000") & '0' & aborted & prog & badop & overrun
               & b2l(qcount >= 12) & busy;
        when x"01" => v := ID_VALUE;
        when x"02" => v := VER_VALUE;
        when x"03" => v := to_unsigned(qcount, 8);
        when x"04" => v := "000000" & mctrl_x;      -- the rounding mode in effect
        when x"05" => v := "000" & unsigned(mflags_r);
        when x"06" => v := unsigned(mcond_r);
        when x"08" => v := unsigned(mint_r(7 downto 0));
        when x"09" => v := unsigned(mlatch(15 downto 8));
        when x"0A" => v := unsigned(mlatch(23 downto 16));
        when x"0B" => v := unsigned(mlatch(31 downto 24));
        when x"0C" => v := mpptr(7 downto 0);
        when x"0D" => v := "0000000" & mpptr(8);
        when x"0E" => v := mpcnt(7 downto 0);
        when x"0F" => v := cntlatch;
        when x"10" => v := "00000" & mperr;
        when x"14" => v := mplimit(7 downto 0);
        when x"15" => v := mplimit(15 downto 8);
        when x"16" => v := mplimit(23 downto 16);
        when x"30" => v := "000000" & unsigned(pm_rdata(49 downto 48));   -- MPREAD: form
        when x"31" => v := unsigned(plat(47 downto 40));                 -- opcode
        when x"32" => v := unsigned(plat(39 downto 32));                 -- regs
        when x"33" => v := unsigned(plat(7 downto 0));                   -- the operand
        when x"34" => v := unsigned(plat(15 downto 8));
        when x"35" => v := unsigned(plat(23 downto 16));
        when x"36" => v := unsigned(plat(31 downto 24));
        when others => v := x"00";
      end case;
    elsif fastio_addr(11 downto 6) = "010000" then          -- $400-$43F: F0-F15
      k := to_integer(fastio_addr(1 downto 0));
      if k = 0 then
        fv := f(to_integer(fastio_addr(5 downto 2)));
        v := unsigned(fv(7 downto 0));
      else
        v := unsigned(flatch(8 * k + 7 downto 8 * k));
      end if;
    end if;
    rbyte <= v;
  end process;

  fastio_rdata <= std_logic_vector(rbyte) when cs = '1' and fastio_read = '1'
                                               and (rd_new = '1' or fastio_addr(11) = '1') else
                  std_logic_vector(port_latch) when cs = '1' and fastio_read = '1' else
                  (others => 'Z');

end rtl;
