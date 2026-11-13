# M65-MCP hardware reference

What the MEGA65 Mathematics Coprocessor looks like to a program: its
registers, commands, memory layout and timing. This describes the unit as
built (MVER `$03`). The reasons, the alternatives and the build history
are in [`MCP.md`](MCP.md) and [`MCP1.md`](MCP1.md) to [`MCP3.md`](MCP3.md);
the ACME include is [`include/mcp.inc`](include/mcp.inc), worked examples
are in [`sdk/`](sdk/), and known problems in [`ISSUES.md`](ISSUES.md).

Every timing here was measured on a MEGA65 R6 (`demo/vtime/vtime.py`,
`demo/geo/geo.py`); a clock is the core's 40.5 MHz clock, 24.7 ns.

Without a MEGA65: Xemu's `mcp` branch emulates the unit as described here,
its timing included ([`README.md`](README.md), "Without a MEGA65").

## Contents

1. [Overview](#1-overview)
2. [Memory map](#2-memory-map)
3. [Data formats](#3-data-formats)
4. [Registers](#4-registers)
5. [Issuing commands](#5-issuing-commands)
6. [Scalar commands](#6-scalar-commands)
7. [Arithmetic](#7-arithmetic)
8. [Vectors and matrices](#8-vectors-and-matrices)
9. [Programs](#9-programs)
10. [The vertex path](#10-the-vertex-path)
11. [Timing](#11-timing)
12. [Reset](#12-reset)
13. [The 45GS02's side](#13-the-45gs02s-side)
14. [DMA](#14-dma)

## 1. Overview

The MCP is a coprocessor in the MEGA65 core, reached through one page of
I/O at `$FFDF000-$FFDFFFF`. It holds:

- **16 registers, F0-F15**, each an IEEE 754 binary32 value (FP32). The
  same registers seen four at a time are the **vectors V0-V3**: V0 is
  F0-F3 as x, y, z, w; V1 is F4-F7; V2 is F8-F11; V3 is F12-F15.
- **A matrix bank, M0-M15**: one 4 x 4 matrix by rows.
- **Program memory**: 512 commands in block RAM. A program runs a number
  of passes without the CPU.
- **A vertex array** (16 KB) that programs read records from, and **a
  result buffer** (32 KB, 1,024 entries of 32 bytes) that they write to.

The CPU sends **commands**. Each is one write (or one 32-bit write), goes
into a 16-entry queue and runs in order. Results stay in the registers
until the CPU reads them. Nothing interrupts and nothing stalls the CPU: a
program polls MSTATUS and reads when the unit is idle.

**Is it there?** MID at `$FFDF101` reads `$4D` ("M") and MVER at `$FFDF102`
reads `$03`. On a core without the MCP that address reads `$00`.

## 2. Memory map

Offsets are from `$FFDF000`.

| Offset | | Access |
|---|---|---|
| `$000-$00F` | the vertex page: the vertex array's port and the vertex path's registers ([4.2](#42-the-vertex-page-000-00f)) | read, write |
| `$010-$0FF` | reserved | reads 0 |
| `$100-$137` | the control page: status, results, the stream and program ports ([4.1](#41-the-control-page-100-137)) | read, write |
| `$180-$1FF` | register forms: a write to `$180 + opcode` issues a command | write |
| `$200-$2FF` | wide forms: two writes at `$200 + op * 2` issue a command | write |
| `$300-$3FF` | reserved | reads 0 |
| `$400-$43F` | F0-F15, four bytes each: read | read |
| `$400-$7FF` | memory forms: a 32-bit write to `$400 + m * 64 + d * 4` issues a command | write |
| `$800-$FFF` | the window: 2 KB of the result buffer, chosen by VBANK | read |

Reads of anything not listed return 0; writes there do nothing.

## 3. Data formats

- **FP32:** IEEE 754 binary32, little-endian: byte 0 holds significand
  bits 0-7, byte 3 the sign and exponent bits 7-1. `STQ` and `LDQ` move one
  in a single instruction (A is byte 0).
- **int32:** two's complement, little-endian.
- **s15.16:** an int32 holding the value times 65,536.
- **int16:** as MINT returns it, sign-extended to 32 bits.

## 4. Registers

### 4.1 The control page (`$100-$137`)

| Offset | Name | |
|---|---|---|
| `$100` | MSTATUS | read: bit 0 **busy** (a command queued or running, a program running, or bytes on their way to the result buffer); bit 1 the queue nearly full (12 or more queued); bit 2 **overrun** (sticky: a command arrived with the queue full and was dropped); bit 3 **bad opcode** (sticky: a reserved command was ignored); bit 4 a program running; bit 5 **a program aborted** (sticky; MPERR says why); bit 7 any MFLAGS bit set. Write any value: clears bits 2, 3 and 5 |
| `$101` | MID | reads `$4D` |
| `$102` | MVER | reads `$03` |
| `$103` | MQLEN | read: commands queued, not counting the one running (0-16) |
| `$104` | MCTRL | bits 0-1 the rounding mode: 0 to nearest-even, 1 toward -∞, 2 toward +∞, 3 toward 0. A write is queued (it is the command SETCTRL), so it applies to the commands after it. A read gives the mode in effect |
| `$105` | MFLAGS | the sticky exception flags: bit 0 invalid, bit 1 divide by zero, bit 2 overflow, bit 3 underflow, bit 4 inexact. A read gives the flags of the commands completed so far. A write is queued (SETFLAGS) and replaces them, so writing 0 clears them |
| `$106` | MCOND | read: the result of the last FCMP, FCLASS or VCLIP ([6.4](#64-mcond)) |
| `$107` | MRESET | write any value: resets the unit ([12](#12-reset)) |
| `$108-$10B` | MINT | read: the int32 result of FTOI, FTOX or FTOI16 |
| `$10C-$10D` | MPPTR | the program memory entry (0-511) that MPLOAD writes and MPREAD reads; it advances a command at a time |
| `$10E-$10F` | MPCNT | read: the passes the last PRUN completed |
| `$110` | MPERR | read: why the last program aborted: 0 it did not, 1 it ran past entry 511, 2 MPLIMIT reached, 3 MPABORT, 4 a reserved command or a PRUN in it |
| `$114-$116` | MPLIMIT | the commands one PRUN may execute before it aborts (24 bits; 0: no limit; `$100000` after MRESET). Taken when a PRUN starts |
| `$120-$123` | MSTREAM | write: the command stream ([5.4](#54-the-stream)). All four addresses are one port |
| `$124` | MSTREAMRST | write any value: the stream restarts at a command boundary (a partly written command is dropped) |
| `$128-$12B` | MPLOAD | write: commands into program memory at MPPTR, in the stream's format. All four addresses are one port |
| `$12C` | MPLOADRST | write any value: MPLOAD restarts at a command boundary |
| `$12D` | MPABORT | write any value: the running program stops at the next command (MPERR 3). The registers keep their values |
| `$130-$137` | MPREAD | read: the program memory entry at MPPTR ([9.5](#95-reading-a-program-back)) |

**Reading more than one byte.** Reading byte 0 of an F register or of MINT
latches its other three bytes, and reading MPCNT's low byte latches the high
one, so an `LDQ` (or two reads) sees one consistent value.

**Nothing waits.** A read returns what is there now. To read a result,
first poll MSTATUS until bit 0 is clear.

### 4.2 The vertex page (`$000-$00F`)

| Offset | Name | |
|---|---|---|
| `$000-$003` | VINDATA | write: a byte into the vertex array at VINPTR, which advances. All four addresses are one port |
| `$004-$005` | VINPTR | the vertex array's write address (14 bits) |
| `$006-$007` | VINIDX | the record VIN reads: a byte address in the vertex array (14 bits, bits 1-0 always 0). VNEXT moves it on by one record |
| `$008` | VFMT | the record format, 5 bits ([10.1](#101-records-vfmt)) |
| `$009` | VPOSEXP | s16 positions are scaled by 2^-n (n 0-15) |
| `$00C-$00D` | VTXIDX | the result buffer entry the stores go to (0-1023). VEND moves it on, wrapping from 1023 to 0 |
| `$00E` | VBANK | which 2 KB (64 entries) of the result buffer the window shows (0-15) |

All of these read back. Unlike commands, **writes here take effect at
once**: write them while the unit is idle.

## 5. Issuing commands

A command names a destination d, a source s and sometimes a third
register t, each 0-15 (an F register, or 0-3 for a V register). There are
three forms, and a stream that carries any of them.

### 5.1 Register forms

One byte write: `(d << 4) | s` to `$180 + opcode`. Opcodes `$00-$7F`.

```
        ldz #$80 + $01      ; FADD (Z = the offset in the control page)
        lda #$12            ; F1 = F1 + F2
        sta [mcp],z         ; mcp: a 32-bit pointer to $FFDF100
```

For a few commands the byte is data, not registers (SETCTRL, SETFLAGS,
PEXIT, VPASS).

### 5.2 Memory forms

One 32-bit write of v to `$400 + m * 64 + d * 4`: `Fd = Fd op v`, m 0-15.
Bytes 0-2 are held, and writing byte 3 issues the command, so one `STQ`
does it. The operand comes with the command: nothing has to be loaded
first.

```
        ldq value           ; an FP32
        stq [mcpf1add]      ; a pointer to $FFDF400 + 1 * 64 + 1 * 4: F1 = F1 + value
```

A write to `$400 + d * 4` (m = 0) is FMOVE: it loads Fd.

### 5.3 Wide forms

Two byte writes: `(d << 4) | s` to `$200 + op * 2`, then `t << 4` to
`$201 + op * 2`. The second write issues the command. Ops `$00-$7F`.

```
        ldz #$02 * 2        ; FMUL3 (Z = the offset from $FFDF200)
        lda #$12            ; F1 = F2 x ...
        sta [wide],z
        inz
        lda #$30            ; ... F3
        sta [wide],z
```

### 5.4 The stream

MSTREAM (`$120-$123`) takes the same commands as bytes, so a DMA job with
its destination held, or code with one pointer, can issue any of them.
MPLOAD takes the same format into program memory.

| First byte | Bytes | |
|---|---|---|
| `$00-$7F` | 2 | a register form: the opcode, then `(d << 4) \| s` |
| `$80-$8F` | 6 | a memory form: `$80 + m`, `d << 4`, then v (4 bytes, low first) |
| `$90` | 4 | a wide form: `$90`, the op, `(d << 4) \| s`, `t << 4` |
| `$91-$FF` | 2 | reserved: ignored, MSTATUS bit 3 |

### 5.5 The queue

- Every command, and every write to MCTRL or MFLAGS, enters one queue of
  16 entries and runs in order.
- The unit usually empties it faster than a CPU can fill it (a register
  form takes the CPU 9 cycles to issue, and most commands one clock to
  start). Only slow commands back to back fill it: divides, square roots,
  vector and matrix commands, or anything queued behind a PRUN.
- A command that finds the queue full is dropped, and MSTATUS bit 2 says
  so. MSTATUS bit 1 warns at 12 queued. [`sdk/async.asm`](sdk/async.asm)
  shows both: 64 divides sent by a DMA job, of which 35 are dropped, and
  the same 64 with bit 1 heeded.
- **Reserved commands** are ignored and set MSTATUS bit 3. In a program
  they abort it instead (MPERR 4).

## 6. Scalar commands

Flags: V invalid, Z divide by zero, O overflow, U underflow, X inexact.

### 6.1 Register forms

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
| `$12` | FTOI16 | MINT = int16(Fs) saturated, sign-extended | V X |
| `$13` | FRECIP | Fd = 1 / Fs | V Z O U X |
| `$14` | FXCHG | Fd and Fs swapped | none |
| `$15` | FCONST | Fd = constant s ([6.5](#65-constants-fconst)) | none |
| `$16` | SETCTRL | MCTRL = the data byte | none |
| `$17` | SETFLAGS | MFLAGS = the data byte | none |
| `$18` | PEXIT | in a program: leave it if `MCOND and data` is not 0 ([9](#9-programs)) | |
| `$19` | PEND | in a program: the end of a pass | |
| `$1A` | VNEXT | VINIDX moves on by one record ([10](#10-the-vertex-path)) | |
| `$1B` | VPASS | the record's attribute words into the entry, from word (data) | |
| `$1C` | VCLIP | Vs's clip codes into MCOND and the entry's byte 30 | |
| `$1E` | VEND | the entry done: VTXIDX moves on | |
| `$1D`, `$1F-$7F` | | reserved | |

### 6.2 Memory forms

Forms 0-10 are the register forms `$00-$0A` with v in place of Fs.

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
| 14 | PRUN | run a program: v bits 0-8 its first entry, bits 16-31 the passes (0: 65,536). d is ignored ([9](#9-programs)) |
| 15 | | reserved |

### 6.3 Wide forms (scalar)

| Op | Name | Operation |
|---|---|---|
| `$00` | FADD3 | Fd = Fs + Ft |
| `$01` | FSUB3 | Fd = Fs - Ft |
| `$02` | FMUL3 | Fd = Fs x Ft |
| `$03` | FMA | Fd = Fs x Ft + Fd, rounded once |
| `$04` | FMS | Fd = Fd - Fs x Ft, rounded once |

The other wide forms are in [8](#8-vectors-and-matrices),
[9](#9-programs) and [10](#10-the-vertex-path). Ops not listed anywhere
are reserved.

### 6.4 MCOND

- **After FCMP:** exactly one of bit 0 (less: Fd < Fs), bit 1 (equal),
  bit 2 (greater), bit 3 (unordered: a NaN). -0 equals +0.
- **After FCLASS:** bit 0 is the sign, plus exactly one of bit 1 (zero),
  bit 2 (subnormal), bit 3 (normal), bit 4 (infinity), bit 5 (quiet NaN),
  bit 6 (signalling NaN).
- **After VCLIP:** the clip codes ([10.4](#104-clip-codes-vclip)).

Other commands leave MCOND alone.

### 6.5 Constants (FCONST)

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

## 7. Arithmetic

Every result is IEEE 754-2008 binary32, rounded once from the exact
result, by the rounding mode in effect when the command was issued. It is
checked bit for bit against Berkeley SoftFloat 3e.

- **FADD, FSUB, FSUBR, FMUL, FDIV, FDIVR, FSQRT, FRECIP, FADD3, FSUB3,
  FMUL3:** correctly rounded. FRECIP is `1.0 / Fs`, one rounding.
- **FMA, FMS:** fused: the product is not rounded before the addition. FMS
  is `fma(-Fs, Ft, Fd)`.
- **Subnormals:** accepted and produced; no flush to zero.
- **Underflow:** tininess is detected after rounding, and the flag is
  raised only when the result is also inexact.
- **NaN:** every NaN result is the default NaN, `$7FC00000`. A signalling
  NaN operand raises invalid. Payloads are not propagated.
- **FMOVE, FABS, FNEG, FXCHG:** bit operations. No flags, and a signalling
  NaN passes through unchanged.
- **FCMP:** a quiet compare; invalid only for a signalling NaN.
- **FMIN, FMAX:** minNum and maxNum, with -0 below +0. One quiet NaN: the
  other operand. Two: the default NaN. A signalling NaN: invalid and the
  default NaN.
- **FRINT, FTRUNC:** roundToIntegral, with no inexact flag.
- **FTOI, FTOX, FTOI16:** rounded by MCTRL's mode, inexact when the value
  changed. Out of range: the type's nearest limit, and invalid. NaN: 0,
  and invalid. FTOX rounds Fs x 2^16 exactly once.
- **FILD, FXLD:** rounded by MCTRL's mode; FXLD scales by 2^-16 exactly.
- **The constants** are rounded to nearest, whatever MCTRL says.
- **The flags** are sticky and accumulate in MFLAGS until SETFLAGS (a write
  to MFLAGS) replaces them.

## 8. Vectors and matrices

V0-V3 are F0-F3, F4-F7, F8-F11 and F12-F15 (x, y, z, w). M0-M15 is a 4 x 4
matrix by rows: M[r][c] is M(4r + c). All of these are wide forms; d, s and
t name V registers unless the table says F.

| Op | Name | Operation |
|---|---|---|
| `$10` | VMOVE | Vd = Vs |
| `$11` | VADD | Vd = Vs + Vt, component by component |
| `$12` | VSUB | Vd = Vs - Vt |
| `$13` | VMUL | Vd = Vs x Vt, component by component |
| `$14` | VSCALE | Vd = Vs x Ft (t an F register) |
| `$15` | VDOT3 | Fd = Vs . Vt over x, y, z (d an F register) |
| `$16` | VDOT4 | Fd = Vs . Vt over x, y, z, w (d an F register) |
| `$17` | VCROSS | Vd.xyz = Vs.xyz x Vt.xyz, Vd.w = +0 |
| `$18` | VNORM3 | Vd.xyz = Vs.xyz / length(Vs.xyz), Vd.w = Vs.w |
| `$20` | MLOAD | M0-M15 = F0-F15 |
| `$21` | MSTORE | F0-F15 = M0-M15 |
| `$22` | MXV | Vd = M x Vs |
| `$23` | MTXV | Vd = transpose(M) x Vs |
| `$24` | MMUL | M = M x F (F0-F15 as a 4 x 4 matrix by rows) |

- **Operands may overlap.** A result is complete before it is written, so
  `VCROSS V1, V1, V2` and `MXV V0, V0` are fine.
- **Each step is one of [7](#7-arithmetic)'s operations**, its flags into
  MFLAGS:
  - **VDOT3, VDOT4:** left to right, the first a product, the rest fused:
    `d = s.x x t.x; d = fma(s.y, t.y, d); d = fma(s.z, t.z, d)` (and
    `fma(s.w, t.w, d)`).
  - **MXV:** Vd[r] = row r of M dotted with Vs, as VDOT4. **MTXV:** column
    r instead.
  - **MMUL:** M[r][c] = M[r][0] x F[c], then fused with M[r][1] x F[4 + c],
    M[r][2] x F[8 + c], M[r][3] x F[12 + c].
  - **VCROSS:** `x = fma(s.y, t.z, -(s.z x t.y))`, and y and z likewise.
  - **VNORM3:** `n = VDOT3(s, s); r = √n; q = 1 / r`, then x, y and z times
    q. A zero vector gives NaN components and invalid.
- **To multiply two matrices A x B:** load A into F0-F15, MLOAD, load B,
  MMUL. To compose a third, load it and MMUL again. MSTORE brings the
  product back.

## 9. Programs

A program is a list of commands in program memory, run for a number of
passes without the CPU: a loop body, an iteration, a vertex.

### 9.1 Loading

1. Write MPLOADRST, and MPPTR with the first entry (0-511).
2. Write the commands to MPLOAD in the stream's format
   ([5.4](#54-the-stream)). Each command takes one entry, whatever its
   length in bytes, and MPPTR advances.

Program memory keeps its contents over MRESET. Do not load while a
program runs. A program can be changed in place: set MPPTR to an entry and
write a command over it (a constant in a memory form, for example).

### 9.2 Running

PRUN (memory form 14) with v = `passes << 16 | first entry` goes through
the queue like any command. When it executes:

- each pass runs commands from the first entry until **PEND**; then the
  next pass starts at the first entry again
- **PEXIT** with a data byte that has a bit in common with MCOND leaves the
  program at once; that pass is not counted
- after the given number of passes the program ends

MPCNT then holds the passes completed, and the queue goes on with the next
command. The CPU may keep queueing commands while a program runs; MSTATUS
bit 0 stays set until everything is done.

The registers are the program's variables: they keep their values from
pass to pass, and are how it takes its inputs and returns its results.

### 9.3 Commands for programs

| Form | Name | Operation |
|---|---|---|
| register `$18` | PEXIT | leave if `MCOND and data` is not 0 |
| register `$19` | PEND | the end of a pass |
| wide `$28` | PSKIP | if `MCOND and (d << 4 \| s)` is not 0, skip the next t commands (0-15). A skip past entry 511 aborts (MPERR 1) |

Outside a program all three do nothing. PEXIT and PSKIP wait for MCOND, so
`FCMP` then `PEXIT` needs nothing in between. There are no backward jumps
and no calls: a pass is straight-line code with skips, and the loop is the
pass count.

### 9.4 Ending early

A program **aborts**, with MSTATUS bit 5 set and MPERR saying why, when:

- it runs past entry 511 without a PEND (MPERR 1)
- it has executed MPLIMIT commands (2): a guard against a pass count that
  is far too large. `$100000` after MRESET; 0 means no limit
- the CPU writes MPABORT (3)
- it meets a reserved command or a PRUN (4): programs do not nest

MPCNT holds the passes completed, and the registers keep what the program
left in them. The queue goes on with the next command, so software checks
bit 5 (or MPERR).

### 9.5 Reading a program back

With no program running, set MPPTR and read the 8 bytes of MPREAD:

| Byte | |
|---|---|
| `$130` | the form: 0 register, 1 memory, 2 wide. Reading it latches the rest |
| `$131` | the opcode (a memory form: `$80 + m`) |
| `$132` | `(d << 4) \| s` |
| `$133-$136` | the operand: a memory form's v; a wide form's `t << 4` in the low byte |
| `$137` | 0. Reading it advances MPPTR |

### 9.6 Example

Newton's iteration for √a, as a program. F0 = a, F1 = the estimate, F2 =
0.5; each pass is `x = (x + a / x) x 0.5`, and it leaves when x stops
changing:

```
        FMOVE  F3, F1       ; the old estimate
        FMOVE  F4, F0
        FDIV   F4, F1       ; a / x
        FADD   F1, F4       ; x + a / x
        FMUL   F1, F2       ; times 0.5
        FCMP   F1, F3
        PEXIT  $02          ; equal: done
        PEND
```

`PRUN 0, 20` runs at most 20 passes; MPCNT says how many it took.
[`sdk/program.asm`](sdk/program.asm) is this program.

## 10. The vertex path

For programs that work through many records: a vertex array to read them
from, a result buffer to write to, and commands that convert on the way in
and out. A **vertex program** is an ordinary program that does one record
a pass.

### 10.1 Records (VFMT)

The vertex array is 16 KB. The CPU (or a DMA job) writes it through
VINDATA at VINPTR. A record's fields are whole 32-bit words, in this order:

| VFMT bits | Field | Bytes | |
|---|---|---|---|
| 0 | position | 8 or 12 | 0: s16 x, y, z and a pad, each x 2^-VPOSEXP. 1: FP32 x, y, z |
| 1 | normal | 0 or 4 | s8 nx, ny, nz and a pad, each x 2^-7 (127 is 0.992) |
| 2 | colour | 0 or 4 | u8 r, g, b, a, each x 2^-8 |
| 3-4 | attributes | 0-12 | 0-3 words passed through unchanged |

A record is 8 to 32 bytes. Every conversion is exact.

### 10.2 The result buffer

1,024 entries of 32 bytes. Stores go to the entry VTXIDX names. The CPU
reads the buffer through the window at `$800-$FFF`: 64 entries at a time,
entry `VBANK * 64 + k` at `$800 + k * 32`. Reading has no side effects.
What goes where in an entry is the program's choice.

### 10.3 Commands

| Form | Name | Operation |
|---|---|---|
| wide `$25` | VIN | Vd = field t of the record at VINIDX, as FP32: t = 0 the position (x, y, z, 1), 1 the normal (nx, ny, nz, 0), 2 the colour (r, g, b, a). A field VFMT lacks, or t > 2: reserved |
| register `$1A` | VNEXT | VINIDX moves on by one record (VFMT's size) |
| wide `$26` | VOUT | Fs into the entry at byte 2t, in format d (below) |
| wide `$27` | VOUTC | Vs's four components as bytes (each x 2^8, rounded, clamped to 0-255) into the entry at byte 2t (t even) |
| register `$1B` | VPASS | the record's attribute words into the entry, from its word n (the data byte, 0-7; the entry's 8 words wrap) |
| register `$1C` | VCLIP | Vs's clip codes into MCOND and into the entry's byte 30 |
| register `$1E` | VEND | the entry done: VTXIDX moves on |

VOUT's formats, each written low byte first:

| d | | Bytes | |
|---|---|---|---|
| 0 | FP32 | 4 (t even) | as it is |
| 1 | FP32's top half | 2 | bits 31-16: the sign, the exponent and 7 bits |
| 2 | s16 12.4 | 2 | x 2^4 |
| 3 | u16 | 2 | x 2^16 (0-1 becomes 0-65535) |
| 4 | s16 | 2 | as an integer |
| 5 | s32 16.16 | 4 (t even) | x 2^16 |
| 6-15 | | | reserved |

The conversions to integers work as FTOI: rounded by MCTRL's mode; a NaN
gives 0 and a value out of range the nearest limit, with invalid; a
rounding sets inexact.

A program that wants a store's bytes waits for the unit to go idle; an
MRESET before that drops stores still on their way.

### 10.4 Clip codes (VCLIP)

For Vs = (x, y, z, w) in clip space, each compare exact (+0 equals -0):

| Bit | |
|---|---|
| 0, 1 | x < -w, x > w |
| 2, 3 | y < -w, y > w |
| 4 | z < 0: in front of the near plane |
| 5 | z > w: beyond the far plane |
| 6 | w <= 0: behind the eye (it has no projection) |
| 7 | a NaN in x, y, z or w (then the only bit set) |

### 10.5 The standard programs

`mcp.inc` ships two vertex programs as data for MPLOAD: `+mcp_stdprog`
(transform, clip codes, project: 25 entries) and `+mcp_stdprog_lit .lx,
.ly, .lz, .ka` (the same with one directional light and an ambient term:
36 entries; the records need a normal).

- **Before the PRUN:** M = projection x view x model; F12-F15 = kx, ky, cx,
  cy (screen x = cx + kx x/w, y = cy - ky y/w); VFMT, VPOSEXP, VINIDX,
  VTXIDX. Then `PRUN first, the number of vertices`.
- **The light** (lit): .lx-.lz is the direction from the surface toward
  the light, in object space, times the diffuse term; .ka the ambient
  term. They are constants in the program: to change them, rewrite entries
  `MCPS_LIGHT` to `MCPS_LIGHT + 2`, `MCPS_AMB1` and `MCPS_AMB2`.
- **Each vertex's entry:**

  | Bytes | |
  |---|---|
  | 0-1, 2-3 | screen x, y: s16 12.4 (not written when byte 30 has bit 6 or 7) |
  | 4-5 | depth z/w: u16 (likewise) |
  | 6-7 | 1/w: FP32's top half (likewise) |
  | 8-11 | r, g, b, a (lit: r, g, b times max(N . L, 0) + ka) |
  | 12-19 | the record's two attribute words |
  | 20-23, 24-27 | clip-space x, y: FP32 |
  | 28-29 | clip-space w: FP32's top half |
  | 30 | the clip codes |

A program of your own can do anything a pass allows: `demo/show/scene.c`
has a vertex program that stores pixels as integers and a face program
that culls, sorts and shades triangles.

## 11. Timing

### 11.1 How commands run

The unit takes commands in order, **one a clock**, from the queue or from
a program. Three things make a command wait:

- **An operand not ready.** A command waits until every register it reads
  or writes has its value. How long a result takes depends on the command
  that makes it (below).
- **The divider.** Divides, square roots and conversions share one unit and
  go through it one at a time. Everything else carries on meanwhile.
- **A sequence.** Vector, matrix and some vertex commands are sequences of
  steps, and nothing else starts until a sequence has finished.

So independent commands overlap. Four FADD3 on different registers take 4
clocks; a divide with eight independent additions after it takes the
divide's 20 clocks. Order a program so that slow results are started early
and their users come last.

### 11.2 Commands

| Commands | Clocks to start | Result ready after |
|---|---|---|
| FMOVE, FABS, FNEG, FXCHG, FCONST, FCMP, FMIN, FMAX, FCLASS, SETCTRL, SETFLAGS, MLOAD, MSTORE | 1 | 1 |
| FADD, FSUB, FSUBR, FMUL (register and memory forms), FADD3, FSUB3, FMUL3, FMA, FMS | 1 | 5 |
| FRINT, FTRUNC, FTOI, FTOX, FTOI16, FILD, FXLD | 1 | 7 (less for some operands, below) |
| FDIV, FDIVR, FRECIP, FSQRT (register and memory forms) | 1 | 20 (5 for some operands, below) |
| VOUT | 1 | its bytes are in the buffer 2 clocks later; nothing waits for them |
| VCLIP, VNEXT, VEND, PEXIT and PSKIP not taken | 1 | 1 |

"Result ready after" counts from the clock the command starts to the
clock a command that uses its result can start. MLOAD and MSTORE first
wait for every F register to be ready.

**The divider is quicker when there is nothing to work out.** It takes 5
clocks, not 20 or 7, when the result follows from what the operands are:

- FDIV, FDIVR, FRECIP: an operand is a zero, an infinity or a NaN
- FSQRT: the operand is a zero, an infinity, a NaN, or negative
- FRINT, FTRUNC: the operand is a zero, an infinity, a NaN, or 2^23 or
  more (an integer already)
- FTOI, FTOX, FTOI16: the operand is a zero or a NaN
- FILD, FXLD of 0: 6 clocks

Sequences, from start to finish (nothing else starts meanwhile):

| Command | Clocks |
|---|---|
| VMOVE | 7 |
| VADD, VSUB, VMUL, VSCALE | 11 |
| VDOT3 | 18 |
| VDOT4 | 23 |
| VCROSS | 16 |
| MXV, MTXV | 26 |
| VNORM3 | 66 (36 when the length's square is a zero, an infinity or a NaN) |
| MMUL | 71 |
| VIN | 7 (the colour: 8) |
| VOUTC | 6 |
| VPASS | 2 + its words (3, 4, 5) |

VNORM3 uses the divider from its 17th clock: if a divide or square root
issued just before it still has it then, the sequence waits there.

### 11.3 Programs

- A pass costs **2 clocks** beyond its commands: PEND, and one to fetch
  the first entry again.
- A PSKIP that is taken costs 2 clocks (one to fetch the entry it skips
  to), and saves the commands it skips.
- **The standard vertex programs** take 72.7 clocks a vertex (1.79 µs)
  unlit and 89.7 (2.21 µs) lit, measured over 528 vertices.
- **The Mandelbrot's inner loop** (11 entries) takes about 1.0 µs an
  iteration.

### 11.4 The CPU's side

At 40.5 MHz, measured over 1,024 repeats:

| | Cycles | µs |
|---|---|---|
| a register form, `STA [zp],Z` | 9 | 0.22 |
| the same with its `LDZ #` and `LDA #` | 13 | 0.32 |
| a memory form, `STQ [zp]` | 15 | 0.37 |
| reading a register, `LDZ #0` and `LDQ [zp]` | 26 | 0.64 |
| one poll of MSTATUS, `LDA [zp],Z`, `AND #1`, `BNE` | 18 | 0.44 |

For short calculations the CPU's instructions, not the arithmetic, set the
pace: issuing ten commands takes longer than running them. Programs and
DMA lists are how to get past that.

### 11.5 Reading results

MSTATUS bit 0 is set from the clock a command is queued until everything
is done, stores included. Poll it, then read. The window's reads take the
bus's own wait state, which the CPU and the DMA both provide.

## 12. Reset

Writing MRESET (`$107`):

- empties the queue and stops the command in progress, a running program
  included, and drops stores still on their way to the result buffer
- sets F0-F15 and M0-M15 to +0.0, and MINT, MCOND, MFLAGS and MCTRL to 0
  (rounding to nearest)
- clears MSTATUS's sticky bits, MPCNT and MPERR; sets MPPTR to 0 and
  MPLIMIT to `$100000`; restarts the stream and MPLOAD
- sets VINPTR, VINIDX, VFMT, VPOSEXP, VTXIDX and VBANK to 0

It **keeps** the contents of program memory, the vertex array and the
result buffer. The unit is in this state after the core starts; do not
rely on what those three memories hold then.

## 13. The 45GS02's side

The MCP is above the 16-bit address space, so programs reach it through
32-bit base-page pointers. `mcp.inc` has the addresses and a few macros
(`+mcp_ptr`, `+mcp_op`, `+mcp_wait`, `+mcp_get`).

- `STA [zp],Z` and `LDA [zp],Z` add Z: one pointer to `$FFDF100` reaches
  the whole control page and every register form.
- `STQ [zp]` writes A, X, Y, Z to four addresses and **does not add Z**: a
  memory form needs a pointer to its exact address.
- `LDQ [zp]` **does add Z**, and both `LDQ` and `STQ` leave Z changed. Set
  Z before every `LDQ [zp]`.
- From BASIC 65, `POKE` and `PEEK` take the full address: `POKE
  $FFDF181,$12` is `FADD F1, F2` ([`sdk/basic.bas`](sdk/basic.bas)).
- **Under BASIC 65** the KERNAL uses all of base page 0. A program that
  returns to BASIC keeps its pointers in a base page of its own (the
  45GS02's B register) in `$1600-$1EFF`, the region the MEGA65 keeps free
  for programs, with interrupts off while B is not 0. [`sdk/sdk.inc`](sdk/sdk.inc)
  does this (`+mcp_enter`, `+mcp_leave`).

## 14. DMA

Every port is one address (four, mirrored), and the window's reads have no
side effects, so the DMA controller can do the moving. With an enhanced
(F018B) list, megabyte `$FF`, bank `$0D`:

| To do | The job |
|---|---|
| issue a command list | copy to `$F120` (MSTREAM), the destination held |
| load a program | copy to `$F128` (MPLOAD), the destination held |
| fill the vertex array | copy to `$F000` (VINDATA), the destination held |
| load F registers | copy 4 bytes a register to `$F400 + d * 4`: each fourth byte is an FMOVE |
| read results | copy from `$F800` (the window), VBANK set first |
| read one field of every entry | the same with a source step of 32 (option `$83`, `$20`) |

A list that loads F4-F7 from `values`:

```
        !byte $0b           ; an F018B list
        !byte $81, $ff      ; the destination's megabyte
        !byte $00           ; the options' end
        !byte $00           ; copy
        !word 16            ; four registers
        !word values        ; from (bank 0)
        !byte $00
        !word $f410         ; to $FFDF410: F4
        !byte $0d
        !byte $00           ; (to hold the destination instead: $08)
        !word 0
```

The DMA can outrun the queue only with slow commands back to back; check
MSTATUS bit 2 once when developing a list.
