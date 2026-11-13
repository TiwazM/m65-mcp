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
  [TiwazM/xemu_ai_agent](https://github.com/TiwazM/xemu_ai_agent)
  ([`src/mcp/README.md`](../src/mcp/README.md), "Without a MEGA65")

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
- **`make NO_FLASHMENU=1`** (`Makefile`, `src/hyppo/main.asm`): Hyppo never
  starts the flash menu on its own, so a bitstream loaded over JTAG stays
  loaded instead of the flash menu reconfiguring the FPGA. The default
  (0) is upstream's behaviour.
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
zsh m65build/run-build.sh               # bin/mega65r6.bit
zsh m65build/report-util.sh             # its utilization by hierarchy
```

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

The MCP was first built on top of [m65tr3d](https://github.com/TiwazM/m65tr3d)
(a tile-based renderer and a fixed-point vertex unit for the MEGA65, itself
on the MEGA65 core's `development`). MCP-1 and MCP-2 were built there step by
step, beside the vertex unit; the renderer and then the vertex unit were
removed. On 2026-11-12 the history was rebuilt on `development` with only
what this core changes, so a diff against upstream shows exactly that. The
step-by-step history is kept under the tag `m65tr3d-history`. The
repository was called mega-fpu until 2026-11-12.

## Credits

- The [MEGA65 project](https://mega65.org) and the authors of
  [mega65-core](https://github.com/MEGA65/mega65-core), on which all of this sits.

## Licence

As the MEGA65 core: unless otherwise marked, the VHDL is under the GNU Lesser
General Public License v3 ([`LICENSE.txt`](../LICENSE.txt)). The upstream
core's own README is [`README.md`](../README.md).
