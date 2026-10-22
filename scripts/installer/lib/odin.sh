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

# flash PART FILE [PART FILE ...]: one heimdall session, every partition guarded
flash() {
	local args=() p f r what=''
	while [ $# -ge 2 ]; do
		p=$1 f=$2
		shift 2
		guard_heimdall "$p" "$f"
		args+=("--$p" "$f")
		what="$what $p"
		dry || info "flashing $p <- $(basename "$f") ($(human_bytes "$(stat -c %s "$f")"), sha256 $(sha256sum "$f" | cut -c1-12))"
	done
	p=${what# }
	dry && { act "flash $p" heimdall flash "${args[@]}"; return 0; }
	_log "heimdall flash ${args[*]}"
	if ! r=$(heimdall flash "${args[@]}" 2>&1); then
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
