# shellcheck shell=bash
# Fixtures, the fake tablet and assertions for tests/installer/run.sh.

MOCK=$HERE/mock
FPR_FILE=$RUN/gpg/fpr

need() { command -v "$1" >/dev/null 2>&1; }

# ---------- fixtures (built once per run) ----------

fx_gpg() {
	mkdir -p "$RUN/gpg/home"
	chmod 700 "$RUN/gpg/home"
	GNUPGHOME=$RUN/gpg/home gpg --batch --quiet --passphrase '' \
		--quick-gen-key 'installer test key <test@example.invalid>' ed25519 sign never
	GNUPGHOME=$RUN/gpg/home gpg --batch --armor --export > "$RUN/gpg/pub.asc"
	GNUPGHOME=$RUN/gpg/home gpg --batch --with-colons --list-keys | awk -F: '/^fpr/ { print $10; exit }' > "$FPR_FILE"
}

sign_sums() { # DIR: SHA256SUMS of its files, signed with the test key
	(cd "$1" && sha256sum -- * | grep -v ' SHA256SUMS' > SHA256SUMS)
	GNUPGHOME=$RUN/gpg/home gpg --batch --yes --quiet --detach-sign -o "$1/SHA256SUMS.gpg" "$1/SHA256SUMS"
}

pad_file() { # FILE MARKER SIZE
	{ printf '%s' "$2"; head -c $(($3 - ${#2})) /dev/zero; } > "$1"
}

fx_stock() {
	local d=$RUN/fx/stock
	mkdir -p "$d"
	pad_file "$d/kernel" FAKE-STOCK-BOOT 65536
	pad_file "$d/dtb" FAKE-STOCK-DTB 4096
	printf 'stock ramdisk' | gzip > "$d/ramdisk"
	mkbootimg --header_version 2 --kernel "$d/kernel" --ramdisk "$d/ramdisk" --dtb "$d/dtb" \
		--base 0x10000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
		--tags_offset 0x00000100 --dtb_offset 0x00000000 --pagesize 2048 \
		--os_version 13.0.0 --os_patch_level 2025-10 --board SRPTF17A015 \
		--cmdline "androidboot.selinux=enforce" -o "$d/boot.img"
	truncate -s 61865984 "$d/boot.img"
	cp "$d/boot.img" "$d/recovery.img"
	lz4 -q -f "$d/boot.img" "$d/boot.img.lz4"
	lz4 -q -f "$d/recovery.img" "$d/recovery.img.lz4"
}

# vendor files as Android has them (fake contents)
fx_vendor_tree() {
	local v=$1/firmware
	mkdir -p "$v/nfc" "$1/etc/wifi"
	for f in bcmdhd_sta.bin_b1 bcmdhd_clm.blob nvram.txt_CS01_semco_b1 bcm4375B1_semco_sem.hcd \
		calliope_sram.bin vts.bin fimc_is_lib.bin; do
		printf 'fake %s\n' "$f" > "$v/$f"
	done
	printf 'fake nfc\n' > "$v/nfc/sec_s3nrn4v_firmware.bin"
	printf 'country=XX\n' > "$1/etc/wifi/indoorchannel.info"
}

fx_super() {
	local d=$RUN/fx/super
	mkdir -p "$d/vendor"
	fx_vendor_tree "$d/vendor"
	mke2fs -q -t ext4 -b 4096 -d "$d/vendor" "$d/vendor.img" 8M
	lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
		--device super:$((64 << 20)) --group main:$((32 << 20)) \
		--partition system:readonly:$((4 << 20)):main --image system=/dev/null \
		--partition vendor:readonly:$((8 << 20)):main --image vendor="$d/vendor.img" \
		--sparse --output "$d/super.img" >/dev/null 2>&1 ||
		lpmake --metadata-size 65536 --super-name super --metadata-slots 2 \
			--device super:$((64 << 20)) --group main:$((32 << 20)) \
			--partition vendor:readonly:$((8 << 20)):main --image vendor="$d/vendor.img" \
			--sparse --output "$d/super.img" >/dev/null
	simg2img "$d/super.img" "$d/super.raw"
	lz4 -q -f "$d/super.img" "$d/super.img.lz4"
}

fx_ap() {
	local d=$RUN/fx/ap n=AP_T570XXSFEYI1_CL0_X_REV00_user_low_ship_meta_OS13.tar
	mkdir -p "$d"
	cp "$RUN/fx/stock/boot.img.lz4" "$RUN/fx/stock/recovery.img.lz4" "$RUN/fx/super/super.img.lz4" "$d/"
	(cd "$d" && tar -cf "$n" boot.img.lz4 recovery.img.lz4 super.img.lz4 &&
		printf '%s  %s\n' "$(md5sum < "$n" | cut -c1-32)" "$n" >> "$n" && mv "$n" "$n.md5")
	AP_TAR=$d/$n.md5
}

fx_payload() {
	local d=$RUN/fx/payload/gtactive3wifi-bootchain_1.0
	mkdir -p "$d"
	pad_file "$d/uniLoader-chain" FAKE-UNILOADER-CHAIN 131072
	pad_file "$d/uniLoader-linux" FAKE-UNILOADER-LINUX 131072
	printf 'fallback ramdisk' | gzip > "$d/ramdisk.cpio.gz"
	printf 'version: 1.0\nsources: test fixture\n' > "$d/MANIFEST"
	mkdir -p "$RUN/srv/dl/samsung-gtactive3wifi_bootchain"
	tar -C "$d" -czf "$RUN/srv/dl/samsung-gtactive3wifi_bootchain/gtactive3wifi-bootchain_1.0.tar.gz" .
	sign_sums "$RUN/srv/dl/samsung-gtactive3wifi_bootchain"
	PAYLOAD_DIR=$d
}

# a small 4 KiB-sector Duranium-like disk: GPT + ESP (FAT16) + "usr"
fx_image() {
	local d=$RUN/fx/img ch=samsung-gtactive3wifi_phosh_edge-dev v=26102213 n
	n=samsung-gtactive3wifi_phosh_edge_$v
	mkdir -p "$d"
	mkfs.fat -F 16 -S 4096 -s 1 -n ESP -C "$d/esp.img" 32768 >/dev/null
	MTOOLS_SKIP_CHECK=1 mmd -i "$d/esp.img" ::/EFI ::/EFI/Linux
	echo uki | MTOOLS_SKIP_CHECK=1 mcopy -i "$d/esp.img" - "::/EFI/Linux/${n}.efi"
	truncate -s $(( (1 << 20) + (32 << 20) + (8 << 20) + (1 << 20) )) "$d/$n.raw"
	sfdisk -q --sector-size 4096 "$d/$n.raw" <<-EOF
		label: gpt
		start=256, size=8192, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=esp
		start=8448, size=2048, type=B0E01050-EE5F-4390-949A-9101B17104E9, name=duranium_${v}_usr
	EOF
	dd if="$d/esp.img" of="$d/$n.raw" bs=1M seek=1 conv=notrunc status=none
	printf 'FAKE-USR' | dd of="$d/$n.raw" bs=4096 seek=8448 conv=notrunc status=none
	mkdir -p "$RUN/srv/dl/$ch"
	zstd -q -f -o "$RUN/srv/dl/$ch/$n.raw.zst" "$d/$n.raw"
	echo uki > "$RUN/srv/dl/$ch/$n.efi"
	sign_sums "$RUN/srv/dl/$ch"
	IMG_RAW_FX=$d/$n.raw
	python3 - "$RUN/srv" "$ch" "$v" <<-'PY'
		import hashlib, json, os, sys
		srv, ch, v = sys.argv[1:]
		files = []
		for n in sorted(os.listdir(f"{srv}/dl/{ch}")):
		    p = f"{srv}/dl/{ch}/{n}"
		    kind = ("install-raw" if n.endswith(".raw.zst") else "uki" if n.endswith(".efi") else
		            "manifest" if n == "SHA256SUMS" else "signature")
		    files.append({"name": n, "size": os.path.getsize(p), "kind": kind,
		                  "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
		                  "url": f"@DL@/{ch}/{n}"})
		idx = {"schema": 1, "generated": "", "repo": "test", "channels": [
		    {"id": ch, "ui": "phosh", "flavour": "dev", "title": "Phosh", "description": "",
		     "prerelease": True, "verified": False, "latest": v,
		     "versions": [{"version": v, "date": "", "files": files}]}]}
		os.makedirs(f"{srv}/pages", exist_ok=True)
		json.dump(idx, open(f"{srv}/pages/releases.json.in", "w"))
		api = [{"tag_name": ch, "prerelease": True,
		        "assets": [{"name": f["name"], "size": f["size"]} for f in files]},
		       {"tag_name": "samsung-gtactive3wifi_bootchain", "prerelease": True, "assets": []}]
		os.makedirs(f"{srv}/api", exist_ok=True)
		json.dump(api, open(f"{srv}/api/releases.json", "w"))
	PY
}

build_fixtures() {
	local t
	for t in mkbootimg avbtool lpmake simg2img mke2fs mkfs.fat sfdisk mmd mcopy zstd lz4 gpg python3 debugfs; do
		need "$t" || { echo "the installer tests need $t" >&2; exit 2; }
	done
	mkdir -p "$RUN/bin" "$RUN/srv"
	for t in adb heimdall lsusb; do ln -sf "$MOCK/mockdev.py" "$RUN/bin/$t"; done
	fx_gpg
	fx_stock
	fx_super
	fx_ap
	fx_payload
	fx_image
	# recorders for the scripts the installer hands work to
	cat > "$RUN/bin/fake-fw-to-tablet" <<-'EOF'
		#!/bin/sh
		echo "fw-to-tablet $(find "$GTA3_FIRMWARE_DIR" -type f | wc -l)" >> "$MOCK_STATE.calls"
	EOF
	cat > "$RUN/bin/fake-duranium-update" <<-'EOF'
		#!/bin/sh
		echo "duranium-update V=$1 UI=$UI EXTENSIONS=[$EXTENSIONS] files=$(ls "$OUT" | tr '\n' ' ')" >> "$MOCK_STATE.calls"
	EOF
	chmod +x "$RUN/bin/fake-fw-to-tablet" "$RUN/bin/fake-duranium-update"
	python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$RUN/srv" > "$RUN/http.log" 2>&1 &
	HTTP_PID=$!
	for t in $(seq 50); do
		HTTP_PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$RUN/http.log" | head -1)
		[ -n "$HTTP_PORT" ] && break
		sleep 0.1
	done
	[ -n "$HTTP_PORT" ] || { echo "http server did not start" >&2; exit 2; }
	sed "s|@DL@|http://127.0.0.1:$HTTP_PORT/dl|g" "$RUN/srv/pages/releases.json.in" > "$RUN/srv/pages/releases.json"
	cp "$RUN/srv/api/releases.json" "$RUN/srv/api/releases"
}

# ---------- the fake tablet, per case ----------

# part NAME NUMBER SIZE [MARKER]
mkpart() {
	local n=$2
	mkdir -p "$ROOT/sys/class/block/sda$n"
	printf 'MAJOR=8\nMINOR=%s\nDEVNAME=sda%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' "$n" "$n" "$n" "$1" \
		> "$ROOT/sys/class/block/sda$n/uevent"
	echo $(($3 / 512)) > "$ROOT/sys/class/block/sda$n/size"
	truncate -s "$3" "$ROOT/dev/sda$n"
	[ -z "${4:-}" ] || printf '%s' "$4" | dd of="$ROOT/dev/sda$n" conv=notrunc status=none
}

# new_tablet MODE: a fresh fake tablet for this case
new_tablet() {
	ROOT=$CASE/root
	mkdir -p "$ROOT/dev" "$ROOT/proc/bus/input" "$ROOT/proc/sys/vm" "$ROOT/run" "$ROOT/var/lib/firmware" \
		"$ROOT/usr/sbin" "$ROOT/android/sdcard/DCIM/Camera" "$ROOT/android/sdcard/Download"
	mkpart efs 1 $((1 << 20)) EFS-IDENTITY
	mkpart sec_efs 2 $((1 << 20)) SEC-EFS
	mkpart boot 12 61865984
	cp "$RUN/fx/stock/boot.img" "$ROOT/dev/sda12"
	mkpart recovery 13 $((1 << 20))
	mkpart vbmeta 22 65536 VBMETA
	mkpart metadata 24 $((4 << 20)) METADATA
	mkpart super 25 "$(stat -c %s "$RUN/fx/super/super.raw")"
	cp "$RUN/fx/super/super.raw" "$ROOT/dev/sda25"
	mkpart cache 28 $((1 << 20))
	mkpart userdata 31 $((64 << 20)) ANDROID-DATA
	head -c 4096 /dev/urandom | dd of="$ROOT/dev/sda31" bs=4096 seek=100 conv=notrunc status=none
	echo "Linux version 7.3.0 (test) #1 SMP" > "$ROOT/proc/version"
	printf 'I: Bus=0019\nN: Name="gpio_keys"\nH: Handlers=kbd event0\n\n' > "$ROOT/proc/bus/input/devices"
	: > "$ROOT/proc/sys/vm/drop_caches"
	: > "$ROOT/usr/sbin/mkfs.f2fs"
	echo photo > "$ROOT/android/sdcard/DCIM/Camera/IMG_0001.jpg"
	echo doc > "$ROOT/android/sdcard/Download/notes.txt"
	mkdir -p "$ROOT/android/data/app/com.example.notes"
	echo apk > "$ROOT/android/data/app/com.example.notes/base.apk"
	fx_vendor_tree "$ROOT/android/vendor"
	python3 - "$CASE/state.json" "$ROOT" "$1" <<-'PY'
		import json, sys
		path, root, mode = sys.argv[1:]
		json.dump({"mode": mode, "root": root, "serial": "R52TEST0001", "adb_auth": "device",
		  "props": {"ro.product.model": "SM-T570", "ro.product.device": "gtactive3wifi",
		    "ro.bootloader": "T570XXSFEYI1", "ro.build.PDA": "T570XXSFEYI1", "ro.revision": "4",
		    "ro.csc.sales_code": "XSA", "ro.build.version.release": "13",
		    "ro.boot.flash.locked": "0", "ro.boot.verifiedbootstate": "orange",
		    "ro.boot.warranty_bit": "1", "ro.oem_unlock_supported": "1",
		    "sys.oem_unlock_allowed": "1", "knox.kg.state": "Completed"},
		  "settings": {"development_settings_enabled": "1"},
		  "vendor_readable": True, "image_flavour": "dev", "events": [], "log": [],
		  "os_release": 'ID="nura"\nIMAGE_ID=samsung-gtactive3wifi\nIMAGE_VERSION="26102213"\nVARIANT_ID=phosh\n',
		  "sh": {"remote": "1111  -\n", "versions": "26102213\n26102201\n",
		         "status": "image:   samsung-gtactive3wifi_phosh_edge 26102213 (phosh)\n",
		         "updatectl-check": "26102213 (current)\n", "updatectl-update": "started\n",
		         "update-state": "inactive\n", "updatectl-result": "Installed 26102214\n"}}, open(path, "w"), indent=1)
	PY
}

# mock STATE-EDIT: python statements on the state dict "s"
mock() {
	python3 - "$CASE/state.json" "$1" <<-'PY'
		import json, sys
		p, code = sys.argv[1:]
		s = json.load(open(p))
		exec(code)
		json.dump(s, open(p, "w"), indent=1)
	PY
}
mget() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CASE/state.json" "$1"; }

start_console() {
	MOCK_STATE=$CASE/state.json python3 -I "$MOCK/fakeconsole.py" "$CASE/console.port" > "$CASE/console.log" 2>&1 &
	CONSOLE_PID=$!
	local _
	for _ in $(seq 50); do [ -s "$CASE/console.port" ] && break; sleep 0.1; done
	CONSOLE_PORT=$(cat "$CASE/console.port")
}

# setup ARGS...: run ./setup.sh against the fake tablet; output in $CASE/out
setup() {
	local rc=0
	# shellcheck disable=SC2086 # EXTRA_ENV: VAR=value words for env
	env PATH="$RUN/bin:$PATH" MOCK_STATE="$CASE/state.json" NO_COLOR=1 \
		GTA3_STATE_DIR="$CASE/st" GTA3_CACHE_DIR="$CASE/cache" GTA3_BACKUP_DIR="$CASE/backups" \
		GTA3_CONSOLE_ADDR=127.0.0.1 GTA3_CONSOLE_PORT="$CONSOLE_PORT" \
		GTA3_PAGES="http://127.0.0.1:$HTTP_PORT/${PAGES_PATH:-pages}" \
		GTA3_API="http://127.0.0.1:$HTTP_PORT/api" GTA3_DL="http://127.0.0.1:$HTTP_PORT/dl" \
		GTA3_TRUSTED_KEY="$RUN/gpg/pub.asc" GTA3_TRUSTED_FPR="$(cat "$FPR_FILE")" \
		GTA3_MKBOOTIMG=mkbootimg GTA3_AVBTOOL=avbtool GTA3_AVB_SALT=00 \
		GTA3_TIMEOUT_PCT="${TIMEOUT_PCT:-1}" GTA3_POLL=0.05 GTA3_PIT_SETTLE=0 \
		GTA3_TEST_FREE="${TEST_FREE:-1000000000000}" GTA3_FIRST_BOOT_EXTRA=1048576 \
		GTA3_FIRMWARE_TO_TABLET="$RUN/bin/fake-fw-to-tablet" \
		GTA3_DURANIUM_UPDATE="$RUN/bin/fake-duranium-update" \
		GTA3_OS_RELEASE="${OS_RELEASE:-/etc/os-release}" GTA3_ALLOW_DEVD=1 \
		${EXTRA_ENV:-} \
		"$REPO/setup.sh" "$@" > "$CASE/out" 2>&1 < /dev/null || rc=$?
	echo "$rc" > "$CASE/rc"
	cat "$CASE/out" >> "$CASE/all.out"
	return 0
}

# ---------- assertions ----------

fail() { echo "    FAIL: $*"; echo "    --- last output ($CASE/out):"; tail -40 "$CASE/out" | sed 's/^/    | /'; exit 1; }
rc_is() { [ "$(cat "$CASE/rc")" = "$1" ] || fail "exit code $(cat "$CASE/rc"), expected $1"; }
out_has() { grep -qF -- "$1" "$CASE/out" || fail "output lacks: $1"; }
out_lacks() { ! grep -qF -- "$1" "$CASE/out" || fail "output has: $1"; }
st_is() { [ "$(sed -n "s/^$1=//p" "$CASE/st/state.env" | tail -1)" = "$2" ] || fail "state $1 is '$(sed -n "s/^$1=//p" "$CASE/st/state.env" | tail -1)', expected '$2'"; }
mode_is() { [ "$(mget 's["mode"]')" = "$1" ] || fail "tablet mode $(mget 's["mode"]'), expected $1"; }
boot_is() { [ "$(mget 's.get("boot", "stock")')" = "$1" ] || fail "BOOT holds $(mget 's.get("boot", "stock")'), expected $1"; }
log_has() { mget '"\n".join(s["log"])' | grep -qF -- "$1" || fail "tablet log lacks: $1 (log: $(mget 's["log"]'))"; }
log_lacks() { ! mget '"\n".join(s["log"])' | grep -qF -- "$1" || fail "tablet log has: $1"; }
no_violation() { [ "$(mget 's.get("violation", "")')" = "" ] || fail "VIOLATION: $(mget 's["violation"]')"; }
userdata_starts() { [ "$(head -c ${#1} "$ROOT/dev/sda31")" = "$1" ] || fail "userdata does not start with $1"; }
