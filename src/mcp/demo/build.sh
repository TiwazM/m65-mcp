#!/bin/zsh
# Builds the M65-MCP's board test: an mcpgen script (the bench's kind) as
# records for mcptest.prg, and the values its reads must return.
#   src/mcp/demo/build.sh [outdir] [seed] [commands]      defaults: out, 1, 3000
# MCP_STAGE=n: the model's stage (mcp_model.h; default 4), as the bench's.
# Needs src/mcp/sim/fetch.sh run once (the model is built on SoftFloat).
set -e
here=${0:A:h}
src=${here:h:h}
out=${1:-$here/out}
sf=$src/mcp/ext/berkeley-softfloat-3
build=Linux-ARM-VFPv2-GCC
[ -f $sf/build/$build/softfloat.a ] || { echo "run src/mcp/sim/fetch.sh first"; exit 1; }
mkdir -p $out
cc -std=gnu99 -O2 -Wall -I$sf/source/include -I$src/mcp/model -o $out/mcpgen \
   $src/mcp/model/mcpgen.c $src/mcp/model/mcp_model.c $sf/build/$build/softfloat.a
$out/mcpgen ${2:-1} ${3:-3000} ${MCP_STAGE:-4} > $out/script.txt
# records: type (1 W, 2 R, 3 I), offset low, high, value; the overrun test
# (O, the bench's: 40 divides at the DMA's rate) is left out
python3 -I - $out <<'PY'
import sys
d = sys.argv[1]
rec, exp = bytearray(), bytearray()
for line in open(f"{d}/script.txt"):
    f = line.split()
    if not f:
        continue
    if f[0] in ("W", "R"):
        a, v = int(f[1], 16), int(f[2], 16)
        rec += bytes((1 if f[0] == "W" else 2, a & 255, a >> 8, v if f[0] == "W" else 0))
        if f[0] == "R":
            exp.append(v)
    elif f[0] == "I":
        rec += bytes((3, 0, 0, 0))
n = len(rec) // 4
assert n <= 65535, f"{n} records: at most 65535 (fewer commands)"
assert len(exp) <= 0xA000, f"{len(exp)} reads: they would run past chip RAM $49FFF"
open(f"{d}/records.bin", "wb").write(rec)
open(f"{d}/expected.bin", "wb").write(exp)
open(f"{d}/regs.txt", "w").write(f"nrec {n}\nnread {len(exp)}\n")
PY
nrec=$(awk '/^nrec/{print $2}' $out/regs.txt)
acme -f cbm -DNREC=$nrec -o $out/mcptest.prg $here/mcptest.asm
echo "mcptest.prg: $nrec records ($(awk '/^nread/{print $2}' $out/regs.txt) reads) from attic RAM \$8100000"
