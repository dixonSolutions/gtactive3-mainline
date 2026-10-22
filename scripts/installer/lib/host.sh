# shellcheck shell=bash
# Checks on this PC: tools, USB permissions, free space.

# tool -> "what for"
declare -gA TOOL_WHY=(
	[adb]="talking to Android"
	[heimdall]="flashing the BOOT partition in Download mode"
	[curl]="downloads"
	[gpg]="checking the release signatures"
	[zstd]="unpacking images, compressing backups"
	[lz4]="unpacking Samsung firmware files"
	[python3]="the installer's helpers"
	[sha256sum]="checking files"
	[openssl]="the local key for the boot image footer"
	[mcopy]="putting the firmware into the image (mtools)"
	[debugfs]="reading firmware out of the Android vendor image (e2fsprogs)"
	[lsusb]="seeing the tablet in Download mode (usbutils)"
	[ip]="the tablet's USB network (iproute2)"
	[tar]="firmware archives"
)

distro_id() {
	local id='' like='' f=${GTA3_OS_RELEASE:-/etc/os-release}
	if [ -r "$f" ]; then
		id=$(sed -n 's/^ID=//p' "$f" | tr -d '"')
		like=$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d '"')
	fi
	case " $id $like " in
		*" fedora "*|*" rhel "*) echo fedora ;;
		*" ubuntu "*|*" debian "*) echo debian ;;
		*" arch "*) echo arch ;;
		*" alpine "*|*" postmarketos "*) echo alpine ;;
		*) echo unknown ;;
	esac
}

# package that provides a tool, per distro family
pkg_for() {
	local d=$1 t=$2
	case $d:$t in
		fedora:adb|arch:adb|alpine:adb) echo android-tools ;;
		debian:adb) echo adb ;;
		debian:heimdall) echo heimdall-flash ;;
		*:heimdall) echo heimdall ;;
		fedora:gpg) echo gnupg2 ;;
		*:gpg) echo gnupg ;;
		arch:python3) echo python ;;
		*:python3) echo python3 ;;
		*:sha256sum) echo coreutils ;;
		*:mcopy) echo mtools ;;
		*:debugfs) echo e2fsprogs ;;
		*:lsusb) echo usbutils ;;
		fedora:ip) echo iproute ;;
		*:ip) echo iproute2 ;;
		*) echo "$t" ;;
	esac
}

install_cmd() {
	case $1 in
		fedora) echo "sudo dnf install" ;;
		debian) echo "sudo apt install" ;;
		arch) echo "sudo pacman -S --needed" ;;
		alpine) echo "sudo apk add" ;;
		*) echo "install with your package manager:" ;;
	esac
}

# check_tools TOOL...: report the missing ones with an install hint
check_tools() {
	local t miss=() pk=() d
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || miss+=("$t")
	done
	[ ${#miss[@]} -eq 0 ] && return 0
	d=$(distro_id)
	for t in "${miss[@]}"; do
		err "missing: $t (${TOOL_WHY[$t]:-needed})"
		pk+=("$(pkg_for "$d" "$t")")
	done
	say ""
	say "  Install them, then run ./setup.sh again:"
	say "    $(install_cmd "$d") $(printf '%s\n' "${pk[@]}" | sort -u | tr '\n' ' ')"
	[ "$d" = debian ] && say "    (heimdall: Debian/Ubuntu call the package heimdall-flash)"
	[ "$d" = alpine ] && say "    (heimdall is in the Alpine testing repository)"
	return 1
}

check_python() {
	python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' ||
		die "python3 is older than 3.8"
}

# USB access rules for Samsung's IDs (adb 04e8:6860, Download mode 04e8:685d)
udev_ok() {
	local f
	for f in /etc/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules /lib/udev/rules.d/*.rules; do
		[ -r "$f" ] || continue
		grep -qi '04e8' "$f" && return 0
	done
	return 1
}

check_udev() {
	if udev_ok; then
		ok "USB rules for Samsung devices are installed"
		return 0
	fi
	warn "no USB rules for Samsung devices (04e8): adb/heimdall may need root"
	if ask_yn "Install $INST/udev/60-gtactive3-samsung.rules into /etc/udev/rules.d (sudo)?" y; then
		act "install USB rules" sudo install -m 0644 "$INST/udev/60-gtactive3-samsung.rules" \
			/etc/udev/rules.d/60-gtactive3-samsung.rules &&
			act "reload USB rules" sudo udevadm control --reload &&
			act "apply USB rules" sudo udevadm trigger --subsystem-match=usb
		info "If the tablet is plugged in, unplug and replug it once."
	fi
}

# free_bytes DIR
free_bytes() {
	local d=$1
	[ -n "${GTA3_TEST_FREE:-}" ] && { echo "$GTA3_TEST_FREE"; return; }
	while [ ! -d "$d" ]; do d=$(dirname "$d"); done
	df -PB1 "$d" | awk 'NR == 2 { print $4 }'
}

# need_space DIR BYTES WHAT
need_space() {
	local f
	f=$(free_bytes "$1")
	if [ "$f" -lt "$2" ]; then
		err "not enough free space in $1 for $3: $(human_bytes "$f") free, $(human_bytes "$2") needed"
		info "Free some space, or point the installer elsewhere (GTA3_CACHE_DIR / GTA3_BACKUP_DIR)."
		return 1
	fi
	dbg "space in $1: $(human_bytes "$f") free, $(human_bytes "$2") needed for $3"
}

preflight() {
	step "Check this PC"
	check_tools adb heimdall curl gpg zstd lz4 python3 sha256sum openssl mcopy lsusb ip tar ||
		die "install the missing tools first"
	check_python
	command -v debugfs >/dev/null 2>&1 ||
		info "debugfs (e2fsprogs) is missing: only needed if the firmware has to come out of a stock firmware package"
	ok "tools: adb heimdall curl gpg zstd lz4 python3 openssl mtools usbutils iproute2"
	check_udev
	# images: ~2 GiB download + ~6.4 GiB unpacked; stock firmware ~5 GiB if downloaded
	need_space "$CACHE_DIR" $((10 << 30)) "downloads and the unpacked image" ||
		die "not enough space"
	ok "free space for downloads: $(human_bytes "$(free_bytes "$CACHE_DIR")") in $CACHE_DIR"
}
