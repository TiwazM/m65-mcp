# M65-MCP SDK examples

Six small programs that use the MCP from an ordinary MEGA65 program:
LOAD one, RUN it, read its results on the screen, and you are back in
BASIC 65. The hardware they use is described in
[`../REFERENCE.md`](../REFERENCE.md).

| | Shows |
|---|---|
| [`scalar.asm`](scalar.asm) | the three ways to give a command (register, memory and wide forms), constants, integers in and out, a compare, the flags |
| [`vector.asm`](vector.asm) | V0-V3: add, dot and cross products, length, normalise, scale |
| [`matrix.asm`](matrix.asm) | the matrix bank: MLOAD, MXV, MMUL, MTXV, MSTORE on a rotation |
| [`program.asm`](program.asm) | programs in the MCP's memory: Newton's iteration with PEXIT, a 1,000-term sum in one PRUN, a bouncing ball with PSKIP |
| [`async.asm`](async.asm) | the unit works while the CPU goes on: a register read too early (the old value), 64 divides by a DMA job (the queue overruns, 35 are dropped), and the same with MSTATUS heeded |
| [`basic.bas`](basic.bas) | the MCP from BASIC 65, with POKE and PEEK only |

What each prints is in [`expected/`](expected/). Those numbers were checked
against an FP32 calculation done apart from the MCP and its model.

## Building and running

With [ACME](https://sourceforge.net/projects/acme-crossass/) 0.97 or later:

```
acme -f cbm -I ../include -o scalar.prg scalar.asm
```

Then load `scalar.prg` on a MEGA65 with an M65-MCP core and RUN it.
`run.py` does that for all six over the USB JTAG link and compares each
screen with `expected/`, or does it in Xemu (its `mcp` branch, which has
the MCP: [`../demo/xemu.py`](../demo/xemu.py)):

```
python3 -I src/mcp/sdk/run.py              # all six, on the board
python3 -I src/mcp/sdk/run.py program --show
python3 -I src/mcp/sdk/run.py --xemu       # no board
```

## What the examples share

- [`../include/mcp.inc`](../include/mcp.inc): the MCP's addresses and
  opcodes.
- [`sdk.inc`](sdk.inc): macros for the three command forms (`+f_op`,
  `+f_mem`, `+f_op3`), for loading and reading registers (`+f_load`,
  `+f_load_n`, `+f_store`), for programs (`+p_load`, `+p_run`) and for
  printing.
- [`sdklib.asm`](sdklib.asm): `sdk_init` and the print routines.
  `print_freg` prints an F register as a decimal number with six places,
  correctly rounded, and uses the MCP itself to do it.

### The base page

The MCP is above the 16-bit address space, so a program reaches it through
32-bit pointers in the base page. Under BASIC 65 the whole base page
belongs to the KERNAL; the memory the MEGA65 guarantees free for programs
is `$1600-$1EFF`. So the SDK keeps its pointers in a base page of its own,
`$1600`:

```
        +mcp_enter              ; interrupts off, the base page register = $16
        +f_op MCP_FADD, 1, 2    ; F1 = F1 + F2
        +f_wait
        +mcp_leave              ; the KERNAL's base page again
        +print_f text, 1        ; (printing calls the KERNAL: outside the stretch)
```

Interrupts are off between `+mcp_enter` and `+mcp_leave`, because the
KERNAL's interrupt routine needs its own base page. A program that takes
the machine over (as the demos in `../demo/` do) can simply use base page
0 and `mcp.inc`'s macros.
