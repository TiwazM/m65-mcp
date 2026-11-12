#!/bin/zsh
# Fetches and builds the MCP's reference: Berkeley SoftFloat 3e and TestFloat
# 3e (John R. Hauser, BSD licence), pinned, into src/mcp/ext (not committed).
#
#   src/mcp/sim/fetch.sh
#
# SoftFloat is built with the ARM-VFPv2-defaultNaN specialisation (MCP1.md,
# "Verification"): every NaN result is the default NaN $7FC00000, a NaN
# converts to integer 0, out-of-range conversions saturate. Tininess after
# rounding is chosen at run time (softfloat_detectTininess, TestFloat's
# -tininessafter). Both are built in their build/Linux-ARM-VFPv2-GCC
# directories: portable C (builds on macOS, cc as gcc), and the only
# SoftFloat build that leaves out bf16, which the ARM specialisations lack.
set -e
here=${0:A:h}
ext=${here:h}/ext
SF_COMMIT=a0c6494cdc11865811dec815d5c0049fba9d82a8   # 2025-03-07
TF_COMMIT=a9c849f1b0eb0264b626d9686ffae167d996e3be   # 2025-03-07
SPEC=ARM-VFPv2-defaultNaN
BUILD=Linux-ARM-VFPv2-GCC
mkdir -p $ext
for pair in berkeley-softfloat-3:$SF_COMMIT berkeley-testfloat-3:$TF_COMMIT; do
    repo=${pair%%:*}; commit=${pair#*:}
    [ -d $ext/$repo ] || git clone -q https://github.com/ucb-bar/$repo.git $ext/$repo
    git -C $ext/$repo checkout -q $commit
done
make -s -C $ext/berkeley-softfloat-3/build/$BUILD SPECIALIZE_TYPE=$SPEC
make -s -C $ext/berkeley-testfloat-3/build/$BUILD SOFTFLOAT_DIR=$ext/berkeley-softfloat-3 PLATFORM=$BUILD
ls $ext/berkeley-softfloat-3/build/$BUILD/softfloat.a \
   $ext/berkeley-testfloat-3/build/$BUILD/{testfloat_gen,testfloat_ver,testsoftfloat}
