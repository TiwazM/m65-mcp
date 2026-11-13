"""vtime: the M65-MCP's commands timed on a MEGA65 R6 (vtime.asm), or in
Xemu.

    python3 -I src/mcp/demo/vtime/vtime.py [bitstream] [--xemu]

Every command twice, as a program run 1,000 passes by one PRUN and timed
by CIA 2: alone in a pass (the command, PEND), and four in a row (so each
waits for the one before it where it uses its result). The passes' own
cost (PEND alone, 2 clocks) is taken off, and the four are given each.
Then what a command costs the CPU to issue or read (1,024 times each, the
loop's own cost taken off). Everything is timed three times and the
longest taken: the CIA's clock, which the MEGA65 derives from the video
timing, now and then reads about 30 µs short.

The tests are listed here, and vtime.asm takes them from out/ (the table
and its length). Loads the bitstream over JTAG (volatile; the flash is not
touched), runs vtime.prg and reads its timers back. The CIA's "1 MHz" from
the video mode the board is in, as the Mandelbrot bench. --xemu: no board;
a headless Xemu with the MCP in it (../xemu.py): the commands' clocks are
the hardware's there, the CPU's side is Xemu's own cycle counts.
"""
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
OUT = os.path.join(HERE, "out")
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
STATS = 0x6000
PASSES = 1000
REPS = 3
CLOCK = 40.5e6
PEND = bytes((0x19, 0x00))
ALLV = 0x1F                     # VFMT: FP32 position, normal, colour, three attribute words


def r(op, d, s):                # a register form
    return bytes((op, d << 4 | s))


def m(mf, d, v):                # a memory form: v an FP32 value, or bits as an int
    return bytes((0x80 + mf, d << 4)) + (struct.pack("<f", v) if isinstance(v, float) else struct.pack("<I", v))


def w(op, d, s, t):             # a wide form
    return bytes((0x90, op, d << 4 | s, t << 4))


# name, the command (it works on what it wrote where it can, so four in a
# row wait for each other), VFMT. F0-F15 start as 1.25 + i / 4 and M as a
# copy, before every test.
TESTS = [
    ("FMOVE F1, F2", r(0x00, 1, 2)),
    ("FADD F1, F2", r(0x01, 1, 2)),
    ("FSUB F1, F2", r(0x02, 1, 2)),
    ("FSUBR F1, F2", r(0x03, 1, 2)),
    ("FMUL F1, F2", r(0x04, 1, 2)),
    ("FDIV F1, F1", r(0x05, 1, 1)),
    ("FDIVR F1, F1", r(0x06, 1, 1)),
    ("FCMP F1, F2", r(0x07, 1, 2)),
    ("FMIN F1, F2", r(0x08, 1, 2)),
    ("FMAX F1, F2", r(0x09, 1, 2)),
    ("FSQRT F1, F1", r(0x0A, 1, 1)),
    ("FABS F1, F1", r(0x0B, 1, 1)),
    ("FNEG F1, F1", r(0x0C, 1, 1)),
    ("FRINT F1, F1", r(0x0D, 1, 1)),
    ("FTRUNC F1, F1", r(0x0E, 1, 1)),
    ("FCLASS F1", r(0x0F, 0, 1)),
    ("FTOI F1", r(0x10, 0, 1)),
    ("FTOX F1", r(0x11, 0, 1)),
    ("FTOI16 F1", r(0x12, 0, 1)),
    ("FRECIP F1, F1", r(0x13, 1, 1)),
    ("FXCHG F1, F2", r(0x14, 1, 2)),
    ("FCONST F1, pi", r(0x15, 1, 5)),
    ("SETCTRL", r(0x16, 0, 0)),
    ("SETFLAGS", r(0x17, 0, 0)),
    ("PEXIT (not taken)", r(0x18, 0, 0)),
    ("FMOVE F1, #v", m(0, 1, 1.5)),
    ("FADD F1, #v", m(1, 1, 1.5)),
    ("FMUL F1, #v", m(4, 1, 1.0)),
    ("FDIV F1, #v", m(5, 1, 1.0)),
    ("FSQRT F1, #v", m(10, 1, 2.0)),
    ("FRECIP F1, #v", m(11, 1, 3.0)),
    ("FILD F1, #n", m(12, 1, 12345)),
    ("FXLD F1, #n", m(13, 1, 12345)),
    ("FADD3 F1, F1, F2", w(0x00, 1, 1, 2)),
    ("FSUB3 F1, F1, F2", w(0x01, 1, 1, 2)),
    ("FMUL3 F1, F1, F2", w(0x02, 1, 1, 2)),
    ("FMA F1, F2, F3", w(0x03, 1, 2, 3)),
    ("FMS F1, F2, F3", w(0x04, 1, 2, 3)),
    ("VMOVE V1, V2", w(0x10, 1, 2, 0)),
    ("VADD V1, V1, V2", w(0x11, 1, 1, 2)),
    ("VSUB V1, V1, V2", w(0x12, 1, 1, 2)),
    ("VMUL V1, V1, V2", w(0x13, 1, 1, 2)),
    ("VSCALE V1, V1, F12", w(0x14, 1, 1, 12)),
    ("VDOT3 F4, V1, V2", w(0x15, 4, 1, 2)),
    ("VDOT4 F4, V1, V2", w(0x16, 4, 1, 2)),
    ("VCROSS V1, V1, V2", w(0x17, 1, 1, 2)),
    ("VNORM3 V1, V1", w(0x18, 1, 1, 0)),
    ("MLOAD", w(0x20, 0, 0, 0)),
    ("MSTORE", w(0x21, 0, 0, 0)),
    ("MXV V1, V1", w(0x22, 1, 1, 0)),
    ("MTXV V1, V1", w(0x23, 1, 1, 0)),
    ("MMUL", w(0x24, 0, 0, 0)),
    ("VIN V1, position (FP32)", w(0x25, 1, 0, 0)),
    ("VIN V1, position (s16)", w(0x25, 1, 0, 0), ALLV & ~1),
    ("VIN V1, normal", w(0x25, 1, 0, 1)),
    ("VIN V1, colour", w(0x25, 1, 0, 2)),
    ("VOUT F1, FP32", w(0x26, 0, 1, 0)),
    ("VOUT F1, FP32's top half", w(0x26, 1, 1, 0)),
    ("VOUT F1, 12.4", w(0x26, 2, 1, 0)),
    ("VOUT F1, u16", w(0x26, 3, 1, 0)),
    ("VOUT F1, s16", w(0x26, 4, 1, 0)),
    ("VOUT F1, 16.16", w(0x26, 5, 1, 0)),
    ("VOUTC V1", w(0x27, 0, 1, 0)),
    ("VPASS (1 word)", r(0x1B, 0, 0), 0x0F),
    ("VPASS (2 words)", r(0x1B, 0, 0), 0x17),
    ("VPASS (3 words)", r(0x1B, 0, 0)),
    ("VCLIP V1", r(0x1C, 0, 1)),
    ("PSKIP (not taken)", w(0x28, 0, 0, 0)),
    ("VNEXT", r(0x1A, 0, 0)),
    ("VEND", r(0x1E, 0, 0)),
]
# four that do not wait for each other: one a clock
INDEPENDENT = ("four FADD3 on different registers",
               w(0x00, 1, 2, 3) + w(0x00, 4, 5, 6) + w(0x00, 7, 8, 9) + w(0x00, 10, 11, 12))
CPU = ["the loop alone", "a register form: STA [zp],Z", "a register form with its LDZ and LDA",
       "a memory form: STQ [zp]", "reading a register: LDZ #0, LDQ [zp]", "a poll of MSTATUS: LDA [zp],Z, AND, BNE"]


link = []                       # m65rs's connection options (Xemu: its socket)
sys.path.insert(0, os.path.join(HERE, ".."))
import xemu                     # noqa: E402  (-I: the path is not searched by itself)


def run(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout


def m65(*args):
    return run(M65RS, *link, *args)


def peek(addr):
    return int(m65("peek", addr).split("$")[-1].split()[0], 16)


def boot(bit):
    """the bitstream over JTAG; a load now and then does not take (the board
    then runs the core in its flash): MID ($FFDF101) tells, three tries"""
    for attempt in range(3):
        m65("jtag", "bit", bit)
        time.sleep(10)
        pc = m65("info").splitlines()[3][:4]
        if pc.startswith("56E"):                 # the ROM waiting for CIA 2 timer A
            m65("poke", "ffd3d04", "ff", "ff")
            m65("poke", "ffd3d0e", "11")
            time.sleep(6)
        if peek("ffdf101") == 0x4D:
            return
        core = [l for l in m65("info").splitlines() if l.startswith("core:")]
        print(f"the load did not take (no MCP; {core[0] if core else 'core unknown'}): loading again",
              flush=True)
    sys.exit("no MCP after three loads")


def records():
    """the programs as vtime.asm runs them: 32 bytes each (VFMT, a spare
    byte, 30 bytes of program, PEND to the end): PEND alone, then each test
    alone and four in a row, then the independent four"""
    progs = [(ALLV, b"")]
    for t in TESTS:
        vfmt = t[2] if len(t) > 2 else ALLV
        progs += [(vfmt, t[1]), (vfmt, t[1] * 4)]
    progs.append((ALLV, INDEPENDENT[1]))
    out = bytearray()
    for vfmt, p in progs:
        assert len(p) <= 28, "a test's program is 28 bytes at most"
        out += bytes((vfmt, 0)) + p + PEND * ((30 - len(p)) // 2)
    return bytes(out), len(progs)


def main():
    args = [a for a in sys.argv[1:] if a != "--xemu"]
    on_xemu = len(args) != len(sys.argv) - 1
    bit = args[0] if args else os.path.join(ROOT, "bin", "mega65r6.bit")
    os.makedirs(OUT, exist_ok=True)
    table, n = records()
    open(os.path.join(OUT, "vtime_tests.bin"), "wb").write(table)
    open(os.path.join(OUT, "vtime.inc"), "w").write(f"NTESTS = {n}\nSTATS = ${STATS:04X}\nPASSES = {PASSES}\nREPS = {REPS}\n")
    prg = os.path.join(OUT, "vtime.prg")
    run("acme", "-f", "cbm", "-I", os.path.join(HERE, "..", "..", "include"), "-I", OUT, "-o", prg,
        os.path.join(HERE, "vtime.asm"))
    if on_xemu:
        link[:] = xemu.start()
    else:
        boot(bit)
    try:
        ntsc = peek("ffd306f") & 0x80
        hz = 27e6 * 65 / 1716 if ntsc else 27e6 * 63 / 1728
        m65("poke", f"{STATS:x}", "00")
        m65("prg", "-r", prg)
        t0 = time.time()
        while peek(f"{STATS:x}") != 0xA5:
            if time.time() - t0 > 60:
                sys.exit("vtime: no result after 60 s")
            time.sleep(0.2)
        path = os.path.join(OUT, "stats.bin")
        m65("save", f"{STATS:x}", f"{STATS + 1 + 4 * REPS * (n + len(CPU)):x}", path)
    finally:
        xemu.stop_mine()
    st = open(path, "rb").read()

    def clocks(i, count):       # test i's longest run, in 40.5 MHz clocks a pass (or a turn of the loop)
        ticks = []
        for k in range(REPS * i, REPS * i + REPS):
            a = st[1 + 4 * k] | st[2 + 4 * k] << 8
            b = st[3 + 4 * k] | st[4 + 4 * k] << 8
            ticks.append((0xFFFF - b) * 65536 + (0xFFFF - a))
        return max(ticks) / hz * CLOCK / count

    base = clocks(0, PASSES)
    print(f"{PASSES} passes each; a pass of PEND alone: {base:.1f} clocks "
          f"({'NTSC' if ntsc else 'PAL'}, CIA at {hz:.0f} Hz)\n")
    print("| command | alone | four in a row, each |")
    print("|---|---|---|")
    for k, t in enumerate(TESTS):
        one, four = clocks(1 + 2 * k, PASSES) - base, (clocks(2 + 2 * k, PASSES) - base) / 4
        print(f"| {t[0]} | {one:.1f} | {four:.1f} |")
    ind = clocks(n - 1, PASSES) - base
    print(f"\n{INDEPENDENT[0]}: {ind:.1f} clocks, {ind / 4:.1f} each")
    loop = clocks(n, 1024)
    print(f"\nthe CPU's side, 40.5 MHz cycles (the loop alone: {loop:.1f}):\n")
    print("| | cycles | µs |")
    print("|---|---|---|")
    for k, name in enumerate(CPU[1:], 1):
        c = clocks(n + k, 1024) - loop
        print(f"| {name} | {c:.1f} | {c / CLOCK * 1e6:.2f} |")


if __name__ == "__main__":
    main()
