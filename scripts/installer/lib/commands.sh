# shellcheck shell=bash
# Companion commands: undo, redo, restore-android, wipe, update, status,
# firmware, backup-files.

# ---------- undo / redo ----------

cmd_undo() {
	local data
	step "Undo: your stock boot image back into BOOT"
	[ -s "$(state_get STOCK_BOOT)" ] || die "no stock boot image saved (nothing to undo)"
	data=$(state_get ANDROID_DATA intact)
	case $data in
		intact)
			box "Android starts exactly as before" \
				"Only BOOT changes back to your stock boot image. Android's" \
				"system, apps and files were never touched." \
				"./setup.sh redo starts our Linux again." ;;
		*)
			box "Android's data is gone (state: $data): Android will NOT start normally" \
				"Duranium (or nothing) is in Android's data partition. Android will" \
				"stop with \"Can't load Android system\" and offer \"Factory data" \
				"reset\". DO NOT accept it: Samsung's reset sets KnoxGuard back to" \
				"Prenormal (Download mode then refuses custom images until the" \
				"tablet checks in online)." \
				"To go back to Android use ./setup.sh restore-android (empty) or" \
				"./setup.sh restore-android-backup (your backup) instead." \
				"./setup.sh redo brings Duranium back."
			confirm_typed UNDO "Flash the stock boot image although Android's data is gone." ;;
	esac
	flash_boot stock
	[ "$data" = intact ] && state_set STAGE unlocked
	ok "stock boot image flashed"
	[ "$data" = intact ] && tablet_box "Android starts" "As before (the unlocked-bootloader warning stays)."
	return 0
}

cmd_redo() {
	local what=${1:-}
	if [ -z "$what" ]; then
		case $(state_get STAGE) in
			installed|chain) what=chain ;;
			*) what=linux ;;
		esac
	fi
	step "Redo: BOOT gets $( [ "$what" = chain ] && echo "the Duranium boot chain" || echo "the live environment") again"
	flash_boot "$what"
	if [ "$what" = linux ]; then
		wait_live 300 || die "the live environment did not answer"
		[ "$(state_get STAGE)" = unlocked ] && state_set STAGE live
	else
		state_set STAGE chain
	fi
	ok "done"
}

# ---------- back to Android ----------

# mkfs.f2fs as Samsung made the stock userdata image (AP userdata.img.lz4,
# T570XXSFEYI1): features encrypt, verity, extra_attr, project_quota,
# quota_ino (superblock feature word 0x499); no checksums, no casefold or
# compression (not in the stock 4.9 kernel). Listed explicitly: -g android
# alone would decide quota by the running (mainline) kernel's version.
# -g android also means -f -w 4096 -R 0:0; -t0: no discard (done before).
# The console's "run" passes at most 7 arguments, hence the attached values.
F2FS_OPTS="-gandroid -Oencrypt,extra_attr,project_quota,quota,verity -t0 -ldata"
F2FS_FEATURES=0x499

cmd_restore_android() {
	local dev f
	step "Back to Android (erases Duranium)"
	[ -s "$(state_get STOCK_BOOT)" ] || die "no stock boot image saved"
	if [ -n "$(state_get ANDROID_BACKUP)" ] && [ -f "$(state_get ANDROID_BACKUP)/MANIFEST" ]; then
		info "you have a full Android backup: $(state_get ANDROID_BACKUP)"
		if ask_yn "Restore that backup instead (Android exactly as it was)?" y; then
			restore_android_backup
			return
		fi
	fi
	if [ "$(state_get ANDROID_OS intact)" != intact ]; then
		box "Android's system partition (super) was erased" \
			"The stock boot image alone cannot start Android. Flash your full" \
			"stock firmware instead (Odin on Windows, or heimdall with every" \
			"image of the AP file), see docs/INSTALL.md \"Full stock firmware\"."
		die "Android's system is not on the tablet"
	fi
	ensure_live
	PAYLOAD_MKFS=${GTA3_MKFS:-/usr/sbin/mkfs.f2fs}
	con_cmd "ls ${PAYLOAD_MKFS%/*}" | grep -qx "${PAYLOAD_MKFS##*/}" ||
		die "this live environment has no mkfs.f2fs (update the boot chain: ./setup.sh --refresh)"
	confirm_typed WIPE "Duranium on this tablet is erased (user, settings, files)." \
		"Android's data partition is formatted empty and Android starts its" \
		"first-time setup, like a new tablet (no Samsung factory reset)."
	confirm_on_tablet "Erase Duranium and return to Android" || die "not confirmed on the tablet"
	dev=$(part userdata)
	guard_console_write mkfs "$dev" userdata
	con_discard userdata
	if dry; then
		act "format $dev as Android's f2fs" true
	else
		_log "mkfs.f2fs $F2FS_OPTS $dev"
		# shellcheck disable=SC2086
		con_cmd "run $PAYLOAD_MKFS $F2FS_OPTS $dev" 90 >> "$LOG_FILE" || die "mkfs.f2fs failed"
		f=$(con_py get "$dev" 4096 /dev/null | python3 -I -c 'import struct,sys; b=sys.stdin.buffer.read(); print(hex(struct.unpack_from("<I",b,1024)[0]), hex(struct.unpack_from("<I",b,3204)[0]))')
		[ "$f" = "0xf2f52010 $F2FS_FEATURES" ] || die "the new userdata is not the expected f2fs ($f)"
		ok "userdata formatted (f2fs, features $F2FS_FEATURES like Samsung's image)"
	fi
	# metadata is "formattable" in the stock fstab: Android recreates it
	con_discard metadata
	state_set ANDROID_DATA formatted
	state_set STAGE unlocked
	if [ "${OPT_STOCK_RECOVERY:-0}" = 1 ]; then
		[ -s "$(state_get STOCK_RECOVERY)" ] || die "no stock recovery image saved (it comes from --stock-ap)"
		flash_boot stock RECOVERY "$(state_get STOCK_RECOVERY)"
	else
		flash_boot stock
	fi
	tablet_box "Android's first start" \
		"It can take 5-10 minutes and restart once. Then the setup screens," \
		"as on a new tablet. Connect to Wi-Fi so KnoxGuard can check in."
	ok "back to Android"
}

# ---------- wipe (fresh Duranium) ----------

cmd_wipe() {
	case $(state_get STAGE) in
		installed|chain) ;;
		*) warn "the installer has no record of a Duranium install here (stage: $(state_get STAGE new))" ;;
	esac
	install_duranium wipe
}

# ---------- update ----------

TEST_VERSION_RE='^[0-9]{8}~test[0-9]+$'
PY_VER() { python3 -I "$INST/py/versions.py" "$@"; }
vercmp() {
	if command -v systemd-analyze >/dev/null 2>&1; then
		systemd-analyze compare-versions "$1" "$2" 2>/dev/null | awk '{ print $2 }' | sed 's/==/=/'
	else
		PY_VER cmp "$1" "$2"
	fi
}

# run a shell script on a booted Duranium dev image (console "run": 60 s)
dur_sh() {
	local t r name=$1
	t=$(mktemp)
	printf '%s\n' "$2" > "$t"
	con_py put "$t" "/run/gta3-setup-$name.sh" "$(stat -c %s "$t")" >/dev/null || { rm -f "$t"; die "console upload failed"; }
	rm -f "$t"
	r=$(con_cmd "run /bin/sh /run/gta3-setup-$name.sh" 75) || die "the tablet's console stopped answering"
	# the console ends the output with "run: exit N signal S"
	printf '%s\n' "$r" | grep -v '^run: \(exit\|killed\)'
	[ "$(printf '%s\n' "$r" | sed -n 's/^run: exit \([0-9]*\) signal 0$/\1/p' | tail -1)" = 0 ]
}

published_newest() {
	local idx=$CACHE_DIR/releases.json
	release_index "$idx"
	PY_REL newest "$idx"
}

# tablet_test_versions: ~test versions on the tablet (partition labels, UKIs)
tablet_versions() {
	dur_sh versions '# gta3:versions
lsblk -no PARTLABEL /dev/loop0 2>/dev/null | sed -n "s/^duranium_\(.*\)_usr$/\1/p"
ls /boot/EFI/Linux 2>/dev/null | sed -n "s/.*_edge_\([^+]*\)\(+.*\)\{0,1\}\.efi$/\1/p"' | sort -u
}

next_test_version() {
	local l base n max=0 v
	l=$(published_newest) || die "cannot find the newest published version"
	base=$(printf '%08d' $((10#$l + 1)))
	for v in $( { con_is_duranium && tablet_versions; state_get TEST_VERSIONS | tr ' ' '\n'; } 2>/dev/null); do
		case $v in "$base~test"*) n=${v#"$base~test"}; [ "$n" -gt "$max" ] 2>/dev/null && max=$n ;; esac
	done
	echo "$base~test$((max + 1))"
}

# osrel_version UKI: IMAGE_VERSION in the UKI's .osrel section
osrel_version() {
	python3 -I - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", d, 0x3c)[0]
if d[pe:pe + 4] != b"PE\0\0":
    sys.exit("not a PE file")
nsec = struct.unpack_from("<H", d, pe + 6)[0]
opt = struct.unpack_from("<H", d, pe + 20)[0]
sec = pe + 24 + opt
for i in range(nsec):
    s = sec + 40 * i
    name = d[s:s + 8].rstrip(b"\0")
    vsize, _, rsize, roff = struct.unpack_from("<IIII", d, s + 8)
    if name == b".osrel":
        for ln in d[roff:roff + min(vsize, rsize)].decode(errors="replace").splitlines():
            if ln.startswith("IMAGE_VERSION="):
                print(ln.split("=", 1)[1].strip().strip('"'))
                sys.exit(0)
sys.exit("no IMAGE_VERSION in .osrel")
PY
}

# A failed or interrupted systemd-sysupdate leaves a slot "partial" or
# "pending": its GPT type becomes a derived UUID. sysupdate then refuses the
# same update and scripts/duranium-update finds no free slot; "vacuum"
# returns the slot to _empty.
KNOWN_PARTTYPES="c12a7328-f81f-11d2-ba4b-00a0c93ec93b b0e01050-ee5f-4390-949a-9101b17104e9
6e11a4e7-fbca-4ded-b9e9-e1a512bb664e b921b045-1df0-41c3-af44-4c6f280d3fae"
sysupdate_clean_slots() {
	local parts bad='' ln t
	parts=$(dur_sh slots '# gta3:slots
lsblk -Pno NAME,PARTLABEL,PARTTYPE /dev/loop0 2>/dev/null') || return 0
	while read -r ln; do
		case $ln in *PARTLABEL=\"duranium_*|*PARTLABEL=\"_empty\"*) ;; *) continue ;; esac
		t=$(printf '%s' "$ln" | sed -n 's/.*PARTTYPE="\([^"]*\)".*/\1/p' | tr '[:upper:]' '[:lower:]')
		case " ${KNOWN_PARTTYPES//$'\n'/ } " in *" $t "*) ;; *) bad="$bad ${ln%% *}" ;; esac
	done <<< "$parts"
	[ -n "$bad" ] || return 0
	warn "an earlier update was interrupted: slot(s)$bad are marked partial/pending"
	ask_yn "Clean them up with systemd-sysupdate vacuum (the booted version is kept)?" y ||
		die "the inactive slot is not free; run: updatectl vacuum"
	act "systemd-sysupdate vacuum" dur_sh vacuum '# gta3:vacuum
/usr/lib/systemd/systemd-sysupdate vacuum 2>&1 | tail -5' || die "vacuum failed"
	ok "slots cleaned up"
}

cmd_update() {
	case ${1:-} in
		--next-test-version) next_test_version; return ;;
		--test) shift; update_test "$@"; return ;;
		"") ;;
		*) die "update: unknown option $1" ;;
	esac
	step "Update Duranium (official channel)"
	if ! con_is_duranium; then
		box "Updating from the tablet" \
			"Release images have no USB console. On the tablet: open a terminal" \
			"and run:  sudo updatectl update   then restart." \
			"(The software centre shows the same updates once it supports" \
			"systemd-sysupdate.)"
		return 0
	fi
	info "booted: $(con_probe)"
	sysupdate_clean_slots
	dur_sh check '# gta3:updatectl-check
updatectl check 2>&1 | tail -20' || warn "updatectl check reported an error"
	ask_yn "Download and install the update now (A/B: the current version stays as the fallback)?" y || return 0
	act "start updatectl update on the tablet" dur_sh update '# gta3:updatectl-update
systemctl reset-failed gta3-setup-update 2>/dev/null
systemd-run --quiet --collect --unit=gta3-setup-update updatectl update && echo started' >/dev/null
	dry && return 0
	wait_for "the update to finish on the tablet" "it downloads ~2 GB; check the tablet's network" 3600 update_done ||
		die "the update did not finish"
	dur_sh result '# gta3:updatectl-result
journalctl -u gta3-setup-update --no-pager -o cat | tail -15' || true
	ok "update installed: restart the tablet to use it"
}
update_done() {
	dur_sh state '# gta3:update-state
systemctl is-active gta3-setup-update 2>/dev/null || true' | grep -qvx 'active\|activating'
}

# what decides where the tablet updates from: must not change in a test update
REMOTE_CFG='# gta3:remote
cat /usr/lib/gtactive3wifi/update-channel 2>/dev/null
for d in /etc/sysupdate.d /usr/lib/sysupdate.d; do [ -d $d ] && find $d -type f | sort | xargs cat 2>/dev/null; done | sha256sum'

# update --test [DIR] [VERSION]: a local build as a one-off A/B update.
# It must be BUILT with VERSION = <newest published + 1>~test<N> (see
# --next-test-version): the build's own os-release must carry the version
# sysupdate protects as booted, and "~" sorts below the plain version, so
# the next official update replaces it. The tablet's update channel is not
# touched.
update_test() {
	local dir=${1:-$GTA3_REPO/build/wt/duranium/mkosi.output} ver=${2:-} ui name uki osv booted l before after stage f
	step "Install a test build as an A/B update"
	ui=${UI:-$(con_probe | awk '{ print $3 }')}
	name=samsung-gtactive3wifi_${ui}_edge
	[ -d "$dir/$name" ] && dir=$dir/$name
	if [ -z "$ver" ]; then
		ver=$(find "$dir" -maxdepth 1 -name "${name}_*~test*.efi" -printf '%f\n' |
			sed -n "s/^${name}_\(.*\)\.efi$/\1/p" | PY_VER max) || die "no ~test build of $name in $dir"
	fi
	[[ $ver =~ $TEST_VERSION_RE ]] || die "test builds need a version like 26102215~test1 (got '$ver'); ./setup.sh update --next-test-version"
	uki=$dir/${name}_$ver.efi
	[ -f "$uki" ] || die "no UKI $uki"
	osv=$(osrel_version "$uki") || die "cannot read the UKI's os-release"
	[ "$osv" = "$ver" ] || die "the UKI says IMAGE_VERSION=$osv, not $ver: rebuild with mkosi --image-version=$ver (never relabel a build)"
	con_is_duranium || die "the tablet is not running a Duranium dev image (USB console)"
	booted=$(con_probe | awk '{ print $2 }')
	[ "$(vercmp "$ver" "$booted")" = ">" ] || die "$ver is not newer than the booted $booted: systemd-boot would not start it"
	l=$(published_newest) && [ "$(vercmp "$ver" "$l")" = ">" ] ||
		die "$ver is not above the newest published version ${l:-?}"
	info "$ver > booted $booted > published $l; the next official update (>= $(printf '%08d' $((10#$l + 1)))) replaces it"
	before=$(dur_sh remote "$REMOTE_CFG") || die "cannot read the tablet's update configuration"
	sysupdate_clean_slots
	# hard links in a directory of its own: duranium-update sizes the files
	# with stat, which would see a symbolic link's size
	stage=$(mktemp -d "$dir/.update-test.XXXXXX")
	for f in "$dir/${name}_$ver".*; do ln "$f" "$stage/" 2>/dev/null || cp "$f" "$stage/"; done
	act "A/B update to $ver" env OUT="$stage" UI="$ui" EXTENSIONS="" \
		"${GTA3_DURANIUM_UPDATE:-$GTA3_REPO/scripts/duranium-update}" "$ver" || { rm -rf "$stage"; die "the update failed; the booted version is unchanged"; }
	rm -rf "$stage"
	after=$(dur_sh remote "$REMOTE_CFG") || die "cannot read the tablet's update configuration"
	[ "$before" = "$after" ] || die "the tablet's update configuration changed during the test update: check /etc/sysupdate.d"
	state_set TEST_VERSIONS "$(state_get TEST_VERSIONS) $ver"
	ok "test version $ver installed; restart the tablet to boot it (boot counting falls back to $booted if it fails twice)"
	info "the update channel is unchanged: the next official update replaces $ver"
}

# ---------- status / doctor ----------

status_duranium() {
	dur_sh status '# gta3:status
. /usr/lib/os-release; echo "image:   $IMAGE_ID $IMAGE_VERSION ($VARIANT_ID)"
echo "kernel:  $(uname -r)"
echo "channel: $(cat /usr/lib/gtactive3wifi/update-channel 2>/dev/null)"
echo "slots:"; lsblk -no NAME,PARTLABEL,SIZE /dev/loop0 2>/dev/null | sed "s/^/  /"
echo "boot entries:"; ls /boot/EFI/Linux 2>/dev/null | sed "s/^/  /"
echo "firmware: $(find /var/lib/firmware -type f 2>/dev/null | wc -l) files"' || true
}

cmd_status() {
	local w
	step "This PC"
	check_tools adb heimdall curl gpg zstd lz4 python3 sha256sum openssl mcopy lsusb ip tar && ok "tools complete"
	if udev_ok; then ok "USB rules for Samsung present"; else warn "no USB rules for Samsung (./setup.sh doctor installs them)"; fi
	info "state: $STATE_FILE"
	state_show
	step "The tablet"
	w=$(where_is)
	case $w in
		android)
			android_inspect ;;
		adb-*)
			info "Android with adb state ${w#adb-}"; adb_connect 30 || true ;;
		download)
			ok "Download mode (heimdall sees the tablet)" ;;
		live)
			ok "live environment (our Linux): $(con_cmd 'cat /proc/version' | head -c 80)"
			read_partitions
			info "userdata ${PART_DEV[userdata]} $(human_bytes "${PART_BYTES[userdata]}")" ;;
		duranium)
			ok "Duranium (dev image, USB console)"
			status_duranium ;;
		none)
			info "nothing on USB: the tablet is off, in Android without USB debugging, in a"
			info "Duranium release image (no USB console), or the cable is charge-only."
			con_diagnose ;;
	esac
}

cmd_doctor() {
	preflight
	cmd_status
}

cmd_firmware() {
	case ${1:-} in
		--export)
			[ -s "$(state_get FIRMWARE_TAR)" ] || firmware_acquire android || die "no firmware"
			cp "$(state_get FIRMWARE_TAR)" "${2:?firmware --export FILE}"
			ok "wrote $2; on the tablet: sudo tar -xf $(basename "$2") -C /var/lib/firmware --no-same-owner" ;;
		*)
			[ -s "$(state_get FIRMWARE_TAR)" ] || firmware_acquire android || die "no firmware: give --stock-ap or --firmware-dir"
			firmware_push ;;
	esac
}
