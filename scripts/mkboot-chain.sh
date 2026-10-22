#!/bin/bash
# Package the safe EFI boot chain into a BOOT image for the SM-T570:
#   S-Boot -> uniLoader (BOOT) -> U-Boot -> EFI -> systemd-boot -> Duranium UKI
# uniLoader carries U-Boot (primary) and the bring-up Linux (Image + DTB +
# ramdisk, as scripts/mkboot.sh packs it) as the fallback. It boots the
# fallback after a cluster 0 watchdog reset (RST_STAT bit 24) or with Volume
# Down held; otherwise it sets the Download-mode reboot reason, arms the
# watchdog (~82 s), checks that it counts, and starts U-Boot.
# Packing as in scripts/mkboot.sh: Android boot image v2 -> SEANDROIDENFORCE
# -> AVB hash footer.
#
#   MODE=chain     (default) build/images/boot-chain.img
#   MODE=linux     build/images/boot-chain-linux.img: always the fallback Linux
#   MODE=wdt-test  build/images/boot-chain-wdt-test.img: arm the watchdog and
#                  wait for its reset (the next boot is the fallback Linux);
#                  if no reset comes, boot the fallback Linux at once
#
# Environment: UL (uniLoader tree with gtactive3wifi_chain_defconfig),
# UB (U-Boot tree), UBO (U-Boot build dir), UBOOT (prebuilt u-boot.bin: skips
# the U-Boot build), INITRAMFS_LIST (gen_init_cpio list for the fallback
# Linux's ramdisk, default build/initramfs.list from scripts/build.sh).
# Never writes boot-mainline.img (what devd.sh flashes).
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
B=$P/build/bringup
OUT=$P/build/images
LOCK=$P/build/kbuild.lock
MODE=${MODE:-chain}

# The chain branches live in the worktrees until they are merged
pick() {
	if [ -e "$1/$3" ]; then echo "$1"; else echo "$2"; fi
}
UL=${UL:-$(pick "$P/src/uniLoader" "$P/build/wt/uniloader" configs/gtactive3wifi_chain_defconfig)}
UB=${UB:-$(pick "$P/src/u-boot-9820" "$P/build/wt/u-boot" drivers/watchdog/exynos_wdt.c)}
UBO=${UBO:-$P/build/wt/u-boot-out}
LIST=${INITRAMFS_LIST:-$P/build/initramfs.list}

case $MODE in
	chain) DEF=0; IMG=$OUT/boot-chain.img ;;
	linux) DEF=1; IMG=$OUT/boot-chain-linux.img ;;
	wdt-test) DEF=2; IMG=$OUT/boot-chain-wdt-test.img ;;
	*) echo "mkboot-chain: MODE must be chain, linux or wdt-test" >&2; exit 1 ;;
esac

[ -e "$UL/configs/gtactive3wifi_chain_defconfig" ] || {
	echo "mkboot-chain: $UL has no gtactive3wifi_chain_defconfig" >&2; exit 1; }

if [ -z "${UBOOT:-}" ]; then
	MKU="make -C $UB O=$UBO CROSS_COMPILE=aarch64-linux-gnu-"
	flock "$LOCK" sh -c "$MKU -s gtactive3wifi_defconfig && nice -n 19 $MKU -s -j6"
	UBOOT=$UBO/u-boot.bin
fi

for f in "$B/arch/arm64/boot/Image" \
	 "$B/arch/arm64/boot/dts/exynos/exynos9810-gtactive3wifi.dtb" \
	 "$B/usr/gen_init_cpio" "$LIST" "$UBOOT" \
	 "$P/firmware/stock/boot-unpacked/dtb" "$P/firmware/keys/avb_rsa4096.pem"; do
	[ -e "$f" ] || { echo "mkboot-chain: missing $f" >&2; exit 1; }
done

# U-Boot must be an arm64 Image ("ARM\x64" at 0x38): uniLoader checks it too
if [ "$(dd if="$UBOOT" bs=1 skip=56 count=4 2>/dev/null)" != "$(printf 'ARM\x64')" ]; then
	echo "mkboot-chain: $UBOOT has no arm64 Image header" >&2
	exit 1
fi

mkdir -p "$OUT"

# Ramdisk for the fallback Linux (same contents as the built-in initramfs)
"$B/usr/gen_init_cpio" "$LIST" | gzip -9 > "$OUT/ramdisk-chain.cpio.gz"

cp "$B/arch/arm64/boot/Image" "$UL/blob/Image"
cp "$B/arch/arm64/boot/dts/exynos/exynos9810-gtactive3wifi.dtb" "$UL/blob/dtb"
cp "$OUT/ramdisk-chain.cpio.gz" "$UL/blob/ramdisk"
cp "$UBOOT" "$UL/blob/u-boot.bin"

MK="make -s -C $UL ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-"
flock "$LOCK" sh -c "
	$MK gtactive3wifi_chain_defconfig &&
	sed -i 's/^CONFIG_CHAINLOAD_DEFAULT=.*/CONFIG_CHAINLOAD_DEFAULT=$DEF/' $UL/.config &&
	nice -n 19 $MK -j6"
grep -q "^#define CONFIG_CHAINLOAD_DEFAULT $DEF\$" "$UL/include/generated/autoconf.h" || {
	echo "mkboot-chain: CONFIG_CHAINLOAD_DEFAULT did not stick" >&2; exit 1; }

# Header values copied from the stock T570XXSFEYI1 recovery/boot image
mkbootimg --header_version 2 \
	--kernel "$UL/uniLoader" \
	--ramdisk "$OUT/ramdisk-chain.cpio.gz" \
	--dtb "$P/firmware/stock/boot-unpacked/dtb" \
	--base 0x10000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
	--tags_offset 0x00000100 --dtb_offset 0x00000000 --pagesize 2048 \
	--os_version 13.0.0 --os_patch_level 2025-10 --board SRPTF17A015 \
	--cmdline "" \
	-o "$IMG"
printf 'SEANDROIDENFORCE' >> "$IMG"

# BOOT is hash-checked by the stock vbmeta; the unlocked bootloader warns and
# continues on a mismatch. Keep an AVB footer so the image looks like a boot image.
avbtool add_hash_footer --image "$IMG" \
	--partition_name boot --partition_size 61865984 \
	--algorithm SHA256_RSA4096 --key "$P/firmware/keys/avb_rsa4096.pem" \
	--rollback_index 0

ls -l "$IMG"
sha256sum "$IMG"
