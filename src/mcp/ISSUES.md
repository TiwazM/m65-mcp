# M65-MCP: known issues

Things found and not yet fixed, noted as they turn up. Fixed ones leave
this list (git has them).

## Hardware

None open: nothing found so far that the unit does differently from
[`REFERENCE.md`](REFERENCE.md) and the model.

## Documents and sources

None open.

## Measurement

- **The CIAs' clock loses one raster line's ticks every video frame**
  (about 31 µs; found as "reads 30 µs short now and then" in `demo/vtime`).
  It is the MEGA65, not the MCP, and upstream's own code:
  `frame_generator.vhdl` hands the 1 MHz clock out as a budget of 63 (PAL)
  or 65 (NTSC) ticks for every two raster lines, filled up again only if
  it is used up when a line reaches a certain point, and sets the ticks'
  accumulator to 0 at the start of every frame; the budget running then
  finishes a few clocks late, is not filled, and the clock stands still for
  a line. Measured with Xemu's `build/tests/timing-m65`: 31.2 ticks a frame
  in PAL, 32.1 in NTSC; the machine's own count (`$D7F2` in C64 mode) reads
  19,624 or 19,625 a frame in PAL where a C64 has 19,656, and 17,062 or
  17,063 in NTSC where it has 17,095. A timing inside one frame is exact
  if it misses the step; one over many frames is 0.16% (PAL) or 0.19%
  (NTSC) short. The same clock paces the CPU in C64 mode. It is the PAL
  figure of upstream's issue 816 (open): 0.982721 MHz there, 0.98281 here.
  That issue's NTSC half (63 ticks a raster instead of 65) was fixed in
  November 2025 (c26aec0c0), which this core has and release 0.97 has not.
  The cause above is not in that issue yet, and no fix is tried. Xemu's
  `mcp` branch does the same as this core.
  - `vtime.py` now times everything three times and takes the longest.
  - `mandel/bench.py`, `geo/geo.py` and `show/show.py` time once: a figure
    of theirs can be 30 µs short for each such step it spans (small against
    their milliseconds, but not nothing for `geo.py`'s 1 ms).
  - It explains the FDIV reading of 29.7 clocks against 31.0 that
    `MCP3.md` (stage 1) could not account for.

## Performance (open points, not faults)

- **A sequence holds the issue until its last result is in** (VIN, MXV,
  VOUTC, VPASS, the vector and matrix commands): about 15 of the lit
  standard program's 90 clocks. `MCP3.md`, "Open points".
- **`demo/show` scene:** 30 frames a second, the CPU's triangle drawing
  the limit (17 of 19.5 ms). Drawing quads and stepping both edges in one
  32-bit add should reach 60.

## Around the project

- **A core built with NO_FLASHMENU=1 reads a mounted disk image as
  rubbish** (2026-11-14, an R6 with ROM 920413; why is not known). Built
  so (20261114.01), a disk image mounted with the freezer lists entries
  whose names are sixteen zero bytes (on the screen `8704 *DEL`, `0 "`,
  `0`, `0`, over and over, then `0 BLOCKS FREE`). The same source built
  with NO_FLASHMENU=0 (20261114.13, 20261114.14) lists a disk rightly,
  mounted with the freezer and with `MOUNT` from BASIC (the latter read
  over JTAG, MID `$4D`), as does upstream `development` with the same
  720p work and no MCP. Not tried: `MOUNT` from BASIC on a NO_FLASHMENU=1
  build. With the switch Hyppo skips megaflash on first boot, the one
  program in a normal boot that talks to the SD and flash controller
  before the ROM starts. **A core for a flash slot:
  `NO_FLASHMENU=0 zsh m65build/run-build.sh`.**
- **A JTAG load now and then does not take** and the board starts the core
  in its flash. The tools check MID and load again.
- **`hwtest.sh -`** (no load) only works on a freshly started machine: the
  demos end in a loop with interrupts off. And the tests (`hwtest.sh`,
  `geo.py`) expect the program memory, vertex array and result buffer as
  a core just loaded has them, cleared: MRESET keeps them, so a second
  run without a load compares against a previous run's leftovers. (In
  Xemu the runners clear them with its monitor's `~mcpinit`.)
- **`mcpgen` can ask for a wait `tb_mcp` gives up on.** Seed 48 (3,000
  commands, stage 5) runs a program of about a million commands (MPLIMIT's
  default): 3.9 million clocks, and the bench's wait_idle stops at
  1,000,000 polls (3 million clocks) with "the unit never went idle". The
  unit is right (Xemu's unit, given the time, finishes and passes). Either
  the generator should keep the limit low when it loops, or the bench wait
  longer.
- **`m65rs load` into Xemu** goes 16 bytes a frame: 240 KB take five
  minutes. Xemu's `mcp` branch has `~load ADDR PATH` for it (`m65rs raw`).
- **Xemu** does not open its `-uartmon` socket, and says nothing, when the
  path is longer than a Unix socket allows (104 bytes on macOS).
- **`demo/show` scene assumes a 4:3 picture** for the pixels' shape (720 x
  480 or 720 x 576). On a monitor that stretches it to 16:9 the torus is
  wide.
