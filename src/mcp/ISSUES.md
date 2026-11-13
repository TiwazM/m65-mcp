# M65-MCP: known issues

Things found and not yet fixed, noted as they turn up. Fixed ones leave
this list (git has them).

## Hardware

None open: nothing found so far that the unit does differently from
[`REFERENCE.md`](REFERENCE.md) and the model.

## Documents and sources

None open.

## Measurement

- **The CIA 2 clock reads about 30 µs short now and then.** Seen on about
  5 of 142 one-shot timings in `demo/vtime`, on different tests each run,
  always short by the same amount; the same programs in the simulator take
  exactly the expected clocks. Not tracked down: the MEGA65 derives the
  CIA's "1 MHz" from the video timing, and a step once a frame would fit.
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
