#!/bin/bash
# Build U-Boot for the SM-T570 and package it as a RECOVERY image:
#   u-boot.bin (+ appended DTB) -> Android boot image v2 -> AVB footer
# U-Boot is built with CONFIG_EXYNOS9810_EARLY_SAFETY (any reset -> Download
# mode, ~82 s watchdog -> BOOT) and CONFIG_EXYNOS_MOBILE_RAMLOG (console log in
# RAM at 0x8ff100000, read it from the bring-up console with "ulog").
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
U=$P/src/u-boot-9820
O=$P/build/u-boot
OUT=$P/build/images
MK="make -C $U O=$O CROSS_COMPILE=aarch64-linux-gnu-"
mkdir -p "$OUT"

$MK -s gtactive3wifi_defconfig
nice -n 19 $MK -s -j4

printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$OUT/empty-ramdisk.gz"
# Header values copied from the stock T570XXSFEYI1 recovery/boot image
mkbootimg --header_version 2 \
	--kernel "$O/u-boot.bin" \
	--ramdisk "$OUT/empty-ramdisk.gz" \
	--dtb "$P/firmware/stock/boot-unpacked/dtb" \
	--base 0x10000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
	--tags_offset 0x00000100 --dtb_offset 0x00000000 --pagesize 2048 \
	--os_version 13.0.0 --os_patch_level 2025-10 --board SRPTF17A015 \
	--cmdline "" \
	-o "$OUT/recovery-uboot.img"
printf 'SEANDROIDENFORCE' >> "$OUT/recovery-uboot.img"
avbtool add_hash_footer --image "$OUT/recovery-uboot.img" \
	--partition_name recovery --partition_size 71106560 \
	--algorithm SHA256_RSA4096 --key "$P/firmware/keys/avb_rsa4096.pem" \
	--rollback_index 0

ls -l "$OUT/recovery-uboot.img"
