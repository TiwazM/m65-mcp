# M65-MCP

The MEGA65 Mathematics Coprocessor.

- **To use it:** [`REFERENCE.md`](REFERENCE.md), the hardware reference
  (registers, commands, memory layout, timing), and [`sdk/`](sdk/), six
  examples to LOAD and RUN (scalar calculations, vectors, matrices,
  programs in the MCP's memory, what happens when a program does not
  wait, and the MCP from BASIC 65).
- **Without a MEGA65:** Xemu with the MCP in it, the `mcp` branch of
  [TiwazM/xemu_ai_agent](https://github.com/TiwazM/xemu_ai_agent). The
  same model does the arithmetic, and the unit keeps the hardware's
  clocks: it is busy as long, reads too early get the old value, a full
  queue drops commands. Every runner below takes `--xemu`
  ([`demo/xemu.py`](demo/xemu.py)).
- **How it came to be:** the design in [`MCP.md`](MCP.md), and each stage as
  it was specified, built and checked in [`MCP1.md`](MCP1.md) (the scalar
  FPU), [`MCP2.md`](MCP2.md) (programs, multiply-add, vectors and matrices)
  and [`MCP3.md`](MCP3.md) (geometry, vertex programs).
- **What is known to be wrong:** [`ISSUES.md`](ISSUES.md).

MCP-1 is built and checked in simulation and on a MEGA65 R6 (board test:
three random scripts, 35,625 reads, all identical to the model's). MCP-2
([`MCP2.md`](MCP2.md)) is built and checked the same way, in four
stages: programs, the fused multiply-add unit and the three-register
forms, the pipeline and the scoreboard, and vectors and matrices. Their
board reads were all identical: 48,515, 47,389, 29,924 and 28,171. The
Mandelbrot on the board (40 x 25 / 80 x 50 points): MCP-2 10.3 / 40.7 ms,
MCP-1 61.8 / 243.7 ms, C with llvm-mos's soft-float 1.93 / 7.91 s, BASIC
65 7.70 / 30.4 s.

MCP-3 ([`MCP3.md`](MCP3.md)) in four stages: making room (the MCP from
19,316 LUTs to 11,035), the vertex path, geometry, light. Its board reads
were all identical (45,355 and 42,863), and the standard vertex program
on a 528-vertex torus leaves the result buffer byte for byte as the model
does: 73 clocks a vertex unlit, 90 lit. The MCP is now 12,740 LUTs.

## Files

| | |
|---|---|
| `../vhdl/mcp.vhdl` | the unit: the registers, the command queue, the three issue paths, programs and the wide forms (MCP-2 stages 1 and 2), the scoreboard (stage 3a), vectors and matrices: the M bank, the temporaries, the micro-operation ROM and sequencer (stage 3b), the core |
| `../vhdl/mcp_fpu.vhdl` | the arithmetic core: IEEE binary32, three units (MCP-2 stage 3a): the multiply-add pipeline, the short unit, the iterative unit |
| `model/mcp_model.c`, `.h` | the reference: Berkeley SoftFloat 3e plus what SoftFloat lacks (min/max, fixed point, int16, classes, constants), and the unit's state command by command |
| `model/mcpcheck.c` | checks the model against TestFloat and the host's floating point |
| `model/mcpvec.c` | test vectors for the core, with the model's results |
| `model/mcpgen.c` | random bus scripts for the whole unit, with the model's state at each checkpoint |
| `sim/fetch.sh` | fetches and builds SoftFloat and TestFloat (pinned) into `ext/`, which git ignores |
| `sim/run_fpu.sh`, `sim/tb_mcp_fpu.vhdl` | the core's bench |
| `sim/run.sh`, `sim/tb_mcp.vhdl` | the unit's bench, through the fastio bus |
| `include/mcp.inc` | for ACME: addresses, opcodes, macros, the standard vertex programs |
| `demo/build.sh`, `demo/hwtest.sh`, `demo/mcptest.asm` | the board test: an `mcpgen` script run on a MEGA65 |
| `demo/geo/` | the standard vertex program on a torus, against the model, on the board or in nvc |
| `sdk/` | the SDK examples, their macros and print routines, and `run.py` to check them on the board or in Xemu |
| `demo/xemu.py` | starts and stops a headless Xemu with the MCP for the runners (`--xemu`) |
| `demo/mandel/`, `demo/vtime/` | the Mandelbrot benchmark; every command's timing (the reference's tables) |
| `demo/show/` | on the screen: the Mandelbrot at 320 x 200 in 256 colours, and a turning lit torus at 30 frames a second (a vertex program and a face program in the MCP, DMA throughout) |

## Running the checks

A C compiler and [nvc](https://github.com/nickg/nvc). Once:

```
src/mcp/sim/fetch.sh
```

Then:

```
src/mcp/sim/run_fpu.sh                 # the model (mcpcheck), then the core: TestFloat level 1 + random
src/mcp/sim/run_fpu.sh 2 100000        # TestFloat level 2: about 200 million vectors, streamed
src/mcp/sim/run.sh 7 20000             # the whole unit: a random script of 20,000 commands
MCP_FASTBUS=1 src/mcp/sim/run.sh       # at the DMA's best bus rate
```

On the board (ACME, `m65rs` over the MEGA65's USB JTAG/serial):

```
src/mcp/demo/build.sh                  # out/mcptest.prg, the records, the expected reads
src/mcp/demo/hwtest.sh bin/mega65r6.bit
python3 -I src/mcp/demo/mandel/bench.py   # the Mandelbrot timing: MCP-1, MCP-2, C (llvm-mos), BASIC 65
python3 -I src/mcp/demo/mandel/bench.py --grid 80x50   # the same at 80 x 50 points
python3 -I src/mcp/demo/vtime/vtime.py    # every command timed: a program each, 1,000 passes
python3 -I src/mcp/sdk/run.py             # the SDK examples, each screen against what it must print
python3 -I src/mcp/demo/geo/geo.py        # the standard vertex program, lit (--unlit: without the light)
python3 -I src/mcp/demo/geo/geo.py --sim  # the same in nvc, no board
python3 -I src/mcp/demo/show/show.py mandel   # the Mandelbrot on the screen, checked pixel by pixel
python3 -I src/mcp/demo/show/show.py scene    # the turning torus: eight frames checked, then the frame rate
zsh m65build/report-util.sh             # after a build: the MCP's size
```

Without a board, in Xemu (its `mcp` branch built: `make` in its
`targets/mega65`; `XEMU=path/to/xmega65.native` if it is not in
`~/Documents/GitHub/xemu-mcp`):

```
python3 -I src/mcp/sdk/run.py --xemu
src/mcp/demo/hwtest.sh xemu
python3 -I src/mcp/demo/geo/geo.py --xemu
python3 -I src/mcp/demo/vtime/vtime.py --xemu      # (Xemu's CIA ticks once a raster line: coarse)
python3 -I src/mcp/demo/show/show.py mandel --xemu
python3 -I src/mcp/demo/show/show.py scene --xemu
python3 -I src/mcp/demo/xemu.py start              # one Xemu kept for a row of runs (stop: the same with stop)
```
