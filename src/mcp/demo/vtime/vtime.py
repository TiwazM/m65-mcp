"""vtime: MCP-2's commands timed on a MEGA65 R6 (vtime.asm): each as a
program of the command and PEND, 1,000 passes, timed by CIA 2. Prints the
clocks a command takes (40.5 MHz), the passes' own cost (PEND alone) taken
off.

    python3 -I src/mcp/demo/vtime/vtime.py [bitstream]

Loads the bitstream over JTAG (volatile; the flash is not touched), runs
vtime.prg and reads its timers back. The CIA's "1 MHz" from the video mode
the board is in, as the Mandelbrot bench (src/mcp/demo/mandel/bench.py).
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
OUT = os.path.join(HERE, "out")
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
STATS = 0x3000
PASSES = 1000
CLOCK = 40.5e6
TESTS = ["PEND alone", "FADD3", "FDIV", "VMOVE", "VADD", "VSCALE", "VDOT3", "VDOT4", "VCROSS",
         "VNORM3", "MLOAD", "MSTORE", "MXV", "MTXV", "MMUL"]


def run(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout


def m65(*args):
    return run(M65RS, *args)


def peek(addr):
    return int(m65("peek", addr).split("$")[-1].split()[0], 16)


def boot(bit):
    m65("jtag", "bit", bit)
    time.sleep(10)
    pc = m65("info").splitlines()[3][:4]
    if pc.startswith("56E"):                     # the ROM waiting for CIA 2 timer A
        m65("poke", "ffd3d04", "ff", "ff")
        m65("poke", "ffd3d0e", "11")
        time.sleep(6)


def main():
    bit = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "bin", "mega65r6.bit")
    os.makedirs(OUT, exist_ok=True)
    prg = os.path.join(OUT, "vtime.prg")
    run("acme", "-f", "cbm", "-I", os.path.join(HERE, "..", "..", "include"), "-o", prg,
        os.path.join(HERE, "vtime.asm"))
    boot(bit)
    ntsc = peek("ffd306f") & 0x80
    hz = 27e6 * 65 / 1716 if ntsc else 27e6 * 63 / 1728
    m65("poke", f"{STATS:x}", "00")
    m65("prg", "-r", prg)
    t0 = time.time()
    while peek(f"{STATS:x}") != 0xA5:
        if time.time() - t0 > 30:
            sys.exit("vtime: no result after 30 s")
        time.sleep(0.2)
    path = os.path.join(OUT, "stats.bin")
    m65("save", f"{STATS:x}", f"{STATS + 1 + 4 * len(TESTS):x}", path)
    st = open(path, "rb").read()
    clocks = []
    for i in range(len(TESTS)):
        a = st[1 + 4 * i] | st[2 + 4 * i] << 8
        b = st[3 + 4 * i] | st[4 + 4 * i] << 8
        secs = ((0xFFFF - b) * 65536 + (0xFFFF - a)) / hz
        clocks.append(secs * CLOCK / PASSES)
    base = clocks[0]
    print(f"{PASSES} passes each; a pass of PEND alone: {base:.1f} clocks "
          f"({'NTSC' if ntsc else 'PAL'}, CIA at {hz:.0f} Hz)\n")
    print("| command | clocks | µs |")
    print("|---|---|---|")
    for name, c in zip(TESTS[1:], clocks[1:]):
        print(f"| {name} | {c - base:.1f} | {(c - base) / CLOCK * 1e6:.2f} |")


if __name__ == "__main__":
    main()
