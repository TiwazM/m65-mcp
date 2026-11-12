#!/bin/zsh
# Bit-exact check of src/vhdl/mcp_fpu.vhdl (the arithmetic core: since
# MCP-2 stage 3a, three units, the operations issued as fast as it takes
# them) against the model, on TestFloat's cases and random operands.
#
#   src/mcp/sim/run_fpu.sh [level] [random per op] [seed]
#                                          defaults: 1 (46,464 cases a function
#                                          and mode), 20000, 1
#
# Needs src/mcp/sim/fetch.sh run once. Builds mcpcheck and mcpvec, checks
# the model first (mcpcheck: TestFloat and the host), writes the vectors, and
# runs tb_mcp_fpu in nvc. Work files go to $MCP_WORK (default
# /tmp/mcp-sim). Exit status 0 = the core matches every vector.
# MCP_FPU_RTL=file: simulate another copy of the core (the mutants).
# MCP_FPU_QUICK=1: without TestFloat's f32_mulAdd cases (24.5 million at level
# 1; the random ones stay), for the mutants.
set -e
here=${0:A:h}
src=${here:h:h}
ext=$src/mcp/ext
work=${MCP_WORK:-/tmp/mcp-sim}
level=${1:-1}
nrand=${2:-20000}
seed=${3:-1}
build=Linux-ARM-VFPv2-GCC
gen=$ext/berkeley-testfloat-3/build/$build/testfloat_gen
sf=$ext/berkeley-softfloat-3
[ -x $gen ] || { echo "run src/mcp/sim/fetch.sh first"; exit 1; }
mkdir -p $work/nvc
cflags=(-std=gnu99 -O2 -frounding-math -Wall -I$sf/source/include -I$src/mcp/model)
cc $cflags -o $work/mcpcheck $src/mcp/model/mcpcheck.c $src/mcp/model/mcp_model.c $sf/build/$build/softfloat.a -lm
cc $cflags -o $work/mcpvec $src/mcp/model/mcpvec.c $src/mcp/model/mcp_model.c $sf/build/$build/softfloat.a
if [ -z "${MCP_FPU_RTL:-}" ]; then
    $work/mcpcheck $gen $level
fi
# the vectors go through a named pipe (level 2 would be ~12 GB as a file)
rm -f $work/vectors.fifo
mkfifo $work/vectors.fifo
cd $work/nvc
nvc --std=2008 -a ${MCP_FPU_RTL:-$src/vhdl/mcp_fpu.vhdl} $here/tb_mcp_fpu.vhdl
nvc --std=2008 -e tb_mcp_fpu -gVECTORS=$work/vectors.fifo
$work/mcpvec $gen $level $nrand $seed > $work/vectors.fifo &
nvc --std=2008 -r tb_mcp_fpu --exit-severity=failure --ieee-warnings=off 2>&1 | tee $work/fpu.log
wait
rm -f $work/vectors.fifo
grep -q "PASS: core identical" $work/fpu.log
