#!/bin/sh
# Build a QEMU-capable kernel Image for repacking an existing image's UKI
# (tests/virt/uki-virt.py --linux): the packaged linux-postmarketos-exynos9810
# config plus the virt.config fragment, from the same kernel commit.
#
# Only needed for images whose kernel predates virt.config. The Image is
# built in the package builder container with the package's compiler and
# ccache, and only the built-in part (make Image): the image's own modules
# (/usr/lib/modules/<release>) keep loading because the release string and
# the module ABI do not change (no MODVERSIONS; virt.config only adds
# built-in drivers).
#
#   tests/virt/build-kernel.sh [KREF]
#     KREF   src/linux commit (default: _commit of the aport)
#   output: build/virt/kernel/Image-<sha12>  (path printed on stdout)
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PMAPORTS=${PMAPORTS:-$ROOT/build/wt/pmaports-duranium}
CONTRIB=${CONTRIB:-$ROOT/build/wt/duranium/contrib/samsung-gtactive3wifi}
APORT=$PMAPORTS/device/testing/linux-postmarketos-exynos9810
BUILDER=${BUILDER:-gta3-pkgbuilder}
JOBS=${JOBS:-8}
OUT=$ROOT/build/virt/kernel

kref=${1:-$(sed -n 's/^_commit="\([0-9a-f]*\)"/\1/p' "$APORT/APKBUILD")}
sha=$(git -C "$ROOT/src/linux" rev-parse "$kref^{commit}")
short=$(echo "$sha" | cut -c1-12)
image=$OUT/Image-$short
if [ -s "$image" ]; then
	echo "$image"
	exit 0
fi

# in-tree build like abuild, at the same path below /b, so the package
# build's ccache entries hit
src=$OUT/src/linux-$sha
if [ ! -d "$src" ]; then
	rm -rf "$OUT/src"
	mkdir -p "$src"
	git -C "$ROOT/src/linux" archive "$sha" | tar -x -C "$src"
fi
cp "$APORT/config-postmarketos-exynos9810.aarch64" "$src/pkg.config"
cp "$CONTRIB/kernel/virt.config" "$CONTRIB/kernel/mergecfg.py" "$src/"

mkdir -p "$ROOT/build/ccache"
# shellcheck disable=SC2016 # expanded by the container shell
flock "$ROOT/build/kbuild.lock" nice -n 19 podman run --rm --entrypoint /bin/sh \
	-v "$ROOT/build/ccache:/ccache:Z" -e CCACHE_DIR=/ccache -e CCACHE_NOHASHDIR=1 \
	-e CCACHE_BASEDIR=/b -e CCACHE_MAXSIZE=15G \
	-e CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime \
	-v "$src:/b/linux-postmarketos-exynos9810/src/linux-$sha:Z" \
	-w "/b/linux-postmarketos-exynos9810/src/linux-$sha" -e JOBS="$JOBS" \
	"$BUILDER" -euc '
	python3 mergecfg.py pkg.config .config virt.config
	k="make ARCH=arm64 CROSS_COMPILE=aarch64-alpine-linux-musl-"
	$k olddefconfig
	$k -j"$JOBS" CC="ccache aarch64-alpine-linux-musl-gcc" \
		KBUILD_BUILD_VERSION=virt-postmarketOS Image
	'

# every virt.config line must have survived olddefconfig
grep -E '^CONFIG_[A-Za-z0-9_]+=' "$CONTRIB/kernel/virt.config" | while IFS= read -r l; do
	grep -qxF "$l" "$src/.config" || { echo "not applied: $l" >&2; exit 1; }
done
mkdir -p "$OUT"
cp "$src/arch/arm64/boot/Image" "$image.tmp"
mv "$image.tmp" "$image"
echo "$image"
