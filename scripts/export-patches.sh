#!/bin/bash
# Export our commits on the gtactive3wifi branches as patch series into patches/.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)
for t in linux uniLoader; do
	r=$P/src/$t
	up=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD)
	base=$(git -C "$r" merge-base gtactive3wifi "$up")
	rm -rf "$P/patches/$t"; mkdir -p "$P/patches/$t"
	git -C "$r" format-patch -q -o "$P/patches/$t" "$base"..gtactive3wifi
	echo "$(git -C "$r" remote get-url origin) $base" > "$P/patches/$t/BASE"
	echo "$t: $(ls "$P/patches/$t"/*.patch | wc -l) patches on $up ($(git -C "$r" rev-parse --short "$base"))"
done
