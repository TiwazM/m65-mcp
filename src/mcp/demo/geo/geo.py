"""geo: the M65-MCP's standard vertex program on a MEGA65 R6 (geo.asm):
528 vertices (a torus, and some behind the camera) transformed, clipped,
projected and stored in the result buffer by one PRUN; every result byte
compared with the model's (geo.c), the PRUN timed by CIA 2.

    python3 -I src/mcp/demo/geo/geo.py [bitstream]

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


def run(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout


def m65(*args):
    return run(M65RS, *args)


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


def build():
    os.makedirs(OUT, exist_ok=True)
    model = os.path.join(SRC, "mcp", "model")
    run("cc", "-std=gnu99", "-O2", "-I", os.path.join(SF, "source", "include"), "-I", model,
        "-o", os.path.join(OUT, "geo"), os.path.join(HERE, "geo.c"), os.path.join(model, "mcp_model.c"),
        os.path.join(SF, "build", SFBUILD, "softfloat.a"), "-lm")
    print(run(os.path.join(OUT, "geo"), OUT).strip())
    run("acme", "-f", "cbm", "-I", os.path.join(SRC, "mcp", "include"), "-I", OUT,
        "-o", os.path.join(OUT, "geo.prg"), os.path.join(HERE, "geo.asm"))


def main():
    bit = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "bin", "mega65r6.bit")
    build()
    exp = open(os.path.join(OUT, "geo_exp.bin"), "rb").read()
    nvtx = len(exp) // 32
    boot(bit)
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
