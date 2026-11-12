#!/bin/zsh
# Runs on the Mac, after run-build.sh: the last R6 build's utilization by
# hierarchy (Vivado in the same container), the MCP's rows picked out. The
# whole report goes to mega65r6.util-hier.txt.
here=${0:A:h}
vom=$HOME/Documents/vivado-on-mac
[ -f ${here:h}/vivado/mega65r6.runs/impl_1/container_routed.dcp ] || { echo "no routed design: run run-build.sh first"; exit 1; }
rm -f ${here:h}/mega65r6.util-hier.txt
docker run --init --rm --platform linux/amd64 --user user \
  --mac-address="$(tr -d '\n\r\t ' < $vom/scripts/mac_address)" \
  -v "$vom:/home/user" -v "${here:h}:/core" -e HOME=/home/user \
  -e VIVADO_VER="${VIVADO_VER:-}" m65build bash -c '
set -e
VIVADO_VER=${VIVADO_VER:-2022.2}
VIVADODIR=$(ls -1d /home/user/Xilinx/${VIVADO_VER}/Vivado /home/user/Xilinx/Vivado/${VIVADO_VER} 2>/dev/null | head -1)
. $VIVADODIR/settings64.sh
cd /tmp
cat > /tmp/util.tcl <<T
open_checkpoint /core/vivado/mega65r6.runs/impl_1/container_routed.dcp
report_utilization -hierarchical -hierarchical_depth 12 -file /core/mega65r6.util-hier.txt
report_utilization -file /core/mega65r6.util.txt
T
vivado -mode batch -nojournal -nolog -source /tmp/util.tcl
' > /dev/null || { echo "vivado failed"; exit 1; }
f=${here:h}/mega65r6.util-hier.txt
[ -f $f ] || { echo "no report written"; exit 1; }
# the header, the whole design, the MCP and its parts
grep -m1 -E "^\| *Instance" $f
grep -m1 -E "^\| container " $f
grep -E "mcp_unit|  core |  progmem " $f
