#!/bin/bash
# Rebuild kernel modules incrementally and push the given ones to the tablet
# (into /lib/modules on the running initramfs), without reflashing.
#   hot-modules.sh drivers/ufs/host/ufs-exynos drivers/phy/samsung/phy-exynos-ufs
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/build/bringup
nice -n 19 make -j4 -s -C "$P/src/linux" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$O" modules 2>&1 | grep -iE "error|warning: " || true
for m in "$@"; do
	f=$O/$m.ko
	aarch64-linux-gnu-strip --strip-debug -o "$P/build/initramfs/modules/$(basename "$m").ko" "$f"
	echo "$(basename "$m").ko: $("$P/scripts/tab-put" "$P/build/initramfs/modules/$(basename "$m").ko" "/lib/modules/$(basename "$m").ko")"
done
