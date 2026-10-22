# shellcheck shell=bash
# Samsung Download mode (USB 04e8:685d) and heimdall.

in_download() {
	lsusb 2>/dev/null | grep -qi '04e8:685d' || return 1
	heimdall detect >/dev/null 2>&1
}

download_explain() {
	tablet_box "Download mode" \
		"A blue/black screen \"Downloading... Do not turn off target\"." \
		"If a warning \"A custom OS can cause critical problems\" comes" \
		"first: press Volume Up to continue." \
		"Read the small text at the top: if it says KG STATE: Prenormal," \
		"stop here (see the KnoxGuard notes in docs/INSTALL.md)."
}

# wait_download TIMEOUT: wait for Download mode, explaining how to get there
wait_download() {
	download_explain
	wait_for "the tablet in Download mode (USB 04e8:685d)" "$HINT_DOWNLOAD" "${1:-180}" in_download ||
		return 1
	ok "Download mode"
}

# PIT partition names as the tablet reports them
pit_names() {
	heimdall print-pit --no-reboot 2>/dev/null | sed -n 's/^Partition Name: *//p' | tr -d '\r'
}

# pit_check: BOOT must exist with the size we build for
pit_check() {
	local pit blocks
	dry && return 0
	pit=$(heimdall print-pit --no-reboot 2>/dev/null) || { warn "could not read the partition table (PIT)"; return 0; }
	printf '%s\n' "$pit" | grep -q '^Partition Name: *BOOT$' ||
		die "the tablet's partition table has no BOOT partition: not an SM-T570?"
	blocks=$(printf '%s\n' "$pit" | awk '/^Partition Block Count:/ { c = $NF } /^Partition Name: *BOOT$/ { print c; exit }')
	[ -z "$blocks" ] || [ $((blocks * 4096)) = "$BOOT_PART_BYTES" ] ||
		warn "BOOT is $((blocks * 4096)) bytes on this tablet (expected $BOOT_PART_BYTES)"
	# heimdall print-pit ends the session; the tablet needs a moment
	sleep "${GTA3_PIT_SETTLE:-3}"
}

# flash PART FILE [--no-reboot]: one partition, guarded
flash() {
	local p=$1 f=$2 r
	shift 2
	guard_heimdall "$p" "$f"
	info "flashing $p <- $(basename "$f") ($(human_bytes "$(stat -c %s "$f")"), sha256 $(sha256sum "$f" | cut -c1-12))"
	dry && { act "heimdall flash --$p" heimdall flash "--$p" "$f" "$@"; return 0; }
	_log "heimdall flash --$p $f $*"
	if ! r=$(heimdall flash "--$p" "$f" "$@" 2>&1); then
		printf '%s\n' "$r" >> "$LOG_FILE"
		err "heimdall could not flash $p"
		printf '%s\n' "$r" | tail -5 >&2
		box "If the tablet shows \"An error has occurred while updating\"" \
			"KnoxGuard may block custom images (KG STATE: Prenormal), or the" \
			"USB link dropped. Download mode itself is always reachable:" \
			"Power + Volume Down 7-10 s, then Volume Up + Volume Down while" \
			"plugging in USB. Then: another USB port/cable, ./setup.sh again," \
			"or ./setup.sh undo to put your stock boot image back."
		return 1
	fi
	printf '%s\n' "$r" >> "$LOG_FILE"
	ok "$p flashed"
}
