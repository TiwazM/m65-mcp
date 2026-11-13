#!/bin/zsh
# MCP-1 on a real MEGA65 R6, unattended, over the USB JTAG/serial link:
# loads the bitstream (volatile), puts build.sh's records into attic RAM,
# pushes mcptest.prg through the serial monitor and starts it, then reads
# back every value its reads returned (chip RAM $40000) and compares them
# with the model's.
#
#   src/mcp/demo/hwtest.sh [bitstream] [test dir]
#   defaults: bin/mega65r6.bit, the dir build.sh used (src/mcp/demo/out)
#   bitstream "xemu": no board; a headless Xemu with the MCP in it (xemu.py)
#   bitstream "-": do not load one, use the core that is running. It must
#   be at BASIC's READY: mcptest and the demos (geo, vtime, mandel) end in
#   a loop with interrupts off, so after one of them load the core again.
#   Bitstreams from m65build (NO_FLASHMENU=1) boot straight to BASIC; with a
#   stock flash menu, hold NO SCROLL while the core loads, release it when
#   the slot list shows, press ESC.
#   M65RS=path/to/m65rs if it is not /Applications/mega65studio's
set -e
here=${0:A:h}
root=${here:h:h:h}
bit=${1:-$root/bin/mega65r6.bit}
dir=${2:-$here/out}
m65rs=${M65RS:-"/Applications/mega65studio/m65rs"}
[ -x "$m65rs" ] || { echo "m65rs not found (install MEGA65 Studio in /Applications or set M65RS)"; exit 1; }
[ -f $dir/mcptest.prg ] || { echo "no $dir/mcptest.prg: run build.sh first"; exit 1; }
link=()                                   # m65rs's connection options (Xemu: its socket)
m65() { "$m65rs" $link "$@"; }
peek() { m65 peek $1 | grep -oE '= \$[0-9A-F]+' | tr -d '= $'; }
xemu_mine=0
on_xemu=0
if [ "$bit" = "xemu" ]; then
    on_xemu=1
    python3 -I $here/xemu.py status | grep -q "^answers" || xemu_mine=1
    python3 -I $here/xemu.py start
    link=(-l /tmp/m65mcp-xemu.sock)
    bit="-"
    trap '[ $xemu_mine = 1 ] && python3 -I $here/xemu.py stop >/dev/null' EXIT
fi

# A JTAG load now and then does not take (the transfer seems to fail without
# m65rs noticing, and the board configures itself from its flash): the
# MCP's MID tells, and the load is tried again, three times in all.
tries=0
while true; do
    if [ "$bit" != "-" ]; then
        echo "== loading $bit"
        m65 jtag bit $bit
        sleep 10                          # HYPPO boots, the ROM comes up
    fi
    m65 info | head -8
    pc=$(m65 info | sed -n 4p | cut -c1-4)
    if [[ "$pc" == 56E? ]]; then
        echo "the ROM waits for CIA 2 timer A (PC \$$pc): starting it"
        m65 poke ffd3d04 ff ff
        m65 poke ffd3d0e 11
        sleep 6
    fi
    id=$(peek ffdf101)
    [ "$id" = "4D" ] && break
    tries=$((tries + 1))
    echo "no MCP at \$FFDF100 (MID \$$id), running: $(m65 info | grep '^core:')"
    if [ "$bit" = "-" ] || [ $tries -ge 3 ]; then
        echo "not an M65-MCP core"
        exit 1
    fi
    echo "the load did not take: loading again"
done

echo "== records -> attic RAM \$8100000, then mcptest"
d7fe=$(peek ffd37fe)
m65 poke ffd37fe $(printf "%02x" $(( 0x$d7fe & 0xEF )))   # attic RAM = HyperRAM
if [ $on_xemu = 1 ]; then                 # (the monitor's own load is 16 bytes a frame there)
    m65 raw "~load 8100000 ${dir:A}/records.bin"
else
    m65 load $dir/records.bin@8100000
fi
m65 poke 340 00
m65 prg -r $dir/mcptest.prg
for i in {1..60}; do
    sleep 1
    done=$(peek 340)
    [ "$done" = "A5" ] && break
done
[ "$done" = "A5" ] || { echo "FAIL: mcptest did not finish (\$0340 = \$$done)"; m65 dump 340 8; exit 1; }
nread=$(awk '/^nread/{print $2}' $dir/regs.txt)
m65 save 40000 $(printf "%x" $(( 0x40000 + nread ))) $dir/hw_reads.bin
m65 save 340 343 $dir/hw_stats.bin

python3 -I - $dir <<'PY'
import sys
d = sys.argv[1]
hw, exp = open(f"{d}/hw_reads.bin", "rb").read(), open(f"{d}/expected.bin", "rb").read()
st = open(f"{d}/hw_stats.bin", "rb").read()
print(f"MID ${st[1]:02X}, MVER ${st[2]:02X}")
# the read addresses, for the report
addrs = [int(l.split()[1], 16) for l in open(f"{d}/script.txt") if l.startswith("R ")]
bad = [i for i in range(len(exp)) if i >= len(hw) or hw[i] != exp[i]]
for i in bad[:10]:
    print(f"read {i} ($FFDF{addrs[i]:03X}): ${hw[i] if i < len(hw) else 0:02X}, the model ${exp[i]:02X}")
print(("PASS: " if not bad else "FAIL: ") + f"{len(exp) - len(bad)} of {len(exp)} reads identical to the model's")
sys.exit(1 if bad else 0)
PY
