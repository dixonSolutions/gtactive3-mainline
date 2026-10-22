# shellcheck shell=bash
# Stock Android over adb: find the tablet, check it, guide Developer
# options / OEM unlocking / the bootloader unlock, back up files.

TESTED_BL_REV=F           # T570XXSFEYI1: bootloader revision F (15)
TESTED_PDA=T570XXSFEYI1

# adb_devices: "serial state" lines (state: device, unauthorized, offline,
# recovery, sideload, no-permissions)
adb_devices() {
	adb devices 2>/dev/null | tr -d '\r' | awk 'NR > 1 && NF >= 2 {
		s = $2; if ($0 ~ /no permissions/) s = "no-permissions"; print $1, s }'
}

# adb_pick: choose the tablet when several devices are attached
# (exports ANDROID_SERIAL, which adb honours). Returns 1 with no device.
adb_pick() {
	local lines n c s st sel=()
	[ -n "${ANDROID_SERIAL:-}" ] && adb_devices | grep -q "^$ANDROID_SERIAL " && return 0
	lines=$(adb_devices)
	n=$(printf '%s\n' "$lines" | grep -c . || true)
	[ "$n" -eq 0 ] && return 1
	if [ "$n" -eq 1 ]; then
		ANDROID_SERIAL=${lines%% *}
		export ANDROID_SERIAL
		return 0
	fi
	warn "$n Android devices are connected"
	local opts=()
	while read -r s st; do sel+=("$s"); opts+=("$s ($st)"); done <<< "$lines"
	[ "$YES" = 1 ] && die "several devices: pick the tablet with --serial SERIAL"
	c=$(choose "Which one is the Galaxy Tab Active3?" 1 "${opts[@]}")
	ANDROID_SERIAL=${sel[$((c - 1))]}
	export ANDROID_SERIAL
}

adb_state() {
	adb_pick || { echo none; return; }
	adb_devices | awk -v s="$ANDROID_SERIAL" '$1 == s { print $2; exit }'
}
adb_ready() { [ "$(adb_state)" = device ]; }
adb_gone() { [ "$(adb_state)" = none ]; }
aprop() { adb shell getprop "$1" 2>/dev/null | tr -d '\r'; }
asetting() { adb shell settings get global "$1" 2>/dev/null | tr -d '\r'; }

# Wait for an authorised adb connection, explaining each state.
adb_connect() {
	local st last=''
	while true; do
		st=$(adb_state)
		[ "$st" = device ] && { ok "Android is connected over adb"; return 0; }
		if [ "$st" != "$last" ]; then
			case $st in
				none)
					todo_box "Connect the tablet with USB debugging on" \
						"1. Settings > About tablet > Software information:" \
						"   tap Build number 7 times (Developer options)." \
						"2. Settings > Developer options: switch on USB debugging." \
						"3. Plug the tablet into this PC with a data USB cable." ;;
				unauthorized)
					tablet_box "\"Allow USB debugging?\" with this PC's RSA key" \
						"Tick \"Always allow from this computer\" and tap Allow." \
						"No prompt? Unplug and replug the cable, or in Developer" \
						"options tap \"Revoke USB debugging authorisations\"." ;;
				offline)
					info "adb sees the tablet as offline: unplug and replug the cable." ;;
				no-permissions)
					warn "no permission to open the USB device: install the USB rules (./setup.sh doctor)" ;;
				*)
					info "adb state: $st" ;;
			esac
			last=$st
		fi
		wait_for "the tablet in adb (state: $st)" "unplug and replug the cable; try another USB port or cable" \
			"${1:-300}" adb_state_changed "$st" || return 1
	done
}
adb_state_changed() { [ "$(adb_state)" != "$1" ]; }

# Identity and lock state; fills A_* globals and the state file
android_inspect() {
	A_MODEL=$(aprop ro.product.model)
	A_DEVICE=$(aprop ro.product.device)
	A_BL=$(aprop ro.bootloader)
	A_PDA=$(aprop ro.build.PDA)
	A_HWREV=$(aprop ro.revision)
	A_CSC=$(aprop ro.csc.sales_code)
	A_ANDROID=$(aprop ro.build.version.release)
	A_LOCKED=$(aprop ro.boot.flash.locked)
	A_VBSTATE=$(aprop ro.boot.verifiedbootstate)
	A_WARRANTY=$(aprop ro.boot.warranty_bit)
	A_OEM_SUPPORTED=$(aprop ro.oem_unlock_supported)
	A_OEM_ALLOWED=$(aprop sys.oem_unlock_allowed)
	A_DEVOPT=$(asetting development_settings_enabled)
	A_KG=$(kg_state)
	case $A_MODEL:$A_DEVICE in
		SM-T570:gtactive3wifi) ;;
		SM-T575*|SM-T577*)
			die "this is a $A_MODEL (LTE): only the Wi-Fi model SM-T570 is supported" ;;
		*) die "this is not a Galaxy Tab Active3 Wi-Fi (model '$A_MODEL', device '$A_DEVICE')" ;;
	esac
	state_set DEVICE_ID "$(adb get-serialno 2>/dev/null | tr -d '\r\n' | sha256sum | cut -c1-16)"
	state_set PDA "$A_PDA"
	state_set BOOTLOADER "$A_BL"
	state_set HWREV "$A_HWREV"
	state_set KG "${A_KG:-unknown}"
	info "Model:        $A_MODEL ($A_DEVICE), hardware revision ${A_HWREV:-?}"
	info "Android:      $A_ANDROID, firmware $A_PDA, bootloader $A_BL, region ${A_CSC:-?}"
	info "Boot state:   flash.locked=${A_LOCKED:-?} verifiedbootstate=${A_VBSTATE:-?} warranty_bit=${A_WARRANTY:-?}"
	info "Developer options=${A_DEVOPT:-?}, OEM unlocking supported=${A_OEM_SUPPORTED:-?} allowed=${A_OEM_ALLOWED:-?}"
	info "KnoxGuard:    ${A_KG:-unknown}"
	check_firmware_family
	case $A_HWREV in
		4) ;;
		5) info "hardware revision 5: the speaker amplifier is a TI TAS2562 (rev 4: Richtek RT5510); audio may differ" ;;
		*) warn "untested hardware revision '${A_HWREV:-?}' (tested: 4)" ;;
	esac
}

# Samsung version strings: <model><region><type><BL rev><major><year><month><build>,
# e.g. T570XXSFEYI1: bootloader revision F.
bl_rev() { printf '%s' "${1: -5:1}"; }

check_firmware_family() {
	local r
	r=$(bl_rev "$A_BL")
	if [ "$A_BL" = "$TESTED_PDA" ]; then
		ok "bootloader $A_BL is the tested version"
	elif [ "$r" = "$TESTED_BL_REV" ]; then
		warn "bootloader $A_BL: same revision ($r) as the tested $TESTED_PDA, but not the same build"
	else
		warn "bootloader $A_BL has revision '$r'; only revision $TESTED_BL_REV ($TESTED_PDA) is tested"
		info "A newer revision can refuse images this installer makes; you cannot go back to an older one."
		ask_yn "Continue anyway?" n || die "stopped before changing anything"
	fi
}

# KnoxGuard: "Completed"/"" are fine; Prenormal/Active/Locked block custom
# images in Download mode ("Only official released binaries are allowed").
kg_state() {
	local s
	s=$(aprop knox.kg.state)
	[ -n "$s" ] && { echo "$s"; return; }
	s=$(adb shell dumpsys knoxguard_service 2>/dev/null | tr -d '\r' |
		sed -n 's/.*vaultState[^A-Za-z]*\([A-Za-z]*\).*/\1/p' | head -1)
	echo "${s:-}"
}

kg_blocks() {
	case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
		prenormal|active|locked|checking) return 0 ;;
	esac
	return 1
}

kg_explain() {
	box "KnoxGuard is \"$1\": Download mode will refuse our images" \
		"In this state Samsung's Download mode only accepts official" \
		"firmware (\"Only official released binaries are allowed\")." \
		"It clears after the tablet checks in with Samsung:" \
		"  1. Connect the tablet to Wi-Fi (internet), keep it on." \
		"  2. Wait 5-10 minutes (it checks every few minutes)." \
		"  3. Restart it once." \
		"Never use \"Factory data reset\" from the recovery menu:" \
		"it sets KnoxGuard back to Prenormal."
}

kg_settled() { ! kg_blocks "$(kg_state)"; }

# Developer options, OEM unlocking, lock state. Returns 0 when unlocked.
android_lock_flow() {
	if [ "${A_LOCKED:-1}" = 0 ] || [ "$A_VBSTATE" = orange ]; then
		ok "the bootloader is unlocked"
		if kg_blocks "$A_KG"; then
			kg_explain "$A_KG"
			wait_for "KnoxGuard to leave the $A_KG state" "keep Wi-Fi on; restart the tablet once" \
				1200 kg_settled || die "KnoxGuard still blocks custom images; try again later"
		fi
		state_set STAGE unlocked
		return 0
	fi
	warn "the bootloader is locked"
	if [ "$A_OEM_SUPPORTED" != 1 ]; then
		box "This tablet does not offer bootloader unlocking" \
			"ro.oem_unlock_supported is '${A_OEM_SUPPORTED:-}'. Carrier or" \
			"business-managed (Knox / financed) tablets often cannot be" \
			"unlocked. Ask the owner organisation, or check that the" \
			"tablet is a retail SM-T570."
		die "cannot continue without an unlockable bootloader"
	fi
	if [ "$A_OEM_ALLOWED" != 1 ]; then
		todo_box "Switch on OEM unlocking" \
			"Settings > Developer options > OEM unlocking: switch it on" \
			"and confirm. Not there? Connect to Wi-Fi, set the date and time" \
			"automatically, check for software updates, restart, and look" \
			"again (it can take a few minutes after the tablet is online)."
		wait_for "OEM unlocking to be switched on" "connect to Wi-Fi and restart the tablet" \
			900 oem_allowed || die "OEM unlocking was not switched on"
		ok "OEM unlocking is on"
	fi
	unlock_guide
}
oem_allowed() { [ "$(aprop sys.oem_unlock_allowed)" = 1 ]; }

unlock_guide() {
	box "Unlocking the bootloader ERASES the tablet" \
		"This is Samsung's own step: the tablet does a factory reset and" \
		"everything on it (apps, photos, files, accounts) is deleted." \
		"After the unlock the installer never erases Android by itself:" \
		"you can try our Linux and go back to Android at any time."
	if ask_yn "Back up the tablet's files to this PC (or its microSD card) first?" y; then
		backup_files
	fi
	confirm_typed UNLOCK "The tablet's data is erased by Samsung's unlock." \
		"Your backup: ${FILES_BACKUP:-none}."
	todo_box "Unlock the bootloader (Samsung's Download mode)" \
		"1. Power the tablet off (hold Power, tap Power off)." \
		"2. Hold Volume Up + Volume Down and plug in the USB cable." \
		"3. A warning screen appears: LONG-press Volume Up for" \
		"   \"Device unlock mode\"." \
		"4. Press Volume Up to confirm \"Unlock bootloader?\"." \
		"5. The tablet erases itself and restarts (a few minutes)."
	wait_for "the tablet to leave Android (power off)" "hold Power, tap Power off" 600 adb_gone ||
		die "the tablet stayed in Android"
	state_set STAGE unlock-pending
	tablet_box "After the unlock" \
		"\"Bootloader unlocked\" warning at every start: normal, it continues." \
		"Then Android's first-start setup. Do it quickly, but CONNECT TO" \
		"Wi-Fi: Samsung's KnoxGuard/RMM check needs the internet." \
		"Then again: Build number x7, Developer options > USB debugging on," \
		"plug in the cable and allow this PC."
	wait_for "Android again after the unlock, with USB debugging on" \
		"$HINT_FORCE_RESTART" 3600 adb_ready || die "Android did not come back over adb"
	adb_connect || die "no adb connection"
	android_inspect
	[ "$A_LOCKED" = 0 ] || [ "$A_VBSTATE" = orange ] ||
		die "the bootloader is still locked (flash.locked=$A_LOCKED); repeat the unlock steps"
	ok "bootloader unlocked"
	state_set ANDROID_DATA intact
	android_lock_flow
}

# ---------- file backup over adb (Android running) ----------

BACKUP_DIRS="DCIM Pictures Download Documents Movies Music Recordings Podcasts Audiobooks Ringtones Alarms Notifications"

sdcard_card() {
	adb shell ls /storage 2>/dev/null | tr -d '\r' | grep -E '^[0-9A-F]{4}-[0-9A-F]{4}$' | head -1
}

backup_files() {
	local d sz total=0 dest card c
	step "Back up the tablet's files"
	adb_ready || adb_connect || die "no adb connection"
	for d in $BACKUP_DIRS; do
		sz=$(adb shell du -sk "/sdcard/$d" 2>/dev/null | tr -d '\r' | awk '{ print $1 }' || true)
		[ -n "$sz" ] && total=$((total + sz * 1024))
	done
	info "about $(human_bytes "$total") in $BACKUP_DIRS"
	info "Not included: app data (needs root), accounts, Wi-Fi passwords, messages."
	card=$(sdcard_card || true)
	c=1
	if [ -n "$card" ]; then
		c=$(choose "Where to?" 1 "this PC ($BACKUP_ROOT)" "the tablet's microSD card ($card; the unlock does not erase it)" "both")
	fi
	if [ "$c" = 1 ] || [ "$c" = 3 ]; then
		dest=$BACKUP_ROOT/android-files-$(date +%Y%m%d-%H%M)
		need_space "$BACKUP_ROOT" $((total + (1 << 30))) "the file backup" || die "not enough space"
		act "create $dest" mkdir -p "$dest"
		for d in $BACKUP_DIRS; do
			adb shell "[ -d /sdcard/$d ]" 2>/dev/null || continue
			say "  /sdcard/$d -> $dest/$d"
			act "copy /sdcard/$d" adb pull -a "/sdcard/$d" "$dest/" || warn "could not copy all of /sdcard/$d"
		done
		dry || adb shell pm list packages -3 | tr -d '\r' | sed 's/^package://' | sort > "$dest/apps.txt"
		info "installed apps: $dest/apps.txt (reinstall them from the store later)"
		if ask_yn "Also copy the apps' installation files (APKs)?" n; then
			backup_apks "$dest/apk"
		fi
		FILES_BACKUP=$dest
		state_set FILES_BACKUP "$dest"
		ok "files backed up to $dest"
	fi
	if [ "$c" = 2 ] || [ "$c" = 3 ]; then
		dest=/storage/$card/gtactive3-backup-$(date +%Y%m%d-%H%M)
		act "create $dest on the card" adb shell mkdir -p "$dest" || die "cannot write to the microSD card"
		for d in $BACKUP_DIRS; do
			adb shell "[ -d /sdcard/$d ]" 2>/dev/null || continue
			say "  /sdcard/$d -> card:$dest"
			act "copy /sdcard/$d to the card" adb shell cp -r "/sdcard/$d" "$dest/" ||
				warn "could not copy /sdcard/$d to the card"
		done
		FILES_BACKUP=${FILES_BACKUP:+$FILES_BACKUP and }card:$dest
		state_set FILES_BACKUP "$FILES_BACKUP"
		ok "files copied to the microSD card ($dest)"
	fi
}

backup_apks() {
	local pkg p
	act "create $1" mkdir -p "$1"
	for pkg in $(adb shell pm list packages -3 | tr -d '\r' | sed 's/^package://'); do
		act "create $1/$pkg" mkdir -p "$1/$pkg"
		for p in $(adb shell pm path "$pkg" | tr -d '\r' | sed 's/^package://'); do
			act "copy $pkg" adb pull "$p" "$1/$pkg/" >/dev/null || warn "could not copy $pkg"
		done
	done
}

# Reboot Android into Download mode (Samsung honours "adb reboot download")
android_to_download() {
	act "restart into Download mode" adb reboot download || true
}
