#!/bin/sh
# Allow suspend for this boot only if the kernel can suspend to idle, the
# power key is an armed wake-up source and the wake-up path has been proven
# on this tablet (marker written after the on-device suspend test).
# Otherwise suspend stays off (sleep.conf.d/50-gtactive3wifi.conf): a sleep the
# user cannot end would strand the tablet until a forced reset.
set -eu

marker=/var/lib/gtactive3wifi/suspend-wake-proven
key=/sys/devices/platform/gpio-keys/power/wakeup
drop=/run/systemd/sleep.conf.d/60-gtactive3wifi-gate.conf

reason=
if ! grep -qw freeze /sys/power/state 2>/dev/null; then
	reason="the kernel cannot suspend to idle"
elif [ "$(cat "$key" 2>/dev/null)" != enabled ]; then
	reason="the power key is not a wake-up source ($key)"
elif [ ! -e "$marker" ]; then
	reason="the wake-up path has not been proven on this tablet ($marker)"
fi

if [ -n "$reason" ]; then
	rm -f "$drop"
	echo "suspend stays disabled: $reason"
	exit 0
fi

mkdir -p "${drop%/*}"
printf '[Sleep]\nAllowSuspend=yes\n' > "$drop"
echo "suspend allowed (wake-up path proven: $(head -n1 "$marker"))"
