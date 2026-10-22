# shellcheck shell=bash
# Published images and the boot-chain payload: list, download, verify.
#
# Trust: every release carries SHA256SUMS signed with the project key
# (pmos/sysupdate-public-key.asc, fingerprint in docs/RELEASES.md), the same
# key the tablets' systemd-sysupdate trusts. A file is used only if its hash
# is in a SHA256SUMS whose signature checks out with that key.

GTA3_PAGES=${GTA3_PAGES:-https://dixonsolutions.github.io/gtactive3-mainline}
GTA3_API=${GTA3_API:-https://api.github.com/repos/dixonSolutions/gtactive3-mainline}
GTA3_DL=${GTA3_DL:-https://github.com/dixonSolutions/gtactive3-mainline/releases/download}
PROJECT_FPR=D0FE850AF01A47831B6EF808583161CE787FF5B5
TRUSTED_KEY=${GTA3_TRUSTED_KEY:-$GTA3_REPO/pmos/sysupdate-public-key.asc}
TRUSTED_FPR=${GTA3_TRUSTED_FPR:-$PROJECT_FPR}
BOOTCHAIN_TAG=samsung-gtactive3wifi_bootchain

PY_REL() { python3 -I "$INST/py/releases.py" "$@"; }

trust_note() {
	if [ "$TRUSTED_FPR" != "$PROJECT_FPR" ]; then
		warn "TESTING: trusting the key $TRUSTED_FPR instead of the project key (GTA3_TRUSTED_FPR)"
	fi
}

fetch() { # URL OUT: small files
	curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
}

# download URL OUT SIZE: big files, resumable (OUT.part), with progress
download() {
	local url=$1 out=$2 size=${3:-0} have
	[ -f "$out" ] && { dbg "already downloaded: $out"; return 0; }
	mkdir -p "$(dirname "$out")"
	have=$(stat -c %s "$out.part" 2>/dev/null || echo 0)
	if [ "$size" -gt 0 ] && [ "$have" -eq "$size" ]; then
		mv -f "$out.part" "$out"
		return 0
	fi
	if [ "$size" -gt 0 ]; then
		need_space "$(dirname "$out")" $((size - have + (256 << 20))) "$(basename "$out")" ||
			die "not enough space"
		info "downloading $(basename "$out") ($(human_bytes "$size"))"
	else
		info "downloading $(basename "$out")"
	fi
	local p=-s
	[ -t 2 ] && p=--progress-bar
	act "download $(basename "$out")" curl -fL $p --retry 5 --retry-delay 3 --connect-timeout 30 \
		-C - -o "$out.part" "$url" || die "download failed: $url (run ./setup.sh again to resume)"
	dry && return 0
	mv -f "$out.part" "$out"
}

# verify_sums DIR: DIR/SHA256SUMS signed by the trusted key (DIR/SHA256SUMS.gpg)
verify_sums() {
	local d=$1 g st
	g=$(mktemp -d)
	GNUPGHOME=$g gpg --batch --quiet --import "$TRUSTED_KEY" 2>>"$LOG_FILE" || { rm -rf "$g"; die "cannot read $TRUSTED_KEY"; }
	st=$(GNUPGHOME=$g gpg --batch --status-fd 1 --verify "$d/SHA256SUMS.gpg" "$d/SHA256SUMS" 2>>"$LOG_FILE" || true)
	rm -rf "$g"
	if printf '%s\n' "$st" | grep -q "^\[GNUPG:\] VALIDSIG $TRUSTED_FPR "; then
		ok "SHA256SUMS signature: good (key $TRUSTED_FPR)"
		return 0
	fi
	_log "gpg status: $st"
	die "SHA256SUMS in $d is NOT signed by the project key: refusing to use it"
}

# sums_hash DIR NAME: the signed hash of NAME
sums_hash() { awk -v n="$2" '$2 == n || $2 == "*" n { print $1; exit }' "$1/SHA256SUMS"; }

check_hash() { # FILE WANT
	local got
	dry && return 0
	[ -n "$2" ] || die "$(basename "$1") is not listed in the signed SHA256SUMS"
	info "checking $(basename "$1") (sha256)..."
	got=$(sha256sum "$1" | cut -c1-64)
	if [ "$got" != "$2" ]; then
		mv -f "$1" "$1.bad"
		die "$(basename "$1") has the wrong hash (moved to $1.bad): download it again"
	fi
	ok "$(basename "$1"): hash matches the signed SHA256SUMS"
}

# get_sums TAG DIR: signed manifest of a release, verified
get_sums() {
	mkdir -p "$2"
	fetch "$GTA3_DL/$1/SHA256SUMS" "$2/SHA256SUMS" || die "cannot download SHA256SUMS of $1"
	fetch "$GTA3_DL/$1/SHA256SUMS.gpg" "$2/SHA256SUMS.gpg" || die "cannot download SHA256SUMS.gpg of $1"
	verify_sums "$2"
}

# release_index OUT: releases.json, or the same built from the GitHub API
release_index() {
	local t
	if fetch "$GTA3_PAGES/releases.json" "$1" 2>/dev/null && PY_REL channels "$1" >/dev/null 2>&1; then
		dbg "index: $GTA3_PAGES/releases.json"
		return 0
	fi
	t=$(mktemp)
	fetch "$GTA3_API/releases?per_page=100" "$t" || { rm -f "$t"; die "cannot reach GitHub ($GTA3_API)"; }
	PY_REL from-api "$t" "$GTA3_DL" > "$1" || { rm -f "$t"; die "cannot read the GitHub releases"; }
	rm -f "$t"
	dbg "index: built from the GitHub releases API"
}

# choose_image: sets IMG_CHANNEL IMG_VERSION IMG_UI IMG_FLAVOUR
choose_image() {
	local idx=$CACHE_DIR/releases.json lines n i c opts=() def=0 ch rec
	step "Choose the image"
	release_index "$idx"
	lines=$(PY_REL channels "$idx")
	[ -n "$lines" ] || die "no published images yet"
	if [ -n "${OPT_CHANNEL:-}" ]; then
		printf '%s\n' "$lines" | grep -q "^$OPT_CHANNEL	" || die "no channel $OPT_CHANNEL (have: $(printf '%s\n' "$lines" | cut -f1 | tr '\n' ' '))"
		c=$(printf '%s\n' "$lines" | grep -n "^$OPT_CHANNEL	" | cut -d: -f1)
	else
		i=1
		# Phosh is the recommended UI (a touch-first shell for the tablet):
		# its release image is the default, else its dev image
		while IFS=$'\t' read -r _ ui fl ver _ latest title; do
			rec=
			if [ "$ui" = phosh ] && { [ "$fl" = release ] || [ "$def" = 0 ]; }; then
				def=$i
			fi
			[ "$ui" = phosh ] && rec=' [recommended]'
			opts+=("$title$rec: $latest$( [ "$fl" = dev ] && printf ' (dev: USB debug layer, passwordless root over USB)')$( [ "$ver" = yes ] && printf ', tested on the device' || printf ', not yet confirmed on a device')")
			i=$((i + 1))
		done <<< "$lines"
		[ "$def" != 0 ] || def=1
		c=$(choose "Which image?" "$def" "${opts[@]}")
	fi
	ch=$(printf '%s\n' "$lines" | sed -n "${c}p")
	IFS=$'\t' read -r IMG_CHANNEL IMG_UI IMG_FLAVOUR n _ IMG_VERSION _ <<< "$ch"
	[ -n "${OPT_VERSION:-}" ] && IMG_VERSION=$OPT_VERSION
	info "chosen: $IMG_CHANNEL $IMG_VERSION"
	[ "$n" = yes ] || warn "this version is not yet confirmed on a device"
	if [ "$IMG_FLAVOUR" = dev ]; then
		box "dev image: development tablets only" \
			"It runs a root shell, ssh and adb on the USB cable WITHOUT a" \
			"password. Anyone who plugs into the tablet owns it. Use the" \
			"release image unless you develop this port."
		ask_yn "Use the dev image?" y || die "choose a release image"
	fi
}

# fetch_image: download + verify the full disk image, sets IMG_RAW
fetch_image() {
	local idx=$CACHE_DIR/releases.json d name size url
	if [ -n "${OPT_IMAGE:-}" ]; then
		[ -f "$OPT_IMAGE" ] || die "no such image: $OPT_IMAGE"
		IMG_RAW=$OPT_IMAGE
		IMG_CHANNEL=${IMG_CHANNEL:-local}
		IMG_VERSION=${IMG_VERSION:-$(basename "$OPT_IMAGE" | grep -oE '_[0-9]{8}' | tr -d _ | tail -1 || true)}
		IMG_VERSION=${IMG_VERSION:-unknown}
		warn "using a local image without a signature check: $OPT_IMAGE"
		return 0
	fi
	[ -n "${IMG_CHANNEL:-}" ] || choose_image
	trust_note
	d=$CACHE_DIR/images/$IMG_CHANNEL
	get_sums "$IMG_CHANNEL" "$d"
	read -r name size url < <(PY_REL files "$idx" "$IMG_CHANNEL" "$IMG_VERSION" |
		awk -F'\t' '$1 == "install-raw" { print $2, $3, $5; exit }')
	[ -n "${name:-}" ] || die "$IMG_CHANNEL $IMG_VERSION has no full disk image"
	download "$url" "$d/$name" "$size"
	check_hash "$d/$name" "$(sums_hash "$d" "$name")"
	IMG_RAW=$d/$name
}

# ---------- boot-chain payload (uniLoader + U-Boot + our bring-up Linux) ----------

# payload_acquire: sets PAYLOAD (a directory with uniLoader-chain,
# uniLoader-linux, ramdisk.cpio.gz, MANIFEST)
payload_acquire() {
	local d name t
	step "Boot chain (uniLoader + U-Boot + our Linux)"
	if [ -n "${OPT_PAYLOAD:-}" ]; then
		if [ -d "$OPT_PAYLOAD" ]; then
			PAYLOAD=$OPT_PAYLOAD
		else
			PAYLOAD=$CACHE_DIR/payload/local
			rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
			tar -xzf "$OPT_PAYLOAD" -C "$PAYLOAD" || die "cannot unpack $OPT_PAYLOAD"
		fi
		warn "using a local boot-chain payload without a signature check: $OPT_PAYLOAD"
	else
		trust_note
		d=$CACHE_DIR/payload
		get_sums "$BOOTCHAIN_TAG" "$d"
		name=$(awk '{ print $2 }' "$d/SHA256SUMS" | tr -d '*' | grep -E '^gtactive3wifi-bootchain_[0-9.]+\.tar\.gz$' |
			sort -V | tail -1)
		[ -n "$name" ] || die "the boot-chain release has no payload"
		download "$GTA3_DL/$BOOTCHAIN_TAG/$name" "$d/$name" 0
		check_hash "$d/$name" "$(sums_hash "$d" "$name")"
		PAYLOAD=$d/${name%.tar.gz}
		if [ ! -f "$PAYLOAD/MANIFEST" ]; then
			t=$PAYLOAD.part
			rm -rf "$t"; mkdir -p "$t"
			tar -xzf "$d/$name" -C "$t" || die "cannot unpack $name"
			mv "$t" "$PAYLOAD"
		fi
	fi
	for t in uniLoader-chain uniLoader-linux ramdisk.cpio.gz; do
		[ -s "$PAYLOAD/$t" ] || die "the boot-chain payload has no $t"
	done
	state_set PAYLOAD_VERSION "$(sed -n 's/^version: //p' "$PAYLOAD/MANIFEST" 2>/dev/null | head -1)"
	ok "boot chain $(state_get PAYLOAD_VERSION local)"
}
