# M65-MCP

The MEGA65 Mathematics Coprocessor. The design is in [`MCP.md`](MCP.md).
The programming model is in [`MCP1.md`](MCP1.md) (MCP-1, the scalar FPU)
and [`MCP2.md`](MCP2.md) (MCP-2: programs, multiply-add, vectors and
matrices) and [`MCP3.md`](MCP3.md) (MCP-3: geometry, vertex programs).

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
| `demo/mandel/`, `demo/vtime/` | the Mandelbrot benchmark, the commands' timings |

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
python3 -I src/mcp/demo/vtime/vtime.py    # MCP-2's commands timed: a program each, 1,000 passes
python3 -I src/mcp/demo/geo/geo.py        # the standard vertex program, lit (--unlit: without the light)
python3 -I src/mcp/demo/geo/geo.py --sim  # the same in nvc, no board
zsh m65build/report-util.sh             # after a build: the MCP's size
```
