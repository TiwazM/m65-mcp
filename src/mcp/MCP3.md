# MCP-3: geometry

Spec, 2026-11-12. Decisions 1-6 taken as recommended (Steve, 2026-11-12).
Stage 0 (making room) built and checked in simulation and on a MEGA65 R6
the same day ("Stage 0" below); nothing of MCP-3 itself built yet.

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

## Decisions (Steve, 2026-11-12: as recommended)

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

### 5. The reciprocal: a radix-4 divider

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
`$000-$FFF`.

| Offset | Name | |
|---|---|---|
| `$000-$003` | VINDATA | write: bytes into the vertex array at VINPTR, which advances (all four addresses one port, as MSTREAM: DMA with the address held, or STQ) |
| `$004-$005` | VINPTR | the vertex array's write address (14 bits) |
| `$006-$007` | VINIDX | the vertex array's read address: VIN reads the vertex there, VNEXT moves it on by one vertex |
| `$008` | VFMT | the vertex format (below) |
| `$009` | VPOSEXP | s16 positions are scaled by 2^-n (n 0-15), as the vertex unit's fraction bits |
| `$00C-$00D` | VTXIDX | the entry VEND completes (10 bits); it advances and wraps from 1023 to 0 |
| `$00E` | VBANK | which 2 KB of the result buffer (64 entries, 0-15) the window shows |
| `$800-$FFF` | VOUTWIN | read: the result buffer, bank VBANK, direct-mapped (reads have no side effects, so a DMA copy needs no care at its ends) |

### The vertex format (VFMT)

| Bits | Field | |
|---|---|---|
| 0 | position | 0: s16 x, y, z (6 bytes) scaled by VPOSEXP; 1: FP32 x, y, z (12 bytes) |
| 1 | normal | s8 nx, ny, nz and a pad byte, 127 = 1 (4 bytes) |
| 2 | colour | r, g, b, a, 0-255 (4 bytes) |
| 3-4 | attributes | 0, 4 or 8 bytes passed to the entry unchanged (texture coordinates, or anything) |

The fields come in that order; a vertex is 6 to 32 bytes.

### The result entry (32 bytes)

The vertex unit's layout where it fits, so software for it carries over:

| Bytes | |
|---|---|
| 0-1, 2-3 | screen x, y: s16, 12.4 |
| 4-5 | depth: u16 |
| 6-7 | 1/w: u16, scaled |
| 8-11 | r, g, b, a |
| 12-19 | the attributes as they came in |
| 20-23, 24-27 | clip-space x, y: FP32 (for software clipping) |
| 28-29 | clip-space w: FP32's top half (a sign, an exponent and 7 bits are enough for the near test and sorting) |
| 30 | flags: the six clip codes, guard band |
| 31 | 0 |

The program decides what goes where: the layout above is the standard
program's, not the hardware's.

### New commands

| Form | Name | Operation |
|---|---|---|
| wide `$25` | VIN | Vd = a field of the vertex at VINIDX, converted to FP32: t = 0 position (x, y, z, 1), 1 normal (nx, ny, nz, 0), 2 colour (r, g, b, a in 0-1) |
| reg `$1A` | VNEXT | VINIDX moves on by one vertex (VFMT's size) |
| wide `$26` | VOUT | Fs into the entry at VTXIDX, at byte t x 2, in format d: FP32, FP32's top half, s16 12.4, u16 (0-1 to 0-65535), s32 |
| wide `$27` | VOUTC | Vs's four components as bytes (0-1 to 0-255, rounded, clamped) into the entry at byte t x 2 |
| reg `$1B` | VPASS | the vertex's attributes into the entry at byte 12 |
| reg `$1C` | VCLIP | Vs's clip codes and guard-band flag into MCOND and into the entry's flags byte |
| reg `$1D` | PSKIP | in a program: if MCOND and the mask in d is not 0, skip the next s commands (0-15) |
| reg `$1E` | VEND | the entry done; VTXIDX advances |

VOUT's conversions round to nearest-even and saturate, as FTOI does (an
invalid flag for a NaN, 0 written).

### The standard program

Per vertex (V0-V3 are F0-F15; the constants live in F12-F15):

```
VIN    V0, position        ; (x, y, z, 1)
MXV    V1, V0              ; clip space (F4-F7)
VCLIP  V1                  ; codes into MCOND and the entry
PSKIP  near, 7             ; behind the near plane: no projection
FRECIP F8, F7              ; q = 1 / w
FMUL3  F4, F4, F8          ; x / w, y / w, z / w
FMUL3  F5, F5, F8
FMUL3  F6, F6, F8
FMA    ...                 ; the viewport: cx + kx * x / w, cy - ky * y / w, depth
VOUT   F4, s12.4, 0        ; screen x, y, depth, 1/w
VOUT   F5, s12.4, 2
...
VIN    V2, colour          ; (lit: VIN V3, normal; VDOT3 with the light; FMAX 0;
VOUTC  V2, 8               ;  an FMA with ambient and diffuse; VMUL)
VPASS
VEND
VNEXT
PEND
```

## Timing (estimates)

| | Clocks a vertex |
|---|---|
| the standard program, unlit | about 70 (MXV 25, the reciprocal 17 + 5, the rest a clock or two each) |
| lit, one directional light | about 110 |
| the vertex unit (for comparison) | 27-30 |
| the DMA's rate, 20-byte vertices | 40 |

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
   timings call for it).

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

## Open points

- **VOUT's formats:** which, exactly; the entry layout is the program's.
- **Registers:** F0-F15 are tight for a lit program (the vertex, clip
  space, the viewport's constants, the light). A second bank of 16
  constants, readable as operands only, would help.
- **Triangles in hardware:** an index stream and near clipping, after
  MCP-3 if software needs them.
