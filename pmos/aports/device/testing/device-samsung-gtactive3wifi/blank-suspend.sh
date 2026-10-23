#!/bin/sh
# Screen off = suspend, like a phone (SM-T570). Phosh keeps the power key
# for itself (a short press only blanks and locks the screen) and the idle
# blank never leads to sleep unless gsd-power's own timer is on, so the
# tablet stayed awake with the screen off. Watch the shell's display power
# state (org.gnome.Mutter.DisplayConfig PowerSaveMode: Phosh and Mutter
# both publish it, for the power key and for the idle blank) and suspend
# GRACE seconds after the screen went off, unless it came back on or an
# application inhibits suspend (gnome-session flag 4; logind refuses on its
# own while a block inhibitor is held). After a wake-up that left the screen
# off (an alarm, the charger) sleep again after RECHECK seconds.
set -u

GRACE=${GTA3_BLANK_SUSPEND_GRACE:-2}
RECHECK=${GTA3_BLANK_SUSPEND_RECHECK:-60}
DC="--session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig"
gen=${XDG_RUNTIME_DIR:-/tmp}/gtactive3wifi-blank-suspend.gen

screen_off() {
	gdbus call $DC --method org.freedesktop.DBus.Properties.Get \
		org.gnome.Mutter.DisplayConfig PowerSaveMode 2>/dev/null |
		grep -q '<[1-9]'
}

# $1 = generation that asked, $2 = seconds the screen has to stay off
try_suspend() {
	sleep "$2"
	[ "$(cat "$gen" 2>/dev/null)" = "$1" ] || return 0
	screen_off || return 0
	if gdbus call --session --dest org.gnome.SessionManager \
		--object-path /org/gnome/SessionManager \
		--method org.gnome.SessionManager.IsInhibited 4 2>/dev/null |
		grep -q true; then
		echo "screen off, but an application inhibits suspend"
		return 0
	fi
	echo "screen off for $2 s: suspending"
	gdbus call --system --dest org.freedesktop.login1 \
		--object-path /org/freedesktop/login1 \
		--method org.freedesktop.login1.Manager.Suspend false >/dev/null ||
		echo "logind refused to suspend"
}

n=0
echo $n > "$gen"
{
	gdbus monitor $DC &
	gdbus monitor --system --dest org.freedesktop.login1 \
		--object-path /org/freedesktop/login1 &
	wait
} | while read -r line; do
	case $line in
	*"'PowerSaveMode': <0>"* | *"PrepareForSleep (true,)"*)
		n=$((n + 1)); echo $n > "$gen" ;;
	*"'PowerSaveMode': <"*)
		n=$((n + 1)); echo $n > "$gen"; try_suspend $n "$GRACE" & ;;
	*"PrepareForSleep (false,)"*)
		n=$((n + 1)); echo $n > "$gen"; try_suspend $n "$RECHECK" & ;;
	esac
done
