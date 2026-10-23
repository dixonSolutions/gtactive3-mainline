#!/bin/sh
# Keep systemd-boot's default on the owner's UI (phosh, gnome, ...), so an
# image of another UI on the ESP (a mistaken update, a test) never takes
# over the next boot. systemd-boot otherwise starts the highest version,
# whatever its UI, and `bootctl set-default` does not survive a reboot here
# (U-Boot keeps no EFI variables).
#
# The UI is /var/lib/gtactive3wifi/ui: written on the first boot from the
# booted image, changed only by gtactive3wifi-switch-ui (the user asking for
# another UI). The default is a pattern, so the newest version of that UI
# wins and boot counting still falls back between its A/B entries.
#
#   boot-default            (boot service) make loader.conf match the UI
#   boot-default set UI     record UI as the owner's choice, then the same
set -eu

pref=/var/lib/gtactive3wifi/ui
conf=/boot/loader/loader.conf

if [ "${1:-}" = set ]; then
	case ${2:-} in
	"" | -* | *[!a-z0-9-]*) echo "usage: boot-default set UI" >&2; exit 1 ;;
	esac
	mkdir -p "${pref%/*}"
	echo "$2" > "$pref.new" && mv -f "$pref.new" "$pref"
fi

if [ ! -s "$pref" ]; then
	# shellcheck source=/dev/null
	. /usr/lib/os-release
	mkdir -p "${pref%/*}"
	echo "$VARIANT_ID" > "$pref"
fi
ui=$(cat "$pref")
case $ui in
"" | -* | *[!a-z0-9-]*) echo "bad UI in $pref: $ui" >&2; exit 1 ;;
esac

want="default samsung-gtactive3wifi_${ui}_edge_*@main"
[ -f "$conf" ] || { echo "no $conf"; exit 0; }
if grep -qx "$want" "$conf" && [ "$(grep -c '^default' "$conf")" = 1 ]; then
	exit 0
fi
{ grep -v '^default' "$conf" || :; echo "$want"; } > "$conf.new"
sync "$conf.new" 2>/dev/null || sync
mv -f "$conf.new" "$conf"
sync
echo "boot default: newest $ui image"
