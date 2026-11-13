"""run: the M65-MCP's SDK examples on a MEGA65 R6, or in Xemu, each checked
against what it must print.

    python3 -I src/mcp/sdk/run.py [name ...] [--bit file] [--xemu] [--write] [--show]

Builds the examples named (default: all; ACME, and the Mandelbrot demo's
bas2prg.py for basic.bas) into out/, loads the bitstream over JTAG once
(volatile; the flash is not touched), then for each: LOAD and RUN, wait for
BASIC's READY, and compare the screen's text with expected/<name>.txt
(every line of it must be on the screen, in order).

--xemu: no board; a headless Xemu with the MCP in it (../demo/xemu.py).
--show prints each screen. --write takes the screen as the new expected
file: read it, and check its numbers, before keeping it. Needs m65rs
(MEGA65 Studio).
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(HERE, "out")
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
EXAMPLES = ["scalar", "vector", "matrix", "program", "async", "basic"]
link = []                                        # m65rs's connection options (Xemu: its socket)
sys.path.insert(0, os.path.join(HERE, "..", "demo"))
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


def build(name):
    prg = os.path.join(OUT, f"{name}.prg")
    if os.path.exists(os.path.join(HERE, f"{name}.bas")):
        run(sys.executable, "-I", os.path.join(HERE, "..", "demo", "mandel", "bas2prg.py"),
            os.path.join(HERE, f"{name}.bas"), prg)
    else:
        run("acme", "-f", "cbm", "-I", os.path.join(HERE, "..", "include"), "-I", HERE, "-o", prg,
            os.path.join(HERE, f"{name}.asm"))
    return prg


def screen():
    return [l.rstrip() for l in m65("screenshot", "--plain").splitlines()]


def lines_of(text):
    return [l.rstrip().upper() for l in text if l.strip()]


def example(name, prg, write, show):
    m65("prg", "-r", prg)
    t0 = time.time()
    while True:                                  # it has run when READY. is below something
        time.sleep(0.5)
        got = lines_of(screen())
        if "READY." in got[1:]:
            got = got[:len(got) - got[::-1].index("READY.") - 1]
            break
        if time.time() - t0 > 30:
            print("\n".join(got))
            sys.exit(f"{name}: no READY. after 30 s")
    if got and got[-1].startswith("RUN"):        # (a BASIC program's RUN stays on the screen)
        got = got[:-1]
    if show or write:
        print("\n".join("    " + l for l in got))
    path = os.path.join(HERE, "expected", f"{name}.txt")
    if write:
        open(path, "w").write("\n".join(got) + "\n")
        print(f"{name}: written to {path}")
        return True
    want, at, missing = lines_of(open(path)), 0, []
    for l in want:
        if l in got[at:]:
            at = got.index(l, at) + 1
        else:
            missing.append(l)
    if missing:
        print(f"FAIL {name}: not on the screen:")
        print("\n".join("    " + l for l in missing))
        if not show:
            print("  the screen:")
            print("\n".join("    " + l for l in got))
        return False
    print(f"PASS {name}: its {len(want)} lines as expected")
    return True


def main():
    args, bit = sys.argv[1:], os.path.join(ROOT, "bin", "mega65r6.bit")
    if "--bit" in args:
        bit = args[args.index("--bit") + 1]
        del args[args.index("--bit"):args.index("--bit") + 2]
    opts = [a for a in args if a.startswith("--")]
    names = [a for a in args if not a.startswith("--")] or EXAMPLES
    if set(opts) - {"--write", "--show", "--xemu"} or set(names) - set(EXAMPLES):
        sys.exit(__doc__)
    os.makedirs(OUT, exist_ok=True)
    prgs = [(n, build(n)) for n in names]
    if "--xemu" in opts:
        link[:] = xemu.start()
    else:
        boot(bit)
    try:
        ok = [example(n, p, "--write" in opts, "--show" in opts) for n, p in prgs]
    finally:
        xemu.stop_mine()
    sys.exit(0 if all(ok) else 1)


if __name__ == "__main__":
    main()
