# MCP-2: programs, vectors and matrices

> **This is the record of how MCP-2 was specified and built, kept as
> written.** MCP-3 changed details (MVER, timings, the address range). For
> the unit as it is now (registers, commands, memory layout, timing), read
> [`REFERENCE.md`](REFERENCE.md).

Spec, 2026-11-12. All of it built and checked in simulation and on a
MEGA65 R6 the same day, in four stages: 1 (programs), 2 (the FMA unit and
the wide forms), 3a (the pipeline and the scoreboard) and 3b (vectors and
matrices); each has its section below.
MCP-1 ([`MCP1.md`](MCP1.md)) is the base: every
MCP-1 register, command and result stays exactly as it is. Codes MCP-1
reserved now have meanings: register forms `$18` and `$19`, memory form 14,
and stream prefix `$90`.

## Why

MCP-1's Mandelbrot on the board (MCP1.md, "Timings") takes 6.0 µs an
iteration:

- **The arithmetic:** about 2.5 µs.
- **The rest:** the 45GS02 writing 13 commands over the fastio bus, one at
  a time, then waiting.

So MCP-2 does two things:

1. **Programs:** command sequences kept in the MCP and started with one
   write, with a repeat count and an exit on a condition. A whole loop runs
   inside the unit, and the CPU pays per loop, not per command.
2. **A faster datapath:** once the bus is out of the way, the arithmetic is
   the limit. One pipelined fused multiply-add (FMA) unit replaces MCP-1's
   separate adder and multiplier, still one multiplier and one adder (the
   IBM POWER1's design, 1990). On top of it come the vector and matrix
   operations MCP.md planned.

## Decisions (Tiwaz, 2026-11-12)

1. **Multiply-add is fused:** `a x b + c` rounded once (IEEE 754-2008
   fusedMultiplyAdd). It is verified by SoftFloat's `f32_mulAdd` and
   TestFloat.
2. **VNORM rounds twice:** the length as a square root, its reciprocal as a
   division, both correctly rounded on their own. A correctly rounded 1/√x
   in one step would cost far more to build and to verify.
3. **The program memory is one block RAM:** 512 commands of 48 bits (the
   queue's command format) in one 36 Kbit RAMB36 (512 x 72).

## Summary of what's new

- **Datapath:** one fused multiply-add pipeline (latency about 5 clocks, one
  operation a clock when independent); FADD, FSUB, FMUL run on it with
  MCP-1's results unchanged. Divide and square root stay iterative.
- **Three-register forms:** `Fd = Fs op Ft` for add, subtract, multiply,
  and FMA (`Fd = Fs x Ft + Fd`), FMS (`Fd = Fd - Fs x Ft`).
- **Vectors:** V0-V3 over F0-F15 (V0 = F0-F3 as x, y, z, w, and so on):
  VMOVE, VADD, VSUB, VMUL, VSCALE, VDOT3, VDOT4, VCROSS, VNORM3.
- **A matrix bank:** M0-M15, a 4 x 4 matrix by rows; MLOAD and MSTORE
  (to and from F0-F15), MXV, MTXV (the transpose), MMUL.
- **Programs:** 512 commands of program memory, loaded through a port like
  the stream; PRUN starts one, PEND ends a pass, PEXIT leaves on a
  condition, MPCNT says how many passes completed.

## Registers (new or changed; `$FFDF000` + offset)

| Offset | Name | |
|---|---|---|
| `$100` | MSTATUS | MCP-1's bits, and bit 4 a program running, bit 5 a program aborted (sticky; a write to MSTATUS clears it with bits 2 and 3) |
| `$102` | MVER | reads `$02` |
| `$10C-$10D` | MPPTR | program memory address (9 bits) for MPLOAD and MPREAD; advances a command at a time |
| `$10E-$10F` | MPCNT | read: the passes the last PRUN completed (16 bits; reading `$10E` latches `$10F`) |
| `$110` | MPERR | read: why the last program aborted: 0 none, 1 it ran past entry 511 (no PEND), 2 MPLIMIT reached, 3 MPABORT, 4 a reserved command or a PRUN in it |
| `$114-$116` | MPLIMIT | the commands a PRUN may execute before it aborts (24 bits; 0: no limit; after MRESET `$100000`). Taken when a PRUN starts: write it while the unit is idle |
| `$128-$12B` | MPLOAD | write: commands into program memory at MPPTR, in the stream's byte format (all four addresses one port, as MSTREAM's) |
| `$12C` | MPLOADRST | write any value: MPLOAD restarts at a command boundary |
| `$12D` | MPABORT | write any value: the running program stops at the next command boundary (MPERR 3); the registers keep their values |
| `$130-$137` | MPREAD | read: the program memory entry at MPPTR, 8 bytes: its form (0 register, 1 memory, 2 wide), opcode, regs byte, the 32-bit operand (a wide form's t byte in its low byte), 0. Byte 0 latches the entry; reading `$137` advances MPPTR. Only while no program runs (MSTATUS bit 4 clear) |
| `$200-$2FF` | wide forms | write `(d << 4) \| s` to `$200 + op * 2`, then `t << 4` to `$201 + op * 2`; the second byte issues the command (ops `$00-$7F`) |

Everything else is MCP-1's. MID says an MCP is there (the vertex unit's
CAPS bit 6 did too, until the vertex unit was removed after MCP-2); MVER
says which.

## Commands

### Stream and program format

The stream (and MPLOAD) gains one form:

| First byte | Length | |
|---|---|---|
| `$00-$7F` | 2 | register form (MCP-1) |
| `$80-$8F` | 6 | memory form (MCP-1) |
| `$90` | 4 | wide form: `$90`, op, `(d << 4) \| s`, `t << 4` |
| `$91-$FF` | 2 | reserved: ignored, MSTATUS bit 3 |

A program memory entry holds any one command (48 bits plus a two-bit form
tag; 50 of the RAMB36's 72 bits).

### New register forms

| Op | Name | Operation |
|---|---|---|
| `$18` | PEXIT | in a program: leave it now if `MCOND and data` is not 0 (the data byte is a mask of MCOND bits). Outside a program: nothing |
| `$19` | PEND | in a program: the end of a pass (the next pass starts at the program's start, or the program ends). Outside: nothing |

### New memory form

| m | Name | Operation |
|---|---|---|
| 14 | PRUN | run the program at `v` bits 0-8, at most `v` bits 16-31 passes (0: 65,536). d is ignored. In a program: it aborts the program (no nesting, MPERR 4) |

### Wide forms (op `$00-$7F`)

F registers are 0-15; V registers 0-3 (in the same 4-bit fields).

| Op | Name | Operation |
|---|---|---|
| `$00` | FADD3 | Fd = Fs + Ft |
| `$01` | FSUB3 | Fd = Fs - Ft |
| `$02` | FMUL3 | Fd = Fs x Ft |
| `$03` | FMA | Fd = Fs x Ft + Fd, rounded once |
| `$04` | FMS | Fd = Fd - Fs x Ft, rounded once (fma(-Fs, Ft, Fd)) |
| `$10` | VMOVE | Vd = Vs |
| `$11` | VADD | Vd = Vs + Vt, component by component |
| `$12` | VSUB | Vd = Vs - Vt |
| `$13` | VMUL | Vd = Vs x Vt, component by component |
| `$14` | VSCALE | Vd = Vs x Ft (t an F register) |
| `$15` | VDOT3 | Fd = Vs . Vt over x, y, z |
| `$16` | VDOT4 | Fd = Vs . Vt over x, y, z, w |
| `$17` | VCROSS | Vd.xyz = Vs.xyz x Vt.xyz, Vd.w = +0 |
| `$18` | VNORM3 | Vd.xyz = Vs.xyz / length(Vs.xyz), Vd.w = Vs.w |
| `$20` | MLOAD | M0-M15 = F0-F15 (regs ignored) |
| `$21` | MSTORE | F0-F15 = M0-M15 |
| `$22` | MXV | Vd = M x Vs |
| `$23` | MTXV | Vd = transpose(M) x Vs |
| `$24` | MMUL | M = M x F (F0-F15 as a 4 x 4 matrix by rows) |
| others | | reserved: ignored, MSTATUS bit 3 (in a program: it aborts, MPERR 4) |

Every result goes through a temporary first, so `d = s` and `d = t` are
fine (`VCROSS V1, V1, V2`, `MXV V0, V0`).

## Arithmetic

Every scalar step is an IEEE 754-2008 binary32 operation, rounded by MCTRL's
mode, its flags into MFLAGS, exactly as MCP-1's.

- **FMA, FMS:** fusedMultiplyAdd, one rounding (SoftFloat `f32_mulAdd`).
  FMS is `f32_mulAdd(-Fs, Ft, Fd)`.
- **FADD, FSUB, FMUL** (MCP-1's, and the three-register forms): the same
  results as MCP-1, now on the FMA unit.
  - `x + y` as `x x 1 + y`: `x x 1` is exact, so the one rounding is the
    addition's.
  - `x x y` as the product with the addend left out. Adding -0 instead
    would be wrong when rounding toward -∞: a +0 product plus -0 gives -0
    there, but IEEE's product is +0.
- **Dot products:** left to right, the first a product, the rest fused:
  `d = s.x x t.x; d = fma(s.y, t.y, d); d = fma(s.z, t.z, d)`, and for
  VDOT4 `d = fma(s.w, t.w, d)`.
- **MXV:** `Vd[r]` = row r of M dotted with Vs, as VDOT4.
- **MTXV:** column r of M dotted with Vs, as VDOT4.
- **MMUL:** `M[r][c] = M[r][0] x F[c]`, then fused with `M[r][1] x F[4 + c]`,
  `M[r][2] x F[8 + c]`, `M[r][3] x F[12 + c]`.
- **VCROSS:** `x = fma(s.y, t.z, -(s.z x t.y))`,
  `y = fma(s.z, t.x, -(s.x x t.z))`, `z = fma(s.x, t.y, -(s.y x t.x))`.
- **VNORM3:** `n = VDOT3(s, s); r = √n; q = 1 / r;` then each of x, y, z
  times q. A zero vector gives q = +∞ and NaN components (invalid), as IEEE
  says.
- **VADD, VSUB, VMUL, VSCALE:** four independent operations.

## Programs

- **Loading:** set MPPTR, then write commands to MPLOAD in the stream's
  format. Each command takes one entry and MPPTR advances. Loading while a
  program runs is not allowed (the result is undefined).
- **MRESET** keeps the program memory's contents (a block RAM can't be
  cleared in a clock, and a loaded program surviving a reset is useful);
  it sets MPPTR to 0, restarts MPLOAD, and MPLIMIT goes back to `$100000`.
- **Reading back:** set MPPTR, then read MPREAD's 8 bytes an entry. Reading
  `$137` advances MPPTR, so a loop (or `m65rs dump` over JTAG) walks a
  program. The CPU borrows the sequencer's read port for this, so it costs
  no block RAM, and it works only while no program runs.
- **Running:** PRUN start, count goes through the queue like any command.
  When it executes, the unit runs passes from `start`:
  - each pass runs commands until PEND, then the next pass begins
  - PEXIT with a matching MCOND bit leaves at once; that pass doesn't count
  - after `count` passes the program ends
  
  MPCNT then holds the passes completed, and the queue continues with the
  next command. The CPU can keep queueing meanwhile; MSTATUS bit 0 covers
  the program too.
- **Aborting:** a program aborts, with MSTATUS bit 5 set and MPERR saying
  why, when:
  - it runs past entry 511 without a PEND (there is no wrap-around)
  - it meets a reserved command or a PRUN (there is no nesting)
  - it has executed MPLIMIT commands (`$100000` after MRESET, a few tens of
    ms of work)
  - the CPU writes MPABORT
  
  MPCNT then holds the passes completed. The registers keep the values the
  program gave them, so a stuck program can be inspected over JTAG. The
  queue continues with the next command, so software checks bit 5. MRESET
  still stops everything.
- **The bound:** with MPLIMIT 0 (no limit), a PRUN is still bounded by its
  count times 512 commands.
- **Speed:** commands come from the block RAM a clock apart, with no bus
  cost.

The Mandelbrot's inner loop as a program, with the three-register forms
(stage 2; with stage 1's two-register forms it is 15 entries). The same
operations and order as MCP-1's version, so the results stay identical:

```
x2 = x * x        FMUL3  F4, F2, F2
y2 = y * y        FMUL3  F5, F3, F3
s = x2 + y2       FADD3  F6, F4, F5
compare s, 4      FCMP   F6, F7
leave if greater  PEXIT  4
t = x * y         FMUL   F3, F2          (F3 = x * y)
t + t             FADD   F3, F3
y = (t + t) + y0  FADD   F3, F1
x = x2 - y2       FSUB3  F2, F4, F5
x = x + x0        FADD   F2, F0
                  PEND
```

Per point the CPU queues `x = 0`, `y = 0`, `PRUN start, 32`, `x0 += 1/16`,
waits, and reads MPCNT: the iteration count.

## Timing targets

Estimates, for the implementation to confirm (stage 3a's measurements are
under "Stage 3a"):

| | Clocks |
|---|---|
| FMA unit: FADD, FSUB, FMUL, FMA, FMS (and the 3-register forms) | latency about 5, one a clock when independent |
| VADD, VSUB, VMUL, VSCALE | about 8 |
| VDOT3, VDOT4 | about 15, 20 (a dependent chain) |
| MXV, MTXV (four independent rows, interleaved) | about 20 |
| MMUL | about 70 |
| VNORM3 | about 90 (a square root and a reciprocal) |
| divide, square root | 33, as MCP-1 |

- **The Mandelbrot program:** a pass is about 30 clocks along its
  dependencies, about 0.75 µs.
- **The CPU's part:** about 1,000 points times a few µs.
- **Target for the benchmark:** under 20 ms, against MCP-1's 61.9 ms.

## The datapath

- **The FMA unit:** one 24 x 24 multiplier and one adder wide enough for
  the unrounded product and the aligned addend (about 75 bits), a
  normaliser and the rounder, as a pipeline of about 5 stages.
- **Divide and square root:** stay in their iterative unit beside the FMA
  unit, as in MCP-1.
- **Vector and matrix operations:** microcode, sequences of FMA-unit steps
  from a small ROM, scheduled so independent steps (MXV's four rows)
  overlap.

### Hazards

With a pipeline and the divider beside it, results arrive out of order;
they must land as if every command ran alone, in order.

- **What each command declares:** a read set and a write set over the
  resources: a 16-bit mask over F0-F15, and a bit each for the M bank,
  MCOND, MINT and MFLAGS.
- **What a vector or matrix command declares:** all it touches, not just the
  register it names.
  - VADD V1, V2, V3 reads 8 F registers and writes 4.
  - MXV reads the M bank and 4 F registers.
  - MMUL reads all of F and M and writes M.
  - MLOAD and MSTORE touch all of both, so they wait for everything in
    flight.
- **The rule:** a command issues only when nothing in its read or write set
  has a result in flight. A write-after-write must wait too, or an earlier
  slow divide could land after a later fast add to the same register. The
  internal temporaries are not resources.
- **MCOND:** PEXIT waits for it, since the FCMP before it may still be in
  flight.
- **MFLAGS:** SETFLAGS waits for every operation in flight (their flags are
  still to arrive). Flags otherwise accumulate (OR) in any order.
- **The rounding mode:** captured per command at issue, so SETCTRL never
  waits and later commands use the new mode.
- **The CPU's reads:** as in MCP-1, a register is read once MSTATUS bit 0
  is clear.

## Verification

As for MCP-1:

- **The model** (`mcp_model.c`) gains FMA and FMS (`f32_mulAdd`), the
  vector and matrix operations by the definitions above, and programs
  (PRUN, PEND, PEXIT, MPCNT).
- **TestFloat:** `f32_mulAdd` at levels 1 and 2 in all four modes, for the
  model and for the core. The add, subtract and multiply vectors again,
  since they now run on the FMA unit.
- **The vector, matrix and program definitions:** checked in the model
  against straightforward host code that follows them step by step.
- **MCP-1's benches, unchanged:** MCP-1's results must not move.
- **Random scripts** (`mcpgen`): with wide forms, programs (loaded,
  reloaded, run with random counts and exit masks) and the queue around
  them, against the model.
- **Planted bugs:** a product rounded before the add, a dot product in
  the wrong order, PEXIT counted as a pass, a vector operation checked only
  against the register it names, PEXIT not waiting for MCOND, a
  write-after-write let through, a program that wraps instead of aborting,
  MPLIMIT off by one.
- **The board:** `mcptest` with MCP-2 scripts, and the Mandelbrot again,
  as a program, against MCP-1's 61.9 ms.

## Build order

Each stage as MCP-1 was built: the model, the benches (MCP-1's unchanged),
a Vivado build, and the board (when it's free).

1. **Programs on MCP-1's core:** the program memory, MPLOAD, MPREAD, PRUN,
   PEND, PEXIT, MPCNT, MPLIMIT, MPABORT, MPERR. This takes on the
   bottleneck MCP-1's timing showed. The Mandelbrot as a 15-entry program
   is expected at about 25 ms (2.2 µs a pass on MCP-1's unpipelined core,
   plus the CPU's work per point).
2. **The FMA unit and the wide forms:** FADD3, FSUB3, FMUL3, FMA, FMS, still
   one command at a time.
3. **The pipeline, the scoreboard, vectors and matrices:** the targets
   above, in two steps:
   - **3a:** the pipeline and the scoreboard, under the commands there
     already are (nothing new for software; only faster)
   - **3b:** vectors and matrices, as sequences of steps on 3a's pipeline

## Stage 1 (2026-11-12)

Programs on MCP-1's core: `src/vhdl/mcp.vhdl` (MVER `$02`).
- **The model:** `mcp_model.c` covers all of MCP-2, a stage setting saying
  which part (0 is MCP-1 exactly). `mcpcheck` passes with no differences:
  - 25,798,608 TestFloat vectors (level 1, `f32_mulAdd` included, all four
    modes)
  - 13,799,214 host checks of MCP-1's operations
  - 1,000,076 wide-form operations against the host's own FMA and floats,
    step by step as "Arithmetic" defines them
  - 200,000 random programs against a separately written interpreter of
    "Programs"
  - 35,000 stream and MPLOAD/MPREAD checks across all four stages
  
  12 planted bugs, all caught: two by making the checker hang where the
  model must abort.
- **The hardware against the model** (`sim/run.sh`, stage 1, `mcpgen` with
  programs: loaded, cut off by MPLOADRST, run through the window and the
  stream, aborted by every cause; MPREAD dumps):
  - seeds 2-13 at both bus rates, 20,000 commands each (about 70,000 writes
    and 68,000 compared reads a run): identical
  - the overrun test, and the MPABORT test (an endless program aborted:
    MSTATUS bit 4 while running, then bit 5, MPERR 3)
  - 15 planted bugs, all caught
- **The build:** WNS +0.179 ns, no failing endpoints. The program memory is
  one RAMB36 (512 x 50).
- **The board:** three scripts (seeds 1, 2, 3), 48,515 reads, all identical
  to the model's. The first attempt at seed 1 printed nothing (most likely
  a transient JTAG or serial failure); the rerun passed.
- **The Mandelbrot as a 15-entry program** (`demo/mandel/mandel_prog.asm`):
  29.7 ms, 2.9 µs an iteration, every point exact. That is 2.1 x MCP-1's
  61.9 ms; the estimate was about 25 ms.
  - **What sets the pace now:** the arithmetic, not the bus. A pass is 13
    operations on MCP-1's unpipelined core (5-8 clocks each) plus a fetch
    per command, about 115 clocks.
  - **What's next:** stages 2 and 3 (the three-register forms: 11 entries;
    the pipeline).

| Mandelbrot on the board (40.5 MHz) | Time | Per iteration |
|---|---|---|
| MCP-2 stage 1, the inner loop as a program | 29.7 ms | 2.9 µs |
| MCP-1, 13 commands an iteration | 61.9 ms | 6.0 µs |
| C, llvm-mos soft-float | 1,932.8 ms | 188.3 µs |
| BASIC 65 | 7,697.4 ms | 750.1 µs |

## Stage 2 (2026-11-12)

The FMA unit and the wide forms: `src/vhdl/mcp_fpu.vhdl` gains a fused
multiply-add path (one rounding, SoftFloat's special-case order), and FADD,
FSUB, FSUBR and FMUL now run on it (as x x 1 + z, or x x y with no add).
`src/vhdl/mcp.vhdl` takes the wide forms through the window (`$200` + op x
2: the even byte is latched, the odd one issues) and the stream (prefix
`$90`): FADD3, FSUB3, FMUL3, FMA, FMS. Still one command at a time.
- **The model:** `mcpcheck` passes with no differences: 25,798,608
  TestFloat vectors (level 1, all four modes), 13,799,214 host checks,
  1,000,076 wide forms, 200,000 programs, 35,000 streams.
- **The core against the model** (`sim/run_fpu.sh`): 26,245,680 vectors
  identical, of them 24.5 million `f32_mulAdd` and 540,000 random operands.
  Add, subtract, multiply and FMA take 9 clocks (add and subtract were 8 on
  MCP-1's datapath). 10 planted bugs in the FMA path, all caught, the
  hardest by 9 vectors (an invalid infinity x 0 + qNaN that has to raise
  the invalid flag).
- **The front end against the model** (`sim/run.sh`, stage 2, `mcpgen` with
  wide forms through the window and the stream, and the reserved wide forms
  checked as they're issued): 24 seeds at both bus rates, about 72,000
  writes and 66,000 compared reads each, identical. 8 planted bugs: 7
  caught; the eighth (FMS negating t instead of s) gives the same results,
  since (-s) x t and s x (-t) are the same product.
- **The build:** WNS +0.041 ns, no failing endpoints. The worst paths are
  in the HyperRAM controller (`hyperram0`), none of the 1,220 reported paths
  goes through the MCP.
- **The board:** three scripts (seeds 1, 2, 3), 47,389 reads, all identical
  to the model's.
- **The Mandelbrot** (`demo/mandel/bench.py`):
  - The program with the three-register forms (11 entries, `-DWIDE=1`):
    25.2 ms, 2.5 µs an iteration, every point exact.
  - The 15-entry program: 31.7 ms, slower than stage 1's 29.7 ms because
    its adds and multiplies now take 9 clocks.
  - MCP-1's version: 61.8 ms, as before (the bus sets its pace).
  - **One bad run.** MCP-1's version once took 171.1 ms with 779 points
    wrong: every point that should escape ran to 32 iterations, so the
    escape test never fired for that whole run. It hasn't happened again
    in 12 runs since, and the program versions never failed (6 runs each).
    - **The likely cause** (found later the same day): the bitstream did
      not load, and the board ran the core in its flash, which has no MCP.
      MCOND then reads `$00`, so no point escapes. 32,000 iterations of
      the CPU's loop with nothing to wait for take about 171 ms.
    - `hwtest.sh` met the same failed load three times, the board then
      reporting no MCP (MID `$00`). The transfer seems to fail now and then
      without `m65rs` noticing, and the board then configures itself from
      its flash.
    - `hwtest.sh`, `bench.py` and `vtime.py` now check MID after every
      load and load again (three tries), printing the core that was
      running. The bench also prints the unit's registers and F0-F10 when
      a version gets points wrong.

| Mandelbrot on the board (40.5 MHz) | Time | Per iteration |
|---|---|---|
| MCP-2 stage 2, the program with three-register forms (11) | 25.2 ms | 2.5 µs |
| MCP-2 stage 2, the program (15) | 31.7 ms | 3.1 µs |
| MCP-2 stage 1, the program (15) | 29.7 ms | 2.9 µs |
| MCP-1, 13 commands an iteration | 61.8 ms | 6.0 µs |
| C, llvm-mos soft-float | 1,932.8 ms | 188.3 µs |
| BASIC 65 | 7,697.4 ms | 750.1 µs |

**What's next:** stage 3, the pipeline. At 9 clocks an operation, the 11
entries of a pass are about 100 clocks unpipelined; the pipeline lets
independent operations overlap.

## Stage 3a (2026-11-12)

The pipeline and the scoreboard, under the commands there already are.
Nothing changes for software (MVER is still `$02`, every result is the
same); it only runs faster.
- **The core** (`src/vhdl/mcp_fpu.vhdl`): three units side by side.
  - **The multiply-add pipeline:** FADD, FSUB, FSUBR, FMUL and FMA (the
    wide forms included) in five stages: unpack; the special cases and the
    multiplier; align and add; normalise; round. It takes an operation a
    clock, and a dependent command issues 5 clocks after the one it waits
    for.
  - **The short unit:** moves, compares, FMIN, FMAX, FABS, FNEG, FCLASS
    and FCONST, the result in the clock after issue, so FCMP then PEXIT
    costs one clock.
  - **The iterative unit:** divide, square root, reciprocal, rounding to an
    integer and the conversions, as on MCP-1, one at a time (33 clocks for
    divide and square root, 7 for the rest).
- **The front end** (`src/vhdl/mcp.vhdl`): it issues in order, a command a
  clock, from the queue or a program, with a scoreboard as "Hazards" says:
  a pending bit for each of F0-F15, MCOND and MINT.
  - A command waits while anything it reads or writes is pending.
    SETFLAGS waits for everything, PEXIT for MCOND, and an iterative
    operation also for its unit.
  - Results land as they come, out of order. A command issued in the clock
    a result lands gets that result (a bypass).
  - Each command takes the rounding mode in effect when it issues.
  - The read sets are a little wider than they need to be: a register form
    always waits for Fd and Fs. That costs nothing in the programs so far.
- **Programs:** the fetch now keeps up, a command a clock. The block RAM
  reads the next entry while one issues, an entry that has to wait is held
  in a register, and a jump (PEND) costs one clock to refill.
- **The core against the model** (`sim/run_fpu.sh`): the bench now issues
  as fast as the core takes operations (one a clock, an iterative one when
  its unit is free, an idle clock about one in four), the random part
  mixes the operations, and each result is matched to its operation by
  tag. 26,245,680 vectors identical, of them 24.5 million `f32_mulAdd`.
- **The front end against the model** (`sim/run.sh`): 24 seeds at both bus
  rates, about 72,000 writes and 67,000 compared reads each (1.6 million
  reads in all), identical.
- **18 planted bugs, all caught:**
  - 13 in the front end: a write-after-write let through (FCONST over a
    divide still running), operands read past the bypass, PEXIT reading
    MCOND without that clock's result, an iterative operation issued while
    its unit is busy, SETFLAGS or FXCHG not waiting, the held entry not
    used, no refill after PEND, MRESET not dropping what is in flight, a
    wide form's t not checked, a multiply-add result not marked pending, a
    waiting command taken off the queue, waits counted toward MPLIMIT
  - 5 in the core: the rounding mode taken from the wrong stage, a tag
    skipping a stage, a special result from the wrong stage, MRESET not
    emptying the pipeline, the iterative unit not busy in the clock it
    starts
  - Two of them (a divide lost) made the bench hang instead of fail. Both
    benches now have a watchdog: no result for 1,000 clocks with
    operations in flight, or a unit that never goes idle.
  - "PEXIT not waiting for MCOND" can't go wrong in this design: only the
    short unit writes MCOND, and its result is there the next clock. The
    bug planted instead was PEXIT reading MCOND without that result.
- **The build:** WNS +0.061 ns, no failing endpoints. The worst paths are
  in the HyperRAM controller again. In the CPU's clock, the worst setup
  slack is +0.502 ns, on a CPU path, so no MCP path comes within half a
  nanosecond.
- **The board:** three scripts (seeds 1, 2, 3), 29,924 reads, all identical
  to the model's.
- **The Mandelbrot** (`demo/mandel/bench.py`, three rounds, every point
  exact in every run; MCP-1's version too, so stage 2's one bad run has
  not come back):
  - The 11-entry program reordered for the pipeline (`-DPIPE=1`: the same
    operations on the same operands, y's chain first, x's commands in its
    waits): 10.3 ms, 1.0 µs an iteration.
  - The 11-entry program as it was: 11.9 ms (25.2 ms on stage 2).
  - The 15-entry program: 12.7 ms (31.7 ms).
  - **What sets the pace now:** a pass of the reordered program is 28
    clocks (34 as it was), measured in simulation: y's chain of y2, the
    sum, the compare, PEXIT, x x y, t + t, + y0, each add or multiply
    waiting 5 clocks for the one before. 10,262 passes at 28 clocks are
    7.1 ms. The other 3 ms is the CPU's work per point (queueing x = 0,
    y = 0, PRUN and x0 += 1/16, waiting, reading MPCNT): about 3 µs a
    point.

| Mandelbrot on the board (40.5 MHz) | Time | Per iteration |
|---|---|---|
| MCP-2 stage 3a, the 11 entries ordered for the pipeline | 10.3 ms | 1.0 µs |
| MCP-2 stage 3a, the 11-entry program as in stage 2 | 11.9 ms | 1.2 µs |
| MCP-2 stage 3a, the 15-entry program | 12.7 ms | 1.2 µs |
| MCP-2 stage 2, the 11-entry program | 25.2 ms | 2.5 µs |
| MCP-1, 13 commands an iteration | 61.8 ms | 6.0 µs |
| C, llvm-mos soft-float | 1,932.8 ms | 188.3 µs |
| BASIC 65 | 7,697.4 ms | 750.1 µs |

**What's next:** stage 3b, vectors and matrices as sequences of steps on
this pipeline.

## Stage 3b (2026-11-12)

Vectors and matrices: every wide form in "Commands" now works. MVER stays
`$02`.
- **Copies:** VMOVE, MLOAD and MSTORE copy in the clock they issue, once
  nothing they read or write has a result still to come.
- **Sequences:** the rest run as sequences of micro-operations from a ROM
  (133 steps in all) on 3a's units:
  - each step reads Vs's or Vt's components, F[t], an F, an M, 1.0 or a
    temporary, and writes one of 16 temporaries, T0-T15
  - T0-T15 have their own scoreboard and bypass, so a step waits only for
    the temporaries it reads
  - the steps go in the order "Arithmetic" defines, independent ones
    interleaved (MXV's four rows, MMUL's sixteen sums)
  - when the last step's result is back, the result goes into F or M in one
    clock; that is "every result goes through a temporary first"
  - a sequence keeps the issue until then, so nothing after it can see half
    a result. The M bank needs no scoreboard bit: only a sequence or MLOAD
    writes it, and neither overlaps anything that reads it.
- **Before it starts,** a command waits until nothing in its read or write
  set has a result still to come (a little wider than needed: Vs, Vt, Vd,
  F[t] and F[d] for every sequence; all of F for MLOAD, MSTORE and MMUL).
- **Clocks** (simulated, and the same on the board, `demo/vtime`):

  | Command | Clocks | Target |
  |---|---|---|
  | VMOVE, MLOAD, MSTORE | 1 | |
  | VADD, VSUB, VMUL, VSCALE | 10 | about 8 |
  | VDOT3, VDOT4 | 17, 22 | about 15, 20 |
  | VCROSS | 14 | |
  | MXV, MTXV | 25 | about 20 |
  | MMUL | 70 | about 70 |
  | VNORM3 | 90 | about 90 |

  A sequence also pays a clock to start and one to put its result in
  place; that is most of the difference from the targets.
- **The front end against the model** (`sim/run.sh`, stage 3, the default
  now: `mcpgen` gives half its wide forms as vector and matrix forms, by
  every path, and about one program entry in six): 24 seeds at both bus
  rates, about 73,000 writes and 65,000 compared reads each, identical.
- **13 planted bugs, all caught:**
  - a dot product in another order (caught on every seed tried, but by 1-5
    reads: an order that rounds differently is rare in random values)
  - a vector command checked only against the registers it names
  - VCROSS's product not negated
  - VNORM3's w from Vd instead of Vs
  - VCROSS keeping w
  - MTXV taking rows
  - MMUL taking F by rows
  - a step not waiting for the temporary it reads
  - a program losing the entry it had fetched while a sequence ran
  - a result put in place before its steps are back
  - MRESET keeping M
  - VSCALE reading Vt instead of F[t]
  - a square root started while the divider is busy (the unit never goes
    idle: the watchdog)
- **The build:** WNS +0.105 ns, the worst paths in the HyperRAM controller;
  the CPU clock's worst setup +0.999 ns, on a CPU path.
- **The board:** three stage-3 scripts (seeds 1, 2, 3), 28,171 reads, all
  identical to the model's. The first attempt at seed 3 found no MCP (the
  bitstream load did not take); the rerun passed.
- **The Mandelbrot,** now also at 80 x 50 (`bench.py --grid 80x50`: the
  same region at twice the resolution, 4,000 points, 40,365 iterations).
  Every point exact in every version:

  | Mandelbrot on the board (40.5 MHz) | 40 x 25 | 80 x 50 |
  |---|---|---|
  | MCP-2, the 11 entries ordered for the pipeline | 10.3 ms | 40.7 ms |
  | MCP-2, the 11-entry program | 11.9 ms | 46.9 ms |
  | MCP-2, the 15-entry program | 12.7 ms | 50.2 ms |
  | MCP-1 | 61.8 ms | 243.7 ms |
  | C, llvm-mos soft-float | 1,932.8 ms | 7,914.4 ms |
  | BASIC 65 | 7,697.4 ms | 30,382.2 ms |

- **Size** (`m65build/report-util.sh`, first measured here): the MCP is
  19,309 LUTs, 3,958 flip-flops, 1 RAMB36 and 2 DSPs, 14% of the A200T's
  LUTs. The vertex unit was 3,364 LUTs, 4,133 flip-flops, 7 RAMB36 and 17
  DSPs; it was removed after this (MCP.md, decision 4).
  - Most of the MCP's LUTs are not arithmetic. Vivado names each LUT
    after the register it feeds: about 8,900 feed F0-F15, 1,800 M, 1,000
    T, and 2,200 the core's operand registers. The arithmetic (align and
    add, normalise, the rounders, the divider, the conversions) is about
    5,000.
  - The reasons are in how the front end is written:
    - every F register can be written from many places: three result
      ports, FXCHG (any register into any other: a 16-way choice for every
      one of the 512 bits), VMOVE, MSTORE and the vector results
    - each operand port picks among the 16 registers once for each of
      several index sources (s, t, d, Vs + k, ...) instead of picking the
      index first and the register once
  - Picking the index first, routing FXCHG and VMOVE through the operand
    ports already there, and one shared shifter in the core took it to
    11,035 LUTs (MCP3.md, "Stage 0").

## Open points

- **PRUN's operand:** a 9-bit start and a 16-bit count in a memory form. A
  table of program entry points instead?
- **The 3D path (MCP-3):** a transform-and-project command for a vertex
  stream, using MXV and the divider. It probably wants a program per mesh,
  with the vertices arriving by DMA.
- **The MCP's size:** see "Stage 3b", "Size".
