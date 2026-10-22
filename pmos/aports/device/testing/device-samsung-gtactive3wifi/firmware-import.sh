#!/bin/sh
# Install the owner's Samsung firmware that the installer (gtactive3-mainline
# setup.sh) left on the ESP: Wi-Fi, Bluetooth, the audio DSPs, NFC and the
# S Pen need it, and the published images cannot carry it. It goes to
# /var/lib/firmware on the encrypted root, which A/B updates never touch and
# which the kernel searches first (firmware_class.path).
#
# The tarball holds paths relative to /lib/firmware (brcm/..., samsung/...).
# It stays on the ESP, so a fresh root (first boot, or a factory reset of
# the root partition) gets the firmware again. It is imported when
# /var/lib/firmware is empty or holds an older import from the ESP; firmware
# put there by hand (scripts/firmware-to-tablet: no .imported) is left alone.
# The copy is checked against its .sha256, unpacked next to the old tree and
# swapped in whole, so a damaged or partial copy is never used.
set -eu

src=/boot/gtactive3wifi-firmware.tar.zst
dst=/var/lib/firmware

want=$(cut -d' ' -f1 "$src.sha256")
if [ -e "$dst/.imported" ]; then
	[ "$(cut -d' ' -f1 "$dst/.imported")" != "$want" ] || exit 0
elif [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
	echo "$dst holds firmware installed by hand, not replaced"
	exit 0
fi

have=$(sha256sum "$src" | cut -d' ' -f1)
if [ "$want" != "$have" ]; then
	echo "$src: checksum mismatch, not imported" >&2
	exit 1
fi

# Only plain relative paths: the tarball comes from a FAT partition anyone
# with the tablet in hand can write
if zstd -dcq "$src" | tar -t -f - | grep -qE '(^/|(^|/)\.\.(/|$))'; then
	echo "$src: absolute or .. paths, not imported" >&2
	exit 1
fi

rm -rf "$dst.new" "$dst.old"
mkdir -p "$dst.new"
zstd -dcq "$src" | tar -x -o -f - -C "$dst.new"
echo "$have" > "$dst.new/.imported"
[ ! -d "$dst" ] || mv "$dst" "$dst.old"
mv "$dst.new" "$dst"
rm -rf "$dst.old"
echo "firmware imported: $(find "$dst" -type f ! -name .imported | wc -l) files"
