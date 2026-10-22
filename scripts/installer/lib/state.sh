# shellcheck shell=bash
# Where the installer keeps things, and its resumable state.
#
#   $STATE_DIR  ${XDG_STATE_HOME:-~/.local/state}/gtactive3-setup   (GTA3_STATE_DIR)
#     state.env      what has been done (KEY=value lines, see below)
#     log/           one log per run
#     stock/         your stock boot.img (+ recovery.img), the undo images
#     firmware/      vendor firmware extracted from your tablet / firmware
#     keys/          the local AVB key that signs the BOOT image footer
#     boot/          the BOOT images built for your tablet
#   $CACHE_DIR  ${XDG_CACHE_HOME:-~/.cache}/gtactive3-setup         (GTA3_CACHE_DIR)
#     images/, payload/, tools/   downloads (big; safe to delete)
#   Android backups go to ~/gtactive3-backups/<date>/ (GTA3_BACKUP_DIR) by
#   default, because they are yours to keep.
#
# Nothing here is ever uploaded. Firmware, the stock images and the backups
# are Samsung's / yours: never share or commit them.
#
# state.env keys:
#   STAGE         new | android | unlocked | live | installed | chain
#   BOOT_NOW      stock | linux | chain   (what the BOOT partition holds)
#   ANDROID_DATA  intact | erased | formatted   (Android userdata)
#   ANDROID_OS    intact | erased               (super)
#   DEVICE_ID     sha256 of the serial number (never the serial itself)
#   PDA, BOOTLOADER, HWREV, KG
#   STOCK_BOOT, STOCK_BOOT_SHA, STOCK_RECOVERY, FIRMWARE_TAR, FIRMWARE_SHA
#   BOOT_LINUX, BOOT_CHAIN, PAYLOAD_VERSION
#   ANDROID_BACKUP (raw backup dir), FILES_BACKUP (adb backup dir)
#   CHANNEL, VERSION (installed image)

STATE_DIR=${GTA3_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gtactive3-setup}
CACHE_DIR=${GTA3_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gtactive3-setup}
BACKUP_ROOT=${GTA3_BACKUP_DIR:-$HOME/gtactive3-backups}
STATE_FILE=$STATE_DIR/state.env

state_init() {
	mkdir -p "$STATE_DIR/log" "$CACHE_DIR"
	chmod 700 "$STATE_DIR"
	[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
	LOG_FILE=$STATE_DIR/log/setup-$(date +%Y%m%d-%H%M%S).log
	: > "$LOG_FILE"
}

state_get() {
	local v
	v=$(sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1)
	printf '%s' "${v:-${2:-}}"
}

state_set() {
	local k=$1 v=$2 t
	case $v in *$'\n'*) die "state value for $k has a newline" ;; esac
	if dry; then
		_log "[dry-run] state $k=$v"
		return 0
	fi
	t=$(mktemp "$STATE_DIR/.state.XXXXXX")
	grep -v "^$k=" "$STATE_FILE" > "$t" || true
	printf '%s=%s\n' "$k" "$v" >> "$t"
	mv -f "$t" "$STATE_FILE"
	_log "state $k=$v"
}

state_show() {
	if [ -s "$STATE_FILE" ]; then
		sed 's/^/    /' "$STATE_FILE"
	else
		echo "    (nothing yet)"
	fi
}
