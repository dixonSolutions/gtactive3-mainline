# shellcheck shell=bash
# Test cases: every function named t_* is one case (see run.sh).

# ---------- helpers' units ----------

t_guard_refuses_protected_partitions() {
	local g
	g=$(mktemp)
	cat > "$g" <<-EOF
		INST=$REPO/scripts/installer; LOG_FILE=/dev/null
		. \$INST/lib/ui.sh; . \$INST/lib/guard.sh
	EOF
	for c in "guard_heimdall EFS /etc/hostname" "guard_heimdall VBMETA /etc/hostname" \
		"guard_heimdall PARAM /etc/hostname" "guard_heimdall SUPER /etc/hostname" \
		"guard_heimdall BOOT /nonexistent" \
		"guard_console_write put /dev/sda1 efs" "guard_console_write discard /dev/sda17 persistent" \
		"guard_console_write put /dev/sdb1 userdata" "guard_console_write mkfs /dev/sda24 metadata" \
		"guard_console_write put /dev/sda31 ''" "guard_console_write put /dev/sda22 vbmeta" \
		"guard_console_write discard /dev/sda25 super"; do
		if bash -c ". $g; $c" >/dev/null 2>&1; then echo "not refused: $c"; return 1; fi
	done
	for c in "guard_heimdall BOOT /etc/hostname" "guard_console_write put /dev/sda31 userdata" \
		"guard_console_write discard /dev/sda24 metadata" "guard_console_write mkfs /dev/sda31 userdata" \
		"guard_console_write put /dev/tty0 ''"; do
		bash -c ". $g; $c" >/dev/null 2>&1 || { echo "refused: $c"; return 1; }
	done
	rm -f "$g"
}

t_versions_match_systemd() {
	local a b py sd
	need systemd-analyze || { echo "(no systemd-analyze: skipped)"; return 0; }
	while read -r a b; do
		py=$(python3 -I "$REPO/scripts/installer/py/versions.py" cmp "$a" "$b")
		sd=$(systemd-analyze compare-versions "$a" "$b" 2>/dev/null | awk '{ print $2 }' | sed 's/==/=/')
		[ "$py" = "$sd" ] || { echo "$a vs $b: python $py, systemd $sd"; return 1; }
	done <<-EOF
		26102213~test1 26102213
		26102214~test1 26102213
		26102214~test2 26102214~test10
		26102214 26102214~test9
		1.2 1.10
		1.0~rc1 1.0
		1.0^p1 1.0
		1.0.0 1.0
		0010 10
		a1 1
		1.2-3 1.2.1
	EOF
}

t_superfs_extracts_vendor() {
	local o=$CASE/vendor.img
	lz4 -dc "$RUN/fx/super/super.img.lz4" | python3 -I "$REPO/scripts/installer/py/superfs.py" extract vendor "$o" >/dev/null
	cmp -n "$(stat -c %s "$RUN/fx/super/vendor.img")" "$o" "$RUN/fx/super/vendor.img" || { echo "sparse: differs"; return 1; }
	python3 -I "$REPO/scripts/installer/py/superfs.py" extract vendor "$o" < "$RUN/fx/super/super.raw" >/dev/null
	cmp -n "$(stat -c %s "$RUN/fx/super/vendor.img")" "$o" "$RUN/fx/super/vendor.img" || { echo "raw: differs"; return 1; }
}

t_aptar_md5_and_members() {
	python3 -I "$REPO/scripts/installer/py/aptar.py" check "$AP_TAR" | grep -q 'md5 ok'
	python3 -I "$REPO/scripts/installer/py/aptar.py" cat "$AP_TAR" boot.img.lz4 | cmp - "$RUN/fx/stock/boot.img.lz4"
	cp "$AP_TAR" "$CASE/bad.tar.md5"
	printf 'X' | dd of="$CASE/bad.tar.md5" bs=1 seek=4000 conv=notrunc status=none
	! python3 -I "$REPO/scripts/installer/py/aptar.py" check "$CASE/bad.tar.md5" >/dev/null 2>&1
}

# ---------- PC checks ----------

t_doctor_names_missing_tools_per_distro() {
	new_tablet off; start_console
	mkdir -p "$CASE/bin"
	for t in bash sh env python3 sed awk grep tr cut sort head tail cat date mkdir mktemp mv rm chmod dirname basename stat df git realpath readlink sha256sum seq printf ls ip; do
		p=$(command -v "$t") && ln -sf "$p" "$CASE/bin/$t"
	done
	printf 'ID=ubuntu\nID_LIKE=debian\n' > "$CASE/os-release"
	env PATH="$CASE/bin" GTA3_OS_RELEASE="$CASE/os-release" GTA3_STATE_DIR="$CASE/st" GTA3_CACHE_DIR="$CASE/cache" \
		NO_COLOR=1 bash "$REPO/scripts/installer/setup" doctor > "$CASE/out" 2>&1 && echo 0 > "$CASE/rc" || echo $? > "$CASE/rc"
	rc_is 1
	out_has "missing: heimdall"
	out_has "sudo apt install"
	out_has "heimdall-flash"
}

t_no_space_for_downloads() {
	new_tablet android; start_console
	TEST_FREE=1000 setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "not enough free space"
	boot_is stock
}

# ---------- stage 1 ----------

t_stage1_unlocked_tablet_to_live() {
	new_tablet android; start_console
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "bootloader T570XXSFEYI1 is the tested version"
	out_has "firmware files copied from Android"
	st_is STAGE live
	st_is BOOT_NOW linux
	st_is ANDROID_DATA intact
	boot_is linux
	mode_is bringup
	userdata_starts ANDROID-DATA
	cmp "$CASE/st/stock/boot.img" "$RUN/fx/stock/boot.img" || fail "stock boot not saved"
	tar -tf "$CASE/st/firmware/firmware.tar" | grep -q 'brcmfmac4375b1-pcie.samsung,gtactive3wifi.bin' || fail "no Wi-Fi firmware"
	tar -tf "$CASE/st/firmware/firmware.tar" | grep -q camera && fail "camera files packed"
	# the BOOT image: our uniLoader + the stock DTB, header like the stock one
	python3 -I "$REPO/scripts/installer/py/bootimg.py" info "$ROOT/dev/sda12" | grep -q '^BI_BOARD=SRPTF17A015$' || fail "board"
	python3 -I "$REPO/scripts/installer/py/bootimg.py" extract "$ROOT/dev/sda12" dtb "$CASE/dtb"
	cmp "$CASE/dtb" "$RUN/fx/stock/dtb" || fail "not the stock DTB"
	avbtool info_image --image "$ROOT/dev/sda12" | grep -q 'Partition Name:        boot' || fail "no AVB footer"
	log_lacks discard
	no_violation
}

t_stage1_firmware_from_ap_when_adb_cannot_read() {
	new_tablet android; start_console
	mock 's["vendor_readable"] = False'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "reading the firmware out of"
	tar -tf "$CASE/st/firmware/firmware.tar" | grep -q 'BCM.samsung,gtactive3wifi.hcd' || fail "no BT firmware"
}

t_stage1_firmware_from_live_super() {
	new_tablet android; start_console
	mock 's["vendor_readable"] = False'
	setup live --yes --stock-boot "$RUN/fx/stock/boot.img.lz4" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "the firmware will be read in the live environment"
	out_has "reading the firmware out of Android's super partition on the tablet"
	tar -tf "$CASE/st/firmware/firmware.tar" | grep -q 'brcmfmac4375b1-pcie.samsung,gtactive3wifi.txt' || fail "no nvram"
	no_violation
}

t_stage1_payload_download_signed() {
	new_tablet android; start_console
	setup live --yes --stock-ap "$AP_TAR"
	rc_is 0
	out_has "SHA256SUMS signature: good"
	out_has "boot chain 1.0"
	boot_is linux
}

t_stage1_offers_debug_tool_default_yes() {
	new_tablet android; start_console
	DEBUG_TOOLS= setup live --yes --stock-ap "$AP_TAR"
	rc_is 0
	out_has "Install the USB debug tool"
	out_has "USB debug tool installed"
	grep -q "^usb-debug-install --yes --device=samsung-gtactive3wifi" "$CASE/state.json.calls" ||
		fail "the debug tool's install script was not run with --yes --device"
	# asked once: a second run does not install it again
	DEBUG_TOOLS= setup live --yes --stock-ap "$AP_TAR"
	[ "$(grep -c "^usb-debug-install" "$CASE/state.json.calls")" = 1 ] || fail "installed twice"
}

t_stage1_no_debug_tools() {
	new_tablet android; start_console
	DEBUG_TOOLS= setup live --yes --no-debug-tools --stock-ap "$AP_TAR"
	rc_is 0
	! grep -q "^usb-debug-install" "$CASE/state.json.calls" 2>/dev/null || fail "installed despite --no-debug-tools"
}

t_stage1_unauthorized_then_allowed() {
	new_tablet android; start_console
	mock 's["adb_auth"] = "unauthorized"; s["events"] = [{"after": 6, "set": {"adb_auth": "device"}}]'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "Allow USB debugging?"
	st_is STAGE live
}

t_stage1_no_device_times_out() {
	new_tablet off; start_console
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "tap Build number 7 times"
	out_has "no adb connection"
}

t_stage1_several_devices_need_serial() {
	new_tablet android; start_console
	mock 's["extra_devices"] = ["emulator-5554"]'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "pick the tablet with --serial"
	setup live --yes --serial R52TEST0001 --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
}

t_stage1_wrong_model() {
	new_tablet android; start_console
	mock 's["props"]["ro.product.model"] = "SM-T575"'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "only the Wi-Fi model SM-T570"
	boot_is stock
}

t_stage1_untested_bootloader_stops() {
	new_tablet android; start_console
	mock 's["props"]["ro.bootloader"] = "T570XXSGFZA1"'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "only revision F"
	boot_is stock
}

t_stage1_locked_oem_off_full_unlock() {
	new_tablet android; start_console
	mock 's["props"].update({"ro.boot.flash.locked": "1", "ro.boot.verifiedbootstate": "green", "sys.oem_unlock_allowed": "0"})
s["card"] = "1A2B-3C4D"
s["events"] = [
 {"after": 30, "set": {"props": {"sys.oem_unlock_allowed": "1"}}},
 {"after": 120, "set": {"mode": "off"}},
 {"after": 160, "set": {"mode": "android", "props": {"ro.boot.flash.locked": "0", "ro.boot.verifiedbootstate": "orange"}}}]'
	TIMEOUT_PCT=10 setup live --yes-wipe --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "Switch on OEM unlocking"
	out_has "Unlocking the bootloader ERASES the tablet"
	out_has "LONG-press Volume Up"
	out_has "bootloader unlocked"
	ls "$CASE"/backups/android-files-*/DCIM/Camera/IMG_0001.jpg >/dev/null || fail "no file backup"
	grep -q com.example.notes "$CASE"/backups/android-files-*/apps.txt || fail "no app list"
	st_is STAGE live
}

t_stage1_unlock_needs_typed_confirmation() {
	new_tablet android; start_console
	mock 's["props"].update({"ro.boot.flash.locked": "1", "ro.boot.verifiedbootstate": "green"})'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "needs a typed confirmation (UNLOCK)"
}

t_stage1_oem_unlock_unsupported() {
	new_tablet android; start_console
	mock 's["props"].update({"ro.boot.flash.locked": "1", "ro.boot.verifiedbootstate": "green", "ro.oem_unlock_supported": "0"})'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "does not offer bootloader unlocking"
}

t_stage1_knoxguard_prenormal_waits_then_clears() {
	new_tablet android; start_console
	mock 's["props"]["knox.kg.state"] = "Prenormal"; s["events"] = [{"after": 60, "set": {"props": {"knox.kg.state": "Completed"}}}]'
	TIMEOUT_PCT=10 setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has 'KnoxGuard is "Prenormal"'
	out_has "Never use \"Factory data reset\""
	boot_is linux
}

t_stage1_knoxguard_stays_blocks() {
	new_tablet android; start_console
	mock 's["props"]["knox.kg.state"] = "Prenormal"'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "KnoxGuard still blocks custom images"
	boot_is stock
}

t_stage1_flash_failure_explains() {
	new_tablet android; start_console
	mock 's["flash_fail"] = True'
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 1
	out_has "heimdall could not flash BOOT"
	out_has "./setup.sh undo"
}

t_stage1_dry_run_changes_nothing() {
	new_tablet android; start_console
	setup live --yes --dry-run --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	out_has "[dry-run] flash BOOT: heimdall flash --BOOT"
	boot_is stock
	mode_is android
	log_lacks flash
	grep -q '^STAGE=live' "$CASE/st/state.env" && fail "dry run recorded a stage"
	true
}

t_stage1_resume_after_interrupted_reboot() {
	new_tablet android; start_console
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
	# the tablet falls into Download mode (Volume Up in the live environment)
	mock 's["mode"] = "download"'
	setup --yes
	rc_is 0
	out_has "continuing with the live environment"
	mode_is bringup
}

# ---------- stage 2 ----------

live_tablet() { # a tablet that went through stage 1
	new_tablet android; start_console
	setup live --yes --stock-ap "$AP_TAR" --payload "$PAYLOAD_DIR"
	rc_is 0
}

t_backup_and_restore_android_raw() {
	live_tablet
	cp "$ROOT/dev/sda31" "$CASE/userdata.orig"
	cp "$ROOT/dev/sda24" "$CASE/metadata.orig"
	setup backup-android --yes
	rc_is 0
	d=$(ls -d "$CASE"/backups/android-raw-*)
	for p in metadata userdata efs sec_efs; do [ -s "$d/$p.img.zst" ] || fail "no $p backup"; done
	grep -q '^part=userdata dev=/dev/sda31 bytes=67108864 sha256=' "$d/MANIFEST" || fail "manifest"
	zstd -dc "$d/userdata.img.zst" | cmp - "$CASE/userdata.orig" || fail "userdata backup differs"
	st_is ANDROID_BACKUP "$d"
	# something else lands in userdata, then the backup goes back
	printf 'SOMETHING-ELSE' | dd of="$ROOT/dev/sda31" conv=notrunc status=none
	: > "$ROOT/dev/sda24"; truncate -s $((4 << 20)) "$ROOT/dev/sda24"
	setup restore-android-backup --yes-wipe
	rc_is 0
	cmp "$ROOT/dev/sda31" "$CASE/userdata.orig" || fail "userdata not restored"
	cmp "$ROOT/dev/sda24" "$CASE/metadata.orig" || fail "metadata not restored"
	cmp "$ROOT/dev/sda1" <(printf 'EFS-IDENTITY'; head -c $(((1 << 20) - 12)) /dev/zero) || fail "efs was written"
	out_has "metadata verified"
	boot_is stock
	mode_is android
	st_is ANDROID_DATA intact
	no_violation
}

t_install_needs_both_confirmations() {
	live_tablet
	setup install --yes --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 1
	out_has "typed confirmation (ERASE)"
	userdata_starts ANDROID-DATA
	mock 's["tablet_key"] = 115'
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 1
	out_has "not confirmed on the tablet"
	userdata_starts ANDROID-DATA
	grep -q 'Press POWER to confirm' "$ROOT/dev/tty0" || fail "no prompt on the tablet's screen"
	log_lacks discard
}

t_install_duranium_dev_image() {
	live_tablet
	mock 's["sh"]["status"] = "image: x\n"'
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	out_has "SHA256SUMS signature: good"
	out_has "vendor firmware added to the image's ESP"
	out_has "image verified (GPT + ESP read back)"
	out_has "Make the full Android backup first?"
	log_has "discard /dev/sda31"
	st_is STAGE chain
	st_is ANDROID_DATA erased
	st_is VERSION 26102213
	boot_is chain
	mode_is duranium
	# the written image = the release image + the firmware on its ESP
	dd if="$ROOT/dev/sda31" bs=4096 skip=1 count=1 status=none | head -c 8 | grep -q 'EFI PART' || fail "no GPT"
	dd if="$ROOT/dev/sda31" of="$CASE/esp.img" bs=1M skip=1 count=32 status=none
	MTOOLS_SKIP_CHECK=1 mcopy -i "$CASE/esp.img" ::/gtactive3wifi-firmware.tar.zst "$CASE/fw.tar.zst"
	MTOOLS_SKIP_CHECK=1 mcopy -i "$CASE/esp.img" ::/gtactive3wifi-firmware.tar.zst.sha256 "$CASE/fw.sha256"
	cmp "$CASE/fw.tar.zst" "$CASE/st/firmware/gtactive3wifi-firmware.tar.zst" || fail "firmware on the ESP differs"
	(cd "$CASE" && sed 's/ gtactive3wifi-firmware.tar.zst$/ fw.tar.zst/' fw.sha256 | sha256sum -c --quiet) || fail "ESP .sha256 does not match"
	zstd -dc "$CASE/fw.tar.zst" | tar -t | grep -qx 'brcm/brcmfmac4375b1-pcie.samsung,gtactive3wifi.bin' || fail "tar layout"
	zstd -dc "$CASE/fw.tar.zst" | tar -t | grep -q '^\./\|/$' && fail "tar has ./ or directory entries"
	grep -q 'fw-to-tablet' "$CASE/state.json.calls" || fail "dev image: firmware not pushed"
	no_violation
}

t_install_bad_signature_refused() {
	live_tablet
	cp -r "$RUN/srv/dl/samsung-gtactive3wifi_phosh_edge-dev" "$CASE/chan.bak"
	echo "0000  extra" >> "$RUN/srv/dl/samsung-gtactive3wifi_phosh_edge-dev/SHA256SUMS"
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	cp "$CASE/chan.bak/SHA256SUMS" "$RUN/srv/dl/samsung-gtactive3wifi_phosh_edge-dev/SHA256SUMS"
	rc_is 1
	out_has "NOT signed by the project key"
	userdata_starts ANDROID-DATA
}

t_install_bad_image_hash_refused() {
	live_tablet
	f=$(ls "$RUN"/srv/dl/samsung-gtactive3wifi_phosh_edge-dev/*.raw.zst)
	cp "$f" "$CASE/img.bak"
	printf 'X' >> "$f"
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	cp "$CASE/img.bak" "$f"
	rc_is 1
	out_has "has the wrong hash"
	userdata_starts ANDROID-DATA
}

t_install_index_falls_back_to_github_api() {
	live_tablet
	PAGES_PATH=nonexistent setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	st_is STAGE chain
}

t_install_userdata_too_small() {
	live_tablet
	EXTRA_ENV="GTA3_FIRST_BOOT_EXTRA=$((1 << 40))" setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 1
	out_has "is smaller than Duranium needs"
	userdata_starts ANDROID-DATA
}

# ---------- undo / redo / back to Android ----------

t_undo_from_live_restores_android() {
	live_tablet
	setup undo --yes
	rc_is 0
	out_has "Android starts exactly as before"
	boot_is stock
	mode_is android
	st_is STAGE unlocked
	cmp "$ROOT/dev/sda12" "$RUN/fx/stock/boot.img" || fail "BOOT is not the stock image"
	setup redo --yes
	rc_is 0
	boot_is linux
	mode_is bringup
}

t_undo_after_install_warns_and_needs_typing() {
	live_tablet
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	setup undo --yes
	rc_is 1
	out_has "DO NOT accept it"
	boot_is chain
	setup undo --yes-wipe
	rc_is 0
	boot_is stock
	mode_is android-broken
	mock 's["mode"] = "download"'   # the user: Power + Volume Down, then Download mode
	setup redo --yes
	rc_is 0
	boot_is chain
	mode_is duranium
}

t_restore_android_formats_userdata() {
	live_tablet
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	mock 's["sh"] = {}'
	sed -i '/^ANDROID_BACKUP=/d' "$CASE/st/state.env"   # the install made one; pretend there is none
	setup restore-android --yes-wipe --stock-recovery
	rc_is 0
	log_has "flash RECOVERY stock"
	log_has "mkfs -gandroid -Oencrypt,extra_attr,project_quota,quota,verity -t0 -ldata /dev/sda31"
	log_has "discard /dev/sda24"
	out_has "features 0x499"
	boot_is stock
	mode_is android
	st_is ANDROID_DATA formatted
	no_violation
}

t_restore_android_refuses_claimed_super() {
	live_tablet
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	mock 's["sh"] = {}'
	sed -i '/^ANDROID_BACKUP=/d' "$CASE/st/state.env"
	# gtactive3wifi-claim-android-space on the tablet: super is LUKS now
	printf 'LUKS\272\276\000\002' | dd of="$ROOT/dev/sda25" conv=notrunc status=none
	cp "$ROOT/dev/sda31" "$CASE/userdata.before"
	setup restore-android --yes-wipe --stock-recovery
	rc_is 1
	out_has "super partition is Duranium storage now"
	st_is ANDROID_OS erased
	cmp "$ROOT/dev/sda31" "$CASE/userdata.before" || fail "userdata was touched"
	no_violation
}

t_restore_android_offers_backup() {
	live_tablet
	setup backup-android --yes
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	setup restore-android --yes-wipe
	rc_is 0
	out_has "Restore that backup instead"
	userdata_starts ANDROID-DATA
	mode_is android
}

t_wipe_reinstalls_with_typed_wipe() {
	live_tablet
	setup install --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	setup wipe --yes --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 1
	out_has "typed confirmation (WIPE)"
	setup wipe --yes-wipe --channel samsung-gtactive3wifi_phosh_edge-dev
	rc_is 0
	st_is STAGE chain
	mode_is duranium
}

# ---------- update ----------

t_update_next_test_version() {
	new_tablet duranium; start_console
	mock 's["sh"]["versions"] = "26102213\n26102214~test1\n"'
	setup update --next-test-version
	rc_is 0
	[ "$(tail -1 "$CASE/out")" = "26102214~test2" ] || fail "next test version: $(tail -1 "$CASE/out")"
}

mk_test_build() { # DIR VERSION [OSREL-VERSION]
	local n=samsung-gtactive3wifi_phosh_edge
	mkdir -p "$1/$n"
	python3 "$MOCK/mkuki.py" "$1/$n/${n}_$2.efi" "${3:-$2}"
	echo usr > "$1/$n/${n}_$2.usr-arm64.abababababababababababababababab.raw"
	echo vty > "$1/$n/${n}_$2.usr-arm64-verity.abababababababababababababababab.raw"
}

t_update_test_build_one_off() {
	new_tablet duranium; start_console
	mk_test_build "$CASE/out-dir" "26102214~test1"
	setup update --test "$CASE/out-dir"
	rc_is 0
	out_has "26102214~test1 > booted 26102213 > published 26102213"
	grep -q 'duranium-update V=26102214~test1 UI=phosh EXTENSIONS=\[\]' "$CASE/state.json.calls" || fail "duranium-update call: $(cat "$CASE/state.json.calls")"
	st_is TEST_VERSIONS " 26102214~test1"
	[ "$(python3 -I "$REPO/scripts/installer/py/versions.py" cmp 26102214~test1 26102214)" = "<" ] || fail "~test must sort below"
}

t_update_test_refuses_relabelled_build() {
	new_tablet duranium; start_console
	mk_test_build "$CASE/out-dir" "26102214~test1" "26102214"
	setup update --test "$CASE/out-dir"
	rc_is 1
	out_has "never relabel a build"
	[ ! -s "$CASE/state.json.calls" ] || fail "duranium-update ran"
}

t_update_test_refuses_old_or_plain_versions() {
	new_tablet duranium; start_console
	mk_test_build "$CASE/out-dir" "26102212~test1"
	setup update --test "$CASE/out-dir" "26102212~test1"
	rc_is 1
	out_has "is not newer than the booted"
	mk_test_build "$CASE/out-dir" "26102299"
	setup update --test "$CASE/out-dir" "26102299"
	rc_is 1
	out_has "test builds need a version like"
}

t_update_test_detects_channel_change() {
	new_tablet duranium; start_console
	mk_test_build "$CASE/out-dir" "26102214~test1"
	cat > "$CASE/dur-update" <<-EOF
		#!/bin/sh
		python3 -c 'import json; p="$CASE/state.json"; s=json.load(open(p)); s["sh"]["remote"]="2222  -\n"; json.dump(s, open(p, "w"))'
	EOF
	chmod +x "$CASE/dur-update"
	EXTRA_ENV="GTA3_DURANIUM_UPDATE=$CASE/dur-update" setup update --test "$CASE/out-dir"
	rc_is 1
	out_has "update configuration changed"
}

t_update_official_over_console() {
	new_tablet duranium; start_console
	setup update --yes
	rc_is 0
	log_has "sh updatectl-check"
	log_has "sh updatectl-update"
	out_has "update installed"
}

# ---------- status ----------

t_status_in_every_mode() {
	new_tablet android; start_console
	setup status
	rc_is 0; out_has "SM-T570 (gtactive3wifi)"
	mock 's["mode"] = "download"'
	setup status
	rc_is 0; out_has "Download mode (heimdall sees the tablet)"
	mock 's["mode"] = "bringup"'
	setup status
	rc_is 0; out_has "live environment (our Linux)"; out_has "userdata /dev/sda31"
	mock 's["mode"] = "duranium"'
	setup status
	rc_is 0; out_has "Duranium (dev image, USB console)"; out_has "26102213 (phosh)"
	mock 's["mode"] = "off"'
	setup status
	rc_is 0; out_has "nothing on USB"
}

t_install_local_image_leaves_file_alone() {
	live_tablet
	cp "$IMG_RAW_FX" "$CASE/my.raw"
	before=$(sha256sum < "$CASE/my.raw")
	setup install --yes-wipe --image "$CASE/my.raw"
	rc_is 0
	out_has "using a local image without a signature check"
	[ "$(sha256sum < "$CASE/my.raw")" = "$before" ] || fail "the local image file was modified"
	dd if="$ROOT/dev/sda31" bs=4096 skip=1 count=1 status=none | head -c 8 | grep -q 'EFI PART' || fail "not written"
	st_is STAGE chain
}

t_prepare_builds_boot_images_without_tablet() {
	new_tablet off; start_console
	mkdir -p "$CASE/fw/brcm"
	for f in brcmfmac4375b1-pcie.samsung,gtactive3wifi.bin brcmfmac4375b1-pcie.samsung,gtactive3wifi.clm_blob \
		brcmfmac4375b1-pcie.samsung,gtactive3wifi.txt BCM.samsung,gtactive3wifi.hcd; do echo x > "$CASE/fw/brcm/$f"; done
	setup prepare --yes --stock-boot "$RUN/fx/stock/boot.img.lz4" --payload "$PAYLOAD_DIR" --firmware-dir "$CASE/fw"
	rc_is 0
	for f in boot-linux.img boot-chain.img; do [ -s "$CASE/st/boot/$f" ] || fail "no $f"; done
	python3 -I "$REPO/scripts/installer/py/bootimg.py" find "$CASE/st/boot/boot-chain.img" FAKE-UNILOADER-CHAIN || fail "chain image"
	python3 -I "$REPO/scripts/installer/py/bootimg.py" find "$CASE/st/boot/boot-linux.img" FAKE-UNILOADER-LINUX || fail "linux image"
	[ -s "$CASE/st/firmware/firmware.tar" ] || fail "firmware not packed"
	log_lacks flash
}
