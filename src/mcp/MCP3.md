# MCP-3: geometry

> **This is the record of how MCP-3 was specified and built, stage by
> stage, kept as written.** For the unit as it is now (registers, commands,
> memory layout, timing), read [`REFERENCE.md`](REFERENCE.md).

Spec, 2026-11-12. Decisions 1-6 taken as recommended (Tiwaz, 2026-11-12).
Stages 0 (making room), 1 (the plumbing), 2 (geometry) and 3 (light, a
program: no new hardware) built and checked in simulation and on a MEGA65
R6 the same day ("Stage 0" to "Stage 3" below).

MCP-3 does what m65tr3d's fixed-point vertex unit did (removed after MCP-2,
MCP.md decision 4), on FP32:

- a stream of vertices comes in by DMA
- each is transformed, given clip codes, projected and lit
- each lands as an entry in a result buffer the CPU or the DMA reads back

Software then assembles, clips and draws triangles as it likes.

## Why

MCP-2 has the arithmetic: MXV in 25 clocks, VDOT3 in 17, divides and
square roots. What it lacks is the plumbing around them:

- **Vertices in:** today each value is a memory-form write, 4 bytes plus
  the command, and the CPU issues the commands one by one.
- **Results out:** a renderer wants 12.4 screen coordinates, a 16-bit depth
  and 8-bit colours. Today the CPU reads FP32 back and converts it.
- **Clip codes:** six compares a vertex, today six FCMPs and the CPU.
- **The reciprocal:** every vertex needs 1/w, and the divider takes 33
  clocks.
- **A vertex behind the camera:** its projection is meaningless, and a
  program can't yet skip it.

The vertex unit took about 30 clocks a vertex, with the DMA bringing a
vertex every 40. In software on the 45GS02 the same work is about 300 µs.

## Decisions (Tiwaz, 2026-11-12: as recommended)

### 1. Fixed-function or programmable: programmable

- **A, fixed function** (as the vertex unit): one command transforms,
  projects and lights a vertex, from blocks of parameters.
- **B, vertex programs:** MCP-2's programs, run once per vertex, with a few
  new commands that move vertex data (below). A standard program, shipped
  in `mcp.inc`, does what the vertex unit did; software can replace it
  (more lights, fog, other projections, texture coordinates generated).

B is recommended. The new hardware is only plumbing: a vertex array, a
converter on the way out, the result buffer. The 3D maths stays microcode
that software can read and change, and almost all of it (MXV, VDOT3,
FRECIP, programs) is already verified. A, by comparison, would mean a
second, fixed datapath to verify for the same arithmetic.

The cost is speed: about 70 clocks a vertex unlit and 110 lit for the
standard program (estimates under "Timing"), against the vertex unit's 30.
At 70 clocks a frame at 60 Hz still has room for about 9,000 vertices, far
more than the 45GS02 can draw.

### 2. The transform: one 4 x 4 matrix

Clip space is `M x (x, y, z, 1)`, with `M = projection x view x model`
built once per object by MMUL. Then come the clip codes against w, the
divide by w and the viewport. That is the usual pipeline (OpenGL's), and
the vertex unit's camera block (a 3 x 3 rotation, a translation, the focal
lengths, the centre, the near plane) maps onto it.

Lighting stays in object space: software turns each light into object
space once per object (MTXV with the model matrix). Per vertex the program
then needs only the normal as it comes, with no second matrix.

### 3. The input: a vertex array, not a FIFO

- **A, a FIFO:** vertices stream in while the program runs. But the DMA
  brings a vertex every 40 clocks and a vertex takes 70-110. The fastio
  bus can't make the DMA wait, so a long stream would overrun the FIFO.
  Software would have to send batches and check between them.
- **B, a vertex array:** a block of RAM software fills at an address
  (VINPTR, by DMA or the CPU), then a PRUN with one pass per vertex runs
  over it. Nothing can overrun. Uploading is fast: a 1,024-vertex mesh of
  20-byte vertices takes about 1 ms by DMA. Software that wants to overlap
  uploading and processing can double-buffer: fill one half while the
  program runs over the other.

B is recommended: simpler to verify, and no flow control to get wrong.
Size: 16 KB (four RAMB36), 800 vertices of 20 bytes.

### 4. Clipping: codes per vertex, not triangles

Per vertex, six clip codes (x < -w, x > w, y < -w, y > w, z < 0 (near),
z > w (far)) and a guard-band flag go into the entry and into MCOND.
Software assembles triangles and clips the few that cross the near plane.
Clipping triangles in hardware needs a primitive path (indices, new
vertices made on the fly): a later milestone, if software shows it's
needed.

### 5. The reciprocal: a radix-4 divider (built: two restoring steps a clock)

Divide and square root at two result bits a clock: 17 clocks instead of 33,
still correctly rounded, so no result changes. This is the "Divider radix"
open point in MCP1.md, and still one unit. The alternative, an approximate
reciprocal (a table and a Newton step on the FMA pipeline), is faster but
not IEEE, and it would add a second kind of division to verify. Not
recommended.

### 6. Make room first

The MCP is 19,309 LUTs, and most of them are the front end's register
muxing, not arithmetic (MCP2.md, "Stage 3b", "Size"). A first stage
restructures that, with nothing changed for software, before MCP-3 adds
more.

## The vertex path

### Registers (new; `$FFDF000` + offset)

The MCP takes the whole slot: its decode grows from `$100-$7FF` to
`$000-$FFF`. MVER reads `$03`. The registers below are written at once (not
queued): write them while the unit is idle. MRESET sets them to 0 and keeps
the vertex array's and the result buffer's contents. It drops what is
queued or in flight, stores included, so software that wants a store's
bytes waits for the unit to go idle (MSTATUS bit 0) before an MRESET.

| Offset | Name | |
|---|---|---|
| `$000-$003` | VINDATA | write: a byte into the vertex array at VINPTR, which advances (all four addresses one port, as MSTREAM: DMA with the address held, or STQ) |
| `$004-$005` | VINPTR | the vertex array's write address (14 bits: 16 KB) |
| `$006-$007` | VINIDX | the vertex VIN reads: a byte address, bits 1-0 always 0 (vertices are whole words); VNEXT moves it on by one vertex |
| `$008` | VFMT | the vertex format (5 bits, below) |
| `$009` | VPOSEXP | s16 positions are scaled by 2^-n (n 0-15), as the vertex unit's fraction bits |
| `$00C-$00D` | VTXIDX | the entry the stores go to (10 bits); VEND moves it on, wrapping from 1023 to 0 |
| `$00E` | VBANK | which 2 KB of the result buffer (64 entries, 0-15) the window shows |
| `$800-$FFF` | VOUTWIN | read: the result buffer, bank VBANK, direct-mapped. Reads have no side effects, so a DMA copy needs no care at its ends. (A read takes the CPU's fastio wait state: the buffer is block RAM.) |

### The vertex format (VFMT)

Every field is whole 32-bit words, and every conversion exact:

| Bits | Field | |
|---|---|---|
| 0 | position | 0: s16 x, y, z and a pad (8 bytes), each x 2^-VPOSEXP; 1: FP32 x, y, z (12 bytes), as they are |
| 1 | normal | s8 nx, ny, nz and a pad byte (4 bytes), each x 2^-7: 127 is 0.992 (a program that cares normalises) |
| 2 | colour | u8 r, g, b, a (4 bytes), each x 2^-8 |
| 3-4 | attributes | 0-3 words passed to the entry unchanged (texture coordinates, or anything) |

The fields come in that order; a vertex is 8 to 32 bytes.

### The result entry (32 bytes)

The vertex unit's layout where it fits, so software for it carries over:

| Bytes | |
|---|---|
| 0-1, 2-3 | screen x, y: s16, 12.4 |
| 4-5 | depth: u16 |
| 6-7 | 1/w: u16, scaled |
| 8-11 | r, g, b, a |
| 12-19 | the attributes as they came in (VPASS from word 3) |
| 20-23, 24-27 | clip-space x, y: FP32 (for software clipping) |
| 28-29 | clip-space w: FP32's top half (a sign, an exponent and 7 bits are enough for the near test and sorting) |
| 30 | flags: the six clip codes, guard band |
| 31 | 0 |

The program decides what goes where: the layout above is the standard
program's, not the hardware's.

### New commands

| Form | Name | Operation |
|---|---|---|
| wide `$25` | VIN | Vd = a field of the vertex at VINIDX, converted to FP32: t = 0 position (x, y, z, 1), 1 normal (nx, ny, nz, 0), 2 colour (r, g, b, a). A field VFMT lacks, or t > 2: reserved |
| reg `$1A` | VNEXT | VINIDX moves on by one vertex (VFMT's size) |
| wide `$26` | VOUT | Fs into the entry at VTXIDX, at byte 2t, in format d (below) |
| wide `$27` | VOUTC | Vs's four components as bytes (each x 2^8, rounded, clamped to 0-255) into the entry at byte 2t (t even) |
| reg `$1B` | VPASS | the vertex's attribute words into the entry, from its word n (the data byte, 0-7; the entry's words wrap) |
| reg `$1C` | VCLIP | Vs's clip codes (below) into MCOND and into the entry's byte 30 |
| wide `$28` | PSKIP | in a program: if MCOND and (d << 4 \| s) is not 0, skip the next t commands (0-15); outside one, nothing. A skip past entry 511 aborts the program (MPERR 1) |
| reg `$1E` | VEND | the entry done; VTXIDX advances |

Register form `$1D` stays reserved: PSKIP needs a whole MCOND mask and a
count, more than a register form's data byte holds.

VCLIP's codes, for Vs = (x, y, z, w), each compare exact (+0 = -0):

| Bit | |
|---|---|
| 0, 1 | x < -w, x > w |
| 2, 3 | y < -w, y > w |
| 4 | z < 0: behind the near plane |
| 5 | z > w: beyond the far plane |
| 6 | w <= 0: behind the eye (no meaningful projection) |
| 7 | a NaN in x, y, z or w (then the only bit set) |

VOUT's formats (d), each written little-endian:

| d | | Bytes | |
|---|---|---|---|
| 0 | FP32 | 4 (t even) | as it is |
| 1 | FP32's top half | 2 | bits 31-16 as they are (a sign, an exponent and 7 bits) |
| 2 | s16 12.4 | 2 | x 2^4 |
| 3 | u16 | 2 | x 2^16, 0-65535 (0-1 to 0-65535) |
| 4 | s16 | 2 | as an integer |
| 5 | s32 16.16 | 4 (t even) | x 2^16 |
| 6-15 | | | reserved |

The conversions to integers work as FTOI: rounded by MCTRL's mode, NaN
gives 0, out of range gives the nearest bound, and either sets the invalid
flag (alone); otherwise a rounding sets the inexact flag.

### The standard program

Two, shipped in `mcp.inc` as data for MPLOAD: `+mcp_stdprog` (unlit, 25
entries) and `+mcp_stdprog_lit` (one directional light and an ambient
term, 36 entries; the vertices need a normal). Before the PRUN: M the
matrix (projection x view x model), F12-F15 the viewport's kx, ky, cx, cy
(screen x = cx + kx x/w, y = cy - ky y/w), VFMT, VPOSEXP, VINIDX, VTXIDX.
Per vertex: V0 the input, V1 clip space, F8 1/w, F9-F11 x/w, y/w, z/w.
`demo/geo/geo.c` builds them for the model, and `geo.py` checks that
`mcp.inc`'s bytes are the same.

The order is for the issue (measured under "Timing"). Commands issue one a
clock, in order. A sequence (VIN, MXV, VOUTC, VPASS, VDOT3) holds the issue
until its result is in; any other command waits only for its operands,
and an FMA-pipeline result can be used 5 clocks after its command issued.
So the divide starts as soon as w is known and the commands that don't
need it run while it does, and in the projection each result's consumer
comes about five commands later. 1/w is computed for every vertex: for w
= 0 that sets the divide-by-zero flag, nothing else.

Unlit:

```
VIN    V0, position        ; (x, y, z, 1)
MXV    V1, V0              ; clip space (F4-F7)
FRECIP F8, F7              ; q = 1 / w
VOUT   F4, FP32, 20        ; clip-space x, y, w's top half (software clips with them)
VOUT   F5, FP32, 24
VOUT   F7, FP32 top, 28
VCLIP  V1                  ; the codes: MCOND, byte 30
VIN    V0, colour
VOUTC  V0, 8
VPASS  3                   ; the attributes, from word 3 (byte 12)
PSKIP  $C0, 11             ; w <= 0 or a NaN: no projection
FMUL3  F9, F4, F8          ; x / w, y / w, z / w
FMUL3  F10, F5, F8
FMUL3  F11, F6, F8
FMOVE  F4, F14             ; cx + kx * x / w
FMOVE  F5, F15             ; cy - ky * y / w
FMA    F4, F9, F12
FMS    F5, F10, F13
VOUT   F8, FP32 top, 6     ; 1 / w
VOUT   F11, u16, 4         ; depth
VOUT   F4, 12.4, 0         ; screen x, y
VOUT   F5, 12.4, 2
VEND
VNEXT
PEND
```

Lit: the colour's r, g, b times max(N . L, 0) + ka, a as it is.

```
VIN    V2, normal          ; F8-F10 = nx, ny, nz
FMUL   F8, #lx             ; (memory forms: the light is in the program)
FMUL   F9, #ly
FMUL   F10, #lz
VIN    V0, position        ; (the products land meanwhile)
FADD3  F11, F8, F9
FADD   F10, #ka
MXV    V1, V0
FADD   F11, F10            ; N . L + ka
FRECIP F8, F7
VOUT   F4, FP32, 20
VOUT   F5, FP32, 24
VOUT   F7, FP32 top, 28
FMAX   F11, #ka            ; max(N . L + ka, ka) = max(N . L, 0) + ka
VCLIP  V1
VIN    V0, colour
FMUL   F0, F11
FMUL   F1, F11
FMUL   F2, F11
VPASS  3
VOUTC  V0, 8
PSKIP  $C0, 11             ; then as the unlit program
...
```

- **The light** (lx, ly, lz) points from the surface toward the light, in
  object space, already times the diffuse term: the CPU turns it once per
  object (by the transpose of the model-view rotation) and rewrites
  entries 1-3; ka is in entries 6 and 13 (`MCPS_LIGHT`, `MCPS_AMB1`,
  `MCPS_AMB2` in `mcp.inc`). The constants live in the program, so the
  light takes no register: F0-F15 hold the vertex, clip space, the
  projection and the viewport, as unlit.
- **The normal** is s8 x 2^-7, not normalised (127 is 0.992); a program
  that cares adds VNORM3 (66 clocks).
- **Not VDOT3:** its three steps depend on one another, and as a sequence
  it holds the issue for all 18 of its clocks. The three products as
  memory forms before the position's VIN, and the sums after it, take 5
  issue clocks. The first lit program, with VDOT3, took 112.6 clocks a
  vertex.
- **Bytes 0-7** are not written for a vertex the program skips: software
  reads byte 30 first. The colour and the clip-space values are written
  for every vertex (clipping an edge needs both ends).

## Timing

Measured in simulation (`geo.py --sim`, on the demo mesh) and on the board
(`geo.py`, timed by CIA 2 to the microsecond): the same but for 0.1 clock.

| | Clocks a vertex |
|---|---|
| the standard program, unlit | 72.7 (1.79 µs; on the board 72.8) |
| the standard program, lit | 89.7 (2.21 µs; on the board 89.7) |
| stage 2's order of the unlit program | 75.6 |
| the lit program with VDOT3 (the first try) | 112.6 |
| the vertex unit (for comparison) | 27-30 |
| the DMA's rate: 20-byte vertices (unlit), 24-byte (lit) | 40, 48 |

Where the lit program's 90 clocks go: 58 are its sequences (VIN three
times, 22; MXV 26; VPASS 4; VOUTC 6), 30 its other commands, one a stall
and one the jump back to the first entry. 15 of the sequences' clocks are
spent waiting for their last result to land, holding the issue ("Open
points"). The spec's estimates were 70 unlit and 110 lit.

## Verification

As for MCP-1 and MCP-2:

- **The model** (`mcp_model.c`) gains the vertex array, the result buffer
  and the new commands.
- **Random scripts** (`mcpgen`): vertex uploads, programs with the new
  commands, the result buffer read back through the window.
- **The standard program** against a host reference in C (FP32, the same
  operations): every entry byte identical.
- **Planted bugs**, as always.
- **The board:** the scripts, the standard program on a mesh, and the
  timing against the C version.

## Build order

0. **Make room:** the front end restructured (decision 6). Every bench,
   unchanged, must still pass, and the size is measured.
1. **The plumbing:** the vertex array, the result buffer and its window,
   VIN, VNEXT, VOUT, VOUTC, VPASS, VEND. Checked with programs that pass
   vertices through.
2. **Geometry:** VCLIP, PSKIP, the radix-4 divider, the standard program,
   a demo mesh, the timings.
3. **Light:** lighting in the standard program (no new hardware unless the
   timings call for it). They didn't: the lit program is 90 clocks a
   vertex against the 110 estimated ("Stage 3").

## Stage 0 (2026-11-12)

The MCP from 19,316 LUTs to 11,035 (-43%), the whole design from 70.8% of
the A200T's LUTs to 64.6%. Nothing changes for software but a few
commands' clocks.

- **Where the LUTs were** (MCP2.md, "Stage 3b", "Size"): not in the
  arithmetic but in the logic feeding the registers. Every place the code
  read a register by an index (Fd, Fs, Ft, a vector's component) became its
  own 16-way choice. And it chose among the registers as they would be
  after this clock's results landed, so each of the 16 inputs was itself a
  choice between the register and up to three results.
- **What changed:**
  - **Reads:** each clock, the command (or the micro-operation) in line
    picks its indices first. Then each read port picks one register and
    only then checks whether a result for it is landing now: three F
    ports, two T ports, one M port.
  - **FXCHG:** it read and wrote any register into any other, so each of
    F's 512 bits had a 16-way choice for it alone. Now it reads its two
    registers through the ports already there, and a small write port
    puts them back the next clock.
  - **VMOVE**, VNORM3's w and VCROSS's w = +0 are micro-operations, so
    every vector result lands the same way: Vd from T0-T3.
  - **The copies** (MLOAD, MSTORE, a vector or matrix result) wait until
    nothing is landing, then copy the registers as they are, without the
    bypass.
  - **The core:** the multiply-add's alignment shifts the operand with the
    lower top through one shared shifter instead of each having its own;
    the conversions to an integer use one right shift instead of a left
    and a right one.
- **By the register the LUTs feed** (Vivado's names; the counts are LUT
  cells):

  | | Before | After |
  |---|---|---|
  | F0-F15 | 8,877 | 3,649 |
  | the core's operand registers | 2,212 | 1,007 |
  | the M bank | 1,845 | 533 |
  | the multiply-add's alignment | 2,075 | 655 |
  | the conversions' shifter | 971 | 742 |
  | T0-T15 | 955 | 1,088 |
  | FXCHG's write port | - | 523 |

- **Clocks:** a vector or matrix command takes one clock more (its result
  is copied a clock after the last step lands), VCROSS two, and VMOVE 7
  instead of 1. Measured on the board (`demo/vtime`): VADD 11, VDOT3 18,
  VDOT4 23, VCROSS 16, MXV and MTXV 26, MMUL 71, VNORM3 92. Everything
  else is unchanged; the Mandelbrot is 10.3 ms as before.
- **The checks:** all of MCP-1's and MCP-2's benches, unchanged, pass:
  - the core: 26,245,680 vectors identical
  - the front end: 24 seeds at both bus rates, 1,552,078 reads identical
  - 9 new planted bugs, all caught: a read port without one of its
    bypasses (the short unit's, FXCHG's), FXCHG writing one way only,
    MLOAD or a vector result copying before everything has landed,
    VNORM3's w from z, VCROSS's w not written, Vt read as Vs, the short
    unit's results going to F instead of T
  - FXCHG's bypass was at first caught on only half the seeds: `mcpgen`
    (stage 3) now often follows an FXCHG in a program with a read of what
    it swapped, and catches it on every seed tried
- **The build:** WNS +0.041 ns, the worst paths in the HyperRAM controller;
  the CPU clock's worst setup +0.871 ns, on a CPU path.
- **The board:** a stage-3 script (seed 3), 10,516 reads identical; the
  Mandelbrot exact (61.9 ms MCP-1, 10.3 ms MCP-2); the command clocks
  above.

## Stage 1 (2026-11-12)

The plumbing: the vertex array, the result buffer, their registers and
window, and VIN, VNEXT, VOUT, VOUTC, VPASS, VEND (formats and commands as
above). MVER reads `$03`.

- **The model** (`mcp_model.c`, stage 4): the vertex array (16 KB) and the
  result buffer (32 KB), the registers, the commands; a conversion as
  FTOX's (the value x 2^k exactly, in double, then rounded and clamped).
  `mcpcheck` runs 1,000,000 random vertex commands against a separate
  host version, 0 differences; 3 planted bugs, all caught.
- **The core** (`mcp_fpu.vhdl`): a fourth unit, the converter, for VOUT's
  and VOUTC's formats. The iterative unit's conversion logic in two stages:
  b x 2^k as 32.32 fixed point through one shifter, then the rounding and
  the saturation. An operation a clock, the result in the clock after
  start. Its six operations take the core's free opcodes `$16-$1B`.
- **The front end** (`mcp.vhdl`):
  - the vertex array: four byte lanes of 4 KB in block RAM, written a byte
    at a time through VINDATA, read a word at a time
  - the result buffer: four byte lanes of 8 KB, written by stores and
    copies, read through the window. Its read address follows the bus's;
    the CPU's fastio wait state covers the block RAM's clock, as for the
    SD card's sector buffer.
  - **VIN** is a sequence of loads (a new micro-operation: a vertex word,
    converted, into a temporary), then Vd = T0-T3 as any vector result.
  - **VOUTC** is a sequence of four stores through the converter, VPASS a
    sequence of up to three copies (vertex array to result buffer).
  - **VOUT** goes to the converter as any core operation.
  - Stores and copies all take two clocks from issue to their data, so
    one a clock never collide. VNEXT and VEND act at once.
- **The checks:**
  - the core: 26,345,680 vectors identical (the converter's: the
    random part, near each format's bounds too)
  - the front end: `mcpgen` stage 4 (the default now: uploads, the
    registers, the commands by every path, the window read back at each
    checkpoint), 24 seeds at both bus rates, 2,387,162 reads identical
  - 14 planted bugs: 13 caught. The fourteenth (MSTATUS not busy for a
    store's last clocks) can't be seen from the bus: a store reaches the
    buffer within 3 clocks, and reading MSTATUS and then the window takes
    longer.
  - The bench now holds every read at least two clocks, as the CPU's wait
    state does: the window needs it.
  - The first runs failed: `mcpgen` sent MRESET with stores still queued.
    The model ran them as they were written, while MRESET drops them, and
    the result buffer is the first state that outlives an MRESET. At stage
    4 the script now waits for the unit before an MRESET. The spec says
    so (above).
- **The build:** WNS +0.224 ns, the worst paths in the HyperRAM controller,
  none through the MCP. The MCP is 11,974 LUTs (939 more than stage 0:
  the converter and the vertex path), 4,313 flip-flops, 13 RAMB36 (12 new:
  the vertex array and the result buffer) and 2 DSPs; the chip 65.3% of its
  LUTs, 42% of its block RAM.
- **The board:** three stage-4 scripts (seeds 1, 2, 3), 45,355 reads
  identical, the result buffer read through the window at the CPU's own
  pace. The Mandelbrot exact and as fast as before (61.8 ms MCP-1, 10.3 ms
  MCP-2; 40.7 ms at 80 x 50), every command's clocks as on stage 0. FDIV in
  `vtime` read 31.0 clocks, as the simulation gives for stage 0 and stage
  1 alike; on stage 0's board run it read 29.7, which I can't account for.

## Stage 2 (2026-11-12)

Geometry: VCLIP, PSKIP, the faster divider and the standard program.

- **The model** (stage 5): VCLIP and PSKIP; `mcpcheck` runs VCLIP against
  the host's own compares (values put near the planes half the time) and
  random programs with PSKIP, stages 1-5, against its separate
  interpreter: 0 differences; 2 planted bugs caught.
- **The core:** divide and square root take two of their restoring steps
  a clock (the same steps, so the same results): the iterative unit's
  longest operation from 32 clocks to 19, a divide 20 clocks issue to
  result. The core bench: 26,345,680 vectors identical.
- **The front end:** VCLIP computes the codes from the settled registers
  (six compares and the NaN test) into MCOND and, through the store
  pipeline, byte 30. PSKIP in a program waits for MCOND, as PEXIT does; a
  skip is a jump forward, as PEND's.
- **The checks:** `mcpgen` stage 5 (the default): 24 seeds at both bus
  rates, 2,382,006 reads identical. 10 planted bugs, all caught.
- **A bug the random scripts found:** SETFLAGS (a write to MFLAGS) waits
  for every flag still to come, but checked only the scoreboard, and a
  VOUT marks nothing there (its result goes to the result buffer). Seed 9
  had a VOUT that saturates, so raises the invalid flag, and then a SETFLAGS:
  the flag landed after it. SETFLAGS now also waits for the store pipeline.
  This was there since stage 1.
- **The demo** (`demo/geo`): a 512-vertex torus close enough that 71
  vertices are behind the near plane, and 16 vertices behind the camera,
  in 20-byte vertices (s16 positions, colour, two attribute words). One
  PRUN of the standard program. In simulation, through the bus as
  `geo.asm` does it: all 16,896 result bytes identical to the model's,
  75.6 clocks a vertex.
- **The build:** WNS +0.106 ns. The MCP is 12,740 LUTs (766 more than
  stage 1: the core 484 more, the divider's second step a clock; the
  front end 91, VCLIP and PSKIP), 4,342 flip-flops, 13 RAMB36; the chip
  65.9% of its LUTs.
- **The board:** the geo demo, all 16,896 result bytes identical to the
  model's, 0.99 ms for the 528 vertices: 75.6 clocks (1.87 µs) a vertex,
  as in simulation. Three stage-5 scripts (seeds 1, 2, 3), 42,863 reads
  identical. `vtime`: FDIV 18.1 clocks (31.0 on stage 1), VNORM3 66.1
  (92: a square root and a reciprocal), every other command as before.
  The Mandelbrot doesn't divide: every version exact and as fast as
  before (10.3, 11.9, 12.7 and 61.8 ms; 40.7 ms at 80 x 50).

## Stage 3 (2026-11-12)

Light: the standard program lit, and both programs shipped in `mcp.inc`.
No new hardware, so MVER stays `$03` and the model's stage 5.

- **The programs** ("The standard program"): the lit one adds the normal's
  VIN, its product with the light (three memory-form multiplies and two
  adds), the intensity (max(N . L + ka, ka)) and the colour's three
  multiplies: 11 commands. The light's constants are in the program, so
  the registers were not tight after all (the open point a second bank
  of constants was for).
- **The order:** the first lit program used VDOT3 and took 112.6 clocks a
  vertex; a trace of one pass showed the issue held by VDOT3's chain of
  steps. Without it, 95.6; reordered so the products land while VIN
  fetches the position and the projection's results are used five
  commands after they start, 89.7. The same projection order takes the
  unlit program from 75.6 to 72.7. Both are now the issue's minimum for
  their commands but a clock or two: every other clock goes to a command
  or a sequence ("Timing").
- **`mcp.inc`:** `+mcp_stdprog` and `+mcp_stdprog_lit .lx, .ly, .lz, .ka`
  (the light as FP32 bit patterns), and the entries to rewrite per object
  (`MCPS_LIGHT`, `MCPS_AMB1`, `MCPS_AMB2`). The MCP's addresses in the
  header now say `$FFDF000-$FFDFFFF`, MVER `$03`.
- **The demo** (`demo/geo`): the torus with normals (24-byte vertices,
  VFMT `$16`), one light from the upper left in front of it (272 of the
  528 vertices face away: the ambient term alone), lit by default and
  `--unlit` for the program without the light. `geo.asm` takes the
  program from `mcp.inc`'s macros, and `geo.py` checks their bytes against
  `geo.c`'s. `geo.py --sim` runs the same writes and reads in nvc and
  times the PRUN (the bench's new `T` line reports the clock).
- **The checks:** in simulation, both programs' 16,896 result bytes
  identical to the model's; the model's colours identical to a host
  computation of the same formula in double. `mcpgen` seed 3 and the
  other demos unchanged.
- **The board** (stage 2's bitstream: no new hardware): both programs, all
  16,896 result bytes identical to the model's; lit 1.17 ms for the 528
  vertices, 89.7 clocks (2.21 µs) a vertex; unlit 0.95 ms, 72.8 clocks
  (1.80 µs). A frame at 60 Hz has room for about 7,500 lit vertices.

## On the screen (2026-11-13)

Two demos that show it (`demo/show`, `show.py`), on a 320 x 200 screen of
256 colours (VIC-IV full-colour characters numbered by column, so a pixel's
neighbour below is 8 bytes on and a column of pixels is one DMA fill with
a step of 8):

- **The Mandelbrot** (`mandel.asm`): 64,000 points, at most 128 iterations,
  each a PRUN of mandel_prog's pipelined program, drawn as it comes. On
  the board 1.78 s (2,256,009 iterations), every pixel as the host's FP32
  computation in the same order.
- **A turning, lit torus** (`scene.asm`, `scene.c`): 240 vertices, 480
  triangles, flat shaded, 30 frames a second. The MCP does all of its
  arithmetic, in two programs queued back to back each frame over one
  array of 16-byte records (VFMT `$06`):
  - **the vertex program**, a pass a vertex: MXV, the divide, the viewport
    (its constants in the program) and the pixel as two s16 (VOUT)
  - **the face program**, a pass a triangle, its record the triangle's
    centroid C, normal N and colour: with D the view direction in object
    space (row 3 of the matrix: MSTORE leaves it in F12-F14), whether it
    faces the eye (N . (E - C) > 0, the eye E = -tz D), its depth bucket
    (C . D) and its shade (N . L, the light in the program's constants,
    turned into object space by MTXV each frame); the three go out as
    bytes through one VOUTC
  - **the DMA** carries the records and the programs in, the matrices into
    F0-F15 (memory forms), clears the frame buffer while the MCP works,
    and brings the results out in one chained list: per 2 KB of the
    window VBANK (a byte through the DMA too), then one byte of every
    entry there, a source step of 32, straight into the CPU's tables. It
    fills every column of every triangle (a step of 8).
  - **the CPU** links the visible faces into 256 depth buckets and sets up
    the triangles' columns (the hardware divider for the slopes).
  - **The frame** (frame 64 on the board): 19.5 ms of work. The MCP's
    part takes 0.09 ms to issue and is done before the frame buffer's
    clear (1.56 ms) ends; the results scattered 0.25, the faces linked
    0.32, the triangles drawn 17.29 (about 3,400 columns: 4.5 µs each,
    of which the DMA's fill is 0.6, and 24 µs a triangle). Shown every
    second refresh: 29.9 frames a second (NTSC).
  - **The MCP's share:** timed alone (a build that waits for it before
    the clear), both programs take 1.25 ms: 720 passes, 70 clocks each on
    average. It is 7% of the frame's work and hidden behind the clear,
    so a faster MCP would not change this frame rate; the CPU's drawing
    sets it. At 30 frames a second the MCP would have time for about 25
    times this geometry.
  - **The checks:** `scene.c` plays every frame of the turn (256) through
    the model and draws it with `scene.asm`'s integer steps; each must
    keep every vertex on the screen and agree with a depth buffer over
    all triangles, computed apart from the MCP's results (at most 6% of
    the pixels differ: the edges, another fill rule). `show.py` steps the
    board through eight frames around the turn: every pixel of each as
    the host's.
  - **The first version was wrong, and its check passed.** It culled the
    front faces and drew the back ones (the inside of the far wall: a
    plausible torus from above, wrong edge on), and frame 0 on the board
    was pixel for pixel the host's, which had the same mistake: the host
    decided which winding is a front face from the triangle's own
    winding. Now the surface's outward normal decides, and the depth
    buffer is the check that does not share the drawing's logic. It also
    did the culling, the sort keys and the shading on the CPU (8.3 ms),
    copied the results out whole (0.8 ms), read them vertex by vertex
    (1.6 ms) and took 38 ms to draw: 15.8 frames a second.
  - **The picture:** a 40 degree lens from 4.5 units (60 degrees from 3
    bent it), and kx for the video mode's pixels (720 x 480 or 720 x 576
    shown 4:3 are not square), taken from `$D06F` at the start.
- **In Xemu** (no MCP): `--xemu` builds the display alone (`TEST=1`), the
  MCP's results computed by the host; both demos pass there pixel for
  pixel too. The Mandelbrot's palette needed `$D030` bit 2 (colours 0-15
  from the palette RAM, not the VIC-III's palette ROM).

## Open points

- **VOUT's formats:** which, exactly; the entry layout is the program's.
- **Sequences hold the issue** until their last result is in: 15 of the
  lit program's 90 clocks (VIN 2-3, MXV 6, VPASS and VOUTC 1). Letting the
  next command issue once a sequence's last step has (the copy into Vd
  marked in the scoreboard, as a single command's result is) would win
  part of them back, about 10 clocks a vertex lit and unlit, for a change
  to the scoreboard and the sequencer.
- **Triangles in hardware:** an index stream and near clipping, after
  MCP-3 if software needs them.
