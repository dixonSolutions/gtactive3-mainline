#!/bin/sh
# Tests for gtactive3wifi-claim-android-space (device package) against a
# fake tablet: a directory with the SM-T570's sysfs partitions, device
# nodes as (sparse) files, /etc, /var and /home, and PATH mocks for
# cryptsetup, blkid, wipefs, mkfs.ext4, mount, systemctl, ... (mock/).
# Needs no root, no loop devices and no tablet. POSIX sh, so it runs under
# BusyBox ash too (tests/claim-space/busybox.sh).
#
#   tests/claim-space/run.sh            every case
#   tests/claim-space/run.sh PATTERN    the cases whose name contains PATTERN
#   SH="busybox ash" ...                the shell that runs the tool (default sh)
#   KEEP=1 ...                          keep the work directory
# Work directory: build/test-claim-space (GTA3_TEST_DIR).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TOOL=${GTA3_CLAIM_TOOL:-$REPO/build/wt/pmaports-duranium/device/testing/device-samsung-gtactive3wifi/claim-android-space.sh}
RUN=${GTA3_TEST_DIR:-$REPO/build/test-claim-space}
SH=${SH:-sh}
[ -f "$TOOL" ] || { echo "no tool at $TOOL (GTA3_CLAIM_TOOL)" >&2; exit 2; }
rm -rf "$RUN"
mkdir -p "$RUN"
[ "${KEEP:-0}" = 1 ] || trap 'rm -rf "$RUN"' EXIT

SUPER_BYTES=7130316800
PRISM_BYTES=629145600
MIB=1048576
ROOT_PASS='correct horse battery'

fail() { echo "FAILED: $*"; exit 1; }

# ---------- the fake tablet ----------

# mkpart NAME DEVNAME SIZE [MAJOR MINOR]: a partition in sysfs + its node
mkpart() {
	mkdir -p "$ROOT/sys/class/block/$2/holders"
	printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=partition\nPARTNAME=%s\n' \
		"${4:-8}" "${5:-${2#sda}}" "$2" "$1" > "$ROOT/sys/class/block/$2/uevent"
	echo $(($3 / 512)) > "$ROOT/sys/class/block/$2/size"
	# full size for the two targets (sparse); the others only need to exist
	case $1 in super | prism) truncate -s "$3" "$ROOT/dev/$2" ;; *) truncate -s 65536 "$ROOT/dev/$2" ;; esac
	printf 'PROTECTED-%s' "$1" | dd of="$ROOT/dev/$2" conv=notrunc 2>/dev/null
	mkdir -p "$ROOT/dev/disk/by-partlabel"
	case $2 in sda*) ln -sfn "../../$2" "$ROOT/dev/disk/by-partlabel/$1" ;; esac
}

# hex2bin HEX: the bytes
hex2bin() {
	for b in $(printf '%s' "$1" | sed 's/../& /g'); do
		# shellcheck disable=SC2059
		printf "\\$(printf %o "0x$b")"
	done
}

u64() { printf '%016x' "$1"; }

# prism with a hashtree-style AVB layout: image, vbmeta at VBOFF, footer
VBOFF=$((500 * MIB))
VBSIZE=2368
avb_prism() {
	dev=$ROOT/dev/sda26
	{ printf 'AVB0'; head -c $((VBSIZE - 4)) /dev/zero | tr '\0' 'v'; } |
		dd of="$dev" bs=4096 seek=$((VBOFF / 4096)) conv=notrunc 2>/dev/null
	{ hex2bin "4156426600000001""00000000""$(u64 $((100 * MIB)))$(u64 "$VBOFF")$(u64 "$VBSIZE")"
		head -c 28 /dev/zero; } |
		dd of="$dev" bs=64 seek=$((PRISM_BYTES / 64 - 1)) conv=notrunc 2>/dev/null
}

new_tablet() {
	ROOT=$CASE/root
	MOCK_STATE=$CASE/state
	mkdir -p "$ROOT/dev/mapper" "$ROOT/proc/self" "$ROOT/etc" "$ROOT/var/lib" "$ROOT/run" \
		"$ROOT/home/tab" "$ROOT/sys/firmware/devicetree/base" "$ROOT/sys/block" "$MOCK_STATE/luks/loop0p3"
	printf 'samsung,gtactive3wifi\000samsung,exynos9810\000' > "$ROOT/sys/firmware/devicetree/base/compatible"
	mkpart efs sda1 $((20 * MIB))
	mkpart sec_efs sda2 $((20 * MIB))
	mkpart param sda3 $((8 * MIB))
	mkpart up_param sda4 $((4 * MIB))
	mkpart dtbo sda10 $((8 * MIB))
	mkpart boot sda12 $((60 * MIB))
	mkpart recovery sda13 $((68 * MIB))
	mkpart steady sda14 $((1 * MIB))
	mkpart persistent sda17 $((1 * MIB))
	mkpart keydata sda19 $((1 * MIB))
	mkpart keyrefuge sda20 $((1 * MIB))
	mkpart vbmeta sda22 $((64 * 1024))
	mkpart metadata sda24 $((16 * MIB))
	mkpart super sda25 "$SUPER_BYTES"
	mkpart prism sda26 "$PRISM_BYTES"
	mkpart optics sda27 $((40 * MIB))
	mkpart cache sda28 $((3 * MIB))
	mkpart userdata sda31 $((64 * MIB))
	# Android's LP metadata on super
	printf 'gDla' | dd of="$ROOT/dev/sda25" bs=4096 seek=1 conv=notrunc 2>/dev/null
	avb_prism
	# a microSD card and Duranium's nested GPT, with names that must be ignored
	mkpart super mmcblk1p1 $((8 * MIB)) 179 1
	mkpart pmOS_root loop0p3 $((32 * MIB)) 259 3
	mkdir -p "$ROOT/sys/block/loop0/loop"
	echo /dev/sda31 > "$ROOT/sys/block/loop0/loop/backing_file"
	printf '27 1 253:0 / / rw,relatime - ext4 /dev/mapper/root rw\n' > "$ROOT/proc/self/mountinfo"
	printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition 5800000 0 100\n' > "$ROOT/proc/swaps"
	printf 'root:x:0:0:root:/root:/bin/sh\ntab:x:10000:10000:Tab:/home/tab:/bin/bash\n' > "$ROOT/etc/passwd"
	echo tab > "$ROOT/etc/default_user"
	echo '# For auto-unlocking the volume if the default/empty passphrase is set' > "$ROOT/etc/crypttab"
	echo 'root	PARTLABEL=pmOS_root	/dev/null	luks,keyfile-timeout=0' >> "$ROOT/etc/crypttab"
	printf '# This file is *not* used to mount / or /boot.\n# More information: https://postmarketos.org/fstab\n' > "$ROOT/etc/fstab"
	cp "$ROOT/etc/crypttab" "$CASE/crypttab.orig"
	cp "$ROOT/etc/fstab" "$CASE/fstab.orig"
	printf '%s' "$ROOT_PASS" | sha256sum | cut -d' ' -f1 > "$MOCK_STATE/luks/loop0p3/slots"
	: > "$MOCK_STATE/calls"
	printf '%s\n' "$ROOT_PASS" > "$CASE/pass"
	snapshot_protected > "$CASE/protected.before"
}

# checksums of every partition the tool must never write
snapshot_protected() {
	for f in "$ROOT"/dev/sda* "$ROOT"/dev/mmcblk* "$ROOT"/dev/loop*; do
		case ${f##*/} in sda25 | sda26) continue ;; esac
		printf '%s %s\n' "${f##*/}" "$(sha256sum < "$f" | cut -d' ' -f1)"
	done
}

YES="--yes --i-understand-android-is-gone"

# tool [VAR=VALUE...] ARGS...: run the tool on the fake tablet (stdin: no
# terminal), the mocks get VAR=VALUE (no spaces)
tool() {
	tenv=
	while case ${1:-} in [A-Z]*=*) true ;; *) false ;; esac; do
		tenv="$tenv $1"
		shift
	done
	echo "+$tenv $*" >> "$CASE/out"
	set +e
	# shellcheck disable=SC2086
	env $tenv GTA3_CLAIM_ROOT="$ROOT" MOCK_STATE="$MOCK_STATE" PATH="$HERE/mock:$PATH" \
		$SH "$TOOL" "$@" < /dev/null >> "$CASE/out" 2>&1
	RC=$?
	set -e
	echo "= $RC" >> "$CASE/out"
	return 0
}
claim() {
	cenv=
	while case ${1:-} in [A-Z]*=*) true ;; *) false ;; esac; do
		cenv="$cenv $1"
		shift
	done
	# shellcheck disable=SC2086
	tool $cenv $YES --passphrase-file "$CASE/pass" "$@"
}

ok() { [ "$RC" = 0 ] || fail "exit $RC, expected 0"; }
refused() { # MESSAGE: failed, said MESSAGE
	[ "$RC" != 0 ] || fail "succeeded, expected a refusal"
	grep -qF -- "$1" "$CASE/out" || fail "output lacks: $1"
}
has() { grep -qF -- "$1" "$CASE/out" || fail "output lacks: $1"; }
called() { grep -qF -- "$1" "$MOCK_STATE/calls" || fail "not called: $1"; }
not_called() { ! grep -qF -- "$1" "$MOCK_STATE/calls" || fail "called: $1"; }
writes() { grep -E '^(cryptsetup (luksFormat|luksAddKey|luksRemoveKey|erase)|wipefs|mkfs)' "$MOCK_STATE/calls" || true; }
nothing_written() {
	[ -z "$(writes)" ] || fail "writes happened: $(writes)"
	cmp -s "$ROOT/etc/crypttab" "$CASE/crypttab.orig" || fail "crypttab changed"
	cmp -s "$ROOT/etc/fstab" "$CASE/fstab.orig" || fail "fstab changed"
	[ ! -e "$ROOT/var/lib/gtactive3wifi/android-space.key" ] || fail "key file written"
	protected_intact
}
protected_intact() {
	snapshot_protected > "$CASE/protected.after"
	cmp -s "$CASE/protected.before" "$CASE/protected.after" ||
		fail "a protected partition changed: $(diff "$CASE/protected.before" "$CASE/protected.after" | tr '\n' ' ')"
	# every device the mocks were handed is super, prism or a mapping
	bad=$(tr ' ' '\n' < "$MOCK_STATE/calls" | grep "^$ROOT/dev/" |
		grep -v -e "^$ROOT/dev/sda25\$" -e "^$ROOT/dev/sda26\$" -e "^$ROOT/dev/mapper/" || true)
	[ -z "$bad" ] || fail "devices outside the whitelist were used: $bad"
}
avb_intact() {
	[ "$(dd if="$ROOT/dev/sda26" bs=4096 skip=$((VBOFF / 4096)) count=1 2>/dev/null | head -c 4)" = AVB0 ] ||
		fail "prism's vbmeta is gone"
	[ "$(dd if="$ROOT/dev/sda26" bs=64 skip=$((PRISM_BYTES / 64 - 1)) count=1 2>/dev/null | head -c 4)" = AVBf ] ||
		fail "prism's AVB footer is gone"
}
uuid_of() { cat "$MOCK_STATE/luks/$1/uuid"; }
block() { awk '/^# >>> gtactive3wifi-claim-android-space/ { s = 1; next } /^# <<< / { s = 0 } s' "$1"; }

# ---------- cases ----------

t_refuses_non_root() {
	tool MOCK_UID=1000 $YES --passphrase-file "$CASE/pass"
	refused "run it as root"
	nothing_written
}

t_refuses_without_terminal_or_yes() {
	tool --passphrase-file "$CASE/pass"
	refused "run it in a terminal"
	nothing_written
}

t_yes_needs_understanding() {
	tool --yes --passphrase-file "$CASE/pass"
	refused "--yes needs --i-understand-android-is-gone"
	nothing_written
}

t_refuses_other_device() {
	printf 'samsung,starlte\000' > "$ROOT/sys/firmware/devicetree/base/compatible"
	claim
	refused "not a Galaxy Tab Active3"
	nothing_written
}

t_refuses_missing_partlabel_link() {
	rm "$ROOT/dev/disk/by-partlabel/super"
	claim
	refused "by-partlabel/super is missing"
	nothing_written
}

t_refuses_partlabel_pointing_elsewhere() {
	ln -sfn ../../sda1 "$ROOT/dev/disk/by-partlabel/super"
	claim
	refused "points to sda1, sysfs says sda25"
	nothing_written
}

t_refuses_two_supers() {
	mkpart super sda40 "$SUPER_BYTES"
	truncate -s 65536 "$ROOT/dev/sda40"
	ln -sfn ../../sda25 "$ROOT/dev/disk/by-partlabel/super"
	snapshot_protected > "$CASE/protected.before"
	claim
	refused "two partitions named super"
	nothing_written
}

t_refuses_wrong_size() {
	echo $((1000000000 / 512)) > "$ROOT/sys/class/block/sda25/size"
	claim
	refused "not the SM-T570's size"
	nothing_written
}

t_refuses_held_partition() {
	: > "$ROOT/sys/class/block/sda25/holders/dm-3"
	claim
	refused "in use (held by dm-3"
	nothing_written
}

t_refuses_mounted_partition() {
	echo '40 27 8:25 / /mnt rw - ext4 /dev/sda25 rw' >> "$ROOT/proc/self/mountinfo"
	claim
	refused "in use (mounted)"
	nothing_written
}

t_refuses_loop_backed_partition() {
	mkdir -p "$ROOT/sys/block/loop5/loop"
	echo /dev/sda25 > "$ROOT/sys/block/loop5/loop/backing_file"
	claim
	refused "in use (backs loop5)"
	nothing_written
}

t_refuses_wrong_passphrase() {
	echo 'wrong' > "$CASE/pass"
	claim
	refused "does not open /dev/loop0p3"
	nothing_written
}

t_refuses_nonempty_mountpoint() {
	mkdir -p "$ROOT/var/mnt/android-space"
	echo x > "$ROOT/var/mnt/android-space/file"
	claim
	refused "/var/mnt/android-space is not empty"
	nothing_written
}

t_dry_run_changes_nothing() {
	tool --dry-run
	ok
	has "format as LUKS2 + ext4"
	has "Android's system, vendor and product partitions are on it now"
	has "--dry-run: nothing was changed"
	nothing_written
}

t_claims_super() {
	claim
	ok
	has "Done:"
	protected_intact
	called "cryptsetup luksFormat --type luks2 --batch-mode --label gta3-android-space --offset 32768 --key-file=- $ROOT/dev/sda25"
	called "--pbkdf pbkdf2 --pbkdf-force-iterations 1000 $ROOT/dev/sda25 $ROOT/var/lib/gtactive3wifi/android-space.key"
	called "wipefs -q -a $ROOT/dev/sda25"
	called "mkfs.ext4 -q -F -L android-space -m 0 $ROOT/dev/mapper/android-space"
	! writes | grep -q sda26 || fail "prism written without --with-prism"
	called "chown 10000:10000 $ROOT/run/gtactive3wifi/claim-android-space.mnt/tab"
	called "chattr +i $ROOT/var/mnt/android-space"
	called "systemctl start systemd-cryptsetup@android\\x2dspace.service var-mnt-android\\x2dspace.mount"
	u=$(uuid_of sda25)
	# the image's lines stay, ours are in the block
	head -n2 "$ROOT/etc/crypttab" | cmp -s - "$CASE/crypttab.orig" || fail "crypttab's own lines changed"
	[ "$(block "$ROOT/etc/crypttab")" = "android-space UUID=$u /var/lib/gtactive3wifi/android-space.key luks,nofail,headless,x-systemd.device-timeout=10s" ] ||
		fail "crypttab: $(cat "$ROOT/etc/crypttab")"
	[ "$(block "$ROOT/etc/fstab")" = "/dev/mapper/android-space /var/mnt/android-space ext4 nofail,noatime,x-systemd.device-timeout=10s 0 2" ] ||
		fail "fstab: $(cat "$ROOT/etc/fstab")"
	[ "$(stat -c %a "$ROOT/var/lib/gtactive3wifi/android-space.key")" = 400 ] || fail "key file mode"
	[ "$(stat -c %s "$ROOT/var/lib/gtactive3wifi/android-space.key")" = 4096 ] || fail "key file size"
	[ "$(readlink "$ROOT/home/tab/android-space")" = /var/mnt/android-space/tab ] || fail "home link"
	[ -e "$ROOT/dev/mapper/android-space" ] || fail "not open"
	grep -qx USER=tab "$ROOT/var/lib/gtactive3wifi/android-space.conf" || fail "state file"
	[ "$(wc -l < "$MOCK_STATE/luks/sda25/slots")" = 2 ] || fail "expected 2 keyslots"
	# the passphrase slot is the disk passphrase
	printf '%s' "$ROOT_PASS" | sha256sum | cut -d' ' -f1 | grep -qxf - "$MOCK_STATE/luks/sda25/slots" ||
		fail "the disk passphrase does not open it"
}

t_second_run_changes_nothing() {
	claim
	ok
	: > "$MOCK_STATE/calls"
	cp "$ROOT/etc/crypttab" "$CASE/crypttab.1"
	claim
	ok
	has "super (/dev/sda25): already set up"
	[ -z "$(writes)" ] || fail "writes on the second run: $(writes)"
	cmp -s "$ROOT/etc/crypttab" "$CASE/crypttab.1" || fail "crypttab changed"
}

t_reattaches_after_root_reset() {
	claim
	ok
	u=$(uuid_of sda25)
	# a factory reset recreated the root: no key file, no entries
	cp "$CASE/crypttab.orig" "$ROOT/etc/crypttab"
	cp "$CASE/fstab.orig" "$ROOT/etc/fstab"
	rm -rf "$ROOT/var/lib/gtactive3wifi" "$ROOT/dev/mapper/android-space" "$MOCK_STATE/mnt" "$ROOT/home/tab/android-space"
	: > "$MOCK_STATE/calls"
	claim
	ok
	has "claimed before, attach it again"
	not_called luksFormat
	not_called mkfs
	called "luksAddKey"
	[ "$(uuid_of sda25)" = "$u" ] || fail "UUID changed"
	block "$ROOT/etc/crypttab" | grep -q "UUID=$u" || fail "crypttab"
	[ -e "$ROOT/dev/mapper/android-space" ] || fail "not open"
}

t_disk_without_passphrase() {
	: > "$MOCK_STATE/luks/loop0p3/slots"
	sha256sum < /dev/null | cut -d' ' -f1 > "$MOCK_STATE/luks/loop0p3/slots"
	printf '\nnew secret\n' > "$CASE/pass"
	claim
	ok
	has "No disk passphrase"
	printf 'new secret' | sha256sum | cut -d' ' -f1 | grep -qxf - "$MOCK_STATE/luks/sda25/slots" ||
		fail "the new passphrase does not open it"
}

t_claims_prism_keeping_avb() {
	claim --with-prism
	ok
	protected_intact
	avb_intact
	has "prism: AVB metadata unchanged"
	called "--label gta3-android-space-prism --offset 32768 --key-file=- $ROOT/dev/sda26"
	not_called "wipefs -q -a $ROOT/dev/sda26"
	called "-E nodiscard $ROOT/dev/mapper/android-space-prism"
	# the filesystem ends 1 MiB before prism's vbmeta
	[ "$(cat "$MOCK_STATE/mkfs-blocks.android-space-prism")" = $(((VBOFF - MIB - 16 * MIB) / 4096)) ] ||
		fail "prism ext4 size $(cat "$MOCK_STATE/mkfs-blocks.android-space-prism")"
	[ "$(block "$ROOT/etc/crypttab" | wc -l)" = 2 ] || fail "crypttab: $(cat "$ROOT/etc/crypttab")"
	block "$ROOT/etc/fstab" | grep -q "^/dev/mapper/android-space-prism /var/mnt/android-space-prism ext4 nofail" ||
		fail "fstab: $(cat "$ROOT/etc/fstab")"
	[ -f "$ROOT/var/lib/gtactive3wifi/prism-avb/vbmeta.bin" ] || fail "no saved vbmeta"
}

t_refuses_prism_without_avb_footer() {
	dd if=/dev/zero of="$ROOT/dev/sda26" bs=64 seek=$((PRISM_BYTES / 64 - 1)) count=1 conv=notrunc 2>/dev/null
	snapshot_protected > "$CASE/protected.before"
	claim --with-prism
	refused "prism (/dev/sda26) has no valid AVB footer"
	nothing_written
}

t_restores_prism_tail_after_overrun() {
	claim MOCK_MKFS_OVERRUN=1 --with-prism
	refused "prism's tail changed during formatting"
	has "prism: AVB footer restored"
	avb_intact
}

t_prism_later() {
	claim
	ok
	: > "$MOCK_STATE/calls"
	claim --with-prism
	ok
	has "super (/dev/sda25): already set up"
	not_called "luksFormat --type luks2 --batch-mode --label gta3-android-space --offset 32768 --key-file=- $ROOT/dev/sda25"
	called "--label gta3-android-space-prism"
	# the passphrase was checked against super, not the root
	called "cryptsetup open --test-passphrase --key-file=- $ROOT/dev/sda25"
	[ "$(block "$ROOT/etc/crypttab" | wc -l)" = 2 ] || fail "crypttab"
	avb_intact
}

t_rerun_keeps_prism_and_containers() {
	claim --with-prism --containers
	ok
	: > "$MOCK_STATE/calls"
	claim
	ok
	[ "$(block "$ROOT/etc/crypttab" | wc -l)" = 2 ] || fail "prism's entry dropped: $(cat "$ROOT/etc/crypttab")"
	[ -z "$(writes)" ] || fail "writes on the re-run: $(writes)"
	grep -qx CONTAINERS=1 "$ROOT/var/lib/gtactive3wifi/android-space.conf" || fail "containers forgotten"
}

t_containers() {
	claim --containers
	ok
	sc=$ROOT/home/tab/.config/containers/storage.conf
	grep -qx 'graphroot = "/var/mnt/android-space/tab/containers/storage"' "$sc" || fail "storage.conf: $(cat "$sc")"
	called "chown 10000:10000 $ROOT/home/tab/.config/containers/storage.conf"
	[ -d "$ROOT/var/mnt/android-space/tab/containers/storage" ] || fail "no graphroot dir"
	tool --undo
	ok
	[ ! -e "$sc" ] || fail "storage.conf left"
}

t_containers_refuses_foreign_storage_conf() {
	mkdir -p "$ROOT/home/tab/.config/containers"
	echo '[storage]' > "$ROOT/home/tab/.config/containers/storage.conf"
	claim --containers
	refused "storage.conf exists"
	nothing_written
}

t_start_failure_is_reported() {
	claim MOCK_SYSTEMCTL_FAIL=1
	refused "could not start: super"
	has "boot is not affected (nofail)"
	block "$ROOT/etc/crypttab" | grep -q nofail || fail "no crypttab entry"
}

t_status() {
	tool --status
	ok
	has "super  /dev/sda25  7.13 GB  Android's system"
	has "prism  /dev/sda26  0.63 GB  not claimed"
	has "AVB footer intact"
	claim
	tool --status
	ok
	has "claimed: LUKS2 gta3-android-space, open as android-space, mounted on /var/mnt/android-space"
	has "/etc/crypttab: android-space"
	tool MOCK_UID=1000 --status
	ok
	has "(run as root for details)"
}

t_undo_keeps_data() {
	claim --with-prism
	ok
	u=$(uuid_of sda25)
	: > "$MOCK_STATE/calls"
	tool --undo
	ok
	cmp -s "$ROOT/etc/crypttab" "$CASE/crypttab.orig" || fail "crypttab: $(cat "$ROOT/etc/crypttab")"
	cmp -s "$ROOT/etc/fstab" "$CASE/fstab.orig" || fail "fstab: $(cat "$ROOT/etc/fstab")"
	[ ! -e "$ROOT/var/lib/gtactive3wifi/android-space.key" ] || fail "key file left"
	[ ! -e "$ROOT/dev/mapper/android-space" ] || fail "still open"
	[ ! -e "$ROOT/home/tab/android-space" ] || fail "home link left"
	called "cryptsetup luksRemoveKey --batch-mode --key-file $ROOT/var/lib/gtactive3wifi/android-space.key $ROOT/dev/sda25"
	not_called erase
	[ "$(uuid_of sda25)" = "$u" ] || fail "LUKS header gone"
	printf '%s' "$ROOT_PASS" | sha256sum | cut -d' ' -f1 | grep -qxf - "$MOCK_STATE/luks/sda25/slots" ||
		fail "the passphrase no longer opens it"
	[ "$(wc -l < "$MOCK_STATE/luks/sda25/slots")" = 1 ] || fail "key file slot left"
	has "prism: AVB footer intact"
	avb_intact
	protected_intact
	tool --undo
	ok
	has "nothing to undo"
}

t_undo_refuses_busy_mount() {
	claim
	ok
	tool MOCK_BUSY="$ROOT/var/mnt/android-space" --undo
	refused "/var/mnt/android-space is busy"
	block "$ROOT/etc/crypttab" | grep -q android-space || fail "entries removed although still mounted"
}

t_undo_wipe() {
	claim
	ok
	: > "$MOCK_STATE/calls"
	tool --undo --wipe --yes
	ok
	called "cryptsetup erase --batch-mode $ROOT/dev/sda25"
	called "wipefs -q -a -t crypto_LUKS $ROOT/dev/sda25"
	not_called "erase --batch-mode $ROOT/dev/sda26"
	not_called "wipefs -q -a -t crypto_LUKS $ROOT/dev/sda26"
	cmp -s "$ROOT/etc/crypttab" "$CASE/crypttab.orig" || fail "crypttab"
	protected_intact
}

t_undo_wipe_needs_confirmation() {
	claim
	ok
	tool --undo --wipe
	refused "run it in a terminal"
}

# ---------- runner ----------

pass=0 failed=
cases=$(sed -n 's/^\(t_[a-z0-9_]*\)() {$/\1/p' "$0")
for t in $cases; do
	case $t in *"${1:-}"*) ;; *) continue ;; esac
	CASE=$RUN/$t
	mkdir -p "$CASE"
	printf '%-44s ' "${t#t_}"
	if (
		new_tablet
		"$t"
	) > "$CASE/case.log" 2>&1; then
		echo PASS
		pass=$((pass + 1))
	else
		echo FAIL
		sed 's/^/  /' "$CASE/case.log"
		[ ! -f "$CASE/out" ] || sed 's/^/  | /' "$CASE/out"
		failed="$failed ${t#t_}"
	fi
done
echo
echo "$pass passed${failed:+, failed:$failed} (tool run with: $SH)"
[ -z "$failed" ]
