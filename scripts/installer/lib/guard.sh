# shellcheck shell=bash
# Hard limits on what the installer may ever write. Checked right before
# every heimdall flash, console write/discard and mkfs, independent of the
# flow that asks for it.
#
# The protected partitions hold the device's identity, keys and boot chain
# (EFS: IMEI/MAC/serial-bound data; PARAM/UP_PARAM: bootloader settings;
# PERSISTENT: factory reset protection; BOOTLOADER*/VBMETA*: the signed boot
# chain, an unsigned vbmeta leaves S-Boot stuck in Odin mode without USB;
# CPEFS; RPMB and the other UFS LUNs sdb..sde). Losing any of them can brick
# the tablet or lose its calibration for good.

DENY_PARTS="bootloader bootloader2 ul_keys ddi pit md5hdr efs sec_efs param up_param
bota keystorage steady uh uhcfg blcmd radio cp_debug nad_refer persistent
keyrefuge keydata dqmdbg vbmeta vbmeta_samsung prism optics omr spu cpefs cm misc dtbo"

# heimdall (Download mode): only these, by PIT name
HEIMDALL_ALLOW="BOOT RECOVERY"

# Linux console (block devices, by GPT name): partition -> allowed operations
console_allowed_ops() {
	case $1 in
		userdata) echo "put discard mkfs" ;;
		metadata) echo "put discard" ;;
		*) echo "" ;;
	esac
}

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_denied_part() {
	local n p
	n=$(_lc "$1")
	for p in $DENY_PARTS; do [ "$n" = "$p" ] && return 0; done
	return 1
}

# guard_heimdall NAME FILE
guard_heimdall() {
	local n=$1 a
	is_denied_part "$n" && die "refusing to flash the protected partition $n"
	for a in $HEIMDALL_ALLOW; do
		if [ "$n" = "$a" ]; then
			[ -s "$2" ] || dry || die "refusing to flash $n: $2 is missing or empty"
			return 0
		fi
	done
	die "refusing to flash $n: the installer only ever writes $HEIMDALL_ALLOW"
}

# guard_console_write OP DEVICE-PATH GPT-NAME
# GPT-NAME must come from the tablet itself (sysfs uevent PARTNAME), read
# just before the write.
guard_console_write() {
	local op=$1 dev=$2 name a
	name=$(_lc "${3:-}")
	case $dev in
		/dev/tty0|/run/*|/tmp/*)
			[ "$op" = put ] && return 0
			die "refusing $op on $dev" ;;
		/dev/sda[0-9]|/dev/sda[0-9][0-9]) ;;
		*) die "refusing $op on $dev: only partitions of the main UFS LUN (sda) are ever touched" ;;
	esac
	[ -n "$name" ] || die "refusing $op on $dev: its partition name is unknown"
	is_denied_part "$name" && die "refusing $op on $dev: $name is a protected partition"
	for a in $(console_allowed_ops "$name"); do
		[ "$a" = "$op" ] && return 0
	done
	die "refusing $op on $dev ($name): not allowed"
}
