# M65-MCP: the MEGA65 Mathematics Coprocessor

Design, 2026-11-12. Decisions 1-4 taken (Steve, 2026-11-12; decision 4
changed the same day). MCP-1 ([`MCP1.md`](MCP1.md)) and MCP-2
([`MCP2.md`](MCP2.md)) are built, and checked in simulation and on a
MEGA65 R6.

## Why

The 45GS02 has no floating point. BASIC 65 does its 5-byte floats in
software, and llvm-mos C turns every `float` operation into a library call:
about 10 µs per operation, as measured in m65tr3d's bench demo. A 3D
program pays about 30 of those per vertex, around 300 µs.

The MEGA65 already has two math units, both integer or fixed point:

- the multiplier and divider at `$D770` (32 x 32 bits)
- the "Formula Plumbing Unit" ([`docs/math-unit.md`](../../docs/math-unit.md)):
  16 fixed-point registers wired together like a spreadsheet

The vertex unit this core started with (m65tr3d's, removed after MCP-2)
did geometry only, in fixed point, so a program converted its data before
using it.

M65-MCP fills that gap with a floating-point and vector coprocessor that
ordinary MEGA65 software can use, for 3D and for anything else. It is meant
to be something that could have been built as an expansion for a machine of
the C65's time (1991), alongside the 68881/68882, the 387, the Weitek 3167
and the TMS320C30.

## What it is: three groups, one datapath

The three groups are instruction groups, not three blocks of hardware:

| Group | Operations | Milestone |
|---|---|---|
| Scalar FPU | FP32 add, subtract, multiply, divide, square root, compare, min/max, abs/negate, round, conversions (int16, int32, 16.16 fixed), constants | MCP-1 |
| Vector math unit | vec3/vec4 add, subtract, scale, dot, cross, normalise; 4x4 matrix load, matrix x vector, matrix x matrix | MCP-2 |
| Geometry accelerator | transform, perspective projection, near and frustum clipping, lighting, streamed by DMA into a result buffer | MCP-3 |

All of them run on one datapath:

```
  45GS02 / DMA                     queue                sequencer
  $FFDF100-$7FF  --> command  --> (16 commands) -->  (MCP-1 hardwired,
                     ports                             MCP-2 microcode)
                                                            |
           registers F0-F15 (extended format) <------------+
                |                     ^
                v                     |
   unpack --> multiplier --> adder, normaliser --> rounder --> pack
          \-> divide / square root (iterative) --/
```

- **Registers:** 16, F0-F15, each holding an extended value (below). In
  MCP-2 they also act as four vec4s (V0 = F0-F3, ...), alongside a matrix
  bank M0-M15.
- **One multiplier:** 32 x 32 significands. FP32 needs only 24 x 24; the
  extra width is for extended precision.
- **One adder:** align, add and normalise, with a leading-zero count.
- **One divide/square-root unit:** iterative, one quotient bit per clock to
  start with.
- **One rounder:** takes the rounding mode and the precision as inputs.
- **A sequencer:** hardwired in MCP-1. In MCP-2 it runs microcode from
  block RAM: a vector or matrix operation is a loop of scalar steps on the
  same datapath, and a geometry function (MCP-3) is a longer microcode
  routine.

## Decisions (Steve, 2026-11-12)

### 1. Precision: extended registers, rounding chosen per operation

Registers hold an extended format: a sign, a 10-bit exponent and a 32-bit
significand with an explicit leading bit. That holds every FP32 value
(subnormals included, normalised) and every BASIC 65 float exactly.

Each operation rounds once, from the exact result, to the precision MCTRL
selects, like the 387's precision control:

- **single:** IEEE binary32, correctly rounded. MCP-1 has only this.
- **extended:** a 32-bit significand, for BASIC 65. MCP-4.

Rounding once matters. Rounding first to 32 bits and then to 24 gives a
different answer for some inputs; double rounding is only safe with at least
2 x 24 + 2 = 50 bits.

Single precision ships first. The register format and the precision field
are fixed now, so nothing is redesigned when extended arrives.

Results for BASIC will be correctly rounded, which is at least as accurate as
the ROM's own routines but not digit-for-digit identical: a program's last
printed digit can change. The BASIC documentation must say so.

### 2. Full IEEE 754 (single)

- subnormals in and out (no flush to zero), ±0, ±∞
- NaN results are always the default NaN, `$7FC00000`
- all four rounding modes
- five sticky flags: invalid, divide by zero, overflow, underflow, inexact
- tininess detected after rounding

This is the cheaper choice to verify: Berkeley TestFloat checks every
operation, mode and flag against SoftFloat. Flush-to-zero would need a
reference written by hand, which is the slog the vertex unit chose fixed
point to avoid (m65tr3d's `VERTEX.md`, decision 1). The hardware cost is a
normalising shift on the way in and out. It is also what the 68881 and the
387 did.

### 3. The era rule: architecture, not implementation

**Hard rule (the architecture):**

- one multiplier, one adder, one iterative divide/square-root unit
- microcoded sequencing, a register file
- memory-mapped commands
- no second datapath, no caches, no memory access of its own (data
  arrives by CPU writes or DMA)

The test: if a feature needs a second multiplier, it isn't 1991.

**Flavour only (the implementation):** DSP48 blocks, microcode in block
RAM, and the 40.5 MHz CPU clock.

The 8-bit bus limits throughput more than the arithmetic does, so a second
datapath would mostly sit idle. The rule costs little speed and keeps the
design small, coherent and testable.

### 4. The fixed-point vertex unit: removed after MCP-2

The decision first taken was to keep m65tr3d's vertex unit until MCP-3
replaced it, the two sharing the `$FFDF000` slot (the vertex unit at
`$000-$0FF` and `$800-$FFF`, the MCP at `$100-$7FF`, CAPS bit 6 saying
the MCP was there). After MCP-2 it went (Steve, 2026-11-12):

- nothing in this core used it
- it cost 3,364 LUTs, 17 DSPs and 7 RAMB36
- it lives on in m65tr3d, with the renderer it was made for

The MCP stays at `$100-$7FF`; `$000-$0FF` and `$800-$FFF` are free. MID
(`$FFDF101`, `$4D`) tells software the MCP is there, MVER which.

MCP-3 rebuilds the vertex unit's functions on FP32:

- the camera and the object as matrices in M
- transform and projection microcode
- the near and guard-band flags
- the result buffer and its window
- frustum clipping, which is new

The result buffer's window can take `$800-$FFF`.

## The 45GS02 interface

Everything goes through one command queue, by three paths:

- **Register forms:** a single byte write to `$180 + opcode`, the data
  `(d << 4) | s`: `STA [ptr],Z` with Z = `$80 + opcode` on a pointer to the
  MCP's control page, `$FFDF100`.
- **Memory forms**, the Weitek 3167's trick (the address is the instruction):
  a 32-bit store to `$400 + op * 64 + d * 4`. One `STQ` delivers the operand
  and starts `Fd = Fd op v`. Reading `$400 + d * 4` returns Fd.
- **The stream port** at `$120-$123`: commands as bytes, for DMA lists (with
  the destination address held) and for code that keeps one pointer.

Status, flags, the compare result and the integer result are registers on
the control page. Details: [`MCP1.md`](MCP1.md).

45GS02 details the interface relies on, checked in `src/vhdl/gs4510.vhdl`
and with ACME:

- `STQ abs` writes A, X, Y and Z to four consecutive addresses (Hyppo writes
  the SD card's sector address this way: `stq $d681`).
- `STQ [zp]` (`42 42 EA 92 zp`) does **not** add Z: Z is part of the value.
  A memory-form store therefore needs the pointer set to the exact address.
- `LDQ [zp]` (`42 42 EA B2 zp`) **does** add Z (`InnZReadVectorHigh`, line
  8109): Z can pick the register to read, and must be 0 otherwise.
- ACME 0.97 writes them as `ldq [ptr]` and `stq [ptr]` (it rejects
  `ldq [ptr],z`).

### Ordinary software

- **Assembly:** an ACME include with the addresses and macros.
- **C:** llvm-mos compiles `float` arithmetic to soft-float library calls.
  An MCP-backed version of those would make existing C code faster without
  source changes; `mcp.h` would offer explicit use. (To check: the names and
  calling convention llvm-mos uses for these calls.)
- **BASIC 65 (MCP-4):** a wedge that sends the ROM's floating-point
  routines to the MCP. (To check: how the ROM reaches them and whether they
  can be redirected.)

## Milestones

| | Scope |
|---|---|
| MCP-1 | Scalar FPU: FP32 operations, conversions, constants, flags; the three issue paths and the queue ([`MCP1.md`](MCP1.md)) |
| MCP-2 | Programs (512 commands in a block RAM, run by one command: the bus bottleneck MCP-1's timing showed), a pipelined fused multiply-add unit, three-register forms, vectors (V0-V3 over F0-F15) and matrices (the M bank, MXV, MTXV, MMUL); the microcode sequencer ([`MCP2.md`](MCP2.md)) |
| MCP-3 | Geometry on FP32: transform and project streams, clipping (near, then the frustum), lighting, the result buffer; does what m65tr3d's fixed-point vertex unit did ([`MCP3.md`](MCP3.md)) |
| MCP-4 | Extended precision, Commodore 5-byte float conversions, the BASIC 65 wedge (independent of MCP-3, could come first) |

Each milestone is built the way the renderer and the vertex unit were:

1. the C model first, bit-exact
2. the VHDL and an nvc bench comparing every result and flag, with random
   and directed tests and planted bugs
3. the board: a test program, read back and compared, with timings
   measured

## Open questions

- **Multiply-add, normalise and the program memory (MCP-2):** decided
  (Steve, 2026-11-12): fused, square root then divide, one block RAM. See
  [`MCP2.md`](MCP2.md).
- **Exceptions:** an interrupt on enabled exceptions, as the 68881 could trap?
- **SSNAIL:** Paul's LUMP coprocessor has FP32 and FP16 element operations
  (m65tr3d's `VERTEX.md`, "Why not SSNAIL"). Align formats or encodings
  where it's cheap?
