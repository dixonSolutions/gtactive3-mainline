#!/bin/sh
# gtactive3wifi-claim-android-space: turn the space of Android's operating
# system into encrypted storage for Duranium. Opt-in, run it by hand.
#
#   gtactive3wifi-claim-android-space [--with-prism] [--containers]
#                                      [--user NAME] [--no-home-link] [--dry-run]
#   gtactive3wifi-claim-android-space --status
#   gtactive3wifi-claim-android-space --undo [--wipe]
#
# Duranium lives in Android's userdata partition (a GPT nested in it), so
# Android's own OS partitions stay on the UFS unused:
#   super  7.13 GB  system, vendor, product (dynamic partitions)
#   prism  0.63 GB  Samsung CSC data
# Claiming them ERASES ANDROID'S OPERATING SYSTEM: afterwards only flashing
# the complete stock firmware (Odin: BL, AP, CP, HOME_CSC) brings Android
# back; "./setup.sh restore-android" and Samsung's recovery cannot.
#
# Only partitions named super and prism (GPT name, read from sysfs and
# checked against /dev/disk/by-partlabel, on the UFS disk sda) are ever
# written; every write re-checks the name. EFS, param, persistent, steady,
# keydata/keyrefuge, the bootloaders, up_param, BOOT/RECOVERY, dtbo,
# vbmeta, optics, userdata (Duranium itself) and everything else are never
# touched. A partition that is held (dm/loop), mounted or used as swap, or
# whose size is not the SM-T570's, is refused.
#
# Layout (and why):
# - super alone by default: one LUKS2 volume with ext4, mounted on
#   /var/mnt/android-space, a directory in it for the user, linked as
#   ~/android-space. ext4 like the root (e2fsprogs is in every Duranium
#   image, fsck at boot); one partition, so no LVM (not in the image) and no
#   device-mapper concatenation to set up before cryptsetup at every boot.
# - prism only with --with-prism, as a second, separate volume on
#   /var/mnt/android-space-prism: prism is a chained partition in the
#   stock vbmeta, and S-Boot reads its AVB footer and vbmeta at every
#   start (with that metadata gone, libavb stops with INVALID_METADATA even
#   when unlocked: Odin mode). So its filesystem ends before prism's
#   vbmeta (ext4 with a fixed size, no discard), the tail is saved and
#   checked byte for byte after formatting, and a prism without a valid
#   AVB footer is refused. Spanning both partitions with one filesystem
#   would let a later resize or balance reach the footer; 0.6 GB is not
#   worth that risk.
# - The same passphrase as the disk (checked against the root's LUKS with
#   --test-passphrase before anything is changed): keyslot 0, argon2id,
#   needed only if the root is ever recreated (factory reset), then
#   "gtactive3wifi-claim-android-space" again re-attaches without
#   formatting. If the disk has no passphrase you choose one.
# - Unlocked at every start with a key file on the already unlocked
#   encrypted root (/var/lib/gtactive3wifi/android-space.key, 0400, keyslot
#   1, PBKDF2 at 1000 iterations: 4 KiB of random data needs no key
#   stretching, and the start stays fast), through /etc/crypttab (by LUKS
#   UUID; nofail, headless, x-systemd.device-timeout=10s) and /etc/fstab
#   (nofail, x-systemd.device-timeout=10s). A missing or broken volume
#   never blocks or prompts at boot. The empty mount point is chattr +i, so
#   nothing writes to the root by mistake while the volume is missing.
# - /etc is a confext overlay: the edited crypttab and fstab become copies
#   in its mutable layer (/var/lib/extensions.mutable/etc) that shadow the
#   image's versions from then on. The lines are kept in a marked block;
#   everything else in the files is preserved; --undo removes the block.
# - --containers (not the default): podman's storage (images, containers,
#   distrobox) of the user moves to the Android space via
#   ~/.config/containers/storage.conf (graphroot). Containers then need the
#   volume (if it is missing podman fails instead of filling the root);
#   images and containers in the old store (~/.local/share/containers) are
#   not moved (podman save/load, or pull again; remove the old store with
#   "podman system reset" before, as the user); the preinstalled Alpine
#   image is loaded again at the next login. Refused if the user already
#   has a storage.conf.
#
# --status shows the partitions and entries. --undo unmounts, closes,
# removes the crypttab/fstab blocks, the key file's keyslot, the key file,
# the home link and the containers setting; the data stays and the
# passphrase still opens it. --undo --wipe also erases the LUKS keyslots
# and signatures (type WIPE): the data is gone for good.
#
# Must run as root in a terminal; for tests: --yes
# --i-understand-android-is-gone --passphrase-file FILE (line 1: the disk
# passphrase; if that is empty, line 2: the new one).
# GTA3_CLAIM_ROOT (tests only) prefixes /sys, /dev, /proc, /etc, /var,
# /run and /home.
set -eu

R=${GTA3_CLAIM_ROOT:-}
PROG=gtactive3wifi-claim-android-space
MARK=$PROG
STATE=/var/lib/gtactive3wifi
KEY=$STATE/android-space.key
CONF=$STATE/android-space.conf
AVB_SAVE=$STATE/prism-avb
CRYPTTAB=/etc/crypttab
FSTAB=/etc/fstab
CONFIRM=ERASE-ANDROID
# LUKS2 data offset (16 MiB, --offset is in 512-byte sectors)
DATA_OFFSET=16777216
MIB=1048576

die() { echo "$PROG: $*" >&2; exit 1; }
say() { echo "$*"; }

usage() {
	sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

# ---------- the two partitions this tool may ever write ----------

# part_info NAME: sets P_MAP P_LUKS P_FS P_MNT P_MIN P_MAX
part_info() {
	case $1 in
	super)
		P_MAP=android-space P_LUKS=gta3-android-space P_FS=android-space
		P_MNT=/var/mnt/android-space P_MIN=6400000000 P_MAX=7900000000 ;;
	prism)
		P_MAP=android-space-prism P_LUKS=gta3-android-space-prism P_FS=android-prism
		P_MNT=/var/mnt/android-space-prism P_MIN=560000000 P_MAX=700000000 ;;
	*) die "internal error: $1 is not a partition this tool may touch" ;;
	esac
}

uevent_get() { sed -n "s/^$2=//p" "$R/sys/class/block/$1/uevent" 2>/dev/null; }

# find_part NAME: the one sdaN whose GPT name is NAME (sysfs), and
# /dev/disk/by-partlabel/NAME must point to it
find_part() {
	fp_found=
	for fp_u in "$R"/sys/class/block/*/uevent; do
		[ -f "$fp_u" ] || continue
		grep -qx "PARTNAME=$1" "$fp_u" || continue
		grep -qx "DEVTYPE=partition" "$fp_u" || continue
		fp_dev=$(sed -n 's/^DEVNAME=//p' "$fp_u")
		case $fp_dev in
		sda[1-9] | sda[1-9][0-9] | sda[1-9][0-9][0-9]) ;;
		*) continue ;; # another disk (microSD, loop, nested GPT): never ours
		esac
		[ -z "$fp_found" ] || die "two partitions named $1 on the UFS ($fp_found, $fp_dev): refusing"
		fp_found=$fp_dev
	done
	[ -n "$fp_found" ] || die "no partition named $1 on the UFS (sda)"
	fp_link=$R/dev/disk/by-partlabel/$1
	[ -L "$fp_link" ] || die "$fp_link is missing: refusing"
	fp_t=$(readlink -f "$fp_link")
	[ "${fp_t##*/}" = "$fp_found" ] ||
		die "$fp_link points to ${fp_t##*/}, sysfs says $fp_found: refusing"
	echo "$fp_found"
}

# guard DEV NAME: right before every write: DEV is sdaN and still named NAME
guard() {
	case $2 in super | prism) ;; *) die "refusing to write $1: only super and prism" ;; esac
	case $1 in
	"$R"/dev/sda[1-9] | "$R"/dev/sda[1-9][0-9] | "$R"/dev/sda[1-9][0-9][0-9]) ;;
	*) die "refusing to write $1: not a partition of the UFS" ;;
	esac
	[ "$(uevent_get "${1##*/}" PARTNAME)" = "$2" ] || die "refusing to write $1: it is not named $2"
}

part_bytes() { echo $(($(cat "$R/sys/class/block/$1/size") * 512)); }

# in_use DEV: prints why and succeeds if anything uses the partition
in_use() {
	iu_h=$(ls -A "$R/sys/class/block/$1/holders" 2>/dev/null || true)
	[ -z "$iu_h" ] || { echo "held by $(echo "$iu_h" | tr '\n' ' ')"; return 0; }
	iu_mm=$(uevent_get "$1" MAJOR):$(uevent_get "$1" MINOR)
	if awk -v mm="$iu_mm" '$3 == mm { f = 1 } END { exit !f }' "$R/proc/self/mountinfo" 2>/dev/null; then
		echo mounted; return 0
	fi
	if grep -q "^/dev/$1[[:space:]]" "$R/proc/swaps" 2>/dev/null; then
		echo "used as swap"; return 0
	fi
	for iu_b in "$R"/sys/block/loop*/loop/backing_file; do
		[ -f "$iu_b" ] || continue
		if [ "$(cat "$iu_b")" = "/dev/$1" ]; then
			iu_b=${iu_b%/loop/backing_file}
			echo "backs ${iu_b##*/}"; return 0
		fi
	done
	return 1
}

# hex DEV BS SKIP N: N bytes at block SKIP (of BS bytes) as hex
hex() { dd if="$1" bs="$2" skip="$3" count=1 2>/dev/null | head -c "$4" | od -An -v -tx1 | tr -d ' \n'; }
hexcut() { printf '%s' "$1" | cut -c"$2"; }

# avb_footer DEV SIZE: sets AVB_VBOFF AVB_VBSIZE if prism carries a valid
# AVB footer (last 64 bytes: "AVBf", major, minor, original size, vbmeta
# offset, vbmeta size; big-endian) pointing to a vbmeta ("AVB0")
avb_footer() {
	af_h=$(hex "$1" 64 $(($2 / 64 - 1)) 64)
	[ "${#af_h}" = 128 ] || return 1
	[ "$(hexcut "$af_h" 1-8)" = 41564266 ] || return 1
	[ "$(hexcut "$af_h" 9-16)" = 00000001 ] || return 1
	# below 2^63, or the shell's arithmetic turns negative
	case $(hexcut "$af_h" 41)$(hexcut "$af_h" 57) in *[89a-f]*) return 1 ;; esac
	AVB_VBOFF=$((0x$(hexcut "$af_h" 41-56)))
	AVB_VBSIZE=$((0x$(hexcut "$af_h" 57-72)))
	[ "$AVB_VBOFF" -gt 0 ] && [ $((AVB_VBOFF % 4096)) = 0 ] || return 1
	[ "$AVB_VBSIZE" -gt 0 ] && [ "$AVB_VBSIZE" -le "$MIB" ] || return 1
	[ $((AVB_VBOFF + AVB_VBSIZE)) -le $(($2 - 64)) ] || return 1
	[ "$(hex "$1" 4096 $((AVB_VBOFF / 4096)) 4)" = 41564230 ] || return 1
}

# prism_end: where prism's filesystem must end, 1 MiB or more before the vbmeta
prism_end() { echo $(((AVB_VBOFF / MIB - 1) * MIB)); }
tail_sum() { dd if="$1" bs="$MIB" skip=$(($2 / MIB)) 2>/dev/null | sha256sum | cut -d' ' -f1; }

luks_label() { blkid -p -o export "$1" 2>/dev/null | sed -n 's/^LABEL=//p'; }
luks_type() { blkid -p -o export "$1" 2>/dev/null | sed -n 's/^TYPE=//p'; }
has_android_lp() { [ "$(hex "$1" 4096 1 4)" = 67446c61 ]; } # LP geometry "gDla"
gb() { awk -v b="$1" 'BEGIN { printf "%.2f GB", b / 1e9 }'; }

# ---------- passphrase ----------

read_secret() { # PROMPT: the answer in SECRET (--passphrase-file: its next line)
	SECRET=
	if [ -n "$PASSFILE" ]; then
		IFS= read -r SECRET <&8 || true
		return 0
	fi
	printf '%s' "$1" >&2
	stty -echo 2>/dev/null || true
	IFS= read -r SECRET || true
	stty echo 2>/dev/null || true
	echo >&2
}

test_pass() { printf '%s' "$1" | cryptsetup open --test-passphrase --key-file=- "$2" >/dev/null 2>&1; }

root_luks_dev() {
	rl_src=$(findmnt -n -o SOURCE / 2>/dev/null) || return 1
	case $rl_src in /dev/mapper/?*) ;; *) return 1 ;; esac
	cryptsetup status "${rl_src#/dev/mapper/}" 2>/dev/null | awk '$1 == "device:" { print $2; exit }'
}

# get_pass CHECKDEV WHAT: PASS = a passphrase that opens CHECKDEV (or a new
# one when the disk has none)
get_pass() {
	gp_try=0
	while [ "$gp_try" -lt 3 ]; do
		gp_try=$((gp_try + 1))
		read_secret "$2 (Enter if you never set one): "
		PASS=$SECRET
		if [ -z "$PASS" ]; then
			say "No disk passphrase: choose one for the Android space (needed only if the root"
			say "is ever recreated; at every start the key file on the root unlocks it)."
			read_secret "New passphrase: "
			PASS=$SECRET
			[ -n "$PASS" ] || die "an empty passphrase is not possible here"
			[ -n "$PASSFILE" ] || { read_secret "Again: "; [ "$SECRET" = "$PASS" ] || die "the passphrases differ"; }
			return 0
		fi
		test_pass "$PASS" "$1" && return 0
		say "That passphrase does not open $1."
		[ -z "$PASSFILE" ] || break
	done
	die "no matching passphrase, nothing was changed"
}

# ---------- /etc/crypttab, /etc/fstab ----------

strip_block() {
	[ -f "$1" ] || return 0
	awk -v m="$MARK" 'index($0, "# >>> " m) == 1 { s = 1; next }
		index($0, "# <<< " m) == 1 { s = 0; next } !s' "$1"
}

# set_block FILE LINES (empty LINES: remove the block)
set_block() {
	sb_f=$R$1
	[ -n "$2" ] || [ -f "$sb_f" ] || return 0
	mkdir -p "${sb_f%/*}"
	{
		strip_block "$sb_f"
		if [ -n "$2" ]; then
			echo "# >>> $MARK (\"$PROG --undo\" removes this block)"
			printf '%s\n' "$2"
			echo "# <<< $MARK"
		fi
	} > "$sb_f.$PROG.new"
	chmod 644 "$sb_f.$PROG.new"
	mv -f "$sb_f.$PROG.new" "$sb_f"
}

block_lines() { [ -f "$R$1" ] && awk -v m="$MARK" 'index($0, "# >>> " m) == 1 { s = 1; next }
		index($0, "# <<< " m) == 1 { s = 0; next } s' "$R$1"; }

conf_get() { sed -n "s/^$1=//p" "$R$CONF" 2>/dev/null | head -n1; }

unit_crypt() { echo "systemd-cryptsetup@$(systemd-escape "$1").service"; }
unit_mount() { systemd-escape -p --suffix=mount "$1"; }

# ---------- options ----------

MODE=claim WITH_PRISM=0 CONTAINERS=0 HOME_LINK=1 DRY=0 YES=0 GONE=0 WIPE=0
USER_NAME= PASSFILE=
while [ $# -gt 0 ]; do
	case $1 in
	--status) MODE=status ;;
	--undo) MODE=undo ;;
	--wipe) WIPE=1 ;;
	--with-prism) WITH_PRISM=1 ;;
	--containers) CONTAINERS=1 ;;
	--no-home-link) HOME_LINK=0 ;;
	--user) [ $# -ge 2 ] || usage 1; USER_NAME=$2; shift ;;
	--user=*) USER_NAME=${1#*=} ;;
	--dry-run) DRY=1 ;;
	--yes) YES=1 ;;
	--i-understand-android-is-gone) GONE=1 ;;
	--passphrase-file) [ $# -ge 2 ] || usage 1; PASSFILE=$2; shift ;;
	-h | --help) usage 0 ;;
	*) echo "$PROG: unknown option $1" >&2; usage 1 ;;
	esac
	shift
done

is_root() { [ "$(id -u)" = 0 ]; }

[ -z "$PASSFILE" ] || exec 8< "$PASSFILE"
if [ -t 0 ]; then
	# never leave the terminal without echo
	trap 'stty echo 2>/dev/null || true' EXIT
	trap 'exit 130' INT TERM
fi

# ---------- --status ----------

status() {
	say "Android space ($PROG)"
	for st_n in super prism; do
		part_info "$st_n"
		st_d=$( (find_part "$st_n") 2>/dev/null) || { say "  $st_n: not found"; continue; }
		st_dev=$R/dev/$st_d
		st_line="  $st_n  /dev/$st_d  $(gb "$(part_bytes "$st_d")")"
		if ! is_root; then
			say "$st_line  (run as root for details)"
			continue
		fi
		if [ "$(luks_type "$st_dev")" = crypto_LUKS ] && [ "$(luks_label "$st_dev")" = "$P_LUKS" ]; then
			st_line="$st_line  claimed: LUKS2 $P_LUKS"
			if [ -e "$R/dev/mapper/$P_MAP" ]; then
				st_line="$st_line, open as $P_MAP"
			else
				st_line="$st_line, not open"
			fi
			if mountpoint -q "$R$P_MNT" 2>/dev/null; then
				st_line="$st_line, mounted on $P_MNT"
				st_df=$(df -Pk "$R$P_MNT" 2>/dev/null | awk 'NR == 2 { printf "%.1f of %.1f GB free", $4 / 1e6 * 1.024, $2 / 1e6 * 1.024 }')
				[ -z "$st_df" ] || st_line="$st_line ($st_df)"
			else
				st_line="$st_line, not mounted"
			fi
		elif [ "$st_n" = super ] && has_android_lp "$st_dev"; then
			st_line="$st_line  Android's system (dynamic partitions)"
		else
			st_line="$st_line  not claimed ($(luks_type "$st_dev" | sed 's/^$/no known signature/'))"
		fi
		if [ "$st_n" = prism ]; then
			if avb_footer "$st_dev" "$(part_bytes "$st_d")"; then
				st_line="$st_line; AVB footer intact"
			else
				st_line="$st_line; NO valid AVB footer"
			fi
		fi
		say "$st_line"
	done
	st_ct=$(block_lines "$CRYPTTAB" | awk '{ print $1 }' | tr '\n' ' ')
	st_ft=$(block_lines "$FSTAB" | awk '{ print $2 }' | tr '\n' ' ')
	say "  $CRYPTTAB: ${st_ct:-no entries}"
	say "  $FSTAB: ${st_ft:-no entries}"
	if [ -e "$R$KEY" ]; then say "  key file: $KEY"; else say "  key file: none"; fi
	st_u=$(conf_get USER)
	[ -z "$st_u" ] || say "  user: $st_u$( [ -z "$(conf_get HOME_LINK)" ] || echo ", link $(conf_get HOME_LINK)")"
	[ "$(conf_get CONTAINERS)" != 1 ] || say "  containers: podman storage of $st_u on the Android space"
	return 0
}

if [ "$MODE" = status ]; then
	status
	exit 0
fi

# ---------- common checks for claim and undo ----------

is_root || die "run it as root (sudo $PROG)"
[ ! -e "$R/etc/initrd-release" ] || die "not in the initrd"
# claiming and --undo --wipe ask; a plain --undo changes no data
if [ ! -t 0 ] && [ "$YES" = 0 ] && [ "$DRY" = 0 ] && { [ "$MODE" = claim ] || [ "$WIPE" = 1 ]; }; then
	die "run it in a terminal (it asks for confirmation and your passphrase)"
fi
tr '\0' '\n' < "$R/sys/firmware/devicetree/base/compatible" 2>/dev/null | grep -qx 'samsung,gtactive3wifi' ||
	die "this is not a Galaxy Tab Active3 Wi-Fi (SM-T570)"

mkdir -p "$R/run/gtactive3wifi"
exec 9> "$R/run/gtactive3wifi/claim-android-space.lock"
flock -n 9 || die "another $PROG is running"

stop_volume() { # NAME: unmount and close (data and header stay)
	part_info "$1"
	if mountpoint -q "$R$P_MNT" 2>/dev/null; then
		systemctl stop "$(unit_mount "$P_MNT")" 2>/dev/null || true
		if mountpoint -q "$R$P_MNT" 2>/dev/null; then
			umount "$R$P_MNT" || die "$P_MNT is busy (close the apps/containers using it: fuser -vm $P_MNT)"
		fi
	fi
	if [ -e "$R/dev/mapper/$P_MAP" ]; then
		systemctl stop "$(unit_crypt "$P_MAP")" 2>/dev/null || true
		[ ! -e "$R/dev/mapper/$P_MAP" ] || cryptsetup close "$P_MAP" || die "cannot close $P_MAP"
	fi
}

# ---------- --undo ----------

undo() {
	ud_parts=
	for ud_n in super prism; do
		part_info "$ud_n"
		if block_lines "$CRYPTTAB" | grep -q "^$P_MAP[[:space:]]" ||
			[ -e "$R/dev/mapper/$P_MAP" ] || mountpoint -q "$R$P_MNT" 2>/dev/null; then
			ud_parts="$ud_parts $ud_n"
		elif [ "$WIPE" = 1 ] && ud_d=$( (find_part "$ud_n") 2>/dev/null) &&
			[ "$(luks_label "$R/dev/$ud_d")" = "$P_LUKS" ]; then
			ud_parts="$ud_parts $ud_n"
		fi
	done
	[ -n "$ud_parts" ] || [ -e "$R$CONF" ] || { say "nothing to undo"; return 0; }

	if [ "$WIPE" = 1 ]; then
		say "--wipe erases the encryption keys of the Android space:$ud_parts."
		say "Its files are gone for good."
		if [ "$YES" = 0 ]; then
			printf 'Type WIPE to continue: ' >&2
			read -r ud_a || true
			[ "$ud_a" = WIPE ] || die "not confirmed, nothing was changed"
		fi
	fi

	for ud_n in $ud_parts; do
		stop_volume "$ud_n"
	done
	ud_user=$(conf_get USER)
	if [ "$(conf_get CONTAINERS)" = 1 ] && [ -n "$ud_user" ]; then
		ud_home=$(awk -F: -v u="$ud_user" '$1 == u { print $6 }' "$R/etc/passwd")
		ud_sc=$R$ud_home/.config/containers/storage.conf
		if [ -f "$ud_sc" ] && head -n1 "$ud_sc" | grep -q "$MARK"; then
			rm -f "$ud_sc"
			say "podman storage of $ud_user is back in ~/.local/share/containers"
		fi
	fi
	ud_link=$(conf_get HOME_LINK)
	if [ -n "$ud_link" ] && [ -L "$R$ud_link" ]; then
		case $(readlink "$R$ud_link") in /var/mnt/android-space*) rm -f "$R$ud_link" ;; esac
	fi

	set_block "$CRYPTTAB" ""
	set_block "$FSTAB" ""
	systemctl daemon-reload 2>/dev/null || true

	for ud_n in $ud_parts; do
		part_info "$ud_n"
		ud_d=$( (find_part "$ud_n") 2>/dev/null) || continue
		ud_dev=$R/dev/$ud_d
		[ "$(luks_label "$ud_dev")" = "$P_LUKS" ] || continue
		guard "$ud_dev" "$ud_n"
		if [ "$WIPE" = 1 ]; then
			cryptsetup erase --batch-mode "$ud_dev"
			wipefs -q -a -t crypto_LUKS "$ud_dev"
			say "$ud_n (/dev/$ud_d): LUKS keyslots and signature erased"
		elif [ -e "$R$KEY" ]; then
			cryptsetup luksRemoveKey --batch-mode --key-file "$R$KEY" "$ud_dev" 2>/dev/null || true
			say "$ud_n (/dev/$ud_d): closed; the data stays, your passphrase still opens it"
		fi
		if [ "$ud_n" = prism ]; then
			if avb_footer "$ud_dev" "$(part_bytes "$ud_d")"; then
				say "prism: AVB footer intact"
			else
				say "WARNING: prism has no valid AVB footer any more" >&2
			fi
		fi
		ud_m=$R$P_MNT
		if [ -d "$ud_m" ] && ! mountpoint -q "$ud_m" 2>/dev/null; then
			chattr -i "$ud_m" 2>/dev/null || true
			rmdir "$ud_m" 2>/dev/null || true
		fi
	done
	rm -f "$R$KEY" "$R$CONF"
	say "undone: no $CRYPTTAB/$FSTAB entries, no key file."
	say "Note: $CRYPTTAB and $FSTAB stay copies in /etc's mutable layer"
	say "(/var/lib/extensions.mutable/etc); delete them there and run"
	say "\"systemd-confext refresh\" to use the image's versions again."
}

if [ "$MODE" = undo ]; then
	undo
	exit 0
fi

# ---------- claim ----------

[ "$WIPE" = 0 ] || die "--wipe goes with --undo"
if [ "$YES" = 1 ] && [ "$GONE" = 0 ]; then
	die "--yes needs --i-understand-android-is-gone as well"
fi
if [ -n "$PASSFILE" ] && [ "$YES" = 0 ]; then
	die "--passphrase-file is for tests, with --yes"
fi
[ "$YES" = 0 ] || [ "$DRY" = 1 ] || [ -n "$PASSFILE" ] || [ -t 0 ] ||
	die "non-interactive: --passphrase-file FILE is needed"

# this is the tablet's own layout, Duranium is running from userdata
find_part efs > /dev/null
find_part userdata > /dev/null
ROOT_DEV=$(root_luks_dev) || die "the root is not a LUKS volume (/dev/mapper/...): is this Duranium?"
[ -n "$ROOT_DEV" ] || die "cannot find the root's LUKS device"

TARGETS=super
if [ "$WITH_PRISM" = 1 ]; then
	TARGETS="super prism"
elif block_lines "$CRYPTTAB" | grep -q "^android-space-prism[[:space:]]"; then
	TARGETS="super prism" # set up before: keep its entries
elif pd=$( (find_part prism) 2>/dev/null) && [ "$(luks_label "$R/dev/$pd")" = gta3-android-space-prism ]; then
	say "note: prism was claimed before; add --with-prism to attach it again"
fi

# the user who gets the space
[ -n "$USER_NAME" ] || USER_NAME=$(head -n1 "$R/etc/default_user" 2>/dev/null || true)
[ -n "$USER_NAME" ] || USER_NAME=${SUDO_USER:-}
[ -n "$USER_NAME" ] || die "which user? (--user NAME)"
U_LINE=$(awk -F: -v u="$USER_NAME" '$1 == u' "$R/etc/passwd")
[ -n "$U_LINE" ] || die "no user $USER_NAME"
U_UID=$(echo "$U_LINE" | cut -d: -f3)
U_GID=$(echo "$U_LINE" | cut -d: -f4)
U_HOME=$(echo "$U_LINE" | cut -d: -f6)
[ "$U_UID" != 0 ] || die "give the space to a normal user (--user NAME)"
STORAGE_CONF=$U_HOME/.config/containers/storage.conf
if [ "$CONTAINERS" = 1 ] && [ -e "$R$STORAGE_CONF" ] && ! head -n1 "$R$STORAGE_CONF" | grep -q "$MARK"; then
	die "$STORAGE_CONF exists: set graphroot = \"/var/mnt/android-space/$USER_NAME/containers/storage\" there yourself"
fi

# check every target before anything is written: NEW (format), OURS
# (claimed before, attach again) or SKIP (attached and in the crypttab)
NEW= OURS= SKIP= ANDROID_OS=0 PASS_DEV=
for n in $TARGETS; do
	part_info "$n"
	d=$(find_part "$n")
	dev=$R/dev/$d
	size=$(part_bytes "$d")
	[ "$size" -ge "$P_MIN" ] && [ "$size" -le "$P_MAX" ] ||
		die "$n (/dev/$d) is $(gb "$size"), not the SM-T570's size: refusing"
	if [ "$(luks_type "$dev")" = crypto_LUKS ] && [ "$(luks_label "$dev")" = "$P_LUKS" ]; then
		[ -n "$PASS_DEV" ] || PASS_DEV=$dev
		if [ -e "$R/dev/mapper/$P_MAP" ] && block_lines "$CRYPTTAB" | grep -q "^$P_MAP[[:space:]]"; then
			SKIP="$SKIP $n"
			continue
		fi
		OURS="$OURS $n"
	fi
	if why=$(in_use "$d"); then
		die "$n (/dev/$d) is in use ($why): refusing"
	fi
	[ ! -e "$R/dev/mapper/$P_MAP" ] || die "/dev/mapper/$P_MAP exists but is not set up by $PROG: refusing"
	if [ -d "$R$P_MNT" ] && ! mountpoint -q "$R$P_MNT" 2>/dev/null && [ -n "$(ls -A "$R$P_MNT")" ]; then
		die "$P_MNT is not empty: refusing to mount over it"
	fi
	case " $OURS " in *" $n "*) continue ;; esac
	if [ "$n" = prism ]; then
		avb_footer "$dev" "$size" ||
			die "prism (/dev/$d) has no valid AVB footer: refusing (S-Boot reads it at every start)"
		[ $(($(prism_end) - DATA_OFFSET)) -ge $((64 * MIB)) ] ||
			die "prism's AVB metadata starts at $AVB_VBOFF: too little space before it, not claimed"
	fi
	[ "$n" != super ] || ! has_android_lp "$dev" || ANDROID_OS=1
	NEW="$NEW $n"
done

say "Android space for $USER_NAME:"
for n in $TARGETS; do
	part_info "$n"
	d=$(find_part "$n")
	case " $NEW " in
	*" $n "*) say "  $n (/dev/$d, $(gb "$(part_bytes "$d")")): format as LUKS2 + ext4, mount on $P_MNT" ;;
	esac
	case " $OURS " in
	*" $n "*) say "  $n (/dev/$d): claimed before, attach it again (no formatting)" ;;
	esac
	case " $SKIP " in
	*" $n "*) say "  $n (/dev/$d): already set up" ;;
	esac
done
[ "$HOME_LINK" = 0 ] || say "  link: $U_HOME/android-space -> /var/mnt/android-space/$USER_NAME"
[ "$CONTAINERS" = 0 ] || say "  podman storage of $USER_NAME: /var/mnt/android-space/$USER_NAME/containers/storage"

if [ -n "$NEW" ]; then
	cat <<-EOF

	!!! This erases Android's operating system for good. !!!

	EOF
	case " $NEW " in *" super "*)
		if [ "$ANDROID_OS" = 1 ]; then
			say "  super: Android's system, vendor and product partitions are on it now."
		else
			say "  super: holds no Android system any more (already erased)."
		fi ;;
	esac
	case " $NEW " in *" prism "*)
		say "  prism: Samsung's CSC data. Its AVB metadata at the end is kept: the"
		say "  bootloader checks it at every start." ;;
	esac
	cat <<-EOF

	Android cannot start any more afterwards. Only flashing the complete stock
	firmware (Odin: BL, AP, CP, HOME_CSC) brings it back; "./setup.sh
	restore-android" and Samsung's recovery cannot. Duranium is not affected
	(it lives in the userdata partition). The space is encrypted with your
	disk passphrase and unlocked at every start by a key file on the root.

	EOF
fi
if [ "$DRY" = 1 ]; then
	say "--dry-run: nothing was changed."
	exit 0
fi
if [ -n "$NEW" ] && [ "$YES" = 0 ]; then
	printf 'Type %s to continue: ' "$CONFIRM" >&2
	read -r answer || true
	[ "$answer" = "$CONFIRM" ] || die "not confirmed, nothing was changed"
fi

if [ -z "$NEW$OURS" ]; then
	: # nothing to unlock: only the entries, the link and the containers setting
elif [ -n "$PASS_DEV" ]; then
	get_pass "$PASS_DEV" "Passphrase of the Android space (normally your disk passphrase)"
else
	get_pass "$ROOT_DEV" "Your disk passphrase"
fi

# the key file, on the encrypted root
mkdir -p "$R$STATE"
chmod 755 "$R$STATE"
if [ ! -s "$R$KEY" ]; then
	(umask 077 && head -c 4096 /dev/urandom > "$R$KEY.new" && mv -f "$R$KEY.new" "$R$KEY")
fi
chmod 400 "$R$KEY"

CT_LINES= FS_LINES= TMP_MNT=$R/run/gtactive3wifi/claim-android-space.mnt
for n in $TARGETS; do
	part_info "$n"
	d=$(find_part "$n")
	dev=$R/dev/$d
	size=$(part_bytes "$d")
	case " $NEW " in
	*" $n "*)
		if [ "$n" = prism ]; then
			avb_footer "$dev" "$size" || die "prism's AVB footer changed: stopping"
			end=$(prism_end)
			mkdir -p "$R$AVB_SAVE"
			dd if="$dev" of="$R$AVB_SAVE/vbmeta.bin" bs=4096 skip=$((AVB_VBOFF / 4096)) \
				count=$(((AVB_VBSIZE + 4095) / 4096)) 2>/dev/null
			dd if="$dev" of="$R$AVB_SAVE/footer.bin" bs=4096 skip=$((size / 4096 - 1)) count=1 2>/dev/null
			printf 'VBOFF=%s\nVBSIZE=%s\nSIZE=%s\nEND=%s\n' "$AVB_VBOFF" "$AVB_VBSIZE" "$size" "$end" \
				> "$R$AVB_SAVE/layout"
			tail_before=$(tail_sum "$dev" "$end")
		fi
		say "formatting $n (/dev/$d)..."
		guard "$dev" "$n"
		[ "$n" = prism ] || wipefs -q -a "$dev"
		printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --batch-mode \
			--label "$P_LUKS" --offset $((DATA_OFFSET / 512)) --key-file=- "$dev"
		;;
	esac
	case " $OURS " in
	*" $n "*)
		say "attaching $n (/dev/$d) again..."
		guard "$dev" "$n"
		;;
	esac
	case " $SKIP " in
	*" $n "*) ;;
	*) if ! cryptsetup open --test-passphrase --key-file "$R$KEY" "$dev" >/dev/null 2>&1; then
		printf '%s' "$PASS" | cryptsetup luksAddKey --batch-mode --key-file=- \
			--pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$dev" "$R$KEY"
	fi ;;
	esac
	uuid=$(cryptsetup luksUUID "$dev")
	[ -n "$uuid" ] || die "no LUKS UUID on $dev"
	case " $NEW " in
	*" $n "*)
		cryptsetup open --key-file "$R$KEY" "$dev" "$P_MAP"
		if [ "$n" = prism ]; then
			mkfs.ext4 -q -F -L "$P_FS" -m 0 -b 4096 -E nodiscard "$R/dev/mapper/$P_MAP" \
				$(((end - DATA_OFFSET) / 4096))
		else
			mkfs.ext4 -q -F -L "$P_FS" -m 0 "$R/dev/mapper/$P_MAP"
		fi
		mkdir -p "$TMP_MNT"
		mount "$R/dev/mapper/$P_MAP" "$TMP_MNT"
		mkdir -p "$TMP_MNT/$USER_NAME"
		chown "$U_UID:$U_GID" "$TMP_MNT/$USER_NAME"
		chmod 700 "$TMP_MNT/$USER_NAME"
		umount "$TMP_MNT"
		cryptsetup close "$P_MAP"
		if [ "$n" = prism ]; then
			tail_after=$(tail_sum "$dev" "$end")
			if [ "$tail_after" != "$tail_before" ]; then
				echo "$PROG: prism's tail changed: restoring its AVB metadata" >&2
				dd if="$R$AVB_SAVE/vbmeta.bin" of="$dev" bs=4096 seek=$((AVB_VBOFF / 4096)) \
					conv=notrunc 2>/dev/null
				dd if="$R$AVB_SAVE/footer.bin" of="$dev" bs=4096 seek=$((size / 4096 - 1)) \
					conv=notrunc 2>/dev/null
				sync
				avb_footer "$dev" "$size" && say "prism: AVB footer restored" ||
					echo "$PROG: prism's AVB footer could not be restored: do not reboot, flash prism.img from the stock firmware" >&2
				die "prism's tail changed during formatting (saved copy: $AVB_SAVE)"
			fi
			say "prism: AVB metadata unchanged"
		fi
		;;
	esac
	CT_LINES="${CT_LINES:+$CT_LINES
}$P_MAP UUID=$uuid $KEY luks,nofail,headless,x-systemd.device-timeout=10s"
	FS_LINES="${FS_LINES:+$FS_LINES
}/dev/mapper/$P_MAP $P_MNT ext4 nofail,noatime,x-systemd.device-timeout=10s 0 2"
	# the empty mount point stays empty: nothing lands on the root by mistake
	if ! mountpoint -q "$R$P_MNT" 2>/dev/null; then
		mkdir -p "$R$P_MNT"
		chmod 755 "$R$P_MNT"
		chattr +i "$R$P_MNT" 2>/dev/null || true
	fi
done

set_block "$CRYPTTAB" "$CT_LINES"
set_block "$FSTAB" "$FS_LINES"
{
	echo "# $PROG"
	echo "USER=$USER_NAME"
	echo "PARTS=$TARGETS"
	# what an earlier run set up stays known to --undo
	if [ "$HOME_LINK" = 1 ] || [ -L "$R$U_HOME/android-space" ]; then
		echo "HOME_LINK=$U_HOME/android-space"
	fi
	if [ "$CONTAINERS" = 1 ] || { [ -f "$R$STORAGE_CONF" ] && head -n1 "$R$STORAGE_CONF" | grep -q "$MARK"; }; then
		echo "CONTAINERS=1"
	fi
} > "$R$CONF"

# start it the way every boot will
systemctl daemon-reload
failed=
for n in $TARGETS; do
	part_info "$n"
	mountpoint -q "$R$P_MNT" 2>/dev/null && continue
	if ! systemctl start "$(unit_crypt "$P_MAP")" "$(unit_mount "$P_MNT")" ||
		! mountpoint -q "$R$P_MNT" 2>/dev/null; then
		failed="$failed $n"
	fi
done
[ -z "$failed" ] ||
	die "could not start:$failed (journalctl -b -u 'systemd-cryptsetup@*'); boot is not affected (nofail)"

if [ "$HOME_LINK" = 1 ] && [ ! -e "$R$U_HOME/android-space" ] && [ ! -L "$R$U_HOME/android-space" ]; then
	ln -s "/var/mnt/android-space/$USER_NAME" "$R$U_HOME/android-space"
	chown -h "$U_UID:$U_GID" "$R$U_HOME/android-space"
fi

if [ "$CONTAINERS" = 1 ]; then
	gr=/var/mnt/android-space/$USER_NAME/containers/storage
	mkdir -p "$R$gr"
	chown "$U_UID:$U_GID" "$R${gr%/storage}" "$R$gr"
	for dir in "$U_HOME/.config" "$U_HOME/.config/containers"; do
		[ -d "$R$dir" ] && continue
		mkdir "$R$dir"
		chown "$U_UID:$U_GID" "$R$dir"
	done
	cat > "$R$STORAGE_CONF" <<-EOF
		# $MARK: podman (and distrobox) storage of $USER_NAME on the Android space
		[storage]
		driver = "overlay"
		graphroot = "$gr"
	EOF
	chown "$U_UID:$U_GID" "$R$STORAGE_CONF"
	# the preinstalled images are loaded again into the new store at login
	rm -f "$R$U_HOME/.local/state/gtactive3wifi/container-images/"* 2>/dev/null || true
fi

say ""
say "Done:"
for n in $TARGETS; do
	part_info "$n"
	say "  $P_MNT ($n), your folder: $P_MNT/$USER_NAME"
done
[ "$HOME_LINK" = 0 ] || say "  ~/android-space -> /var/mnt/android-space/$USER_NAME"
if [ "$CONTAINERS" = 1 ]; then
	say "  podman storage: log out and in again; old images in ~/.local/share/containers"
	say "  are not moved (\"podman system reset\" with the old setting frees them)"
fi
say "Unlocked at every start; \"$PROG --status\" shows it, \"--undo\" stops using it."
