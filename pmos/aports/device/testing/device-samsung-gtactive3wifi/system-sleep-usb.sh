#!/bin/sh
# systemd-sleep hook: remember the USB gadget state before sleep (DWC3
# disconnects for sleep and the host enumerates it again on resume), and
# afterwards let gtactive3wifi-usb-resume.service check that it
# came back: the development console lives on that link.
set -eu
state=/run/gtactive3wifi/udc-before

case "$1" in
pre)
	mkdir -p "${state%/*}"
	for s in /sys/class/udc/*/state; do
		if [ -r "$s" ]; then cat "$s"; fi
	done > "$state"
	;;
post)
	systemctl --no-block start gtactive3wifi-usb-resume.service
	;;
esac
