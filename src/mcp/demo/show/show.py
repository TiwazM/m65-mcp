"""show: the M65-MCP's display demos on a MEGA65 R6, or in Xemu.

    python3 -I src/mcp/demo/show/show.py mandel|scene [bitstream] [--xemu]

mandel: the Mandelbrot, 320 x 200 points in 256 colours (mandel.asm), each
computed by the MCP and drawn as it comes. Once it is done the frame
buffer is read back and compared, pixel by pixel, with the one mandel.c
computes on the host (FP32, the MCP's order of operations), and the time
is printed; a screenshot goes to out/.

scene: a turning, lit torus (scene.asm): the MCP does its arithmetic (a
vertex program and a face program), the DMA moves the data and fills the
triangles' columns, the CPU links the visible faces by depth and sets up
the triangles. Eight frames around the turn are stepped through and
compared, pixel by pixel, with the ones scene.c draws from the model's
results; then it turns, and the frame rate and frame 64's time per step
are printed, with screenshots.

On the board: the bitstream is loaded over JTAG (volatile; the flash is not
touched). --xemu: no board; a headless Xemu with the MCP in it (../xemu.py)
runs the same programs, and takes the board's time for them (in the same
video mode: XEMU_ARGS="-videostd 1" for NTSC).
Needs ACME, a C compiler and m65rs (MEGA65 Studio).
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ROOT = os.path.abspath(os.path.join(SRC, ".."))
OUT = os.path.join(HERE, "out")
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
CLOCK = 40.5e6
link = []                           # m65rs's connection options (Xemu: its socket)
sys.path.insert(0, os.path.join(HERE, ".."))
import xemu                         # noqa: E402  (-I: the path is not searched by itself)


def run(*args, **kw):
    return subprocess.run(list(args), check=True, capture_output=True, text=True, **kw).stdout


def m65(*args):
    return run(M65RS, *link, *args)


def peek(addr):
    return int(m65("peek", addr).split("$")[-1].split()[0], 16)


def boot(bit):
    """the bitstream over JTAG; a load now and then does not take (the board
    then runs the core in its flash): MID ($FFDF101) tells, three tries"""
    for _ in range(3):
        m65("jtag", "bit", bit)
        time.sleep(10)
        pc = m65("info").splitlines()[3][:4]
        if pc.startswith("56E"):                 # the ROM waiting for CIA 2 timer A
            m65("poke", "ffd3d04", "ff", "ff")
            m65("poke", "ffd3d0e", "11")
            time.sleep(6)
        if peek("ffdf101") == 0x4D:
            return
        print("the load did not take (no MCP): loading again", flush=True)
    sys.exit("no MCP after three loads")


def acme(name, *defs):
    run("acme", "-f", "cbm", "-I", os.path.join(SRC, "mcp", "include"), "-I", HERE, "-I", OUT,
        *defs, "-o", os.path.join(OUT, f"{name}.prg"), os.path.join(HERE, f"{name}.asm"))


def host(name, *args, model=False):
    """the host's half: name.c (with the MCP's model and SoftFloat), run
    with args and the output folder"""
    extra = []
    if model:
        sf = os.path.join(SRC, "mcp", "ext", "berkeley-softfloat-3")
        md = os.path.join(SRC, "mcp", "model")
        extra = ["-I", os.path.join(sf, "source", "include"), "-I", md, os.path.join(md, "mcp_model.c"),
                 os.path.join(sf, "build", "Linux-ARM-VFPv2-GCC", "softfloat.a")]
    run("cc", "-std=gnu99", "-O2", "-ffp-contract=off", "-o", os.path.join(OUT, name),
        os.path.join(HERE, f"{name}.c"), *extra, "-lm")
    opts = [a for a in args if a.startswith("--")]
    print(run(os.path.join(OUT, name), *opts, OUT, *[a for a in args if not a.startswith("--")]).strip())


def wait_done(limit):
    t0 = time.time()
    while peek("340") != 0xA5:
        if time.time() - t0 > limit:
            sys.exit(f"no result after {limit} s")
        time.sleep(0.5)


def cia_hz():
    """the CIA's "1 MHz", from the video mode (the Mandelbrot bench's
    calibration)"""
    return 27e6 * 65 / 1716 if peek("ffd306f") & 0x80 else 27e6 * 63 / 1728


def cia_ticks(b):
    """CIA 2's cascaded timers, as stored (A low, high, B low, high), counted
    down from $FFFF each: the ticks gone"""
    return (0xFFFF - (b[2] | b[3] << 8)) * 65536 + (0xFFFF - (b[0] | b[1] << 8))


def cia_seconds():
    st = os.path.join(OUT, "stats.bin")
    m65("save", "340", "345", st)
    return cia_ticks(open(st, "rb").read()[1:5]) / cia_hz()


def compare_fb(addr, expected, what):
    got = os.path.join(OUT, f"{what}_got.bin")
    m65("save", f"{addr:x}", f"{addr + len(expected):x}", got)
    g = open(got, "rb").read()
    bad = [i for i in range(len(expected)) if i >= len(g) or g[i] != expected[i]]
    for i in bad[:8]:
        col, rest = divmod(i, 1600)
        y, xb = divmod(rest, 8)
        print(f"pixel ({col * 8 + xb}, {y}): {g[i] if i < len(g) else 0}, expected {expected[i]}")
    return len(bad)


def mandel(bit, on_xemu):
    os.makedirs(OUT, exist_ok=True)
    host("mandel")
    acme("mandel")
    if on_xemu:
        link[:] = xemu.start()
    else:
        boot(bit)
    m65("poke", "340", "00")
    m65("prg", "-r", os.path.join(OUT, "mandel.prg"))
    wait_done(120)
    secs = cia_seconds()
    shot = os.path.join(OUT, f"mandel_{'xemu' if on_xemu else 'board'}.png")
    m65("screenshot", "-p", shot)
    bad = compare_fb(0x40000, open(os.path.join(OUT, "mandel_fb.bin"), "rb").read(), "mandel")
    print(f"the MCP{' in Xemu' if on_xemu else ''}: {secs:.2f} s for 64,000 points; screenshot {shot}")
    if bad:
        sys.exit(f"FAIL: {bad} of 64000 pixels differ from the host's")
    print("PASS: all 64000 pixels as the host computes them")


FRAMES = [0, 21, 48, 64, 111, 160, 201, 255]       # checked pixel by pixel


def scene(bit, on_xemu):
    os.makedirs(OUT, exist_ok=True)
    where = "xemu" if on_xemu else "board"
    if on_xemu:
        link[:] = xemu.start()
    else:
        boot(bit)
    ntsc = peek("ffd306f") & 0x80                # the frames are for the machine's video mode
    host("scene", "--ntsc" if ntsc else "--pal", *[str(n) for n in FRAMES], model=True)
    acme("scene")

    def check(n):
        wait_done(30)
        bad = compare_fb(peek("372") << 16, open(os.path.join(OUT, f"scene_fb{n}.bin"), "rb").read(), "scene")
        if bad:
            shot = os.path.join(OUT, f"scene_bad{n}_{where}.png")
            m65("screenshot", "-p", shot)
            sys.exit(f"FAIL: frame {n}, {bad} of 64000 pixels differ from the host's; screenshot {shot}")

    m65("poke", "340", "00")
    m65("prg", "-r", os.path.join(OUT, "scene.prg"))
    check(0)                                     # (it holds after its first frame)
    shot = os.path.join(OUT, f"scene0_{where}.png")
    m65("screenshot", "-p", shot)
    for n in FRAMES[1:]:                         # then frame by frame
        m65("poke", "371", f"{n:02x}")
        m65("poke", "370", "01")
        m65("poke", "340", "00")
        check(n)
    print(f"PASS: frames {', '.join(str(n) for n in FRAMES)}: all 64000 pixels of each as the host draws them "
          f"from the model's results; {shot}")
    hz = cia_hz()
    m65("poke", "370", "00")                     # turning
    m65("poke", "340", "00")
    st = os.path.join(OUT, "scene_stats.bin")

    def sample():
        m65("save", "340", "364", st)
        b = open(st, "rb").read()
        return b[5] | b[6] << 8, cia_ticks(b[1:5]), b
    time.sleep(3)
    f1, t1, _ = sample()
    time.sleep(6)
    f2, t2, b = sample()
    fps = (f2 - f1) / ((t2 - t1) / hz)
    if on_xemu:
        print("(in Xemu, whose CPU, memory, DMA and CIA timing is measured against a MEGA65 R6: its build/tests/timing-m65)")
    print(f"turning: {f2 - f1} frames in {(t2 - t1) / hz:.2f} s, {fps:.1f} frames a second "
          f"({1000 / fps:.1f} ms a frame; {'NTSC' if ntsc else 'PAL'})")
    stamps = [cia_ticks(b[8 + 4 * k:12 + 4 * k]) for k in range(7)]
    steps = ["the MCP's matrices and light, both PRUNs issued", "the frame buffer cleared (DMA)",
             "waiting for the MCP", "the results scattered into the tables (DMA)",
             "the visible faces linked into buckets", "the triangles drawn"]
    print("frame 64, step by step:")
    for k, name in enumerate(steps):
        print(f"  {(stamps[k + 1] - stamps[k]) / hz * 1e3:6.2f} ms  {name}")
    print(f"  ({(stamps[6] - stamps[0]) / hz * 1e3:.2f} ms in all, then the wait for the bottom border)")
    shot = os.path.join(OUT, f"scene_{where}.png")
    m65("screenshot", "-p", shot)
    print(f"screenshot {shot}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = [a for a in sys.argv[1:] if a.startswith("--")]
    if not args or args[0] not in ("mandel", "scene") or set(opts) - {"--xemu"}:
        sys.exit(__doc__)
    bit = args[1] if len(args) > 1 else os.path.join(ROOT, "bin", "mega65r6.bit")
    try:
        (mandel if args[0] == "mandel" else scene)(bit, "--xemu" in opts)
    finally:
        xemu.stop_mine()


if __name__ == "__main__":
    main()
