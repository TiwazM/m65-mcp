#!/bin/zsh
# Runs on the Mac: builds the tools image once, then the R6 bitstream.
# NO_FLASHMENU=0 zsh m65build/run-build.sh for a core that goes into a flash
# slot (the default, 1, is for bitstreams loaded over JTAG).
here=${0:A:h}
vom=$HOME/Documents/vivado-on-mac
docker image inspect m65build >/dev/null 2>&1 || docker build --platform linux/amd64 -t m65build "$here" || exit 1
# Same MAC address as vivado-on-mac, so the node-locked licence matches.
docker run --init --rm --platform linux/amd64 --user user \
  --mac-address="$(tr -d '\n\r\t ' < $vom/scripts/mac_address)" \
  -v "$vom:/home/user" -v "${here:h}:/core" -e HOME=/home/user \
  -e VIVADO_VER="${VIVADO_VER:-}" -e NO_FLASHMENU="${NO_FLASHMENU:-}" m65build bash /core/m65build/build-r6.sh
