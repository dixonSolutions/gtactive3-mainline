#!/bin/sh
# Bring the BCM4375 Wi-Fi back when its firmware dies for good.
#
# After a firmware crash the chip can end up in a state that no reset over
# PCIe clears: brcmfmac's own reset and a full driver reload both fail with
# "FW failed to initialize" (and a firmware trap at start-up), minutes later,
# and the driver lets go of the chip (measured 2026-10-24). Only cutting
# WLAN_REG_ON brings it back. That regulator belongs to the PCIe controller
# driver (vpcie3v3), so reload pcie_exynos9810 with brcmfmac unloaded: the
# chip powers off, the link retrains, and brcmfmac probes a fresh chip.
#
# Acts only when the chip is present but no driver holds it (or the chip
# has fallen off the bus) while brcmfmac is loaded and idle: a brcmfmac
# that the user or the sleep hook unloaded is left alone, and so is a
# re-init still in progress (its async firmware request pins the module;
# removing the device under it would free memory it still uses).
set -u
lock=/run/gtactive3wifi/wifi.lock
asleep=/run/gtactive3wifi/brcmfmac-unloaded
log=/run/gtactive3wifi/wifi-recover.log
interval=15
# at most $burst power cycles within $window seconds, then give up until
# the next boot (a chip that never comes back must not loop forever)
burst=3
window=1800

say() { echo "wifi-recover: $*"; }

chip() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x14e4 ] || continue
		case "$(cat "$d/class" 2>/dev/null)" in 0x0280*) echo "$d"; return 0 ;; esac
	done
	return 1
}

# brcmfmac loaded and not pinned by anything but its own helper modules
brcmfmac_idle() {
	local refs holders
	[ -r /sys/module/brcmfmac/refcnt ] || return 1
	refs=$(cat /sys/module/brcmfmac/refcnt)
	holders=$(ls /sys/module/brcmfmac/holders 2>/dev/null | wc -l)
	[ "$refs" -le "$holders" ]
}

# prints why Wi-Fi needs a power cycle, or fails if it does not
broken() {
	local d
	[ -e "$asleep" ] && return 1
	brcmfmac_idle || return 1
	if ! d=$(chip); then
		[ -d /sys/module/pcie_exynos9810 ] || return 1
		echo "the Wi-Fi chip is gone from the PCIe bus"
		return 0
	fi
	[ -e "$d/driver" ] && return 1
	echo "brcmfmac let go of the Wi-Fi chip ($(basename "$d"))"
}

power_cycle() {
	local d i
	say "power-cycling the Wi-Fi chip"
	# its vendor modules (brcmfmac_wcc, ...) first
	modprobe -r $(ls /sys/module/brcmfmac/holders) brcmfmac ||
		{ say "brcmfmac is busy, retrying later"; return 1; }
	if [ -d /sys/module/pcie_exynos9810 ]; then
		modprobe -r pcie_exynos9810 || { say "cannot unload pcie_exynos9810"; modprobe brcmfmac; return 1; }
		sleep 1
		modprobe pcie_exynos9810
	elif d=$(chip); then
		# built-in controller: no power cut, a re-enumeration at least
		echo 1 > "$d/remove"
		sleep 1
		echo 1 > /sys/bus/pci/rescan
	fi
	modprobe brcmfmac
	for i in $(seq 30); do
		if d=$(chip) && ls "$d"/net/* >/dev/null 2>&1; then
			say "Wi-Fi is back ($(basename "$(ls -d "$d"/net/* | head -1)")) after ${i}s"
			return 0
		fi
		sleep 1
	done
	say "no Wi-Fi interface 30 s after the power cycle"
	return 1
}

mkdir -p "${lock%/*}"
: > "$log"
seen=0
while :; do
	sleep "$interval"
	if ! why=$(broken); then
		seen=0
		continue
	fi
	# the same state twice in a row: not a probe or an unbind in passing
	seen=$((seen + 1))
	[ "$seen" -ge 2 ] || continue
	seen=0
	now=$(cut -d. -f1 /proc/uptime)
	recent=$(awk -v t=$((now - window)) '$1 >= t' "$log" | wc -l)
	if [ "$recent" -ge "$burst" ]; then
		say "$why; $burst power cycles in the last $((window / 60)) min, giving up until reboot"
		exit 0
	fi
	echo "$now" >> "$log"
	say "$why"
	exec 9> "$lock"
	flock 9
	why=$(broken) && power_cycle
	exec 9>&-
done
