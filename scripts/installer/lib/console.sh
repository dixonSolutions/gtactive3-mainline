# shellcheck shell=bash
# The tablet's USB debug console (TCP 23 over USB NCM): the live
# environment (our bring-up Linux in BOOT) and Duranium dev images serve it.

con_py() { python3 -I "$INST/py/console.py" "$@"; }

# Prints "bringup" / "duranium VERSION VARIANT"; fails if nothing answers.
con_probe() { con_py probe 2>/dev/null; }
con_is_live() { [ "$(con_probe)" = bringup ]; }
con_is_duranium() { case $(con_probe) in duranium*) return 0 ;; esac; return 1; }
con_cmd() { con_py cmd "$@"; }

ncm_iface() {
	local d
	for d in /sys/class/net/*; do
		[ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = cdc_ncm ] &&
			{ basename "$d"; return 0; }
	done
	return 1
}

# Explain why the console does not answer (no USB network, link down, ...)
con_diagnose() {
	local i
	[ -n "${GTA3_CONSOLE_ADDR:-}" ] && { info "console address override: $GTA3_CONSOLE_ADDR"; return; }
	if ! i=$(ncm_iface); then
		info "No USB network from the tablet yet (no cdc_ncm interface on this PC)."
		info "Check the cable and that the tablet shows the white text console."
		return
	fi
	if ! ip link show "$i" 2>/dev/null | grep -q 'state UP\|LOWER_UP'; then
		warn "the tablet's USB network ($i) is down on this PC"
		if ask_yn "Bring $i up with sudo (ip link set $i up)?" y; then
			act "bring the USB network up" sudo ip link set "$i" up
		fi
	else
		info "USB network $i is up but nothing answers on port ${GTA3_CONSOLE_PORT:-23} yet."
	fi
}

# wait_live TIMEOUT: wait until the live environment answers
wait_live() {
	wait_for "the tablet's live environment (USB console)" \
		"$HINT_FORCE_RESTART If it ends up in Download mode, run ./setup.sh again." \
		"${1:-240}" con_is_live || { con_diagnose; return 1; }
	ok "live environment answers"
}

# Partition table of the main UFS LUN, from the tablet itself:
# fills PART_DEV[name]=/dev/sdaN and PART_BYTES[name]
declare -gA PART_DEV=() PART_BYTES=()
read_partitions() {
	local n ue name sz
	PART_DEV=() PART_BYTES=()
	for n in $(con_cmd "ls /sys/class/block" | tr -d '\r' | grep -E '^sda[0-9]+$' | sort -V); do
		ue=$(con_cmd "cat /sys/class/block/$n/uevent")
		name=$(printf '%s\n' "$ue" | sed -n 's/^PARTNAME=//p' | tr -d '\r' | tr '[:upper:]' '[:lower:]')
		[ -n "$name" ] || continue
		sz=$(con_cmd "cat /sys/class/block/$n/size" | tr -dc 0-9)
		PART_DEV[$name]=/dev/$n
		PART_BYTES[$name]=$(( ${sz:-0} * 512 ))
	done
	[ -n "${PART_DEV[userdata]:-}" ] || die "the tablet reports no userdata partition; is this an SM-T570?"
	dbg "partitions: $(for k in "${!PART_DEV[@]}"; do printf '%s=%s ' "$k" "${PART_DEV[$k]}"; done)"
}

# part NAME: the device of a partition, checked against the tablet's own name
part() {
	[ -n "${PART_DEV[$1]:-}" ] || read_partitions
	[ -n "${PART_DEV[$1]:-}" ] || die "the tablet has no partition named $1"
	printf '%s' "${PART_DEV[$1]}"
}

# con_put LOCAL|- NAME|PATH LEN [LABEL]: write to a partition (by GPT name)
# or a plain path, after the guard
con_put() {
	local src=$1 tgt=$2 len=$3 label=${4:-} dev name=
	case $tgt in
		/*) dev=$tgt ;;
		*) name=$tgt; dev=$(part "$name") ;;
	esac
	guard_console_write put "$dev" "$name"
	if dry; then
		act "write $(human_bytes "$len") to $dev${name:+ ($name)}" true
		return 0
	fi
	_log "put $src -> $dev ($len bytes)"
	[ "$(con_py put "$src" "$dev" "$len" "$label")" = "ok $len" ] ||
		die "writing $dev${name:+ ($name)} failed"
}

con_discard() {
	local name=$1 dev r
	dev=$(part "$name")
	guard_console_write discard "$dev" "$name"
	dry && { act "discard (erase) $dev ($name)" true; return 0; }
	_log "discard $dev ($name)"
	r=$(con_cmd "discard $dev" 600)
	printf '%s\n' "$r" | grep -q '^discarded' || die "erasing $name failed: $r"
	ok "$name erased ($(printf '%s' "$r" | tr -dc 0-9 | head -c 20) bytes)"
}

# Show text on the tablet's screen (the live environment's text console)
con_screen() {
	local t
	t=$(mktemp)
	printf '\n%s\n' "$@" > "$t"
	con_py put "$t" /dev/tty0 "$(stat -c %s "$t")" >/dev/null 2>&1 || true
	rm -f "$t"
}

# The gpio-keys input device (Power, Volume Up, ...)
keys_device() {
	local d=/proc/bus/input/devices ev
	ev=$(con_cmd "cat $d" | tr -d '\r' | awk '
		/^N: Name=/ { k = ($0 ~ /gpio[-_]keys/) }
		/^H: Handlers=/ && k { for (i = 1; i <= NF; i++) if ($i ~ /^event[0-9]+$/) { print $i; exit } }')
	printf '/dev/input/%s' "${ev:-event0}"
}

# confirm_on_tablet "what": Power = yes, Volume Up = no (Volume Up also
# makes the live environment restart into Download mode).
confirm_on_tablet() {
	local dev k
	dry && { act "ask for confirmation on the tablet: $1" true; return 0; }
	if [ "${GTA3_SKIP_TABLET_CONFIRM:-0}" = 1 ]; then
		warn "tablet confirmation skipped (GTA3_SKIP_TABLET_CONFIRM=1, testing only)"
		return 0
	fi
	dev=$(keys_device)
	con_screen "==============================================" \
		"  $1" "" "  Press POWER to confirm." \
		"  Press VOLUME UP to cancel (the tablet restarts" \
		"  into Download mode; nothing is changed)." \
		"=============================================="
	tablet_box "The screen asks you to confirm: $1" \
		"Press POWER on the tablet to confirm," \
		"or VOLUME UP to cancel (nothing is changed)."
	say "  Waiting for a key press on the tablet (2 minutes)..."
	k=$(con_py key "$dev" 120) || {
		info "The tablet went away (Volume Up restarts it into Download mode)."
		return 1
	}
	case $k in
		116) ok "confirmed on the tablet (Power)"; con_screen "  Confirmed. Working..."; return 0 ;;
		timeout) info "no key pressed on the tablet"; con_screen "  Timed out: nothing was changed."; return 1 ;;
		*) info "another key was pressed ($k): not confirmed"; con_screen "  Not confirmed: nothing was changed."; return 1 ;;
	esac
}
