#!/bin/sh
# Build out-of-tree test modules against the packaged Duranium kernel
# (same compiler and config as linux-postmarketos-exynos9810).
set -e
M="make -C /src O=/out ARCH=arm64 CROSS_COMPILE=aarch64-alpine-linux-musl- LOCALVERSION= -j${JOBS:-12}"
[ -f /out/scripts/module.lds ] || $M olddefconfig modules_prepare >/out/prepare.log 2>&1
for d in "$@"; do make -C /out ARCH=arm64 CROSS_COMPILE=aarch64-alpine-linux-musl- LOCALVERSION= KBUILD_MODPOST_WARN=1 M=/mod/$d modules 2>&1 | grep -vE "undefined!$|^make"; done
