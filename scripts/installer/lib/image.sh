# shellcheck shell=bash
# The Duranium disk image: unpack, check, add the vendor firmware to its
# ESP, size check against userdata.
#
# Layout (build/wt/duranium mkosi.repart + postmarketos-duranium repart.d):
# the image is a 4 KiB-sector GPT with ESP (1 GiB) + usr-verity A (400 MiB)
# + usr A (5 GiB). The first boot's systemd-repart adds usr B + verity B
# (5.4 GiB) and the encrypted root (at least 1 GiB, grows into the rest of
# userdata).

FIRST_BOOT_EXTRA=${GTA3_FIRST_BOOT_EXTRA:-$(( (5 << 30) + (400 << 20) + (1 << 30) ))}
RECOMMENDED_FREE=$((8 << 30))   # for apps and files on the root partition
ESP_FW_DIR=gtactive3wifi        # /boot/gtactive3wifi/firmware.tar (+ .sha256)

# gpt_esp IMAGE: "offset size" of the ESP in bytes (4 KiB sectors)
gpt_esp() {
	python3 -I - "$1" <<'PY'
import struct, sys, uuid
f = open(sys.argv[1], "rb")
f.seek(4096)
hdr = f.read(92)
if hdr[:8] != b"EFI PART":
    sys.exit("no GPT header at byte 4096: not a 4K-sector Duranium image")
lba, n, size = struct.unpack_from("<QII", hdr, 72)
f.seek(lba * 4096)
esp = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le
for _ in range(n):
    e = f.read(size)
    if e[:16] == esp:
        first, last = struct.unpack_from("<QQ", e, 32)
        print(first * 4096, (last - first + 1) * 4096)
        break
else:
    sys.exit("the image has no EFI System Partition")
PY
}

# image_prepare ZST|RAW: sets IMG_FILE (raw, in the cache) and IMG_LEN
image_prepare() {
	local src=$1 raw
	case $src in
		*.zst)
			raw=$CACHE_DIR/images/$(basename "${src%.zst}")
			if [ ! -f "$raw" ] || [ "$src" -nt "$raw" ]; then
				need_space "$(dirname "$raw")" $((7 << 30)) "the unpacked image" || die "not enough space"
				info "unpacking $(basename "$src") (~6.4 GiB)..."
				mkdir -p "$(dirname "$raw")"
				act "unpack the image" zstd -d -q -f -o "$raw.part" "$src" || die "cannot unpack $src"
				dry || mv -f "$raw.part" "$raw"
			fi ;;
		*)
			# a copy: the firmware is added to the image's ESP, never to your file
			raw=$CACHE_DIR/images/$(basename "$src")
			if [ "$(realpath "$src")" != "$(realpath -m "$raw")" ]; then
				mkdir -p "$(dirname "$raw")"
				need_space "$(dirname "$raw")" "$(stat -c %s "$src")" "a copy of the image" || die "not enough space"
				act "copy the image" cp --reflink=auto "$src" "$raw" || die "cannot copy $src"
			fi ;;
	esac
	IMG_FILE=$raw
	dry && { IMG_LEN=$((6 << 30)); return 0; }
	IMG_LEN=$(stat -c %s "$raw")
	[ $((IMG_LEN % 4096)) -eq 0 ] || die "the image size is not a multiple of 4096 (UFS sector)"
	read -r ESP_OFF ESP_LEN < <(gpt_esp "$raw") || die "$raw is not a Duranium disk image"
	ok "image: $(basename "$raw"), $(human_bytes "$IMG_LEN"), ESP at $ESP_OFF"
}

# image_size_check USERDATA_BYTES
image_size_check() {
	local need=$((IMG_LEN + FIRST_BOOT_EXTRA)) have=$1
	if [ "$have" -lt "$need" ]; then
		die "userdata ($(human_bytes "$have")) is smaller than Duranium needs ($(human_bytes "$need"))"
	fi
	if [ "$have" -lt $((need + RECOMMENDED_FREE)) ]; then
		warn "only $(human_bytes $((have - need))) would be left for your files"
	fi
	ok "userdata: $(human_bytes "$have"); Duranium uses $(human_bytes "$need"), $(human_bytes $((have - need))) stay free for you"
}

# image_add_firmware: the vendor firmware goes into the image's ESP, where
# the device package imports it into /var/lib/firmware on the first boot
# (and again whenever /var/lib/firmware does not match it). The ESP is not
# covered by dm-verity and updates only add/remove UKIs there.
image_add_firmware() {
	local fw sha t
	fw=$(state_get FIRMWARE_TAR)
	if [ ! -s "$fw" ]; then
		warn "no vendor firmware yet: Wi-Fi, Bluetooth and audio will not work until it is installed"
		return 0
	fi
	dry && { act "copy the vendor firmware into the image's ESP" true; return 0; }
	sha=$(sha256sum "$fw" | cut -c1-64)
	t=$(mktemp)
	printf '%s  firmware.tar\n' "$sha" > "$t"
	export MTOOLS_SKIP_CHECK=1
	mmd -D s -i "$IMG_FILE@@$ESP_OFF" "::/$ESP_FW_DIR" 2>/dev/null || true
	if ! mcopy -o -i "$IMG_FILE@@$ESP_OFF" "$fw" "::/$ESP_FW_DIR/firmware.tar" ||
		! mcopy -o -i "$IMG_FILE@@$ESP_OFF" "$t" "::/$ESP_FW_DIR/firmware.tar.sha256"; then
		die "could not copy the firmware into the image's ESP"
	fi
	rm -f "$t"
	ok "vendor firmware added to the image's ESP (/boot/$ESP_FW_DIR/firmware.tar)"
}
