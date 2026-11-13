"""xemu: a headless Xemu with the M65-MCP in it, for the runners that
otherwise need a MEGA65 (sdk/run.py, hwtest.sh, geo/geo.py, show/show.py,
vtime/vtime.py): no board, no bitstream.

    python3 -I src/mcp/demo/xemu.py start|stop|status

The Xemu is the mcp branch of TiwazM/xemu_ai_agent (Xemu's MEGA65 with the
MCP at $FFDF000, and the UART monitor commands m65rs uses), built with
make in its targets/mega65: $XEMU, or ~/Documents/GitHub/xemu-mcp's. It
runs without a window, its UART monitor on a socket m65rs connects to
(m65rs -l).

As a module (the runners): start() makes sure one runs, resets it to
BASIC's READY, puts the MCP back as a core just loaded has it (the
monitor's ~mcpinit: the tests start from cleared memories, as on the board,
where they load the bitstream) and returns m65rs's connection options; a
runner stops the Xemu it started itself (stop_mine) and leaves one that was
running already, so `xemu.py start` once keeps one for a row of runs.
"""
import os
import subprocess
import sys
import time

XEMU = os.environ.get("XEMU", os.path.expanduser("~/Documents/GitHub/xemu-mcp/build/bin/xmega65.native"))
SOCK = "/tmp/m65mcp-xemu.sock"      # (a socket's path must be short: 104 bytes with the name)
LINK = ["-l", SOCK]
M65RS = os.environ.get("M65RS", "/Applications/mega65studio/m65rs")
PIDFILE = "/tmp/m65mcp-xemu.pid"
mine = False                        # this process started it


def m65(*args):
    return subprocess.run([M65RS, *LINK, *args], check=True, capture_output=True, text=True).stdout


def answers():
    try:
        m65("info")
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def has_mcp():
    return m65("peek", "ffdf101").split("$")[-1].split()[0] == "4D"


def start(need_mcp=True, log=None):
    """m65rs's options for a Xemu at BASIC's READY (started if none answers)"""
    global mine
    if not answers():
        if not os.path.exists(XEMU):
            sys.exit(f"no Xemu at {XEMU}: build the mcp branch (make in targets/mega65) or set XEMU")
        if os.path.exists(SOCK):
            os.remove(SOCK)
        p = subprocess.Popen([XEMU, "-headless", "-besure", "-fastboot", "-uartmon", SOCK],
                             cwd="/tmp", stdout=open(log or "/tmp/m65mcp-xemu.log", "w"),
                             stderr=subprocess.STDOUT, start_new_session=True)
        open(PIDFILE, "w").write(str(p.pid))
        mine = True
        for _ in range(60):
            time.sleep(0.5)
            if answers():
                break
        else:
            sys.exit("Xemu did not answer")
    m65("reset")
    time.sleep(4)
    if has_mcp():
        m65("raw", "~mcpinit")      # the MCP as a core just loaded has it: its three memories cleared too
    elif need_mcp:
        stop_mine()
        sys.exit(f"the Xemu at {SOCK} has no M65-MCP (MID at $FFDF101 is not $4D): it needs the mcp branch's build")
    return list(LINK)


def stop():
    try:
        pid = int(open(PIDFILE).read())
        os.kill(pid, 15)
    except (OSError, ValueError):
        return False
    for f in (PIDFILE, SOCK):
        if os.path.exists(f):
            os.remove(f)
    return True


def stop_mine():
    if mine:
        stop()


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) == 2 else ""
    if what == "start":
        start()
        print(f"Xemu with the M65-MCP at {SOCK}: m65rs -l {SOCK} ...")
    elif what == "stop":
        print("stopped" if stop() else "none of this script's was running")
    elif what == "status":
        print(f"answers at {SOCK}, {'with' if has_mcp() else 'WITHOUT'} the M65-MCP" if answers() else "none answers")
    else:
        sys.exit(__doc__)
