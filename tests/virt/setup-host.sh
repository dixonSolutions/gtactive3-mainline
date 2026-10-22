#!/bin/sh
# Host tools for the QEMU harness: qemu-system-aarch64 (+ the virtio-gpu
# module), aarch64 edk2, mtools, zstd, gpg, sfdisk.
#
# Fedora without root: the RPMs are downloaded and unpacked into
# build/virt/host (harness.py prefers that tree; nothing is installed into
# the system). Debian/Ubuntu (CI): apt-get install.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOST=$ROOT/build/virt/host

if command -v apt-get >/dev/null 2>&1; then
	sudo apt-get update -q
	sudo apt-get install -y -q --no-install-recommends qemu-system-arm \
		qemu-efi-aarch64 mtools zstd gpg fdisk
	exit 0
fi

command -v dnf >/dev/null || { echo "neither apt-get nor dnf found" >&2; exit 1; }
for t in mcopy zstd gpg sfdisk rpm2cpio cpio; do
	command -v $t >/dev/null || { echo "missing host tool: $t" >&2; exit 1; }
done
if [ -x "$HOST/usr/bin/qemu-system-aarch64" ]; then
	echo "already set up: $HOST"
	exit 0
fi
rpms=$ROOT/build/virt/rpms
mkdir -p "$rpms" "$HOST"
# --resolve fetches only the dependencies this host lacks
(cd "$rpms" && dnf download -q --resolve qemu-system-aarch64-core edk2-aarch64 \
	qemu-device-display-virtio-gpu qemu-device-display-virtio-gpu-pci)
for r in "$rpms"/*.rpm; do
	case ${r##*/} in
	systemd-*|*.i686.rpm) continue ;;	# never shadow the host's systemd
	esac
	(cd "$HOST" && rpm2cpio "$r" | cpio -idm --quiet)
done
LD_LIBRARY_PATH=$HOST/usr/lib64 "$HOST/usr/bin/qemu-system-aarch64" --version | head -1
