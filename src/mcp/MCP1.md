# MCP-1: the scalar FPU

> **This is the record of how MCP-1 was specified and built, kept as
> written.** Later stages changed details (MVER, the divider's timing, the
> address range). For the unit as it is now (registers, commands, memory
> layout, timing), read [`REFERENCE.md`](REFERENCE.md).

Spec, 2026-11-12. Built the same day (`src/vhdl/mcp.vhdl`,
`src/vhdl/mcp_fpu.vhdl`), checked in simulation and on a MEGA65 R6
("Verification" below). The design and the decisions behind it are in
[`MCP.md`](MCP.md).

MCP-1 is the first milestone of the M65-MCP: IEEE single-precision arithmetic
on 16 registers, driven by memory-mapped commands from the 45GS02 or its DMA.
It sits in the `$FFDF000` slot at `$FFDF100-$FFDF7FF` (beside m65tr3d's
fixed-point vertex unit until that was removed after MCP-2: MCP.md,
decision 4).

## Summary

- 16 registers, F0-F15, each holding an FP32 value. The extended format
  (MCP.md, decision 1) arrives with MCP-4; the programming model stays the
  same.
- Operations: add, subtract (both orders), multiply, divide (both orders),
  reciprocal, square root, compare, min/max, abs, negate, round to integer,
  classify, exchange, constants, and conversions from and to int32, int16
  and s15.16 fixed point.
- IEEE 754 binary32 throughout: correctly rounded, four rounding modes,
  subnormals, default NaN, five sticky flags.
- A 16-command queue fed three ways: register forms (one byte write),
  memory forms (one `STQ`, Weitek-style) and a stream port (DMA lists).
- Commands run in order, one at a time.

## Registers (`$FFDF000` + offset)

| Offset | Name | |
|---|---|---|
| `$100` | MSTATUS | read: bit 0 busy (a command queued or running), bit 1 queue nearly full (12 or more queued), bit 2 overrun (sticky: a command arrived with the queue full and was dropped), bit 3 bad opcode (sticky: a reserved opcode was ignored), bit 7 any MFLAGS bit set. Write any value: clears bits 2 and 3 |
| `$101` | MID | reads `$4D` ("M") |
| `$102` | MVER | reads `$01` (MCP-1) |
| `$103` | MQLEN | read: commands queued, not counting the one running (0-16) |
| `$104` | MCTRL | bits 0-1 rounding (x87 order: 0 nearest-even, 1 toward -∞, 2 toward +∞, 3 toward 0); bits 2-3 precision (0 single; 3 extended, MCP-4: MCP-1 keeps 0). Writing is queued (command `$16`): it applies to the commands after it. Reads give the rounding mode in effect: once the unit is idle, the last one set by any path (the queue, the stream, a program) |
| `$105` | MFLAGS | sticky: bit 0 invalid, bit 1 divide by zero, bit 2 overflow, bit 3 underflow, bit 4 inexact. Reads give the flags of the commands completed so far; writing is queued (command `$17`) |
| `$106` | MCOND | read: the last FCMP's or FCLASS's result (below) |
| `$107` | MRESET | write any value: empties the queue, stops the command in progress, F0-F15 = +0.0, MINT, MCOND, MFLAGS and MCTRL = 0, the sticky bits cleared, the stream restarted |
| `$108-$10B` | MINT | read: the int32 result of FTOI, FTOX or FTOI16 (little-endian) |
| `$120-$123` | MSTREAM | write: the command stream. All four addresses are the same port, so an `STQ` to `$120` appends four bytes, and a DMA job can hold the destination |
| `$124` | MSTREAMRST | write any value: the stream restarts at a command boundary (a partly written command is dropped) |
| `$180-$1FF` | register forms | write `(d << 4) \| s` to `$180 + opcode` (opcodes `$00-$7F`) |
| `$200-$2FF` | | reserved (MCP-2: vector forms) |
| `$300-$37F` | | reserved (MCP-4: the extended view, 8 bytes a register) |
| `$400-$7FF` | memory forms | write a 32-bit value to `$400 + m * 64 + d * 4` (m = 0-15): `Fd = Fd op v`. Read `$400 + d * 4`: Fd as FP32 |

Other offsets in `$100-$7FF` read 0 and ignore writes. MID (`$101`, `$4D`)
says the MCP is there. (While the vertex unit was in the slot, its CAPS at
`$049` also had bit 6 set and read `$68`.)

**Multi-byte reads** (Fd, MINT): reading byte 0 latches all four bytes, and
bytes 1-3 come from the latch, so an `LDQ` reads one consistent value.

**Multi-byte writes** (memory forms): bytes 0-2 are held, and writing byte 3
issues the command with the op and register its address names. An `STQ`
writes bytes 0 to 3 in order.

**Nothing waits.** The fastio slot cannot hold the CPU, so a read returns
what is there now. Before reading a result, wait for MSTATUS bit 0 to clear.

## Commands

### Register forms (opcode `$00-$7F`)

Issued by writing `(d << 4) | s` to `$180 + opcode`, or as two stream bytes:
the opcode, then `(d << 4) | s`.

| Op | Name | Operation | Flags |
|---|---|---|---|
| `$00` | FMOVE | Fd = Fs | none (bits copied) |
| `$01` | FADD | Fd = Fd + Fs | V O U X |
| `$02` | FSUB | Fd = Fd - Fs | V O U X |
| `$03` | FSUBR | Fd = Fs - Fd | V O U X |
| `$04` | FMUL | Fd = Fd x Fs | V O U X |
| `$05` | FDIV | Fd = Fd / Fs | V Z O U X |
| `$06` | FDIVR | Fd = Fs / Fd | V Z O U X |
| `$07` | FCMP | MCOND = compare(Fd, Fs) | V (signalling NaN only) |
| `$08` | FMIN | Fd = min(Fd, Fs) | V (signalling NaN only) |
| `$09` | FMAX | Fd = max(Fd, Fs) | V (signalling NaN only) |
| `$0A` | FSQRT | Fd = √Fs | V X |
| `$0B` | FABS | Fd = abs(Fs) | none (sign bit cleared) |
| `$0C` | FNEG | Fd = -Fs | none (sign bit flipped) |
| `$0D` | FRINT | Fd = Fs rounded to an integer, MCTRL's mode | V |
| `$0E` | FTRUNC | Fd = Fs rounded to an integer toward 0 | V |
| `$0F` | FCLASS | MCOND = the class of Fs (d ignored) | none |
| `$10` | FTOI | MINT = int32(Fs), MCTRL's mode, saturated (d ignored) | V X |
| `$11` | FTOX | MINT = s15.16(Fs): int32(Fs x 2^16), saturated | V X |
| `$12` | FTOI16 | MINT = int16(Fs) saturated, sign-extended to 32 bits | V X |
| `$13` | FRECIP | Fd = 1 / Fs | V Z O U X |
| `$14` | FXCHG | Fd and Fs swapped | none |
| `$15` | FCONST | Fd = constant s (table below) | none |
| `$16` | SETCTRL | MCTRL = the data byte (the regs byte is the value) | none |
| `$17` | SETFLAGS | MFLAGS = the data byte | none |
| `$18-$7F` | | reserved: ignored, MSTATUS bit 3 set | |

Flags: V invalid, Z divide by zero, O overflow, U underflow, X inexact.

### Memory forms (m = 0-15)

Issued by a 32-bit write of v to `$400 + m * 64 + d * 4`, or as six stream
bytes: `$80 + m`, then `d << 4`, then v (4 bytes, little-endian). Forms 0-10
are register forms `$00-$0A` with v in place of Fs.

| m | Name | Operation |
|---|---|---|
| 0 | FMOVE | Fd = v |
| 1 | FADD | Fd = Fd + v |
| 2 | FSUB | Fd = Fd - v |
| 3 | FSUBR | Fd = v - Fd |
| 4 | FMUL | Fd = Fd x v |
| 5 | FDIV | Fd = Fd / v |
| 6 | FDIVR | Fd = v / Fd |
| 7 | FCMP | MCOND = compare(Fd, v) |
| 8 | FMIN | Fd = min(Fd, v) |
| 9 | FMAX | Fd = max(Fd, v) |
| 10 | FSQRT | Fd = √v |
| 11 | FRECIP | Fd = 1 / v |
| 12 | FILD | Fd = float(v as int32), MCTRL's mode |
| 13 | FXLD | Fd = float(v as s15.16) |
| 14-15 | | reserved: ignored, MSTATUS bit 3 set |

The pointer for a memory form has to name the exact address: `STQ [zp]`
does not add Z (MCP.md, "The 45GS02 interface"). For forms 0-3 the address
is in `$400-$4FF`. Repeating one form on one register keeps the pointer.

### The stream

- An opcode byte `$00-$7F` takes one more byte; `$80-$8F` take five more.
- `$90-$FF` are reserved: treated as two-byte commands, ignored, and they
  set MSTATUS bit 3.
- MSTREAMRST and MRESET bring a stream that has lost its place back to a
  command boundary.

### MCOND

- **After FCMP:** exactly one of bit 0 (less), bit 1 (equal), bit 2
  (greater), bit 3 (unordered: a NaN). -0 equals +0.
- **After FCLASS:** bit 0 is the sign, plus exactly one of bit 1 (zero),
  bit 2 (subnormal), bit 3 (normal), bit 4 (infinity), bit 5 (quiet NaN),
  bit 6 (signalling NaN).

Other commands leave MCOND alone.

### Constants (FCONST, s = 0-15)

| s | value | FP32 | s | value | FP32 |
|---|---|---|---|---|---|
| 0 | +0.0 | `$00000000` | 8 | e | `$402DF854` |
| 1 | 1.0 | `$3F800000` | 9 | ln 2 | `$3F317218` |
| 2 | 2.0 | `$40000000` | 10 | log2 e | `$3FB8AA3B` |
| 3 | 0.5 | `$3F000000` | 11 | log10 2 | `$3E9A209B` |
| 4 | 10.0 | `$41200000` | 12 | √2 | `$3FB504F3` |
| 5 | π | `$40490FDB` | 13 | 1/√2 | `$3F3504F3` |
| 6 | π/2 | `$3FC90FDB` | 14 | +∞ | `$7F800000` |
| 7 | 2π | `$40C90FDB` | 15 | NaN | `$7FC00000` |

Rounded to nearest, whatever MCTRL says, as the 68881's FMOVECR constant
ROM does.

## Formats

- **FP32:** IEEE 754 binary32, little-endian: byte 0 holds significand bits
  0-7, byte 3 the sign and exponent bits 1-7. This is C's `float` under
  llvm-mos, and `STQ` and `LDQ` move it in one instruction (A = byte 0).
- **int32:** two's complement, little-endian.
- **s15.16:** an int32 holding value x 65536.
- **int16 (FTOI16):** in MINT, sign-extended to 32 bits.

## Arithmetic

Every result is IEEE 754-2008 binary32, rounded once, by MCTRL's mode, from
the exact result.

- **FADD, FSUB, FSUBR, FMUL, FDIV, FDIVR, FSQRT, FRECIP:** correctly rounded.
  FRECIP is `1.0 / Fs`, one rounding.
- **Subnormals:** accepted and produced; no flush to zero.
- **Underflow:** tininess is detected after rounding. The underflow flag is
  raised only when the result is also inexact.
- **NaN:** every NaN result is the default NaN, `$7FC00000`. A signalling
  NaN operand raises invalid. Payloads are not propagated.
- **FMOVE, FABS, FNEG, FXCHG:** bit operations. No flags, and a signalling
  NaN passes through unchanged.
- **FCMP:** a quiet compare; invalid only for a signalling NaN.
- **FMIN, FMAX:** IEEE 754-2008 minNum and maxNum, with -0 below +0.
  - one quiet NaN: the other operand
  - two quiet NaNs: the default NaN
  - any signalling NaN: invalid and the default NaN
- **FRINT, FTRUNC:** roundToIntegral, with no inexact flag. A signalling
  NaN gives invalid and the default NaN.
- **FTOI, FTOX, FTOI16:** rounded by MCTRL's mode, inexact when the value
  changed.
  - out of range: saturates to the type's limit and raises invalid
  - NaN: gives 0 and raises invalid
  - FTOX rounds Fs x 2^16 exactly once.
- **FILD, FXLD:** rounded by MCTRL's mode; FXLD scales by 2^-16 exactly
  after rounding.

## Queue and timing

Every command, and every write to MCTRL or MFLAGS, enters one 16-entry
queue (a memory form carries its 32-bit value) and runs in order. Execution
times of the arithmetic core (`src/vhdl/mcp_fpu.vhdl`), measured by its
bench in 40.5 MHz clocks from start to done:

| Commands | Clocks |
|---|---|
| FMOVE FABS FNEG FCONST FCLASS FCMP FMIN FMAX | 5 |
| FRINT FTRUNC FTOI FTOX FTOI16 FILD FXLD | 7 |
| FADD FSUB FSUBR FMUL | 8 |
| FDIV FDIVR FRECIP FSQRT | 33 (one quotient or root bit a clock) |

The first targets were 2, 4 and about 30; the core spends extra clocks on
separate unpack, special-case and rounding steps, which can be merged later
if it matters. A command costs the CPU at least a few bus accesses, so only
chains of divides and square roots can fill the queue. Sixteen divides take
about 530 clocks (13 µs). MSTATUS bit 1 warns at 12 queued; a command that finds
the queue full is dropped and sets bit 2.

Bus accesses per operation:

| Path | Accesses |
|---|---|
| register form | 1 write |
| memory form | 4 writes (one `STQ`), plus the pointer's low bytes when the form or register changes |
| stream | 2 writes (register form), 6 (memory form) |
| reading Fd or MINT | 4 reads (one `LDQ`), after polling MSTATUS (1 read a poll) |

## Example

`F0 = √(x² + y²)` for FP32 values in memory, with three 32-bit base-page
pointers. It assembles with ACME 0.97:

```
mcp     = $02              ; (4) $0FFDF100: the control page (Z picks the register or the command)
mcpf0   = $06              ; (4) $0FFDF400: F0 (read), FMOVE F0 (write)
mcpf1   = $0a              ; (4) $0FFDF404: F1

hypot:                     ; F0 = sqrt(x * x + y * y)
        ldq x_val
        stq [mcpf0]        ; F0 = x
        ldq y_val
        stq [mcpf1]        ; F1 = y
        ldz #$80 + $04     ; FMUL
        lda #$00           ; F0 = F0 * F0
        sta [mcp],z
        lda #$11           ; F1 = F1 * F1
        sta [mcp],z
        ldz #$80 + $01     ; FADD
        lda #$01           ; F0 = F0 + F1
        sta [mcp],z
        ldz #$80 + $0a     ; FSQRT
        lda #$00           ; F0 = sqrt(F0)
        sta [mcp],z
        ldz #0
-       lda [mcp],z        ; MSTATUS bit 0: wait while busy
        and #1
        bne -
        ldq [mcpf0]        ; Q = F0 (LDQ adds Z, which is 0 here)
        stq result
        rts
```

A command list for the stream port, copied by DMA to `$FFDF120` with the
destination held:

```
cmds:   !byte $80, $00     ; FMOVE F0, v (memory form)
        !32 $40490fdb      ;   v = pi
        !byte $84, $00     ; FMUL F0, v
        !32 $40000000      ;   v = 2.0
        !byte $15, $10     ; FCONST F1 = constant 0 (+0.0)
        !byte $01, $10     ; FADD F1 = F1 + F0
```

Mind Z: `LDQ` and `STQ` overwrite it, and `LDQ [zp]` adds it.

## Verification (2026-11-12)

**The reference.** Berkeley SoftFloat 3e and TestFloat 3e (BSD licence),
fetched and built by `sim/fetch.sh`, not committed:
- SoftFloat is pinned at `a0c6494` (2025-03-07), the last commit before bf16
  support, which the ARM specialisations can't build yet; TestFloat at
  `a9c849f`.
- It is built with the `ARM-VFPv2-defaultNaN` specialisation: default NaN
  `$7FC00000`, a NaN converts to integer 0, out-of-range values saturate.
- Tininess is set to after rounding (`softfloat_detectTininess`;
  TestFloat's `-tininessafter`).
- TestFloat's own self-test (`testsoftfloat`) passes on this build for every
  function the MCP uses, in every rounding mode.

**The model** (`model/mcp_model.c`), checked by `model/mcpcheck.c`:
- against TestFloat, levels 1 and 2, all four rounding modes, for `f32_add`,
  `f32_sub` (and FSUBR), `f32_mul`, `f32_div` (and FDIVR), `f32_sqrt`,
  `f32_roundToInt` (FRINT; FTRUNC in every mode against the toward-zero
  vectors), `f32_to_i32`, `i32_to_f32`, `f32_eq`, `f32_lt_quiet`,
  `f32_le_quiet`: 202,599,984 vectors, 0 differences
- what SoftFloat has no function for, against the host's own floating point
  in each rounding mode (FTOX, FTOI16, FXLD, FMIN, FMAX, FCLASS, FRECIP,
  FCONST): 13,799,214 checks, 0 differences
- the stream port against the same commands given directly: 20,000 lists
- 11 planted bugs, all caught (one only after the checker was fixed to run
  FTRUNC in every rounding mode)

**The arithmetic core** (`src/vhdl/mcp_fpu.vhdl`), by `sim/run_fpu.sh` and
`sim/tb_mcp_fpu.vhdl`: every result, flag and write enable compared with the
model's (`model/mcpvec.c`; the vectors stream through a pipe):
- TestFloat level 1 plus 20,000 random operands per operation: 1,692,688
  vectors identical
- TestFloat level 2 plus 100,000 random per operation: 190,207,600 vectors
  identical (28 minutes)
- 15 planted bugs, all caught: rounding half-up instead of to even,
  tininess before rounding, underflow without inexact, subnormals flushed,
  no sticky bit in the divider, the multiplier or the alignment, the square
  root's odd exponent, overflow to infinity when rounding toward 0, the
  sign of an exact cancellation, NaN payloads propagated, the negative int32
  limit, the sign of zero in min/max, -0 unequal to +0, int to float without
  its sticky bit

**The whole unit** (`src/vhdl/mcp.vhdl`), by `sim/run.sh` and
`sim/tb_mcp.vhdl`, through the fastio bus:
- random scripts from `model/mcpgen.c` mixing all three issue paths, MCTRL
  and MFLAGS writes, MSTATUS writes, MRESET, partial memory forms, stream
  bytes interleaved with the other paths and cut off by MSTREAMRST, and
  reserved opcodes; at every checkpoint all of F0-F15, MINT, MCOND, MFLAGS,
  MCTRL, MSTATUS, MQLEN, MID and MVER read back and compared
- seeds 2-13 at the CPU's and the DMA's bus rates, 20,000 commands each
  (about 45,000 writes and 51,000 compared reads a run): all identical
- the overrun test: 40 divides back to back fill the queue (MQLEN 16), set
  MSTATUS bit 2, and a write to MSTATUS clears it
- 15 planted bugs: 14 caught at once. The 15th (the stream's command
  length) was planted where it could never take effect; planted where it
  does, it was caught too.

**The build.** The R6 bitstream with MCP-1 builds (Vivado 2022.2) and meets
timing: WNS +0.076 ns, no failing endpoints (+0.209 ns without it). The
worst path is in the VIC-IV's sprite fetch; none of the worst paths go
through the MCP. The only critical warnings are the core's own timing loops
(`gs4510.vhdl`, `mega65r6.vhdl`), as before.

**The board** (MEGA65 R6, 2026-11-12). `demo/mcptest.asm` replays an
mcpgen script from attic RAM and keeps every read; `demo/hwtest.sh` loads
the bitstream over JTAG and compares the reads with the model's. Three
scripts (seeds 1, 2 and 3: 3,000, 6,000 and 6,000 commands): 7,275, 15,075
and 13,275 reads, all identical. The board reports MID `$4D` and the vertex
unit's CAPS `$68`. The script's overrun test is left out: the CPU's loop is
too slow to fill the queue the way the bench's DMA-rate writes do.

## Timings (board, 2026-11-12)

The base timing for what comes next: `demo/mandel/`, run by `bench.py`.
- **The work:** a 40 x 25 Mandelbrot, at most 32 iterations a point,
  10,262 iterations in all.
- **Inputs:** x0 = -2 + col/16, y0 = -1.5 + row/8, exact in every format.
- **Same operations everywhere:** x² and y², the escape test, then
  y = (t + t) + y0 with t = xy, and x = (x² - y²) + x0.
- **The clock:** CIA 2's timers cascaded, started before the first point
  and stopped after the last. In the board's NTSC mode the CIA's "1 MHz" is
  65 ticks per raster line of 1,716 pixels at 27 MHz, which is 1,022,727 Hz
  (`calibrate.py` measures it against the host).

| Version (40.5 MHz) | Time | Per iteration | vs MCP-1 |
|---|---|---|---|
| MCP-1, FP32 in hardware (`mandel_mcp.asm`) | 61.9 ms | 6.0 µs | |
| C, llvm-mos soft-float, FP32 (`mandel.c`, `-Os`) | 1,932.9 ms | 188.4 µs | 31 x slower |
| BASIC 65, 40-bit floats (`mandel.bas`) | 7,697.4 ms | 750.1 µs | 124 x slower |

- **Results:** all three return the same 1,000 counts as the host's FP32
  and double references. No point lies close enough to the boundary for 24-
  against 32-bit significands to matter.
- **What sets MCP-1's pace:** the CPU, not the arithmetic. An iteration is
  13 register-form commands (about 100 clocks of arithmetic, 2.5 µs), then
  a wait and an MCOND read; issuing the 13 commands over the fastio bus
  takes most of the 6 µs. That is the case for MCP-2's microcode (an
  iteration as one command) and for DMA'd command lists.
- **The comparison includes the language:** hand-written assembly against
  compiled C against interpreted BASIC. BASIC runs with its usual
  interrupts; the other two turn them off.

**Not yet:** C through the MCP (an MCP-backed version of llvm-mos's
soft-float calls), which would separate the hardware's gain from the
language's.

## Deliverables

| | | |
|---|---|---|
| `src/vhdl/mcp.vhdl`, `src/vhdl/mcp_fpu.vhdl` | the unit and its arithmetic core | done, simulated |
| `src/vhdl/iomapper.vhdl` | the slot's decode: the MCP answers `$100-$7FF` (the vertex unit had `$000-$0FF` and `$800-$FFF` until its removal after MCP-2) | done |
| `src/mcp/model/` | `mcp_model.c` on SoftFloat, `mcpcheck.c`, `mcpvec.c`, `mcpgen.c` | done |
| `src/mcp/sim/` | `fetch.sh`, the core's bench (`run_fpu.sh`), the unit's (`run.sh`) | done |
| `src/mcp/demo/` | `mcptest.asm`, `build.sh`, `hwtest.sh` | done, passes on the board |
| `src/mcp/demo/mandel/` | the Mandelbrot timing: MCP-1, C and BASIC 65 versions, `bench.py`, `calibrate.py`, `bas2prg.py` | done, base timings above |
| `src/mcp/include/mcp.inc` | ACME addresses, opcodes, macros | done (assembles) |
| `src/mcp/README.md` | what's where, how to run the checks | done |

## Open points for MCP-1

Taken for now, as defaults, and open to change:

- **Queue depth:** 16, with the warning at 12.
- **Divider radix:** radix 2 (33 clocks, era-typical) in MCP-1 and MCP-2;
  two steps a clock since MCP-3 stage 2 (20 clocks, the same results).
- **The memory-form window:** 1 KB, because `STQ [zp]` ignores Z.
- **The slot's decode:** in the iomapper; the MCP is its own entity. (It was
  split with the vertex unit until that was removed after MCP-2.)
