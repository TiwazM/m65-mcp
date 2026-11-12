#!/bin/zsh
# Bit-exact check of src/vhdl/mcp.vhdl (MCP-1: the registers, the queue, the
# three issue paths, with the arithmetic core) against the model, through
# the fastio bus.
#
#   src/mcp/sim/run.sh [seed] [commands]      defaults: 1, 4000
#
# Needs src/mcp/sim/fetch.sh run once (the model is built on SoftFloat).
# Writes mcpgen's script and runs tb_mcp in nvc. Work files go to $MCP_WORK
# (default /tmp/mcp-sim). Exit status 0 = every read matched the model.
# MCP_FASTBUS=1: every access one clock (a byte every two, the DMA's best).
# MCP_STAGE=n: the model's stage (mcp_model.h; default 4: MCP-2 and MCP-3 stage 1, the vertex path).
# MCP_RTL=file, MCP_FPU_RTL=file: simulate another copy of mcp.vhdl or of
# its core mcp_fpu.vhdl (the mutants).
# (run_fpu.sh checks the arithmetic core alone, on TestFloat's cases.)
set -e
here=${0:A:h}
src=${here:h:h}
ext=$src/mcp/ext
work=${MCP_WORK:-/tmp/mcp-sim}
build=Linux-ARM-VFPv2-GCC
sf=$ext/berkeley-softfloat-3
[ -f $sf/build/$build/softfloat.a ] || { echo "run src/mcp/sim/fetch.sh first"; exit 1; }
mkdir -p $work/nvc
cc -std=gnu99 -O2 -Wall -I$sf/source/include -I$src/mcp/model -o $work/mcpgen \
   $src/mcp/model/mcpgen.c $src/mcp/model/mcp_model.c $sf/build/$build/softfloat.a
$work/mcpgen ${1:-1} ${2:-4000} ${MCP_STAGE:-4} > $work/script.txt
cd $work/nvc
nvc --std=2008 -a $src/vhdl/mcp_ram.vhdl ${MCP_FPU_RTL:-$src/vhdl/mcp_fpu.vhdl} ${MCP_RTL:-$src/vhdl/mcp.vhdl} $here/tb_mcp.vhdl
nvc --std=2008 -e tb_mcp -gSCRIPT=$work/script.txt -gFASTBUS=${MCP_FASTBUS:-0}
nvc --std=2008 -r tb_mcp --exit-severity=failure --ieee-warnings=off 2>&1 | tee $work/mcp.log
grep -q "PASS: MCP identical" $work/mcp.log
