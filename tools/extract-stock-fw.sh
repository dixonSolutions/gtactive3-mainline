#!/bin/bash
# Extract every vendor firmware blob from the stock SM-T570 firmware package.
#
#   FW.zip.enc4 --AES-128-ECB--> FW.zip --stream--> AP tar --> super.img.lz4, boot.img.lz4
#   super: lz4 -> simg2img -> lpunpack -> {system,vendor,product,odm}.img -> debugfs rdump
#   boot:  lz4 -> kernel Image -> CONFIG_EXTRA_FIRMWARE + bbd patch (builtin_fw_extract.py)
#   -> firmware/extracted/{vendor,kernel-builtin,hints,linux-firmware} + INDEX.md (fw_index.py)
#
# Everything lands under firmware/ (gitignored). Idempotent: finished steps are skipped.
# The encrypted .enc4 is never modified or deleted.
#
# usage: tools/extract-stock-fw.sh [FW.zip.enc4]
#   env: FW=<firmware dir> KEY=<logic-check key file> PY=<python with 'cryptography'>
#        CLEAN=1  remove the 7 GB unsparsed super.raw.img at the end
# needs: lz4, simg2img, lpunpack, debugfs (e2fsprogs); fsck.erofs only if a partition is EROFS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS=$ROOT/tools
FW=${FW:-$ROOT/firmware}
KEY=${KEY:-$FW/enc4-key.txt}
PY=${PY:-$TOOLS/venv/bin/python}
ENC=${1:-$(ls "$FW"/*.zip.enc4 | head -n1)}
ZIP=${ENC%.enc4}
AP=$FW/ap
SUPER=$FW/super
FS=$FW/fs
OUT=$FW/extracted
LOW="nice -n 19 ionice -c3"

log() { printf '\n== %s\n' "$*"; }
for t in lz4 simg2img lpunpack debugfs; do
	command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

log "1/6 decrypt $(basename "$ENC")"
if [ -s "$ZIP" ] && [ "$(stat -c %s "$ZIP")" = "$(stat -c %s "$ENC")" ]; then
	echo "already decrypted: $ZIP"
else
	$LOW "$PY" -I "$TOOLS/enc4_decrypt.py" "$ENC" "$KEY" "$ZIP"
fi

log "2/6 pull images out of the AP tar"
mkdir -p "$AP"
if [ ! -s "$AP/super.img.lz4" ] || [ ! -s "$AP/boot.img.lz4" ]; then
	$LOW "$PY" -I "$TOOLS/fwzip_extract.py" "$ZIP" "$AP" \
		super.img.lz4 boot.img.lz4 dtbo.img.lz4 vbmeta.img.lz4 | tee "$AP/listing.txt"
fi

log "3/6 super -> logical partitions"
if [ ! -s "$SUPER/vendor.img" ]; then
	if [ ! -s "$AP/super.raw.img" ]; then
		$LOW lz4 -d -q -f "$AP/super.img.lz4" "$AP/super.sparse.img"
		$LOW simg2img "$AP/super.sparse.img" "$AP/super.raw.img.part"
		mv "$AP/super.raw.img.part" "$AP/super.raw.img"
		rm -f "$AP/super.sparse.img"
	fi
	mkdir -p "$SUPER"
	lpunpack "$AP/super.raw.img" "$SUPER/"
fi
ls -l "$SUPER"

log "4/6 dump filesystems"
for img in "$SUPER"/*.img; do
	p=$(basename "$img" .img)
	[ -s "$img" ] || continue
	[ -e "$FS/$p/.done" ] && { echo "$p: done"; continue; }
	rm -rf "${FS:?}/$p"; mkdir -p "$FS/$p"
	case $(file -b "$img") in
	*ext[234]*)
		# rdump cannot chown as a user; those warnings are harmless
		$LOW debugfs -R "rdump / $FS/$p" "$img" 2>&1 | grep -v 'changing ownership' || true ;;
	*EROFS*|*erofs*)
		command -v fsck.erofs >/dev/null || { echo "$p is EROFS: install erofs-utils" >&2; exit 1; }
		$LOW fsck.erofs --extract="$FS/$p" "$img" ;;
	*) echo "$p: unknown filesystem, skipped"; continue ;;
	esac
	touch "$FS/$p/.done"
	echo "$p: $(du -sh "$FS/$p" | cut -f1)"
done

log "5/6 stock kernel built-in firmware"
if [ ! -s "$AP/boot-kernel" ]; then
	lz4 -d -q -f "$AP/boot.img.lz4" "$AP/boot.img"
	# Android boot header (v0-v2): kernel_size @8, page_size @36, kernel at 1 page
	python3 -I -c '
import struct, sys
b = open(sys.argv[1], "rb").read()
assert b[:8] == b"ANDROID!", "not an Android boot image"
ks, ps = struct.unpack_from("<I", b, 8)[0], struct.unpack_from("<I", b, 36)[0]
open(sys.argv[2], "wb").write(b[ps:ps + ks])
' "$AP/boot.img" "$AP/boot-kernel"
fi
rm -rf "$FW/builtin-fw"
python3 -I "$TOOLS/builtin_fw_extract.py" "$AP/boot-kernel" "$FW/builtin-fw" tsp_himax/hx83102e_gtactive3.bin

log "6/6 collect into $OUT"
V=$FS/vendor
rm -rf "$OUT"; mkdir -p "$OUT/vendor/etc" "$OUT/hints/vendor/etc" "$OUT/hints/odm/etc"
cp -a "$V/firmware" "$OUT/vendor/firmware"
cp -a "$V/tee" "$OUT/vendor/tee"
for d in wifi nfc gnss sensor sensors; do
	[ -d "$V/etc/$d" ] && cp -a "$V/etc/$d" "$OUT/vendor/etc/$d"
done
cp -a "$FW/builtin-fw" "$OUT/kernel-builtin"
# reference material: init scripts, HAL manifests, partitions, props, audio routing
cp -a "$V/etc/init" "$V/etc/vintf" "$OUT/hints/vendor/etc/"
cp -a "$V/etc/"*.xml "$V/etc/fstab."* "$V/etc/"*.conf "$V/etc/"*.json "$OUT/hints/vendor/etc/" 2>/dev/null || true
cp -a "$V/ueventd.rc" "$V/build.prop" "$OUT/hints/vendor/"
cp -a "$FS/odm/etc/build.prop" "$OUT/hints/odm/etc/" 2>/dev/null || true
[ -f "$V/vendor_dlkm/etc/build.prop" ] && cp "$V/vendor_dlkm/etc/build.prop" "$OUT/hints/vendor/vendor_dlkm.build.prop"

# vendor kernel modules (expected: none, the stock kernel is monolithic)
{
	echo "Kernel modules (*.ko) in all dumped partitions:"
	find "$FS" -name '*.ko' -printf '  %P\n' | sort
	echo "  (end)"
} > "$OUT/hints/kernel-modules.txt"
cat "$OUT/hints/kernel-modules.txt"

{
	echo "package: $(basename "$ENC")"
	echo "enc4 sha256: $(sha256sum "$ENC" | cut -d' ' -f1)"
	grep -h '^entry ' "$AP/listing.txt" 2>/dev/null | sed 's/^entry /tar: /'
	if ! unzip -l "$ZIP" >/dev/null 2>&1; then
		echo "zip has no central directory (download incomplete); members that inflate completely are" \
			"the ones listed above, extraction stops once super/boot/dtbo/vbmeta are out"
	fi
	grep -h '^ro.vendor.build.fingerprint=\|^ro.vendor.build.version.incremental=' "$V/build.prop"
	echo "kernel: $(strings "$AP/boot-kernel" | grep -m1 '^Linux version' | cut -c1-60)"
} > "$OUT/SOURCE.txt"

python3 -I "$TOOLS/fw_index.py" "$OUT"

if [ "${CLEAN:-0}" = 1 ]; then
	rm -f "$AP/super.raw.img" "$AP/boot.img"
fi
log "done: $OUT/INDEX.md"
