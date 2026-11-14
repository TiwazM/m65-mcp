#!/bin/bash
# Runs inside the container: /core = mega65-core, /home/user = vivado-on-mac.
# VIVADO_VER picks an installed version (default 2022.2, which has incremental
# compile in its free tier). The libudev preload was for 2026.1; with 2022.2 it
# crashes the licence manager (free() in libselinux during dlopen), so it is
# only applied to other versions.
set -e
VIVADO_VER=${VIVADO_VER:-2022.2}
VIVADODIR=$(ls -1d /home/user/Xilinx/${VIVADO_VER}/Vivado /home/user/Xilinx/Vivado/${VIVADO_VER} 2>/dev/null | head -1)
[ -n "$VIVADODIR" ] || { echo "ERROR: no Vivado $VIVADO_VER under /home/user/Xilinx"; exit 1; }
echo "Vivado: $VIVADODIR"
PRELOAD=""
[ "$VIVADO_VER" = "2022.2" ] || PRELOAD="LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1"
mkdir -p /tmp/vw
cat > /tmp/vw/vivado_wrapper <<W
#!/bin/bash
. $VIVADODIR/settings64.sh
$PRELOAD vivado "\$@"
W
chmod +x /tmp/vw/vivado_wrapper
cd /core
# NO_FLASHMENU=1 (default here): our bitstreams are JTAG-loaded test builds.
# Both make calls get it (the first one already assembles Hyppo), and Hyppo is
# reassembled every time (make does not see a changed flag).
NFM=${NO_FLASHMENU:-1}
rm -f bin/HICKUP.M65
# The version files (src/version.txt and the rest) depend only on .git/HEAD,
# which a commit on the same branch doesn't change: without this a folder
# that builds after each commit keeps the first build's version.
rm -f src/version.txt
# Generated files first, serially: their parallel build races (megaflash:
# both variants compile through megaflash.s, and they are rebuilt whenever
# the version changes). The version files before the rest, in a make of
# their own: made in the same one they come out after megaflash, which the
# parallel make below then builds again, both variants at once.
make DO_SMU=0 NO_FLASHMENU=$NFM src/version.txt
make DO_SMU=0 NO_FLASHMENU=$NFM preliminaries \
  src/utilities/megaflash/megaflash-attic.prg src/utilities/megaflash/megaflash-no-attic.prg
make DO_SMU=0 NO_FLASHMENU=$NFM VIVADO=/tmp/vw/vivado_wrapper -j8 bin/mega65r6.bit
# the first-boot instruction: $4C (jmp) = no flash menu, $2C (bit) = flash menu
addr=$(awk '/first_boot_flag_instruction/ {print $3}' src/hyppo/HICKUP.sym | tr -d '$')
echo "Hyppo first_boot_flag_instruction: $(od -An -tx1 -j $((0x$addr - 0x8000)) -N 1 bin/HICKUP.M65) (NO_FLASHMENU=$NFM)"
