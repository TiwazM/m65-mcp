"""calibrate: the rate of CIA 2's cascaded timers (A counts the 1 MHz phase,
B counts A's underflows: a 32-bit down counter), measured against the
host's clock over a few seconds through m65rs.

    python3 -I calibrate.py [seconds]

The CIA's "1 MHz" follows the video mode (63 or 65 cycles a raster line),
so the timings convert with this, not with 1 MHz.
"""
import subprocess
import sys
import time

M65RS = "/Applications/mega65studio/m65rs"


def m65(*args):
    return subprocess.run([M65RS, *args], capture_output=True, text=True, check=True).stdout


def peek(addr):
    out = m65("peek", addr)
    return int(out.split("$")[-1].split()[0], 16)


secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
print(f"PALNTSC $D06F = ${peek('ffd306f'):02X} (bit 7: NTSC)")
m65("poke", "ffd3d0d", "7f")                     # no CIA 2 interrupts
m65("poke", "ffd3d0e", "00")
m65("poke", "ffd3d0f", "00")
m65("poke", "ffd3d04", "ff", "ff", "ff", "ff")   # both latches $FFFF
m65("poke", "ffd3d0f", "51")                     # B: load, count A's underflows, run
t0 = time.time()
m65("poke", "ffd3d0e", "11")                     # A: load, count the 1 MHz phase, run
t1 = time.time()
time.sleep(secs)
t2 = time.time()
m65("poke", "ffd3d0e", "00")                     # A stopped (B with it)
t3 = time.time()
b = [peek(f"ffd3d0{k}") for k in (4, 5, 6, 7)]
ta, tb = b[0] | b[1] << 8, b[2] | b[3] << 8
ticks = (0xFFFF - tb) * 65536 + (0xFFFF - ta)
lo, hi = t2 - t1, t3 - t0
print(f"{ticks} ticks in {lo:.3f}-{hi:.3f} s: {ticks / hi:.0f}-{ticks / lo:.0f} Hz")
