#!/bin/bash
# Build the SM-T570 bring-up image: init (nolibc) + kernel + modules + DTB,
# packed by uniLoader into build/images/boot-mainline.img.
# Runs at low priority on 4 cores so the laptop stays cool.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
# kernel tree (default: the integration worktree) and optional extra config
# fragments applied after the bring-up config, e.g. configs/gtactive3-pm.config
K=${KSRC:-src/linux}
case $K in /*) ;; *) K=$P/$K ;; esac
EXTRA_CONFIGS=${EXTRA_CONFIGS:-}
O=$P/build/bringup
MK="flock $P/build/kbuild.lock nice -n 5 make -j12 -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=$O"
MODS="drivers/phy/samsung/phy-exynos5-usbdrd drivers/usb/dwc3/dwc3 drivers/usb/dwc3/dwc3-exynos drivers/i2c/busses/i2c-exynos5 drivers/ufs/core/ufshcd-core drivers/ufs/host/ufshcd-pltfrm drivers/ufs/host/ufs-exynos drivers/phy/samsung/phy-exynos-ufs drivers/soc/samsung/exynos-usi drivers/video/backlight/exynos9810-dsim-bl"

gen_list() {
	sed "s|@P@|$P|g" "$P/configs/initramfs.list.in" > "$P/build/initramfs.list"
	for f in "$P"/build/initramfs/modules/*.ko; do
		[ -e "$f" ] && echo "file /lib/modules/$(basename "$f") $f 0644 0 0"
	done >> "$P/build/initramfs.list"
	# vendor Wi-Fi/BT firmware (local only, never committed), if extracted
	fw=$P/firmware/extracted/linux-firmware/lib/firmware/brcm
	if [ -d "$fw" ]; then
		printf 'dir /lib/firmware 0755 0 0\ndir /lib/firmware/brcm 0755 0 0\n'
		for f in "$fw"/*; do echo "file /lib/firmware/brcm/$(basename "$f") $f 0644 0 0"; done
	fi >> "$P/build/initramfs.list"
	# optional local userspace overlay (e.g. iw, wpa_supplicant, busybox
	# from Alpine aarch64 packages for the Wi-Fi tests), never committed
	x=$P/build/initramfs-extra
	if [ -d "$x" ]; then
		(cd -P "$x" && find . -mindepth 1 | sort | while read -r e; do
			d=${e#.}
			if [ -L "$e" ]; then echo "slink $d $(readlink "$e") 0777 0 0"
			elif [ -d "$e" ]; then echo "dir $d 0755 0 0"
			else echo "file $d $(pwd -P)/${e#./} $(stat -c %a "$e") 0 0"; fi
		done)
	fi >> "$P/build/initramfs.list"
}

echo "== init"
aarch64-linux-gnu-gcc -Os -static -nostdlib -fno-stack-protector -fno-asynchronous-unwind-tables \
	-I"$P/initramfs/stub" -I"$K/tools/include/nolibc" -I"$P/build/hdr/usr/include" \
	-include "$K/tools/include/nolibc/nolibc.h" \
	-o "$P/build/initramfs/init" "$P/initramfs/init.c" -lgcc

echo "== config"
mkdir -p "$P/build"
gen_list
sed "s|@P@|$P|g" "$P/configs/gtactive3-bringup.config" > "$P/build/gtactive3-bringup.config"
cd "$K"
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$O" allnoconfig >/dev/null
extra=
for f in $EXTRA_CONFIGS; do
	case $f in /*) ;; *) f=$P/$f ;; esac
	extra="$extra $f"
done
# shellcheck disable=SC2086 # $extra is a list of paths
KCONFIG_CONFIG=$O/.config scripts/kconfig/merge_config.sh -m -O "$O" "$O/.config" \
	"$P/build/gtactive3-bringup.config" $extra >/dev/null
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O="$O" olddefconfig

echo "== kernel + modules"
mkdir -p "$P/build/initramfs/modules"
# every module the config builds goes into /lib/modules (flat), listed in the
# generated initramfs list; placeholders first so the list resolves on the
# first link, then the real files and a relink
for m in $MODS; do f=$P/build/initramfs/modules/$(basename "$m").ko; [ -e "$f" ] || touch "$f"; done
$MK Image modules
rm -f "$P"/build/initramfs/modules/*.ko
find "$O" -name '*.ko' -exec cp {} "$P/build/initramfs/modules/" \;
aarch64-linux-gnu-strip --strip-debug "$P"/build/initramfs/modules/*.ko
gen_list
# relink so the initramfs carries the fresh modules
$MK Image exynos/exynos9810-gtactive3wifi.dtb

echo "== package"
"$P/scripts/mkboot.sh" | tail -1
