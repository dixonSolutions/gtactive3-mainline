#!/bin/bash
# Export our commits on the gtactive3wifi branches as patch series into patches/.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
# name:repo-dir:upstream-ref (empty ref = origin/HEAD)
for e in linux:linux: uniLoader:uniLoader: u-boot:u-boot-9820:exynos9820; do
	IFS=: read -r t d up <<<"$e"
	r=$P/src/$d
	[ -n "$up" ] || up=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD)
	base=$(git -C "$r" merge-base gtactive3wifi "$up")
	rm -rf "$P/patches/$t"; mkdir -p "$P/patches/$t"
	git -C "$r" format-patch -q -o "$P/patches/$t" "$base"..gtactive3wifi
	echo "$(git -C "$r" remote get-url origin) $base" > "$P/patches/$t/BASE"
	echo "$t: $(ls "$P/patches/$t"/*.patch | wc -l) patches on $up ($(git -C "$r" rev-parse --short "$base"))"
done
