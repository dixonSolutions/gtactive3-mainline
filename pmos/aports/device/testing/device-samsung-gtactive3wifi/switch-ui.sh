#!/bin/sh
# Switch this tablet to another UI image (phosh, gnome, ...) with the normal
# A/B update: systemd-sysupdate with this image's transfer definitions, the
# UI (%W, os-release VARIANT_ID) replaced by the one asked for. The booted
# version stays as the fallback; reboot to start the new UI.
#
#   gtactive3wifi-switch-ui UI [systemd-sysupdate options]
#
# Never edit /etc/os-release for this: the next boot checks the image's
# base confext (/etc) against it, and a copy naming the old version makes
# /etc lose the new image's configuration (sshd, GDM, ... fail).
set -eu

ui=${1:-}
case $ui in
-h | --help) echo "usage: gtactive3wifi-switch-ui UI [systemd-sysupdate options] (UI: phosh, gnome)"; exit 0 ;;
"" | -* | *[!a-z0-9-]*) echo "usage: gtactive3wifi-switch-ui UI (phosh, gnome)" >&2; exit 1 ;;
esac
shift

# shellcheck source=/dev/null
. /usr/lib/os-release
if [ "$ui" = "$VARIANT_ID" ]; then
	echo "this image is already $ui; updates come with: updatectl update"
	exit 0
fi

defs=/run/gtactive3wifi/switch-ui.d
rm -rf "$defs"
mkdir -p "$defs"
for f in /usr/lib/sysupdate.d/* /etc/sysupdate.d/*; do
	[ -f "$f" ] || continue
	sed "s/%W/$ui/g" "$f" > "$defs/${f##*/}"
done
echo "switching from $VARIANT_ID to $ui (newest published version)"
/usr/lib/systemd/systemd-sysupdate --definitions="$defs" "$@" update
# the user asked for this UI: boot it by default from now on
/usr/libexec/gtactive3wifi/boot-default set "$ui"
