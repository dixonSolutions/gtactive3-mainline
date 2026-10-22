#!/bin/sh
# tests/claim-space/run.sh with BusyBox (ash, coreutils, awk, sed, dd, od)
# instead of the PC's tools, in an Alpine container without network: the
# tablet runs BusyBox userland next to util-linux and coreutils.
#
#   tests/claim-space/busybox.sh [PATTERN]
#   ALPINE=docker.io/library/alpine:3.22 (default, must be pulled already)
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
exec podman run --rm --network=none --security-opt label=disable \
	-v "$REPO:$REPO" -w "$REPO" -e GTA3_TEST_DIR="$REPO/build/test-claim-space-busybox" \
	"${ALPINE:-docker.io/library/alpine:3.22}" sh tests/claim-space/run.sh "$@"
