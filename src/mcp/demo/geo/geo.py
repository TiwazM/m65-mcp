"""geo: the M65-MCP's standard vertex program on a MEGA65 R6 (geo.asm):
528 vertices (a torus, and some behind the camera) transformed, lit,
clipped, projected and stored in the result buffer by one PRUN; every
result byte compared with the model's (geo.c), the PRUN timed by CIA 2.

    python3 -I src/mcp/demo/geo/geo.py [bitstream] [--unlit] [--sim] [--xemu]

--unlit: the program without the light (MCP-3 stage 2's), vertices
without normals. --sim: no board; the same writes and reads through the
fastio bus in nvc (src/mcp/sim/tb_mcp.vhdl), the PRUN timed in clocks.
--xemu: no board; geo.prg in a headless Xemu with the MCP in it
(../xemu.py).

Needs src/mcp/sim/fetch.sh run once (geo.c is built on the model and
SoftFloat). Loads the bitstream over JTAG (volatile; the flash is not
touched). The CIA's "1 MHz" from the video mode, as the Mandelbrot bench.
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
SF = os.path.join(SRC, "mcp", "ext", "berkeley-softfloat-3")
SFBUILD = "Linux-ARM-VFPv2-GCC"


link = []                                        # m65rs's connection options (Xemu: its socket)
sys.path.insert(0, os.path.join(HERE, ".."))
import xemu                                      # noqa: E402  (-I: the path is not searched by itself)


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


def build(unlit):
    os.makedirs(OUT, exist_ok=True)
    model = os.path.join(SRC, "mcp", "model")
    run("cc", "-std=gnu99", "-O2", "-I", os.path.join(SF, "source", "include"), "-I", model,
        "-o", os.path.join(OUT, "geo"), os.path.join(HERE, "geo.c"), os.path.join(model, "mcp_model.c"),
        os.path.join(SF, "build", SFBUILD, "softfloat.a"), "-lm")
    print(run(os.path.join(OUT, "geo"), *(["--unlit"] if unlit else []), OUT).strip())
    run("acme", "-f", "cbm", "-I", os.path.join(SRC, "mcp", "include"), "-I", OUT,
        "-o", os.path.join(OUT, "geo.prg"), os.path.join(HERE, "geo.asm"))
    # mcp.inc's standard program, byte for byte the one geo.c gave the model
    # (the simulation loads geo.c's; geo.prg carries mcp.inc's)
    t = os.path.join(OUT, "stdprog.asm")
    open(t, "w").write('!source "mcp.inc"\n!source "geo.inc"\n* = 0\n'
                       '!if LIT {\n+mcp_stdprog_lit LX, LY, LZ, KA\n} else {\n+mcp_stdprog\n}\n')
    run("acme", "-f", "plain", "-I", os.path.join(SRC, "mcp", "include"), "-I", OUT,
        "-o", os.path.join(OUT, "stdprog.bin"), t)
    if open(os.path.join(OUT, "stdprog.bin"), "rb").read() != open(os.path.join(OUT, "geo_prog.bin"), "rb").read():
        sys.exit("mcp.inc's standard program differs from geo.c's")


def simulate(exp):
    """geo.asm's writes and the window's reads as a tb_mcp script, in nvc:
    every read compared with the model's, the PRUN timed"""
    rd = lambda n: open(os.path.join(OUT, n), "rb").read()
    regs, vtx, prog = rd("geo_regs.bin"), rd("geo_vtx.bin"), rd("geo_prog.bin")
    inc = dict(l.split(" = ") for l in open(os.path.join(OUT, "geo.inc")).read().split("\n") if l)
    nvtx, vfmt, pexp = int(inc["NVTX"]), int(inc["VFMT"].strip("$"), 16), int(inc["VPOSEXP"])
    lines = []
    w = lambda a, v: lines.append(f"W {a:03X} {v & 255:02X}")
    w(0x107, 0)                                       # MRESET
    for x in range(64):                               # F0-F15 (FMOVE memory forms), MLOAD
        w(0x400 + x, regs[x])
    w(0x200 + 2 * 0x20, 0)
    w(0x201 + 2 * 0x20, 0)
    for x in range(16):                               # F12-F15
        w(0x430 + x, regs[64 + x])
    lines.append("I")
    w(0x004, 0)                                       # VINPTR, VINDATA
    w(0x005, 0)
    for v in vtx:
        w(0x000, v)
    w(0x12C, 0)                                       # MPLOADRST, MPPTR, MPLOAD
    w(0x10C, 0)
    w(0x10D, 0)
    for v in prog:
        w(0x128, v)
    for a, v in ((0x008, vfmt), (0x009, pexp), (0x006, 0), (0x007, 0), (0x00C, 0), (0x00D, 0)):
        w(a, v)
    lines.append("I")
    for k in range(4):                                # PRUN 0, nvtx passes (the fourth byte issues)
        w(0x780 + k, (nvtx << 16) >> (8 * k))
    lines += ["T", "I", "T"]
    lines += [f"R 10E {nvtx & 255:02X}", f"R 10F {nvtx >> 8:02X}", "R 110 00"]
    for i, v in enumerate(exp):
        if i % 2048 == 0:
            w(0x00E, i // 2048)                       # VBANK
        lines.append(f"R {0x800 + i % 2048:03X} {v:02X}")
    sim = os.path.join(OUT, "sim")
    os.makedirs(sim, exist_ok=True)
    script = os.path.join(sim, "script.txt")
    open(script, "w").write("\n".join(lines) + "\n")
    vhdl, tb = os.path.join(SRC, "vhdl"), os.path.join(SRC, "mcp", "sim", "tb_mcp.vhdl")
    nvc = lambda *a: subprocess.run(["nvc", "--std=2008", *a], cwd=sim, capture_output=True, text=True)
    for step in (("-a", os.path.join(vhdl, "mcp_ram.vhdl"), os.path.join(vhdl, "mcp_fpu.vhdl"),
                  os.path.join(vhdl, "mcp.vhdl"), tb),
                 ("-e", "tb_mcp", f"-gSCRIPT={script}", "-gFASTBUS=1")):
        r = nvc(*step)
        if r.returncode:
            sys.exit(r.stdout + r.stderr)
    r = nvc("-r", "tb_mcp", "--exit-severity=failure", "--ieee-warnings=off")
    out = r.stdout + r.stderr
    t = [int(l.split("T ")[-1]) for l in out.splitlines() if "Note" in l and ": T " in l]
    for l in out.splitlines():
        if "Error" in l or "PASS" in l or "FAIL" in l:
            print(l.split(": ", 1)[-1])
    if r.returncode or len(t) != 2 or "PASS" not in out:
        sys.exit("FAIL: the simulation")
    clocks = t[1] - t[0]
    print(f"PRUN to idle: {clocks} clocks, {clocks / nvtx:.1f} a vertex ({clocks / nvtx / CLOCK * 1e6:.2f} µs; "
          "the idle poll adds a few clocks once)")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = [a for a in sys.argv[1:] if a.startswith("--")]
    if set(opts) - {"--unlit", "--sim", "--xemu"}:
        sys.exit(__doc__)
    bit = args[0] if args else os.path.join(ROOT, "bin", "mega65r6.bit")
    build("--unlit" in opts)
    exp = open(os.path.join(OUT, "geo_exp.bin"), "rb").read()
    nvtx = len(exp) // 32
    if "--sim" in opts:
        simulate(exp)
        return
    if "--xemu" in opts:
        link[:] = xemu.start()
    else:
        boot(bit)
    try:
        ntsc = peek("ffd306f") & 0x80
        hz = 27e6 * 65 / 1716 if ntsc else 27e6 * 63 / 1728
        m65("poke", "340", "00")
        m65("prg", "-r", os.path.join(OUT, "geo.prg"))
        t0 = time.time()
        while peek("340") != 0xA5:
            if time.time() - t0 > 30:
                sys.exit("geo: no result after 30 s")
            time.sleep(0.2)
        stats, res = os.path.join(OUT, "stats.bin"), os.path.join(OUT, "results.bin")
        m65("save", "340", "348", stats)
        m65("save", "40000", f"{0x40000 + len(exp):x}", res)
    finally:
        xemu.stop_mine()
    st, got = open(stats, "rb").read(), open(res, "rb").read()
    ta, tb = st[1] | st[2] << 8, st[3] | st[4] << 8
    secs = ((0xFFFF - tb) * 65536 + (0xFFFF - ta)) / hz
    mpcnt, mperr = st[5] | st[6] << 8, st[7]
    bad = [i for i in range(len(exp)) if i >= len(got) or got[i] != exp[i]]
    print(f"PRUN: {mpcnt} passes, MPERR {mperr}; {secs * 1e3:.2f} ms, {secs * 1e6 / nvtx:.2f} µs "
          f"({secs * CLOCK / nvtx:.1f} clocks) a vertex ({'NTSC' if ntsc else 'PAL'}, CIA at {hz:.0f} Hz)")
    for i in bad[:10]:
        print(f"entry {i // 32} byte {i % 32}: ${got[i] if i < len(got) else 0:02X}, the model ${exp[i]:02X}")
    if bad or mpcnt != nvtx or mperr:
        sys.exit(f"FAIL: {len(bad)} of {len(exp)} result bytes differ")
    print(f"PASS: all {len(exp)} result bytes ({nvtx} entries) identical to the model's")


if __name__ == "__main__":
    main()
