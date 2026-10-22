# shellcheck shell=bash
# Your stock firmware: the stock boot image (undo, and the DTB + header our
# BOOT image needs) and the vendor firmware blobs (Wi-Fi, Bluetooth, audio,
# ...). Samsung's files: they stay on this PC, in $STATE_DIR, and are never
# published.
#
# Sources, first match wins (options of ./setup.sh):
#   --stock-boot FILE    boot.img or boot.img.lz4 of the installed firmware
#   --stock-ap FILE      AP_<version>_..._.tar.md5 (from SamFW, Frija, Bifrost,
#                        samloader, ...): boot + recovery + super (firmware)
#   --stock-zip FILE     the full firmware zip (decrypted)
#   --download-stock     Samsung's server, via tools/fusdl.py (needs
#                        tools/auth_param.dat, see docs/INSTALL.md)
# Vendor firmware, first match wins:
#   --firmware-dir DIR   an extracted tree (lib/firmware layout)
#   adb pull from the running Android (/vendor/firmware)
#   super.img from --stock-ap / --stock-zip
#   the live environment reading Android's super partition (Android intact)

PY_APTAR() { python3 -I "$INST/py/aptar.py" "$@"; }
PY_BOOTIMG() { python3 -I "$INST/py/bootimg.py" "$@"; }
PY_SUPERFS() { python3 -I "$INST/py/superfs.py" "$@"; }

# vendor files the drivers request today (fw_index.py stages them under
# these names): without them there is no Wi-Fi or Bluetooth
REQUIRED_FW="brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.bin
brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.clm_blob
brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.txt
brcm/BCM.samsung,gtactive3wifi.hcd"

STOCK_DIR() { echo "$STATE_DIR/stock"; }

# version in a Samsung file name: AP_T570XXSFEYI1_... -> T570XXSFEYI1
fw_version_of() { basename "$1" | grep -oE 'T570[A-Z0-9]{8}' | head -1; }

check_fw_matches() {
	local v=$1 pda
	pda=$(state_get PDA)
	[ -n "$v" ] && [ -n "$pda" ] || return 0
	if [ "$v" != "$pda" ]; then
		warn "the stock firmware is $v but the tablet runs $pda"
		info "Undo would then start Android with a boot image of another version, which may not boot."
		ask_yn "Use it anyway?" n || die "get the firmware that matches $pda (Settings > About tablet > Software information)"
	else
		ok "stock firmware $v matches the tablet"
	fi
}

# lz4 or plain -> OUT
unlz4_to() {
	case $1 in
		*.lz4) lz4 -dc "$1" > "$2" ;;
		*) cp "$1" "$2" ;;
	esac
}

save_stock_boot() { # SRC(.img|.lz4) [recovery SRC]
	local d
	d=$(STOCK_DIR)
	mkdir -p "$d"
	unlz4_to "$1" "$d/boot.img.part"
	PY_BOOTIMG info "$d/boot.img.part" > /dev/null || die "$1 is not a boot image"
	mv -f "$d/boot.img.part" "$d/boot.img"
	state_set STOCK_BOOT "$d/boot.img"
	state_set STOCK_BOOT_SHA "$(sha256sum "$d/boot.img" | cut -c1-64)"
	if [ -n "${2:-}" ]; then
		unlz4_to "$2" "$d/recovery.img"
		state_set STOCK_RECOVERY "$d/recovery.img"
	fi
	ok "stock boot image saved: $d/boot.img ($(human_bytes "$(stat -c %s "$d/boot.img")"))"
}

stock_from_ap() { # AP tar
	local ap=$1 w
	[ -f "$ap" ] || die "no such file: $ap"
	check_fw_matches "$(fw_version_of "$ap")"
	info "checking $(basename "$ap") (md5)..."
	PY_APTAR check "$ap" >> "$LOG_FILE" || die "the AP file is damaged or incomplete (md5): download it again"
	ok "$(basename "$ap"): md5 ok"
	PY_APTAR list "$ap" | grep -q '^boot.img.lz4 ' || die "$ap has no boot.img.lz4: is it the AP file?"
	w=$(mktemp -d "$CACHE_DIR/ap.XXXXXX")
	PY_APTAR cat "$ap" boot.img.lz4 > "$w/boot.img.lz4"
	if PY_APTAR list "$ap" | grep -q '^recovery.img.lz4 '; then
		PY_APTAR cat "$ap" recovery.img.lz4 > "$w/recovery.img.lz4"
		save_stock_boot "$w/boot.img.lz4" "$w/recovery.img.lz4"
	else
		save_stock_boot "$w/boot.img.lz4"
	fi
	rm -rf "$w"
	state_set STOCK_AP "$ap"
}

stock_from_zip() { # decrypted firmware zip
	local z=$1 w
	[ -f "$z" ] || die "no such file: $z"
	check_fw_matches "$(fw_version_of "$z")"
	w=$CACHE_DIR/stock-zip
	mkdir -p "$w"
	need_space "$w" $((5 << 30)) "the AP images from the zip" || die "not enough space"
	info "reading boot, recovery and super out of $(basename "$z") (several minutes)..."
	python3 -I "$GTA3_REPO/tools/fwzip_extract.py" "$z" "$w" boot.img.lz4 recovery.img.lz4 super.img.lz4 >> "$LOG_FILE" ||
		die "could not read $z"
	save_stock_boot "$w/boot.img.lz4" "$w/recovery.img.lz4"
	state_set STOCK_SUPER "$w/super.img.lz4"
}

stock_download() {
	local d=$CACHE_DIR/samsung serial region py=python3
	[ -f "$GTA3_REPO/tools/auth_param.dat" ] || {
		box "Downloading from Samsung needs tools/auth_param.dat" \
			"It is not ours to redistribute. Copy it from Bifrost" \
			"(github.com/zacharee/Bifrost, common/src/commonMain/composeResources/" \
			"files/auth_param.dat) into tools/, or download the firmware" \
			"yourself (SamFW, Frija, Bifrost) and use --stock-ap AP_....tar.md5."
		die "no tools/auth_param.dat"
	}
	"$py" -c 'import requests, cryptography' 2>/dev/null || {
		[ -x "$CACHE_DIR/venv/bin/python" ] ||
			act "create a Python environment for the download" python3 -m venv "$CACHE_DIR/venv"
		act "install requests + cryptography" "$CACHE_DIR/venv/bin/pip" -q install requests cryptography
		py=$CACHE_DIR/venv/bin/python
	}
	serial=$(adb get-serialno 2>/dev/null | tr -d '\r\n')
	region=$(aprop ro.csc.sales_code)
	[ -n "$serial" ] && [ -n "$region" ] || die "the download needs the tablet in Android (serial and region)"
	need_space "$d" $((12 << 30)) "the firmware download (~5 GB) and its decrypted copy" || die "not enough space"
	info "downloading the newest SM-T570 firmware for region $region from Samsung (about 5 GB)..."
	info "(the tablet's serial number is sent to Samsung only, as Samsung's own tools do)"
	# not through act: its log line would carry the serial number
	dry && { act "download the stock firmware (tools/fusdl.py SM-T570 $region <serial>)" true; return 0; }
	"$py" -I "$GTA3_REPO/tools/fusdl.py" SM-T570 "$region" "$serial" "$d" || die "the download failed"
	stock_from_zip "$(find "$d" -maxdepth 1 -name '*.zip' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
}

# stock_acquire: make sure $STATE_DIR/stock/boot.img exists
stock_acquire() {
	local b
	step "Your stock boot image (for undo and for our BOOT image)"
	b=$(state_get STOCK_BOOT)
	if [ -n "$b" ] && [ -f "$b" ] && [ "$(sha256sum "$b" | cut -c1-64)" = "$(state_get STOCK_BOOT_SHA)" ]; then
		ok "have it: $b"
		return 0
	fi
	if [ -n "${OPT_STOCK_BOOT:-}" ]; then
		save_stock_boot "$OPT_STOCK_BOOT"
	elif [ -n "${OPT_STOCK_AP:-}" ]; then
		stock_from_ap "$OPT_STOCK_AP"
	elif [ -n "${OPT_STOCK_ZIP:-}" ]; then
		stock_from_zip "$OPT_STOCK_ZIP"
	elif [ "${OPT_DOWNLOAD_STOCK:-0}" = 1 ]; then
		stock_download
	else
		box "The installer needs your tablet's stock firmware" \
			"Samsung's files cannot be shipped with this project. Get the" \
			"firmware matching your tablet ($(state_get PDA unknown)) for SM-T570:" \
			"  SamFW / Frija / Bifrost, or samloader with your serial number," \
			"then run:  ./setup.sh --stock-ap /path/to/AP_....tar.md5" \
			"Or let the installer fetch it: ./setup.sh --download-stock" \
			"(needs tools/auth_param.dat, see docs/INSTALL.md)."
		die "no stock firmware given"
	fi
}

# ---------- vendor firmware ----------

FW_WORK() { echo "$STATE_DIR/firmware/work"; }

# stage OUT: fw_index.py layout (OUT/vendor/firmware, OUT/kernel-builtin)
# -> $STATE_DIR/firmware/firmware.tar
fw_stage() {
	local out=$1 f t lf missing=0
	# blobs the stock kernel carried built in (touch, pen; reference only)
	if [ -s "$(state_get STOCK_BOOT)" ] && [ ! -d "$out/kernel-builtin" ]; then
		t=$(mktemp)
		if ! PY_BOOTIMG extract "$(state_get STOCK_BOOT)" kernel "$t" ||
			! python3 -I "$GTA3_REPO/tools/builtin_fw_extract.py" "$t" "$out/kernel-builtin" \
				tsp_himax/hx83102e_gtactive3.bin >> "$LOG_FILE" 2>&1; then
			dbg "no built-in firmware from the stock kernel (optional)"
		fi
		rm -f "$t"
	fi
	python3 -I "$GTA3_REPO/tools/fw_index.py" "$out" >> "$LOG_FILE" || die "could not sort the firmware files"
	lf=$out/linux-firmware/lib/firmware
	while read -r f; do
		[ -s "$lf/$f" ] || { err "missing firmware: $f"; missing=1; }
	done <<< "$REQUIRED_FW"
	[ "$missing" = 0 ] || return 1
	fw_pack "$lf"
}

# The firmware as it goes onto the tablet: a tar of regular files, paths
# relative to the firmware search path (brcm/..., samsung/gtactive3wifi/...),
# owner 0:0, sorted, mtime 0 (the same input gives the same bytes). Camera
# ISP files are left out (no driver yet).
#   firmware.tar                      ./setup.sh firmware, --export
#   gtactive3wifi-firmware.tar.zst    + .sha256: what goes onto the image's
#                                     ESP for the first-boot import
fw_pack() {
	local d=$STATE_DIR/firmware z
	mkdir -p "$d"
	(cd "$1" && find . -type f ! -path './samsung/gtactive3wifi/camera/*' | sed 's|^\./||' | LC_ALL=C sort) |
		tar -C "$1" --owner=0 --group=0 --numeric-owner --mtime=@0 --no-recursion -cf "$d/firmware.tar.part" -T - ||
		die "could not pack the firmware"
	mv -f "$d/firmware.tar.part" "$d/firmware.tar"
	z=$d/gtactive3wifi-firmware.tar.zst
	zstd -q -19 -f -o "$z" "$d/firmware.tar" || die "could not compress the firmware"
	(cd "$d" && sha256sum gtactive3wifi-firmware.tar.zst > gtactive3wifi-firmware.tar.zst.sha256)
	state_set FIRMWARE_TAR "$d/firmware.tar"
	state_set FIRMWARE_SHA "$(sha256sum "$d/firmware.tar" | cut -c1-64)"
	state_set FIRMWARE_ZST "$z"
	state_set FIRMWARE_ZST_SHA "$(cut -c1-64 "$z.sha256")"
	ok "vendor firmware ready: $(tar -tf "$d/firmware.tar" | grep -c .) files, $(human_bytes "$(stat -c %s "$z")") compressed (stays on this PC)"
}

# vendor image -> OUT/vendor/{firmware,etc/...}
fw_from_vendor_img() {
	local img=$1 out=$2 d
	command -v debugfs >/dev/null || die "debugfs (e2fsprogs) is needed to read the vendor image"
	mkdir -p "$out/vendor/etc"
	case $(file -b "$img" 2>/dev/null) in
		*EROFS*|*erofs*)
			command -v fsck.erofs >/dev/null || die "the vendor image is EROFS: install erofs-utils"
			fsck.erofs --extract="$out/vendor.all" "$img" >> "$LOG_FILE" 2>&1
			cp -a "$out/vendor.all/firmware" "$out/vendor/firmware"
			for d in wifi nfc; do [ -d "$out/vendor.all/etc/$d" ] && cp -a "$out/vendor.all/etc/$d" "$out/vendor/etc/"; done
			rm -rf "$out/vendor.all" ;;
		*)
			debugfs -R "rdump /firmware $out/vendor" "$img" 2>&1 | grep -v 'changing ownership' >> "$LOG_FILE" || true
			for d in wifi nfc; do
				debugfs -R "rdump /etc/$d $out/vendor/etc" "$img" 2>&1 | grep -v 'changing ownership' >> "$LOG_FILE" || true
			done ;;
	esac
	[ -n "$(ls -A "$out/vendor/firmware" 2>/dev/null)" ] || die "no /firmware in the vendor image"
}

fw_from_adb() {
	local out=$1
	adb_ready || return 1
	mkdir -p "$out/vendor"
	adb pull -a /vendor/firmware "$out/vendor/" >> "$LOG_FILE" 2>&1 || true
	mkdir -p "$out/vendor/etc"
	adb pull -a /vendor/etc/wifi "$out/vendor/etc/" >> "$LOG_FILE" 2>&1 || true
	[ -s "$out/vendor/firmware/bcmdhd_sta.bin_b1" ] && [ -s "$out/vendor/firmware/bcmdhd_clm.blob" ]
}

fw_from_super_stream() { # CMD... producing the super partition (sparse or raw)
	local out=$1 img
	shift
	img=$CACHE_DIR/vendor.img
	"$@" | PY_SUPERFS extract vendor "$img" >> "$LOG_FILE" || die "could not read vendor out of super"
	fw_from_vendor_img "$img" "$out"
	rm -f "$img"
}

ap_super() { PY_APTAR cat "$1" super.img.lz4 | lz4 -dc; }

# firmware_acquire [android|live]: where the tablet is right now
firmware_acquire() {
	local where=${1:-android} out ap sup end
	step "Vendor firmware (Wi-Fi, Bluetooth, audio)"
	if [ -s "$(state_get FIRMWARE_TAR)" ] && [ "$(sha256sum "$(state_get FIRMWARE_TAR)" | cut -c1-64)" = "$(state_get FIRMWARE_SHA)" ]; then
		ok "have it: $(state_get FIRMWARE_TAR)"
		return 0
	fi
	dry && { act "collect the vendor firmware" true; return 0; }
	if [ -n "${OPT_FIRMWARE_DIR:-}" ]; then
		[ -d "$OPT_FIRMWARE_DIR/brcm" ] || die "$OPT_FIRMWARE_DIR has no brcm/ (expected a lib/firmware tree)"
		fw_pack "$OPT_FIRMWARE_DIR"
		return 0
	fi
	out=$(FW_WORK)
	rm -rf "$out"
	mkdir -p "$out"
	if [ "$where" = android ] && fw_from_adb "$out"; then
		ok "firmware files copied from Android"
		fw_stage "$out" && return 0
	fi
	rm -rf "$out"; mkdir -p "$out"
	ap=$(state_get STOCK_AP)
	sup=$(state_get STOCK_SUPER)
	if [ -n "$ap" ] && [ -f "$ap" ]; then
		info "reading the firmware out of $(basename "$ap") (super.img, ~1 minute)..."
		fw_from_super_stream "$out" ap_super "$ap"
	elif [ -n "$sup" ] && [ -f "$sup" ]; then
		info "reading the firmware out of $(basename "$sup") (~1 minute)..."
		fw_from_super_stream "$out" lz4 -dc "$sup"
	elif [ "$where" = live ] && [ "$(state_get ANDROID_OS intact)" = intact ]; then
		info "reading the firmware out of Android's super partition on the tablet..."
		end=$(con_py get "$(part super)" $((1 << 20)) /dev/null | PY_SUPERFS end vendor) ||
			die "could not read Android's partition table"
		fw_from_super_stream "$out" con_py get "$(part super)" "$end" /dev/null "Android super (to vendor)"
	else
		info "Android did not let adb read /vendor/firmware; the firmware comes from"
		info "the stock firmware (--stock-ap) or, later, from the live environment."
		return 1
	fi
	fw_stage "$out" || die "the firmware is incomplete"
	rm -rf "$out"
}
