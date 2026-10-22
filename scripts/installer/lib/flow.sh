# shellcheck shell=bash
# Getting the tablet from where it is to where a step needs it, and the
# two install stages.
#
# Stage 1 ("try", nothing of Android is erased): your stock boot image is
# kept on this PC and BOOT gets our Linux (the live environment). Android's
# system and data stay as they are; ./setup.sh undo puts the stock boot
# image back and Android starts exactly as before.
# Stage 2 (from inside the live environment, over the USB console): full
# Android backup, the Duranium install (erases Android's data, after you
# confirm on this PC and on the tablet), or going back to Android.

# where_is: android | adb-<state> | download | live | duranium | none
where_is() {
	local c st
	if c=$(con_probe); then
		case $c in
			bringup) echo live; return ;;
			duranium*) echo duranium; return ;;
		esac
	fi
	in_download && { echo download; return; }
	st=$(adb_state)
	case $st in
		device) echo android ;;
		none) echo none ;;
		*) echo "adb-$st" ;;
	esac
}

# Another flasher on this PC would fight over Download mode (the developer
# loop scripts/devd.sh reflashes BOOT whenever it appears)
check_no_devd() {
	local p
	for p in /proc/[0-9]*; do
		[ "${p#/proc/}" = $$ ] && continue
		tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'scripts/devd\.sh' || continue
		[ "${GTA3_ALLOW_DEVD:-0}" = 1 ] && { warn "scripts/devd.sh is running (allowed by GTA3_ALLOW_DEVD=1)"; return 0; }
		die "scripts/devd.sh (PID ${p#/proc/}) is running and would reflash BOOT in Download mode: stop it first"
	done
}

kg_screen_check() {
	[ "$YES" = 1 ] && return 0
	[ -n "${KG_SCREEN_CHECKED:-}" ] && return 0
	KG_SCREEN_CHECKED=1
	if ask_yn "Does the small text at the top of the Download mode screen say \"KG STATE: Prenormal\" (or Active/Locked)?" n; then
		kg_explain Prenormal
		info "Restart into Android with Power + Volume Down (7-10 s), let it check in, then run ./setup.sh again."
		die "KnoxGuard blocks custom images right now"
	fi
}

# to_download: get the tablet into Download mode from wherever it is
to_download() {
	local w
	check_no_devd
	w=$(where_is)
	dbg "tablet is: $w"
	case $w in
		download) ;;
		android) android_to_download ;;
		live|duranium)
			act "restart the tablet into Download mode" con_cmd "reboot download" 10 >/dev/null 2>&1 || true ;;
		*)
			todo_box "Put the tablet into Download mode" \
				"1. Force restart: hold Power + Volume Down for 7-10 s." \
				"2. As soon as the screen goes black, hold Volume Up +" \
				"   Volume Down and plug in the USB cable (if it is plugged" \
				"   in, hold them while it restarts)." \
				"3. At the warning screen press Volume Up." ;;
	esac
	wait_download 300 || die "the tablet did not reach Download mode"
	kg_screen_check
}

# flash_boot linux|chain|stock [PART FILE ...]: Download mode, then BOOT
# (and the extra partitions in the same session)
flash_boot() {
	local what=$1 img
	shift
	case $what in
		linux) img=$(state_get BOOT_LINUX) ;;
		chain) img=$(state_get BOOT_CHAIN) ;;
		stock) img=$(state_get STOCK_BOOT) ;;
	esac
	[ -s "$img" ] || dry || die "no $what boot image yet (run ./setup.sh first)"
	if [ "$what" = stock ] && [ -s "$img" ] && [ "$(sha256sum "$img" | cut -c1-64)" != "$(state_get STOCK_BOOT_SHA)" ]; then
		die "the saved stock boot image does not match its recorded hash: $img"
	fi
	# no PIT read first: after a heimdall session without reboot the next
	# one needs --resume, and a stray session confuses later runs
	to_download
	flash BOOT "$img" "$@" || die "flashing failed"
	state_set BOOT_NOW "$what"
	[ "$what" = stock ] || tablet_box "Next on the tablet" \
		"\"The bootloader is unlocked and software integrity cannot be" \
		"guaranteed\" (orange/yellow text): normal, it continues by itself" \
		"after a few seconds (or press Power once)."
}

# ensure_live: the tablet in the live environment, whatever it runs now
ensure_live() {
	local w
	w=$(where_is)
	if [ "$w" = live ]; then
		ok "the tablet is in the live environment"
		read_partitions
		return 0
	fi
	info "the tablet is in: $w; starting the live environment"
	[ -s "$(state_get BOOT_LINUX)" ] || dry || die "no live environment image yet: run ./setup.sh first"
	flash_boot linux
	tablet_box "The live environment" \
		"White text on black: \"Galaxy Tab Active3 - mainline Linux is alive\"," \
		"then the USB console starts. VOLUME UP there restarts into Download mode."
	wait_live 300 || die "the live environment did not answer; $HINT_DOWNLOAD Then run ./setup.sh again."
	dry && return 0
	[ "$(state_get STAGE)" = unlocked ] && state_set STAGE live
	read_partitions
	return 0
}

# ---------- stage 1 ----------

stage1() {
	local w
	preflight
	step "Find the tablet"
	w=$(where_is)
	case $w in
		live) ok "the tablet is already in the live environment"; stage1_live_checks; return 0 ;;
		duranium) ok "Duranium is running on the tablet"; status_duranium; return 0 ;;
		download)
			if [ -s "$(state_get BOOT_LINUX)" ]; then
				info "the tablet is in Download mode: continuing with the live environment"
				ensure_live; stage1_live_checks; return 0
			fi
			die "the tablet is in Download mode, but the installer needs Android first: restart it (Power + Volume Down 7-10 s)" ;;
	esac
	adb_connect 600 || die "no adb connection to the tablet"
	android_inspect
	android_lock_flow
	state_set ANDROID_DATA "$(state_get ANDROID_DATA intact)"
	state_set ANDROID_OS "$(state_get ANDROID_OS intact)"
	android_space_note
	stock_acquire
	firmware_acquire android || info "the firmware will be read in the live environment"
	payload_acquire
	build_boot_images
	step "Start our Linux on the tablet (nothing in Android is changed)"
	box "What happens now" \
		"Only the BOOT partition changes: it gets our Linux (the live" \
		"environment). Android's system, apps and files stay untouched," \
		"and your stock boot image is saved on this PC:" \
		"  $(state_get STOCK_BOOT)" \
		"./setup.sh undo puts it back and Android starts as before."
	ask_yn "Start the live environment now?" y || die "stopped; nothing was changed"
	ensure_live
	if dry; then
		say "  (dry run: the next steps need the live environment running)"
		return 0
	fi
	stage1_live_checks
}

android_space_note() {
	local used
	used=$(adb shell df -k /data 2>/dev/null | tr -d '\r' | awk 'NR == 2 { print $3 * 1024 }')
	[ -n "$used" ] && state_set ANDROID_USED "$used" && info "Android uses $(human_bytes "$used") of its data partition"
}

stage1_live_checks() {
	step "Check the tablet from the live environment"
	read_partitions
	info "userdata: ${PART_DEV[userdata]} ($(human_bytes "${PART_BYTES[userdata]}")), metadata: ${PART_DEV[metadata]:-?}"
	state_set USERDATA_BYTES "${PART_BYTES[userdata]}"
	[ "$(state_get STAGE)" = installed ] || [ "$(state_get STAGE)" = chain ] || state_set STAGE live
	firmware_acquire live || warn "no vendor firmware: Wi-Fi/Bluetooth/audio will be missing until you give --stock-ap"
	stage2_menu
}

stage2_menu() {
	local c
	box "The tablet runs our Linux (live environment)" \
		"Android is still there, untouched. What next?"
	c=$(choose "Choose" "${GTA3_STAGE2:-4}" \
		"Back up all of Android to this PC (byte-exact, restorable)" \
		"Install Duranium (erases Android's data; you confirm twice)" \
		"Go back to Android now (./setup.sh undo)" \
		"Stop here (the tablet stays in the live environment)")
	case $c in
		1) backup_android; stage2_menu ;;
		2) install_duranium ;;
		3) cmd_undo ;;
		4) say ""; say "  Later: ./setup.sh backup-android | install | undo | status" ;;
	esac
}

# ---------- stage 2: Android raw backup / restore ----------

# Partitions of a full backup. efs/sec_efs: a read-only safety copy of the
# tablet's identity data, never written back by the installer.
BACKUP_PARTS="metadata userdata"
BACKUP_RO_PARTS="efs sec_efs"

backup_android() {
	local dir n dev len est free sha
	step "Full Android backup (raw, byte-exact)"
	ensure_live
	[ "$(state_get ANDROID_DATA intact)" = intact ] || warn "Android's data was already erased (state: $(state_get ANDROID_DATA)); the backup holds what is there now"
	est=$(( $(state_get ANDROID_USED 0) + (2 << 30) ))
	info "userdata is $(human_bytes "${PART_BYTES[userdata]}"); used and encrypted data does not compress,"
	info "unused (trimmed) space reads as zeros: expect about $(human_bytes "$est") (Android said it uses $(human_bytes "$(state_get ANDROID_USED 0)"))."
	info "Reading 52 GB over USB takes 20-40 minutes."
	dir=$BACKUP_ROOT/android-raw-$(date +%Y%m%d-%H%M)
	free=$(free_bytes "$BACKUP_ROOT")
	need_space "$BACKUP_ROOT" "$est" "the Android backup" || die "not enough space; set GTA3_BACKUP_DIR to a bigger disk"
	info "into $dir ($(human_bytes "$free") free)"
	ask_yn "Start the backup?" y || return 0
	act "create $dir" mkdir -p "$dir"
	{
		echo "# gtactive3-setup Android backup: restore with ./setup.sh restore-android-backup $dir"
		echo "device_id=$(state_get DEVICE_ID)"
		echo "pda=$(state_get PDA)"
		echo "date=$(date -Is)"
	} > "$dir/MANIFEST.part" 2>/dev/null || dry
	for n in $BACKUP_PARTS $BACKUP_RO_PARTS; do
		dev=$(part "$n")
		len=${PART_BYTES[$n]}
		say "  $n ($dev, $(human_bytes "$len"))"
		if dry; then act "read $dev into $dir/$n.img.zst" true; continue; fi
		con_py get "$dev" "$len" "$dir/$n.sha256" "$n" | zstd -q -T0 -3 -o "$dir/$n.img.zst" ||
			die "reading $n failed"
		zstd -q -t "$dir/$n.img.zst" || die "the compressed copy of $n is damaged"
		sha=$(cut -c1-64 "$dir/$n.sha256")
		echo "part=$n dev=$dev bytes=$len sha256=$sha" >> "$dir/MANIFEST.part"
		ok "$n: $(human_bytes "$(stat -c %s "$dir/$n.img.zst")") compressed, sha256 ${sha:0:16}"
	done
	dry && return 0
	mv "$dir/MANIFEST.part" "$dir/MANIFEST"
	chmod -R go-rwx "$dir"
	state_set ANDROID_BACKUP "$dir"
	box "Backup done: $dir" \
		"It only works on THIS tablet (Android's encryption keys live in" \
		"its secure hardware). efs/sec_efs are a safety copy of the tablet's" \
		"identity: keep them private, the installer never writes them back."
}

restore_android_backup() {
	local dir=${1:-$(state_get ANDROID_BACKUP)} n dev len sha want got
	step "Restore the Android backup"
	[ -f "$dir/MANIFEST" ] || die "no backup at '$dir' (give the backup directory)"
	if [ "$(sed -n 's/^device_id=//p' "$dir/MANIFEST")" != "$(state_get DEVICE_ID)" ]; then
		warn "this backup was made on another tablet (or before the installer knew this one)"
		ask_yn "Restore it anyway? (Android will not be able to decrypt it on another tablet)" n || die "stopped"
	fi
	ensure_live
	confirm_typed RESTORE "Android's userdata and metadata on the tablet are replaced" \
		"by the backup from $(sed -n 's/^date=//p' "$dir/MANIFEST")." \
		"Whatever is there now (Duranium or Android) is lost."
	confirm_on_tablet "Restore the Android backup (erases what is there now)" || die "not confirmed on the tablet"
	for n in $BACKUP_PARTS; do
		read -r len want < <(awk -v p="part=$n" '$1 == p { sub("bytes=", "", $3); sub("sha256=", "", $4); print $3, $4 }' "$dir/MANIFEST")
		[ -n "${len:-}" ] || die "the backup has no $n"
		dev=$(part "$n")
		[ "$len" = "${PART_BYTES[$n]}" ] || die "$n on the tablet is ${PART_BYTES[$n]} bytes, the backup $len"
		say "  restoring $n ($(human_bytes "$len"))"
		if dry; then act "write $dir/$n.img.zst to $dev" true; continue; fi
		zstd -q -dc "$dir/$n.img.zst" | con_put - "$n" "$len" "$n"
		con_cmd "write /proc/sys/vm/drop_caches 3" >/dev/null
		if [ "$n" = metadata ] || [ "${GTA3_VERIFY_FULL:-0}" = 1 ]; then
			got=$(con_py hash "$dev" "$len" "verify $n")
			[ "$got" = "$want" ] || die "$n read back differs from the backup ($got)"
			ok "$n verified"
		fi
	done
	state_set ANDROID_DATA intact
	flash_boot stock
	state_set STAGE unlocked
	ok "Android is restored and starts now"
}

# ---------- stage 2: install ----------

install_duranium() {
	local wipe=${1:-} vlen want got
	step "Install Duranium"
	[ -n "${IMG_CHANNEL:-}" ] || [ -n "${OPT_IMAGE:-}" ] || choose_image
	fetch_image
	image_prepare "$IMG_RAW"
	ensure_live
	image_size_check "${PART_BYTES[userdata]}"
	firmware_acquire live || true
	image_add_firmware
	if [ "$wipe" != wipe ] && [ "$(state_get ANDROID_DATA intact)" = intact ] && [ -z "$(state_get ANDROID_BACKUP)" ]; then
		box "Android's data is still on the tablet and there is no backup" \
			"Installing erases it (apps, accounts, photos, files)." \
			"A full backup lets you bring Android back exactly as it is."
		ask_yn "Make the full Android backup first?" y && backup_android
	fi
	if [ "$wipe" = wipe ]; then
		confirm_typed WIPE "The installed Duranium is erased: your user, settings and files." \
			"The image $IMG_CHANNEL $IMG_VERSION is installed fresh."
	else
		confirm_typed ERASE "Android's data partition (userdata, $(human_bytes "${PART_BYTES[userdata]}")) is erased" \
			"and Duranium $IMG_CHANNEL $IMG_VERSION is written into it." \
			"Android's system stays; ./setup.sh restore-android can bring Android back" \
			"(empty, or from your backup)."
	fi
	confirm_on_tablet "Erase Android's data and install Duranium" || die "not confirmed on the tablet; nothing was changed"
	con_discard userdata
	state_set ANDROID_DATA erased
	state_set STAGE installing
	say "  writing the image into userdata..."
	con_put "$IMG_FILE" userdata "$IMG_LEN" "Duranium image"
	# read back what dm-verity does not protect: the GPT and the ESP
	vlen=$((ESP_OFF + ESP_LEN))
	if ! dry; then
		con_cmd "write /proc/sys/vm/drop_caches 3" | grep -q '^ok' || die "could not drop the tablet's page cache for the check"
		want=$(head -c "$vlen" "$IMG_FILE" | sha256sum | cut -c1-64)
		got=$(con_py hash "$(part userdata)" "$vlen" "verify")
		[ "$want" = "$got" ] || die "the image read back from the tablet differs (want $want, got $got); run ./setup.sh install again"
		ok "image verified (GPT + ESP read back)"
	fi
	state_set STAGE installed
	state_set CHANNEL "$IMG_CHANNEL"
	state_set VERSION "$IMG_VERSION"
	# uniLoader's boot record: start the chain from a clean "fallback" state
	con_cmd "poke 0x8ff1ff04c 3" >/dev/null 2>&1 || true
	flash_boot chain
	state_set STAGE chain
	first_boot
}

first_boot() {
	local fw
	step "First start of Duranium"
	tablet_box "First start (5-10 minutes)" \
		"U-Boot, then systemd-boot, then the postmarketOS logo." \
		"The first start creates the encrypted root partition: wait." \
		"Then set up the disk passphrase (asked at every start) and your" \
		"user in the setup screens." \
		"If it does not come up in 15 min: $HINT_FORCE_RESTART" \
		"(after a failed start our Linux comes up instead; run ./setup.sh status)."
	case ${IMG_FLAVOUR:-} in
		dev)
			wait_for "Duranium's USB console (dev image)" "$HINT_FORCE_RESTART" 900 con_is_duranium ||
				die "Duranium did not answer; run ./setup.sh status"
			ok "Duranium is up: $(con_probe)"
			firmware_check_installed ;;
		*)
			info "Release images have no USB console: the installer cannot watch the first start."
			info "Wi-Fi, Bluetooth and audio need the vendor firmware: Duranium imports it from"
			info "/boot/$ESP_FW by itself at the first start. If Wi-Fi is missing after setup,"
			info "copy $(state_get FIRMWARE_TAR) to the tablet (USB stick) and in a terminal run:"
			info "  sudo tar -xf firmware.tar -C /var/lib/firmware --no-same-owner && sudo reboot"
			;;
	esac
	fw=$(state_get FIRMWARE_TAR)
	[ -n "$fw" ] || warn "no vendor firmware was installed: run ./setup.sh firmware once you have it"
	ok "done. Updates: Settings / Software, or ./setup.sh update"
}

# dev images: firmware imported from the ESP? else push it over the console
firmware_check_installed() {
	local want have
	want=$(state_get FIRMWARE_ZST_SHA)
	[ -n "$want" ] || return 0
	have=$(con_cmd "cat /var/lib/firmware/.imported" 2>/dev/null | grep -oE '^[0-9a-f]{64}' || true)
	if [ "$have" = "$want" ]; then
		ok "vendor firmware is installed (imported from the ESP)"
		return 0
	fi
	info "the image did not import the firmware by itself: installing it over the USB console"
	firmware_push
}

firmware_push() {
	local t fw
	fw=$(state_get FIRMWARE_TAR)
	[ -s "$fw" ] || die "no vendor firmware on this PC (./setup.sh --stock-ap AP_....tar.md5 firmware)"
	con_is_duranium || die "firmware over USB needs a booted Duranium dev image"
	t=$(mktemp -d)
	tar -xf "$fw" -C "$t"
	mkdir -p "$GTA3_REPO/build"
	act "install the vendor firmware into /var/lib/firmware" \
		env GTA3_FIRMWARE_DIR="$t" "${GTA3_FIRMWARE_TO_TABLET:-$GTA3_REPO/scripts/firmware-to-tablet}" ||
		{ rm -rf "$t"; die "installing the firmware failed"; }
	rm -rf "$t"
	ok "vendor firmware installed (takes effect after a restart)"
}
