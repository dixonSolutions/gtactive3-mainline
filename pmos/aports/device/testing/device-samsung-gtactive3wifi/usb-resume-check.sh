#!/bin/sh
# After resume: if the USB gadget was configured before sleep, wait for the
# host to enumerate it again. If that does not happen, reconnect it (soft
# disconnect/connect), then unbind and rebind the gadget from its UDC.
set -eu

[ "$(head -n1 /run/gtactive3wifi/udc-before 2>/dev/null)" = configured ] ||
	exit 0

udc=
for d in /sys/class/udc/*; do
	[ -e "$d/state" ] && udc=${d##*/} && break
done
[ -n "$udc" ] || { echo "no USB device controller after resume" >&2; exit 1; }

configured_within() {
	i=0
	while [ "$i" -lt "$1" ]; do
		[ "$(cat "/sys/class/udc/$udc/state")" = configured ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

configured_within 30 && exit 0

echo "$udc not enumerated after resume, reconnecting" >&2
echo disconnect > "/sys/class/udc/$udc/soft_connect"
sleep 1
echo connect > "/sys/class/udc/$udc/soft_connect"
configured_within 15 && exit 0

echo "$udc still not enumerated, rebinding its gadget" >&2
for g in /sys/kernel/config/usb_gadget/*/UDC; do
	[ "$(cat "$g" 2>/dev/null)" = "$udc" ] || continue
	echo > "$g"
	sleep 1
	echo "$udc" > "$g"
done
configured_within 15 && exit 0

echo "$udc did not come back after resume" >&2
exit 1
