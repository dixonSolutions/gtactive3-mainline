#!/bin/bash
# Export our work on the gtactive3wifi branches:
#   Linux      -> patches/linux, a patch series on its base (BASE)
#   U-Boot     -> bootchain/u-boot   } the vendored trees the boot chain
#   uniLoader  -> bootchain/uniLoader} builds from (bootchain/README.md)
# Boot-chain fixes that are not about this device belong in
# exynos-linux/device-template's bootchain/ first.
set -euo pipefail
P=$(cd "$(dirname "$0")/.." && pwd)

r=$P/src/linux
base=$(git -C "$r" merge-base gtactive3wifi "$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD)")
rm -rf "$P/patches/linux"; mkdir -p "$P/patches/linux"
git -C "$r" format-patch -q -o "$P/patches/linux" "$base"..gtactive3wifi
echo "$(git -C "$r" remote get-url origin) $base" > "$P/patches/linux/BASE"
echo "linux: $(ls "$P/patches/linux"/*.patch | wc -l) patches ($(git -C "$r" rev-parse --short "$base"))"

# every file of the branch, export-ignore and .gitignore'd ones included
# (git archive would drop them), through a scratch index
for e in u-boot:u-boot-9820 uniLoader:uniLoader; do
	IFS=: read -r t d <<<"$e"
	r=$P/src/$d dst=$P/bootchain/$t idx=$(mktemp)
	rm -rf "$dst"; mkdir -p "$dst"
	GIT_INDEX_FILE=$idx git -C "$r" read-tree gtactive3wifi
	GIT_INDEX_FILE=$idx git -C "$r" checkout-index -a -f --prefix="$dst/"
	rm -f "$idx"
	git -C "$P" add -f -A "bootchain/$t"
	echo "$t: bootchain/$t = $(git -C "$r" log --oneline -1 gtactive3wifi)"
done
