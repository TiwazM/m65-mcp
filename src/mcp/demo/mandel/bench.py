"""bench: the Mandelbrot benchmark on a MEGA65 R6 - MCP-1 (FP32 in
hardware), MCP-2's programs (the inner loop in the MCP), C with llvm-mos's
soft-float, and BASIC 65 - each checked against the host's reference and
timed by CIA 2.

    python3 -I src/mcp/demo/mandel/bench.py [bitstream] [--only mcp,prog,wide,pipe,c,basic]
                                            [--grid 80x50]

Builds mandelref (cc), mandel_mcp.prg and mandel_prog.prg (ACME; the
program version needs an MCP-2 core), mandel_c.prg (llvm-mos in
~/llvm-mos, or $LLVM_MOS), mandel_bas.prg (bas2prg.py) into out/. Then for
each version: the bitstream loaded over JTAG (a clean machine; volatile,
the flash is not touched), the program run, its counts and the timer read
back. --grid 80x50: 80 x 50 points over the same region instead of 40 x 25
(every version built for it, its files named *_80x50). The CIA's "1 MHz" is 65 cycles a 27 MHz NTSC raster line
(1716 pixels: 1,022,727 Hz) or 63 a PAL one (1728: 984,375 Hz), from the
video mode the board is in (calibrate.py measures it).
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
OUT = os.path.join(HERE, "out")
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
LLVM_MOS = os.environ.get("LLVM_MOS", os.path.expanduser("~/llvm-mos"))


def run(*args, **kw):
    return subprocess.run(list(args), check=True, capture_output=True, text=True, **kw).stdout


def m65(*args):
    return run(M65RS, *args)


def peek(addr):
    return int(m65("peek", addr).split("$")[-1].split()[0], 16)


def read(addr, n, name):
    path = os.path.join(OUT, name)
    m65("save", f"{addr:x}", f"{addr + n:x}", path)
    return open(path, "rb").read()


def build(big):
    """every version into out/; big: 80 x 50 (the files named *_80x50)"""
    sfx = "_80x50" if big else ""
    os.makedirs(OUT, exist_ok=True)
    run("cc", "-std=c99", "-O2", "-ffp-contract=off", "-o", os.path.join(OUT, "mandelref"),
        os.path.join(HERE, "mandelref.c"))
    print(run(os.path.join(OUT, "mandelref"), OUT, *(["80x50"] if big else [])).strip())
    inc = os.path.join(HERE, "..", "..", "include")
    a = ["acme", "-f", "cbm", "-I", inc, "-DBIG=%d" % big]
    run(*a, "-o", os.path.join(OUT, f"mandel_mcp{sfx}.prg"), os.path.join(HERE, "mandel_mcp.asm"))
    run(*a, "-o", os.path.join(OUT, f"mandel_prog{sfx}.prg"), os.path.join(HERE, "mandel_prog.asm"))
    run(*a, "-DWIDE=1", "-o", os.path.join(OUT, f"mandel_wide{sfx}.prg"), os.path.join(HERE, "mandel_prog.asm"))
    run(*a, "-DWIDE=1", "-DPIPE=1", "-o", os.path.join(OUT, f"mandel_pipe{sfx}.prg"),
        os.path.join(HERE, "mandel_prog.asm"))
    run(os.path.join(LLVM_MOS, "bin", "mos-mega65-clang"), "-Os", *(["-DBIG"] if big else []), "-o",
        os.path.join(OUT, f"mandel_c{sfx}.prg"), os.path.join(HERE, "mandel.c"))
    bas = os.path.join(HERE, "mandel.bas")
    if big:                                      # the same program, 80 x 50 points, half the steps
        src = open(bas).read()
        for x, y in (("FOR R=0 TO 24", "FOR R=0 TO 49"), ("FOR C=0 TO 39", "FOR C=0 TO 79"),
                     ("X0=X0+.0625", "X0=X0+.03125"), ("Y0=Y0+.125", "Y0=Y0+.0625")):
            assert src.count(x) == 1, x
            src = src.replace(x, y)
        bas = os.path.join(OUT, "mandel_80x50.bas")
        open(bas, "w").write(src)
    run(sys.executable, "-I", os.path.join(HERE, "bas2prg.py"), bas, os.path.join(OUT, f"mandel_bas{sfx}.prg"))


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


VERSIONS = [  # name, PRG, what it is, timeout (s)
    ("mcp", "mandel_mcp.prg", "MCP-1, FP32 in hardware (assembly)", 30),
    ("prog", "mandel_prog.prg", "MCP-2: the inner loop as a program (15 entries)", 30),
    ("wide", "mandel_wide.prg", "MCP-2 stage 2: the program with 3-register forms (11)", 30),
    ("pipe", "mandel_pipe.prg", "MCP-2 stage 3a: the 11 entries ordered for the pipeline", 30),
    ("c", "mandel_c.prg", "C, llvm-mos soft-float (FP32)", 120),
    ("basic", "mandel_bas.prg", "BASIC 65 (40-bit floats)", 900),
]   # (80 x 50: the PRGs named *_80x50, the timeouts four times as long)


def main():
    args, only, grid, it = [], None, "40x25", iter(sys.argv[1:])
    for a in it:
        if a.startswith("--only"):                       # --only=a,b or --only a,b
            only = (a.split("=", 1)[1] if "=" in a else next(it, "")).split(",")
        elif a.startswith("--grid"):                     # --grid=80x50 or --grid 80x50
            grid = a.split("=", 1)[1] if "=" in a else next(it, "")
        else:
            args.append(a)
    if grid not in ("40x25", "80x50"):
        sys.exit("--grid: 40x25 or 80x50")
    big = grid == "80x50"
    sfx = "_80x50" if big else ""
    npoints = 4000 if big else 1000
    bit = args[0] if args else os.path.join(ROOT, "bin", "mega65r6.bit")
    build(big)
    ref32 = open(os.path.join(OUT, f"ref32{sfx}.bin"), "rb").read()
    ref64 = open(os.path.join(OUT, f"ref64{sfx}.bin"), "rb").read()
    iters = sum(ref32)
    rows = []
    for name, prg, what, timeout in VERSIONS:
        if only and name not in only:
            continue
        if big:
            prg, timeout = prg.replace(".prg", "_80x50.prg"), timeout * 4
        boot(bit)
        ntsc = peek("ffd306f") & 0x80
        hz = 27e6 * 65 / 1716 if ntsc else 27e6 * 63 / 1728
        m65("poke", "340", "00")
        m65("prg", "-r", os.path.join(OUT, prg))
        t0 = time.time()
        while peek("340") != 0xA5:
            if time.time() - t0 > timeout:
                sys.exit(f"{name}: no result after {timeout} s")
            time.sleep(0.5 if timeout > 60 else 0.2)
        st = read(0x340, 7, f"{name}{sfx}_stats.bin")
        where = st[5] | st[6] << 8 if name == "c" else 0x40000
        counts = read(where, npoints, f"{name}{sfx}_counts.bin")
        ta, tb = st[1] | st[2] << 8, st[3] | st[4] << 8
        secs = ((0xFFFF - tb) * 65536 + (0xFFFF - ta)) / hz
        d32 = sum(a != b for a, b in zip(counts, ref32))
        d64 = sum(a != b for a, b in zip(counts, ref64))
        if d32 and name in ("mcp", "prog", "wide", "pipe"):      # the unit's state, for the record
            regs = {n: peek(f"ffdf{o:03x}") for n, o in
                    (("MSTATUS", 0x100), ("MQLEN", 0x103), ("MCTRL", 0x104), ("MFLAGS", 0x105),
                     ("MCOND", 0x106), ("MPERR", 0x110), ("MVER", 0x102))}
            print(f"{name}: the unit after the run: " + ", ".join(f"{k} ${v:02X}" for k, v in regs.items()),
                  flush=True)
            fregs = []                          # F0-F10 (byte 0 first: it latches the other three)
            for d in range(11):
                b = [peek(f"ffdf{0x400 + d * 4 + k:03x}") for k in range(4)]
                fregs.append(f"F{d} ${b[3]:02X}{b[2]:02X}{b[1]:02X}{b[0]:02X}")
            print(f"{name}: " + ", ".join(fregs), flush=True)
        rows.append((name, what, secs, d32, d64))
        print(f"{name}: {secs * 1000:.1f} ms, {d32} points differ from FP32, {d64} from double "
              f"({'NTSC' if ntsc else 'PAL'}, CIA at {hz:.0f} Hz)", flush=True)
    print(f"\n{iters} iterations ({grid.replace('x', ' x ')} points, at most 32 each)\n")
    print(f"| version | time | per iteration | points differing (FP32 / double) |")
    print(f"|---|---|---|---|")
    for name, what, secs, d32, d64 in rows:
        print(f"| {what} | {secs * 1000:,.1f} ms | {secs * 1e6 / iters:,.1f} µs | {d32} / {d64} |")
    t = {r[0]: r[2] for r in rows}
    for fast in ("pipe", "wide", "prog", "mcp"):
        if fast in t:
            for k in ("wide", "prog", "mcp", "c", "basic"):
                if k in t and k != fast and t[k] > t[fast]:
                    print(f"{fast} is {t[k] / t[fast]:.1f} x faster than {k}")


if __name__ == "__main__":
    main()
