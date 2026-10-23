#!/bin/bash
# Build the boot-chain payload (ci/bootchain/build calls this), from the
# sources in this repo only:
#
#   bootchain/build.sh OUTDIR VERSION
#
#   uniLoader-chain   uniLoader -> U-Boot -> EFI (Duranium); the bring-up
#                     Linux is the fallback after a failed chained boot
#   uniLoader-linux   uniLoader that always starts the bring-up Linux (the
#                     installer's live environment, USB console on TCP 23)
#   ramdisk.cpio.gz   the bring-up Linux's initramfs (init + modules +
#                     mkfs.f2fs for "restore-android")
#   MANIFEST          versions and sources
#
# Sources: Linux = torvalds/linux at the kernel aport's _base + its patch,
# configured with bootchain.bringup_config; init = initramfs/init.c;
# U-Boot = bootchain/u-boot, uniLoader = bootchain/uniLoader (vendored with
# git subtree: SoC and board fixes land in the template and reach every
# port through Sync fork); mkfs.f2fs = Alpine's aarch64 f2fs-tools. The
# board is chosen by bootchain.u_boot_defconfig / uniloader_defconfig /
# dtb in config.toml. No Samsung file goes in: the installer adds the
# owner's stock DTB and the AVB footer on their PC.
#
# env: WORK (default ./build/bootchain), JOBS (default nproc),
#      LINUX_GIT: a local linux clone that has _base (skips the download),
#      NO_F2FS=1 (no container available)
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:?usage: bootchain/build.sh OUTDIR VERSION}" && cd "$1" && pwd)
VER=${2:?usage: bootchain/build.sh OUTDIR VERSION}
eval "$("$R/scripts/config" shell)"
W=$(mkdir -p "${WORK:-$R/build/bootchain}" && cd "${WORK:-$R/build/bootchain}" && pwd)
JOBS=${JOBS:-$(nproc)}
CC=aarch64-linux-gnu-
AP=$R/$CFG_KERNEL_APORT
KPATCH=$AP/$CFG_DEVICE_CODENAME.patch
DTB=$CFG_BOOTCHAIN_DTB
log() { echo "== $*"; }

for d in "$R/bootchain/u-boot" "$R/bootchain/uniLoader" "$R/initramfs/init.c" "$R/$CFG_BOOTCHAIN_BRINGUP_CONFIG" "$KPATCH"; do
	[ -e "$d" ] || { echo "missing $d (docs/PORTING.md, boot chain)" >&2; exit 1; }
done
KBASE=$(sed -n 's/^_base="\([0-9a-zA-Z.-]*\)"/\1/p' "$AP/APKBUILD")
[ -n "$KBASE" ] || { echo "no _base in $AP/APKBUILD" >&2; exit 1; }

log "Linux $KBASE + $(basename "$KPATCH")"
K=$W/linux
rm -rf "$K"; mkdir -p "$K"
if [ -n "${LINUX_GIT:-}" ]; then
	git -C "$LINUX_GIT" archive "$KBASE" | tar -x -C "$K"
else
	t=$W/linux-$KBASE.tar.gz
	# the repo's own "sources" release first: GitHub answers anonymous
	# archive downloads from shared runner IPs with 429; else the archive,
	# authenticated (GH_TOKEN in CI), with retries
	if [ -n "${GITHUB_REPOSITORY:-}" ] &&
		gh release download sources -R "$GITHUB_REPOSITORY" -D "$W" -p "linux-$KBASE.tar.gz" 2>/dev/null; then
		:
	else for i in 1 2 3 4 5; do
		curl -fsSL --retry 3 --retry-delay 20 ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
			-o "$t" "https://github.com/torvalds/linux/archive/$KBASE.tar.gz" && break
		[ "$i" = 5 ] && { echo "cannot download Linux $KBASE" >&2; exit 1; }
		echo "download attempt $i failed, waiting $((i * 60)) s" >&2; sleep $((i * 60))
	done; fi
	tar -xzf "$t" -C "$K" --strip-components=1
	rm -f "$t"
fi
patch -d "$K" -p1 -s --no-backup-if-mismatch < "$KPATCH"

# out-of-tree U-Boot build; uniLoader builds in place, so in a copy: the
# vendored trees stay clean
UB=$R/bootchain/u-boot
UL=$W/uniloader
rm -rf "$UL"; cp -r "$R/bootchain/uniLoader" "$UL"

# ---------- mkfs.f2fs (Alpine aarch64 binaries, no emulation needed) ----------
F=$W/f2fs
rm -rf "$F"; mkdir -p "$F"
F2FS_VER=none
if [ "${NO_F2FS:-0}" != 1 ] && [ "$CFG_BOOTCHAIN_F2FS" = true ]; then
	log "f2fs-tools (Alpine aarch64)"
	# rootful docker: hand the files back to us; rootless podman: its root
	# already is us (a chown would move them to a subordinate uid)
	if command -v docker >/dev/null; then RT=docker OWN="chown -R $(id -u):$(id -g) /out"
	else RT=podman OWN=true; fi
	"$RT" run --rm -v "$F:/out:Z" docker.io/library/alpine:3.22 sh -euc '
		apk add --quiet --no-cache --arch aarch64 --root /out --initdb --no-scripts \
			--keys-dir /usr/share/apk/keys/aarch64 \
			--repository https://dl-cdn.alpinelinux.org/alpine/v3.22/main f2fs-tools
		apk info --root /out -v 2>/dev/null | sort > /out/.versions
		'"$OWN"
	F2FS_VER=$(tr '\n' ' ' < "$F/.versions")
	[ -x "$F/usr/sbin/mkfs.f2fs" ] || { echo "no mkfs.f2fs from Alpine" >&2; exit 1; }
fi

# ---------- the bring-up Linux ----------
B=$W/bringup
P=$W/p           # stands in for the repo root in the @P@ templates
rm -rf "$P"; mkdir -p "$P/build/initramfs/modules"
MK="make -s -C $K ARCH=arm64 CROSS_COMPILE=$CC O=$B"

gen_list() {
	sed "s|@P@|$P|g" "$R/bootchain/initramfs.list.in"
	local f
	for f in "$P"/build/initramfs/modules/*.ko; do
		[ -e "$f" ] && echo "file /lib/modules/$(basename "$f") $f 0644 0 0"
	done
	# mkfs.f2fs with its libraries (musl loader at /lib, libs at /usr/lib)
	if [ -x "$F/usr/sbin/mkfs.f2fs" ]; then
		printf 'dir /usr 0755 0 0\ndir /usr/sbin 0755 0 0\ndir /usr/lib 0755 0 0\n'
		(cd "$F" && find lib usr/lib usr/sbin/mkfs.f2fs -path lib/apk -prune -o \
			\( -type f -o -type l -o -type d \) -print 2>/dev/null | sort | while read -r e; do
			case $e in lib|usr/lib) continue ;; esac
			if [ -L "$e" ]; then echo "slink /$e $(readlink "$e") 0777 0 0"
			elif [ -d "$e" ]; then echo "dir /$e 0755 0 0"
			else echo "file /$e $F/$e $(stat -c %a "$e") 0 0"; fi
		done)
	fi
}

log "kernel headers"
$MK headers_install INSTALL_HDR_PATH="$W/hdr/usr" >/dev/null
log "init"
${CC}gcc -Os -static -nostdlib -fno-stack-protector -fno-asynchronous-unwind-tables \
	-I"$R/initramfs/stub" -I"$K/tools/include/nolibc" -I"$W/hdr/usr/include" \
	-include "$K/tools/include/nolibc/nolibc.h" \
	-o "$P/build/initramfs/init" "$R/initramfs/init.c" -lgcc

log "kernel config"
gen_list > "$P/build/initramfs.list"
sed "s|@P@|$P|g" "$R/$CFG_BOOTCHAIN_BRINGUP_CONFIG" > "$W/bringup.config"
$MK allnoconfig >/dev/null
(cd "$K" && KCONFIG_CONFIG=$B/.config scripts/kconfig/merge_config.sh -m -O "$B" "$B/.config" "$W/bringup.config" >/dev/null)
$MK olddefconfig

log "kernel + modules (-j$JOBS)"
$MK -j"$JOBS" Image modules
find "$B" -name '*.ko' -exec cp {} "$P/build/initramfs/modules/" \;
if ls "$P"/build/initramfs/modules/*.ko >/dev/null 2>&1; then
	${CC}strip --strip-debug "$P"/build/initramfs/modules/*.ko
fi
gen_list > "$P/build/initramfs.list"
$MK -j"$JOBS" Image "$DTB"   # relink with the modules
"$B/usr/gen_init_cpio" "$P/build/initramfs.list" | gzip -9n > "$OUT/ramdisk.cpio.gz"

log "U-Boot ($CFG_BOOTCHAIN_U_BOOT_DEFCONFIG)"
UBO=$W/u-boot-out
make -s -C "$UB" O="$UBO" CROSS_COMPILE=$CC "$CFG_BOOTCHAIN_U_BOOT_DEFCONFIG"
make -s -C "$UB" O="$UBO" CROSS_COMPILE=$CC -j"$JOBS"
[ "$(dd if="$UBO/u-boot.bin" bs=1 skip=56 count=4 2>/dev/null)" = "$(printf 'ARM\x64')" ] ||
	{ echo "u-boot.bin has no arm64 Image header" >&2; exit 1; }

log "uniLoader ($CFG_BOOTCHAIN_UNILOADER_DEFCONFIG: chain, linux)"
cp "$B/arch/arm64/boot/Image" "$UL/blob/Image"
cp "$B/arch/arm64/boot/dts/$DTB" "$UL/blob/dtb"
cp "$OUT/ramdisk.cpio.gz" "$UL/blob/ramdisk"
cp "$UBO/u-boot.bin" "$UL/blob/u-boot.bin"
for m in chain:0 linux:1; do
	make -s -C "$UL" ARCH=aarch64 CROSS_COMPILE=$CC clean >/dev/null 2>&1 || true
	make -s -C "$UL" ARCH=aarch64 CROSS_COMPILE=$CC "$CFG_BOOTCHAIN_UNILOADER_DEFCONFIG"
	sed -i "s/^CONFIG_CHAINLOAD_DEFAULT=.*/CONFIG_CHAINLOAD_DEFAULT=${m#*:}/" "$UL/.config"
	make -s -C "$UL" ARCH=aarch64 CROSS_COMPILE=$CC -j"$JOBS"
	grep -q "^#define CONFIG_CHAINLOAD_DEFAULT ${m#*:}\$" "$UL/include/generated/autoconf.h" ||
		{ echo "CONFIG_CHAINLOAD_DEFAULT did not stick" >&2; exit 1; }
	cp "$UL/uniLoader" "$OUT/uniLoader-${m%:*}"
done

tree_id() { git -C "$R" rev-parse "HEAD:$1" 2>/dev/null || echo unknown; }
{
	echo "version: $VER"
	echo "repo: https://github.com/$CFG_PROJECT_REPO $(git -C "$R" rev-parse HEAD 2>/dev/null || echo unknown)"
	echo "linux: https://github.com/torvalds/linux $KBASE + $CFG_KERNEL_APORT/$(basename "$KPATCH") (sha256 $(sha256sum < "$KPATCH" | cut -c1-64))"
	echo "linux-config: $CFG_BOOTCHAIN_BRINGUP_CONFIG"
	echo "init: initramfs/init.c"
	echo "u-boot: bootchain/u-boot (tree $(tree_id bootchain/u-boot)), $CFG_BOOTCHAIN_U_BOOT_DEFCONFIG"
	echo "uniloader: bootchain/uniLoader (tree $(tree_id bootchain/uniLoader)), $CFG_BOOTCHAIN_UNILOADER_DEFCONFIG"
	echo "f2fs-tools: $F2FS_VER (https://dl-cdn.alpinelinux.org/alpine/v3.22/main, aarch64)"
	echo "licenses: GPL-2.0 (Linux, U-Boot, uniLoader, init), GPL-2.0/LGPL-2.1 (f2fs-tools), MIT (musl)"
	echo "contains no Samsung files: the installer adds the owner's stock DTB and the AVB footer"
	(cd "$OUT" && sha256sum uniLoader-chain uniLoader-linux ramdisk.cpio.gz)
} > "$OUT/MANIFEST"
tar -C "$OUT" -czf "$OUT/${CFG_DEVICE_CODENAME}-bootchain_$VER.tar.gz" uniLoader-chain uniLoader-linux ramdisk.cpio.gz MANIFEST
log "payload: $OUT/${CFG_DEVICE_CODENAME}-bootchain_$VER.tar.gz"
cat "$OUT/MANIFEST"
