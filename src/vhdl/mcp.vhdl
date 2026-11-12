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
-- src/mcp/model/mcp_model.c (stage 3): the order of the results is the
-- scoreboard's business, never visible.

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
  constant VER_VALUE : unsigned(7 downto 0) := x"02";   -- MCP-2
  constant QN : integer := 16;
  constant LIMIT_RESET : unsigned(23 downto 0) := x"100000";

  constant C_FXCHG    : integer := 16#14#;
  constant C_FCONST   : integer := 16#15#;
  constant C_SETCTRL  : integer := 16#16#;
  constant C_SETFLAGS : integer := 16#17#;
  constant C_PEXIT    : integer := 16#18#;
  constant C_PEND     : integer := 16#19#;
  constant C_NREGOPS  : integer := 16#1A#;
  constant C_CORE_FMA : integer := 16#1E#;     -- the core's a x b + c

  -- what a command did (dispatch)
  constant X_OK   : integer := 0;
  constant X_EXIT : integer := 1;               -- PEXIT taken (in a program)
  constant X_END  : integer := 2;               -- PEND (in a program)
  constant X_BAD  : integer := 3;               -- a reserved command
  constant X_WAIT : integer := 4;               -- not yet: a result it needs is still to come

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

  -- a micro-operation: the core's op, its operands a and b (a kind and an
  -- index: Vs's, Vt's component, F[t], an F, an M, 1.0, a T), its addend c
  -- (none, a T, a T negated), the T it writes; the last of its sequence
  constant K_VS  : natural := 0;
  constant K_VT  : natural := 1;
  constant K_FT  : natural := 2;
  constant K_F   : natural := 3;
  constant K_M   : natural := 4;
  constant K_ONE : natural := 5;
  constant K_T   : natural := 6;
  constant CK_NONE : natural := 0;
  constant CK_T    : natural := 1;
  constant CK_NEGT : natural := 2;
  type uop_t is record
    op           : natural range 0 to 31;
    ak, bk, ck   : natural range 0 to 7;
    ai, bi, ci   : natural range 0 to 15;
    dst          : natural range 0 to 15;
    last         : boolean;
  end record;
  constant NUOPS : natural := 133;
  type ucode_t is array (0 to NUOPS - 1) of uop_t;

  function uo(op, ak, ai, bk, bi, ck, ci, dst : natural; last : boolean) return uop_t is
    variable r : uop_t;
  begin
    r.op := op; r.ak := ak; r.ai := ai; r.bk := bk; r.bi := bi; r.ck := ck; r.ci := ci;
    r.dst := dst; r.last := last;
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
    -- VCROSS (23): the products T4-T6, then T0-T2 = fma(.., .., -T)
    u(n) := uo(C_CORE_MUL, K_VS, 2, K_VT, 1, CK_NONE, 0, 4, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 0, K_VT, 2, CK_NONE, 0, 5, false); n := n + 1;
    u(n) := uo(C_CORE_MUL, K_VS, 1, K_VT, 0, CK_NONE, 0, 6, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 1, K_VT, 2, CK_NEGT, 4, 0, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 2, K_VT, 0, CK_NEGT, 5, 1, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 0, K_VT, 1, CK_NEGT, 6, 2, true); n := n + 1;
    -- VNORM3 (29): T4 = Vs.xyz . Vs.xyz, T5 = sqrt T4, T6 = 1 / T5, Tk = Vs.k x T6
    u(n) := uo(C_CORE_MUL, K_VS, 0, K_VS, 0, CK_NONE, 0, 4, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 1, K_VS, 1, CK_T, 4, 4, false); n := n + 1;
    u(n) := uo(C_CORE_FMA, K_VS, 2, K_VS, 2, CK_T, 4, 4, false); n := n + 1;
    u(n) := uo(C_CORE_SQRT, K_ONE, 0, K_T, 4, CK_NONE, 0, 5, false); n := n + 1;
    u(n) := uo(C_CORE_DIV, K_ONE, 0, K_T, 5, CK_NONE, 0, 6, false); n := n + 1;
    for k in 0 to 2 loop
      u(n) := uo(C_CORE_MUL, K_VS, k, K_T, 6, CK_NONE, 0, k, k = 2); n := n + 1;
    end loop;
    -- MXV (37), MTXV (53): Tr = row (column) r of M . Vs, the four rows interleaved
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
    -- MMUL (69): T(4r + c) = row r of M . column c of F, the sixteen interleaved
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
      when 16#18# => return 29;                   -- VNORM3
      when 16#22# => return 37;                   -- MXV
      when 16#23# => return 53;                   -- MTXV
      when others => return 69;                   -- MMUL
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
              it_flags => it_flags, it_wf => it_wf, it_wm => it_wm);

  -- the program memory: written by MPLOAD; read by the program (at pc) or by
  -- MPREAD (at MPPTR) when no program runs
  progmem : entity work.mcp_ram generic map (AW => 9, DW => 50)
    port map (clock => clock, we => pm_we, waddr => pm_waddr, wdata => pm_wdata,
              raddr => pm_raddr, rdata => pm_rdata);
  pm_raddr <= fp when prog = '1' else mpptr;

  rd_new <= cs and fastio_read and ((not last_rd) or b2l(fastio_addr /= last_addr));
  wr_new <= cs and fastio_write and ((not last_wr) or b2l(fastio_addr /= last_addr));
  busy <= b2l(qcount /= 0) or prog or b2l(pendf /= x"0000") or pend_cond or pend_mint or seq_active;

  process (clock)
    variable cmd : cmd_t;
    variable x : cmd_t;
    variable enq, deq : boolean;
    variable sa : unsigned(7 downto 0);
    variable k, n : integer;
    variable qc : integer range 0 to QN + 1;
    variable res : integer;
    variable cnt : unsigned(16 downto 0);
    -- the unit's state as this clock's results leave it (a command issued
    -- now reads it: a result landing now is there for it)
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
    variable ua, ub, uc, w : std_logic_vector(31 downto 0);
    variable ready : boolean;

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

    -- a micro-operation's operand (fv, mv, tv: this clock's)
    impure function opnd(k, i : natural) return std_logic_vector is
    begin
      case k is
        when K_VS => return fv(4 * seq_vs + i mod 4);
        when K_VT => return fv(4 * seq_vt + i mod 4);
        when K_FT => return fv(seq_t);
        when K_F => return fv(i);
        when K_M => return mv(i);
        when K_ONE => return x"3F800000";
        when others => return tv(i);
      end case;
    end function;

    -- a core operation into the core, once nothing it reads or writes (the
    -- F registers in need; MCOND or MINT if it writes them) has a result
    -- still to come, and its unit can take it; else stall
    procedure issue(cop : integer; need : std_logic_vector(15 downto 0);
                    va, vb, vc : std_logic_vector(31 downto 0); d : integer) is
      variable u : natural;
      variable wc, wm : boolean;
    begin
      u := fpu_unit(to_unsigned(cop, 5));
      wc := cop = C_CORE_CMP or cop = C_CORE_CLASS;
      wm := cop >= C_CORE_TOI and cop <= C_CORE_TOI16;
      if (pv and need) /= x"0000" or (wc and pcd = '1') or (wm and pmt = '1')
         or (u = U_ITER and it_busy = '1') then
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
        else
          pv(d) := '1';
        end if;
      end if;
    end procedure;

    -- a command, from the queue or a program: into the core, or done at once
    -- (exchange, control, flags, PEXIT, PEND, a reserved command); X_WAIT if
    -- it must wait for a result
    procedure dispatch(cm : cmd_t; in_prog : boolean; r : out integer) is
      variable d, s, mf, t, cop : integer;
      variable rv : integer;              -- (an out parameter can't be read in Vivado)
      variable tmp : std_logic_vector(31 downto 0);
      variable tmp4 : fregs_t;
    begin
      rv := X_OK;
      stall := false;
      d := to_integer(cm.regs(7 downto 4));
      s := to_integer(cm.regs(3 downto 0));
      if cm.form = "00" then
        if cm.op = C_SETCTRL then
          mctrl_x <= cm.regs(1 downto 0);
        elsif cm.op = C_SETFLAGS then                    -- after every flag still to come
          if pv /= x"0000" or pcd = '1' or pmt = '1' then
            stall := true;
          else
            flv := std_logic_vector(cm.regs(4 downto 0));
          end if;
        elsif cm.op = C_FXCHG then
          if pv(d) = '1' or pv(s) = '1' then
            stall := true;
          else
            tmp := fv(d);
            fv(d) := fv(s);
            fv(s) := tmp;
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
        elsif cm.op >= C_NREGOPS then
          rv := X_BAD;
        elsif cm.op = C_FCONST then
          issue(C_FCONST, bit_of(d), fv(d), std_logic_vector(resize(cm.regs(3 downto 0), 32)),
                x"00000000", d);
        else
          issue(to_integer(cm.op), bit_of(d) or bit_of(s), fv(d), fv(s), x"00000000", d);
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
          issue(cop, bit_of(d), fv(d), cm.v, x"00000000", d);
        end if;
      elsif cm.form = "10" then                          -- wide forms: Fd = Fs op Ft
        t := to_integer(unsigned(cm.v(7 downto 4)));
        case to_integer(cm.op) is
          when W_VMOVE =>                                -- Vd = Vs, now
            if (pv and (vmask(s) or vmask(d))) /= x"0000" then
              stall := true;
            else
              for j in 0 to 3 loop
                tmp4(j) := fv(4 * (s mod 4) + j);
              end loop;
              for j in 0 to 3 loop
                fv(4 * (d mod 4) + j) := tmp4(j);
              end loop;
            end if;
          when 16#11# to W_VNORM3 | W_MXV | W_MTXV =>   -- a sequence, once its registers are settled
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
          when W_MLOAD | W_MSTORE | W_MMUL =>            -- every F register
            if pv /= x"0000" then
              stall := true;
            elsif cm.op = W_MLOAD then
              mv := fv;
            elsif cm.op = W_MSTORE then
              fv := mv;
            else
              seq_active <= '1';
              seq_issued <= '0';
              upc <= ustart(W_MMUL);
              seq_op <= W_MMUL;
            end if;
          when 0 => issue(16#01#, bit_of(d) or bit_of(s) or bit_of(t), fv(s), fv(t), fv(d), d);  -- FADD3
          when 1 => issue(16#02#, bit_of(d) or bit_of(s) or bit_of(t), fv(s), fv(t), fv(d), d);  -- FSUB3
          when 2 => issue(16#04#, bit_of(d) or bit_of(s) or bit_of(t), fv(s), fv(t), fv(d), d);  -- FMUL3
          when 3 =>                                                                               -- FMA: Fs x Ft + Fd
            issue(C_CORE_FMA, bit_of(d) or bit_of(s) or bit_of(t), fv(s), fv(t), fv(d), d);
          when 4 =>                                                                               -- FMS: -Fs x Ft + Fd
            issue(C_CORE_FMA, bit_of(d) or bit_of(s) or bit_of(t), (not fv(s)(31)) & fv(s)(30 downto 0),
                  fv(t), fv(d), d);
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

      -- the commands the bus brings (one access a clock: at most one command)
      enq := false;
      cmd := CMD_ZERO;
      if wr_new = '1' then
        sa := fastio_addr(7 downto 0);
        if fastio_addr(11 downto 8) = "0001" then          -- the control page, $1xx
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

      -- the core's results land (each unit's in the clock it gives it)
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
        if sh_wf = '1' then fv(k) := sh_r; pv(k) := '0'; end if;
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

      -- a command a clock, in order: a sequence's next step, a program's next
      -- command, or the queue's head
      deq := false;
      if seq_active = '1' then
        if seq_issued = '0' then                         -- the next step, once its T operands are in
          u := UCODE(upc);
          ua := opnd(u.ak, u.ai);
          ub := opnd(u.bk, u.bi);
          if u.ck = CK_NONE then
            uc := x"00000000";
          elsif u.ck = CK_T then
            uc := tv(u.ci);
          else
            uc := (not tv(u.ci)(31)) & tv(u.ci)(30 downto 0);
          end if;
          ready := tp(u.dst) = '0' and (u.bk /= K_T or tp(u.bi) = '0')
                   and (u.ck = CK_NONE or tp(u.ci) = '0')
                   and not (fpu_unit(to_unsigned(u.op, 5)) = U_ITER and it_busy = '1');
          if ready then
            c_start <= '1';
            c_op <= to_unsigned(u.op, 5);
            c_a <= ua;
            c_b <= ub;
            c_c <= uc;
            c_rm <= mctrl_x;
            c_tag <= to_unsigned(16 + u.dst, 8);
            tp(u.dst) := '1';
            if u.last then
              seq_issued <= '1';
            else
              upc <= upc + 1;
            end if;
          end if;
        elsif tp = x"0000" then                          -- every step back: the result into place
          case seq_op is
            when W_VDOT3 | W_VDOT4 =>
              fv(seq_d) := tv(0);
            when W_VCROSS =>
              for j in 0 to 2 loop
                fv(4 * seq_vd + j) := tv(j);
              end loop;
              fv(4 * seq_vd + 3) := x"00000000";
            when W_VNORM3 =>
              w := fv(4 * seq_vs + 3);
              for j in 0 to 2 loop
                fv(4 * seq_vd + j) := tv(j);
              end loop;
              fv(4 * seq_vd + 3) := w;
            when W_MMUL =>
              mv := tv;
            when others =>                               -- VADD, VSUB, VMUL, VSCALE, MXV, MTXV
              for j in 0 to 3 loop
                fv(4 * seq_vd + j) := tv(j);
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
          if ir_valid = '1' then
            x := unpack(ir);
          else
            x := unpack(pm_rdata);
          end if;
          cnt := ppass;
          if abort_req = '1' then                          -- MPABORT
            prog <= '0'; mperr <= "011"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
          elsif plimit /= 0 and pexec = plimit then        -- MPLIMIT
            prog <= '0'; mperr <= "010"; aborted <= '1'; mpcnt <= cnt(15 downto 0);
          else
            dispatch(x, true, res);
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
        x := q(to_integer(qhead));
        if x.form = "01" and x.op(3 downto 0) = "1110" then
          deq := true;
          prog <= '1';
          pc <= unsigned(x.v(8 downto 0));
          fp <= unsigned(x.v(8 downto 0));
          refill <= '1';
          ir_valid <= '0';
          pstart <= unsigned(x.v(8 downto 0));
          if x.v(31 downto 16) = x"0000" then
            ptotal <= '1' & x"0000";
          else
            ptotal <= '0' & unsigned(x.v(31 downto 16));
          end if;
          ppass <= (others => '0');
          pexec <= (others => '0');
          plimit <= mplimit;
          mperr <= "000";
          abort_req <= '0';
        else
          dispatch(x, false, res);
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
           pm_rdata, plat)
    variable v : unsigned(7 downto 0);
    variable k : integer;
    variable fv : std_logic_vector(31 downto 0);
  begin
    v := x"00";
    if fastio_addr(11 downto 8) = "0001" then
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

  fastio_rdata <= std_logic_vector(rbyte) when cs = '1' and fastio_read = '1' and rd_new = '1' else
                  std_logic_vector(port_latch) when cs = '1' and fastio_read = '1' else
                  (others => 'Z');

end rtl;
