#!/bin/sh
# Download one version of a published update channel (a GitHub release) and
# check it the way a tablet does: SHA256SUMS signed with the project key
# (pmos/sysupdate-public-key.asc), every file's sha256.
#
#   tests/virt/fetch-release.sh TAG [VERSION] [all]
#     TAG      e.g. samsung-gtactive3wifi_phosh_edge-dev
#     VERSION  default: the newest one in SHA256SUMS
#     raw      the disk image (default)
#     update   the update artifacts (UKI, usr, verity, extensions), for
#              harness.py check --update DIR:VERSION
#     all      both
#   output: build/virt/dl/TAG/ (path of the disk image printed on stdout)
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REPO=${REPO:-$("$(dirname "$0")/../../scripts/config" get project.repo)}
TAG=$1
VERSION=${2:-}
WHAT=${3:-raw}
BASE=https://github.com/$REPO/releases/download/$TAG
DL=$ROOT/build/virt/dl/$TAG
mkdir -p "$DL"
cd "$DL"

curl -sfL -o SHA256SUMS "$BASE/SHA256SUMS"
curl -sfL -o SHA256SUMS.gpg "$BASE/SHA256SUMS.gpg"
ring=$(mktemp)
trap 'rm -f "$ring"' EXIT
gpg -q --batch --no-default-keyring --keyring "$ring" --import "$ROOT/pmos/sysupdate-public-key.asc" 2>/dev/null
gpg -q --batch --no-default-keyring --keyring "$ring" --verify SHA256SUMS.gpg SHA256SUMS >&2

prefix=${TAG%-dev}
[ -n "$VERSION" ] ||
	VERSION=$(sed -n "s/.* ${prefix}_\([0-9]\{8\}\)\..*/\1/p" SHA256SUMS | sort -n | tail -1)
[ -n "$VERSION" ] || { echo "no versions in $TAG" >&2; exit 1; }
all=$(awk '{print $2}' SHA256SUMS | grep "^${prefix}_$VERSION\." || true)
[ -n "$all" ] || { echo "$VERSION is not (or no longer) in $TAG" >&2; exit 1; }
case $WHAT in
raw) files=${prefix}_$VERSION.raw.zst ;;
update) files=$(echo "$all" | grep -vx "${prefix}_$VERSION.raw.zst") ;;
all) files=$all ;;
*) echo "third argument: raw, update or all" >&2; exit 1 ;;
esac

avail=$(df -Pk . | awk 'NR == 2 {print $4}')
# the disk image unpacks to ~7 GB next to the download
[ "$avail" -gt $((12 * 1024 * 1024)) ] || { echo "less than 12 GB free in $DL" >&2; exit 1; }
for f in $files; do
	if ! grep " $f\$" SHA256SUMS | sha256sum -c --status 2>/dev/null; then
		echo "downloading $f" >&2
		curl -sfL --retry 3 -o "$f.part" "$BASE/$f"
		mv "$f.part" "$f"
	fi
	grep " $f\$" SHA256SUMS | sha256sum -c --quiet >&2
done
echo "$DL/${prefix}_$VERSION.raw.zst"
