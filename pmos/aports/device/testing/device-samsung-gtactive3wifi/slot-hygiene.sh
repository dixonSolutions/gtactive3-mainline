#!/bin/sh
# Keep the A/B usr slots honest for systemd-sysupdate. Partition labels are
# duranium_<version>_usr / _vty, without the UI: a GNOME 26102219 slot looks
# like an installed Phosh 26102219, so updating Phosh to 26102219 wrote only
# the UKI, whose usrhash then named partitions that were not there (the
# initrd found no /usr: emergency mode, 2026-10-23).
#
# So, before every update (and at boot): a usr/verity partition that neither
# the running system nor any UKI of the running UI on the ESP uses is
# labelled "_empty" (sysupdate's free slot; the data and PARTUUID stay, so
# an entry still pointing at it keeps booting until it is overwritten), and
# a UKI whose usr or verity partition no longer exists is removed (it can
# only end in emergency mode).
set -eu

# DRY=1: only say what would change
run() { if [ -n "${DRY:-}" ]; then echo "would: $*"; else "$@"; fi; }

esp=/boot/EFI/Linux
. /usr/lib/os-release
ui=$VARIANT_ID

disk=/dev/$(lsblk -no PKNAME /dev/disk/by-partlabel/esp | head -n1)
[ -b "$disk" ] || { echo "no ESP disk"; exit 0; }
[ -d "$esp" ] || { echo "no $esp"; exit 0; }

uuid() { # 32 hex -> 8-4-4-4-12, lower case
	echo "$1" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/' | tr 'A-F' 'a-f'
}
hash_of() { # UKI -> usrhash (64 hex)
	grep -a -o -m1 'usrhash=[0-9a-f]\{64\}' "$1" | head -n1 | cut -d= -f2
}

parts=$(sfdisk -l -o Device,Name,UUID "$disk" | awk -v d="$disk" 'index($1, d) == 1 { print $1, $2, tolower($3) }')

keep=
h=$(sed -n 's/.*usrhash=\([0-9a-f]\{64\}\).*/\1/p' /proc/cmdline)
[ -z "$h" ] || keep="$keep $(uuid "$(echo "$h" | cut -c1-32)") $(uuid "$(echo "$h" | cut -c33-64)")"

for f in "$esp"/*.efi; do
	[ -f "$f" ] || continue
	h=$(hash_of "$f")
	[ -n "$h" ] || continue
	u=$(uuid "$(echo "$h" | cut -c1-32)")
	v=$(uuid "$(echo "$h" | cut -c33-64)")
	if ! echo "$parts" | grep -q " $u\$" || ! echo "$parts" | grep -q " $v\$"; then
		# never the running entry (its partitions exist by definition)
		run rm -f "$f" && echo "removed ${f##*/}: its system is not on this tablet"
		continue
	fi
	case ${f##*/} in
	samsung-gtactive3wifi_"$ui"_edge_*) keep="$keep $u $v" ;;
	esac
done

echo "$parts" | while read -r dev name id; do
	case $name in
	duranium_*_usr | duranium_*_vty) ;;
	*) continue ;;
	esac
	case " $keep " in *" $id "*) continue ;; esac
	n=$(echo "$dev" | sed 's/.*[^0-9]//')
	run sfdisk -q --no-reread --part-label "$disk" "$n" _empty &&
		echo "$dev ($name): not used by $ui, marked free for the next update"
done
sync
