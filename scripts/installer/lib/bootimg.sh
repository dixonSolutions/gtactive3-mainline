# shellcheck shell=bash
# Build the BOOT images for this tablet, on this PC:
#   uniLoader (from the boot-chain payload, ours, GPL)
#   + your stock DTB and header values (from your stock boot.img, Samsung's)
#   -> Android boot image v2 -> SEANDROIDENFORCE -> AVB hash footer
# exactly as scripts/mkboot-chain.sh packs it for the development tablet.
#
#   boot-linux.img  uniLoader always starts our Linux (the live environment)
#   boot-chain.img  uniLoader -> U-Boot -> systemd-boot -> Duranium; our Linux
#                   is the fallback after a failed boot
#
# AVB footer: BOOT is hash-checked by the stock vbmeta; with the bootloader
# unlocked S-Boot warns and continues on a mismatch, so the signing key does
# not matter (it is not Samsung's anyway). The footer only makes the image
# look like a boot image. A key is made locally, once, and never leaves
# this PC.
#
# mkbootimg.py and avbtool.py (AOSP, Apache-2.0) are fetched at a pinned
# release and checked by hash; GTA3_MKBOOTIMG / GTA3_AVBTOOL override them.

AOSP_TAG=android-15.0.0_r1
AOSP_GS=https://android.googlesource.com/platform
# path in AOSP | local name | sha256
AOSP_FILES="system/tools/mkbootimg/+/refs/tags/$AOSP_TAG/mkbootimg.py|mkbootimg.py|37d84b3d162e0bc62e36c1f4e1c63c85ea0caa9f29be023eb2f8efe006ad948c
system/tools/mkbootimg/+/refs/tags/$AOSP_TAG/gki/generate_gki_certificate.py|gki/generate_gki_certificate.py|6ee0b2e3c3323ae8fccf326bf9a526451eac977005efabf7d129b3063bcfb945
external/avb/+/refs/tags/$AOSP_TAG/avbtool.py|avbtool.py|78a50c8620985709f2e131cf948dcd66ecc43f09ed735e09d75751a7e21e4eb8"
BOOT_PART_BYTES=61865984   # BOOT: 15104 blocks of 4 KiB (PIT)

aosp_tools() {
	local d=$CACHE_DIR/tools/aosp-$AOSP_TAG src name sum t
	MKBOOTIMG=${GTA3_MKBOOTIMG:-} AVBTOOL=${GTA3_AVBTOOL:-}
	if [ -n "$MKBOOTIMG" ] && [ -n "$AVBTOOL" ]; then
		return 0
	fi
	while IFS='|' read -r src name sum; do
		if [ ! -f "$d/$name" ] || [ "$(sha256sum "$d/$name" | cut -c1-64)" != "$sum" ]; then
			mkdir -p "$(dirname "$d/$name")"
			t=$(mktemp)
			fetch "$AOSP_GS/$src?format=TEXT" "$t" || { rm -f "$t"; die "cannot download $name from AOSP"; }
			base64 -d < "$t" > "$d/$name.part" || die "bad download: $name"
			rm -f "$t"
			[ "$(sha256sum "$d/$name.part" | cut -c1-64)" = "$sum" ] ||
				die "$name from AOSP does not have the expected hash"
			mv -f "$d/$name.part" "$d/$name"
		fi
	done <<< "$AOSP_FILES"
	# not -I: mkbootimg.py imports gki/ from its own (hash-checked) directory
	MKBOOTIMG=${MKBOOTIMG:-python3 -E -s $d/mkbootimg.py}
	AVBTOOL=${AVBTOOL:-python3 -E -s $d/avbtool.py}
}

avb_key() {
	local k=$STATE_DIR/keys/avb-local.pem
	if [ ! -s "$k" ]; then
		mkdir -p "$(dirname "$k")"
		( umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$k.part" 2>>"$LOG_FILE" ) ||
			die "openssl could not make the AVB key"
		mv -f "$k.part" "$k"
	fi
	printf '%s' "$k"
}

# pack_boot MODE OUT: MODE linux|chain
pack_boot() {
	local mode=$1 out=$2 stock ul
	stock=$(state_get STOCK_BOOT)
	[ -s "$stock" ] || die "no stock boot image"
	ul=$PAYLOAD/uniLoader-$mode
	[ -s "$ul" ] || die "no $ul in the payload"
	[ "$(stat -c %s "$stock")" = "$BOOT_PART_BYTES" ] ||
		warn "the stock boot image is $(stat -c %s "$stock") bytes, BOOT is $BOOT_PART_BYTES"
	aosp_tools
	local w BI_BASE BI_KERNEL_OFFSET BI_RAMDISK_OFFSET BI_TAGS_OFFSET BI_DTB_OFFSET \
		BI_PAGE_SIZE BI_OS_VERSION BI_OS_PATCH_LEVEL BI_BOARD BI_HEADER_VERSION
	eval "$(PY_BOOTIMG info "$stock" | grep -E '^BI_(BASE|KERNEL_OFFSET|RAMDISK_OFFSET|TAGS_OFFSET|DTB_OFFSET|PAGE_SIZE|OS_VERSION|OS_PATCH_LEVEL|BOARD|HEADER_VERSION)=')"
	[ "$BI_HEADER_VERSION" = 2 ] || die "the stock boot image has header v$BI_HEADER_VERSION (expected 2)"
	w=$(mktemp -d)
	PY_BOOTIMG extract "$stock" dtb "$w/dtb" || die "no DTB in the stock boot image"
	# shellcheck disable=SC2086 # MKBOOTIMG/AVBTOOL are commands with arguments
	$MKBOOTIMG --header_version 2 \
		--kernel "$ul" --ramdisk "$PAYLOAD/ramdisk.cpio.gz" --dtb "$w/dtb" \
		--base "$BI_BASE" --kernel_offset "$BI_KERNEL_OFFSET" --ramdisk_offset "$BI_RAMDISK_OFFSET" \
		--tags_offset "$BI_TAGS_OFFSET" --dtb_offset "$BI_DTB_OFFSET" --pagesize "$BI_PAGE_SIZE" \
		--os_version "$BI_OS_VERSION" --os_patch_level "$BI_OS_PATCH_LEVEL" --board "$BI_BOARD" \
		--cmdline "" -o "$w/boot.img" >> "$LOG_FILE" 2>&1 || { rm -rf "$w"; die "mkbootimg failed"; }
	printf 'SEANDROIDENFORCE' >> "$w/boot.img"
	# shellcheck disable=SC2086
	$AVBTOOL add_hash_footer --image "$w/boot.img" --partition_name boot \
		--partition_size "$BOOT_PART_BYTES" --algorithm SHA256_RSA4096 --key "$(avb_key)" \
		--rollback_index 0 ${GTA3_AVB_SALT:+--salt "$GTA3_AVB_SALT"} >> "$LOG_FILE" 2>&1 ||
		{ rm -rf "$w"; die "avbtool failed"; }
	mkdir -p "$(dirname "$out")"
	mv -f "$w/boot.img" "$out"
	rm -rf "$w"
	dbg "$out: $(sha256sum "$out" | cut -c1-16)"
}

build_boot_images() {
	local d=$STATE_DIR/boot
	dry && { act "build boot-linux.img and boot-chain.img from the payload and the stock boot image" true; return 0; }
	pack_boot linux "$d/boot-linux.img"
	pack_boot chain "$d/boot-chain.img"
	state_set BOOT_LINUX "$d/boot-linux.img"
	state_set BOOT_CHAIN "$d/boot-chain.img"
	ok "BOOT images built for this tablet: $d/boot-linux.img, $d/boot-chain.img"
}
