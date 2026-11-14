# M65-MCP - the MEGA65 Mathematics Coprocessor

A variant of the [MEGA65 core](https://github.com/MEGA65/mega65-core)
(branch `development`) with an FP32 and vector coprocessor in the spirit of
an early-1990s expansion. It has three instruction groups:

- a scalar FPU: FP32 arithmetic, square root, conversions
- a vector and matrix unit
- a geometry accelerator: transformation, projection, clipping, lighting
  (MCP-3: vertex programs)

Ordinary MEGA65 software reaches it through memory-mapped commands at
`$FFDF000-$FFDFFFF`:

- [`src/mcp/REFERENCE.md`](../src/mcp/REFERENCE.md), the hardware
  reference: registers, commands, memory layout and timing
- [`src/mcp/sdk/`](../src/mcp/sdk/), SDK examples to LOAD and RUN: scalar
  calculations, vectors, matrices, programs in the MCP's memory, what
  happens when a program does not wait, and the MCP from BASIC 65
- without a MEGA65: Xemu with the MCP in it, the `mcp` branch of
  [TiwazM/xemu_ai_agent](https://github.com/TiwazM/xemu_ai_agent), with
  builds for Linux, Windows and macOS on its
  [releases page](https://github.com/TiwazM/xemu_ai_agent/releases)
  ([`src/mcp/README.md`](../src/mcp/README.md), "Without a MEGA65")

## Getting it

A core file for the MEGA65 R6 is on the
[releases page](https://github.com/TiwazM/m65-mcp/releases). Copy it to the
SD card and put it into a slot with the MEGA65's flash menu (NO SCROLL held
at power-on), as any other core. It is the MEGA65 as before with the MCP
added, and with HDMI at 720p as an option (below). The R6 is the only board
the MCP is built for.

The design and its decisions are in [`src/mcp/MCP.md`](../src/mcp/MCP.md).

- **MCP-1** ([`src/mcp/MCP1.md`](../src/mcp/MCP1.md)), the scalar FPU: built
  and checked in simulation against Berkeley SoftFloat and TestFloat (about
  190 million vectors through the core, all identical); it passes its board
  test on a MEGA65 R6.
- **MCP-2** ([`src/mcp/MCP2.md`](../src/mcp/MCP2.md)): built and passes on the
  board:
  - programs stored in the MCP
  - a fused multiply-add unit with three-register forms
  - a pipeline with a scoreboard
  - vectors and matrices (V0-V3 over the F registers, a 4 x 4 matrix bank)

  Together they take the Mandelbrot benchmark from 61.9 ms to 10.3 ms
  (40 x 25 points; 80 x 50: 243.7 ms to 40.7 ms).
- **MCP-3** ([`src/mcp/MCP3.md`](../src/mcp/MCP3.md)), geometry: a vertex
  array and a result buffer, conversions on the way in and out, clip
  codes, a skip for vertices behind the camera, a faster divider. The
  standard vertex program (in [`mcp.inc`](../src/mcp/include/mcp.inc))
  transforms, clips, projects and lights a vertex in 90 clocks (2.2 µs;
  73 unlit). Built and passes on the board.

See [`src/mcp/README.md`](../src/mcp/README.md).

## What differs from the MEGA65 core

The base is `development` at `3c0c27feb` (2026-10-31), still that branch's
newest commit. On top of it:

- **The MCP:** `src/vhdl/mcp*.vhdl`, two hooks in `src/vhdl/iomapper.vhdl`
  (the instance and its chip select, in the fastio slot of the unused vFPGA
  at `$FFDF000`) and three files in `vivado/mega65r6_gen.tcl`. MEGA65 R6
  only. No changes to the 45GS02 or the VIC-IV.
- **HDMI at 720p** on the R3, R4 and R6: `$D61A` bit 5, or "digital video
  size" on the Video tab of Configure, sends the picture upscaled to 720p
  (4:3 within 16:9) in place of 576p or 480p, for the displays that do not
  show those as 4:3; "720p made for: a 21:9 display" is for ultrawide
  monitors. NTSC at 720p is announced as of variable refresh rate, and
  with "digital video: DVI only" it still is, the sound being silence then.
  With it come three fixes to the core: the CIAs' timers power up as
  `$FFFF` (BASIC 65 up to V920413 otherwise stays on a blue screen with
  this `development`), a framing bit of the HDMI packets, and the R4's
  build script. The five commits are the ones proposed upstream in
  [MEGA65/mega65-core#982](https://github.com/MEGA65/mega65-core/pull/982);
  their messages have the details, and `src/tests/upscaler/` and
  `src/tests/hdmi/` the simulations.
- **`make NO_FLASHMENU=1`** (`Makefile`, `src/hyppo/main.asm`): Hyppo never
  starts the flash menu on its own, so a bitstream loaded over JTAG stays
  loaded instead of the flash menu reconfiguring the FPGA. The default
  (0) is upstream's behaviour, and what a core for a flash slot has to be
  built with: built with 1, a disk image mounted with the freezer reads as
  rubbish ([`src/mcp/ISSUES.md`](../src/mcp/ISSUES.md)).
- **The audio tone generator** (`src/vhdl/audio_out_test_tone.vhdl`): its
  sample-ready toggle synchronised into `pcm_clk` before the edge detect
  (upstream issue #949; Paul Gardner-Stephen's commit, not yet in
  `development`).
- **`m65build/`:** the Vivado build in Docker.

## Layout

| | |
|---|---|
| [`src/mcp/`](../src/mcp/README.md) | The design, the MCP-1 and MCP-2 specs, the reference model, the benches, the board tests and benchmarks |
| `src/vhdl/mcp.vhdl` | The unit: registers, command queue, programs, scoreboard, vectors and matrices |
| `src/vhdl/mcp_fpu.vhdl` | Its arithmetic core |
| `src/vhdl/mcp_ram.vhdl` | Its program memory |
| `m65build/` | The Vivado build in Docker, and the utilization report |

## Building and testing

Simulation (macOS or Linux: a C compiler, [nvc](https://github.com/nickg/nvc)):

```
src/mcp/sim/fetch.sh                    # once: SoftFloat and TestFloat
src/mcp/sim/run_fpu.sh                  # the model, then the core: TestFloat level 1 + random
src/mcp/sim/run.sh 7 20000              # the whole unit: a random script of 20,000 commands
```

Bitstream (Vivado 2022.2 in Docker, the
[vivado-on-mac](https://github.com/tae2yi/vivado-on-mac) setup; the
submodules checked out):

```
git submodule update --init --recursive
zsh m65build/run-build.sh               # bin/mega65r6.bit, to load over JTAG
NO_FLASHMENU=0 zsh m65build/run-build.sh   # the same for a flash slot
zsh m65build/report-util.sh             # its utilization by hierarchy
```

`m65build` builds with NO_FLASHMENU=1 unless told otherwise, for the board
tests below, which load the bitstream over JTAG.

Board test and benchmarks (ACME, `m65rs` over the MEGA65's USB
JTAG/serial):

```
src/mcp/demo/build.sh                   # mcptest.prg, the records, the expected reads
src/mcp/demo/hwtest.sh bin/mega65r6.bit
python3 -I src/mcp/demo/mandel/bench.py
```

`hwtest.sh` loads the bitstream (volatile; the flash is not touched), runs
a random script on the board and compares every read with the model's.

## History

The MCP was first built on top of m65tr3d (a tile-based renderer and a
fixed-point vertex unit for the MEGA65, itself on the MEGA65 core's
`development`). MCP-1 and MCP-2 were built there step by step, beside the
vertex unit; the renderer and then the vertex unit were removed. On
2026-11-12 the history was rebuilt on `development` with only what this
core changes, so a diff against upstream shows exactly that; the steps
before are not in this repository. The repository was called mega-fpu
until 2026-11-12.

## Credits

- The [MEGA65 project](https://mega65.org) and the authors of
  [mega65-core](https://github.com/MEGA65/mega65-core), on which all of this sits.

## Licence

As the MEGA65 core: unless otherwise marked, the VHDL is under the GNU Lesser
General Public License v3 ([`LICENSE.txt`](../LICENSE.txt)). The upstream
core's own README is [`README.md`](../README.md).
