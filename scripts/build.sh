#!/bin/bash
# Build the SM-T570 bring-up image: init (nolibc) + kernel + modules + DTB,
# packed by uniLoader into build/images/boot-mainline.img.
# Runs at low priority on 4 cores so the laptop stays cool.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
K=$P/src/linux
O=$P/build/bringup
MK="nice -n 19 make -j4 -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=$O"
MODS="drivers/phy/samsung/phy-exynos5-usbdrd drivers/usb/dwc3/dwc3 drivers/usb/dwc3/dwc3-exynos drivers/i2c/busses/i2c-exynos5 drivers/ufs/core/ufshcd-core drivers/ufs/host/ufshcd-pltfrm drivers/ufs/host/ufs-exynos drivers/phy/samsung/phy-exynos-ufs"

echo "== init"
aarch64-linux-gnu-gcc -Os -static -nostdlib -fno-stack-protector -fno-asynchronous-unwind-tables \
	-I"$P/initramfs/stub" -I"$K/tools/include/nolibc" -I"$P/build/hdr/usr/include" \
	-include "$K/tools/include/nolibc/nolibc.h" \
	-o "$P/build/initramfs/init" "$P/initramfs/init.c" -lgcc

echo "== config"
mkdir -p "$P/build"
sed "s|@P@|$P|g" "$P/configs/initramfs.list.in" > "$P/build/initramfs.list"
sed "s|@P@|$P|g" "$P/configs/gtactive3-bringup.config" > "$P/build/gtactive3-bringup.config"
cd "$K"
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$O" allnoconfig >/dev/null
KCONFIG_CONFIG=$O/.config scripts/kconfig/merge_config.sh -m -O "$O" "$O/.config" \
	"$P/build/gtactive3-bringup.config" >/dev/null
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$O" olddefconfig

echo "== kernel + modules"
mkdir -p "$P/build/initramfs/modules"
for m in $MODS; do f=$P/build/initramfs/modules/$(basename "$m").ko; [ -e "$f" ] || touch "$f"; done
$MK Image modules
for m in $MODS; do cp "$O/$m.ko" "$P/build/initramfs/modules/"; done
aarch64-linux-gnu-strip --strip-debug "$P"/build/initramfs/modules/*.ko
# relink so the initramfs carries the fresh modules
$MK Image exynos/exynos9810-gtactive3wifi.dtb

echo "== package"
"$P/scripts/mkboot.sh" | tail -1
