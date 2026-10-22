#!/bin/sh
# System and configuration extensions are built for one image version
# (their extension-release says ID=_any, so systemd-sysext would merge any
# version found). scripts/duranium-update keeps the images of the booted
# and the new version in /var/lib/duranium-extensions; link the ones built
# with this /usr into /run/extensions and /run/confexts, so a fallback boot
# of the previous version gets its own.
set -eu
S=/var/lib/duranium-extensions
. /usr/lib/os-release
[ -n "${IMAGE_VERSION:-}" ] || exit 0
mkdir -p "$S"
# versioned images copied straight into the search paths by hand (before
# this service existed) would be merged whatever their version: move them
for f in /var/lib/extensions/*_[0-9]*.*-sysext-*.raw \
	/var/lib/confexts/*_[0-9]*.*-confext-*.raw; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	mv -f "$f" "$S/"
	echo "moved $f to $S"
done
for f in "$S"/*_"$IMAGE_VERSION".*.raw; do
	[ -f "$f" ] || continue
	case "${f##*/}" in
	*-sysext-*) d=/run/extensions ;;
	*-confext-*) d=/run/confexts ;;
	*) continue ;;
	esac
	mkdir -p "$d"
	ln -sfn "$f" "$d/"
	echo "${f##*/} -> $d"
done
