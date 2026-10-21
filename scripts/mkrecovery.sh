#!/bin/bash
# Package the mainline bring-up kernel into a RECOVERY image for the SM-T570:
#   Linux Image + DTB + ramdisk -> uniLoader -> Android boot image v2 -> AVB footer
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
B=$P/build/bringup
U=$P/src/uniLoader
OUT=$P/build/images
mkdir -p "$OUT"

# Ramdisk for uniLoader (same contents as the built-in initramfs)
"$B/usr/gen_init_cpio" "$P/configs/initramfs.list" | gzip -9 > "$OUT/ramdisk.cpio.gz"

cp "$B/arch/arm64/boot/Image" "$U/blob/Image"
cp "$B/arch/arm64/boot/dts/exynos/exynos9810-gtactive3wifi.dtb" "$U/blob/dtb"
cp "$OUT/ramdisk.cpio.gz" "$U/blob/ramdisk"

make -s -C "$U" ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu- gtactive3wifi_defconfig
nice make -s -C "$U" -j4 ARCH=aarch64 CROSS_COMPILE=aarch64-linux-gnu-

# Header values copied from the stock T570XXSFEYI1 recovery/boot image
mkbootimg --header_version 2 \
	--kernel "$U/uniLoader" \
	--ramdisk "$OUT/ramdisk.cpio.gz" \
	--dtb "$P/firmware/stock/boot-unpacked/dtb" \
	--base 0x10000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
	--tags_offset 0x00000100 --dtb_offset 0x00000000 --pagesize 2048 \
	--os_version 13.0.0 --os_patch_level 2025-10 --board SRPTF17A015 \
	--cmdline "" \
	-o "$OUT/recovery-mainline.img"
printf 'SEANDROIDENFORCE' >> "$OUT/recovery-mainline.img"

# RECOVERY is a chained partition in the stock vbmeta, so give it an AVB footer.
# Our key does not match Samsung's; an unlocked bootloader is expected to warn and
# continue, as it did for the modified BOOT image.
avbtool add_hash_footer --image "$OUT/recovery-mainline.img" \
	--partition_name recovery --partition_size 71106560 \
	--algorithm SHA256_RSA4096 --key "$P/firmware/keys/avb_rsa4096.pem" \
	--rollback_index 0

ls -l "$OUT/recovery-mainline.img"
