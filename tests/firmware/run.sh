#!/bin/bash
# The firmware tools' tests: scripts/firmware-tool on synthetic files, and
# scripts/firmware-snapshot against a fake device (tests/firmware/mock/adb).
# Needs no device, no network and no Samsung file.
#
#   tests/firmware/run.sh       KEEP=1 keeps the work directory
# Work directory: build/test-firmware (gitignored, like a real snapshot).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
unset GITHUB_REPOSITORY CONFIG
RUN=$REPO/build/test-firmware
rm -rf "$RUN"
mkdir -p "$RUN"
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$RUN"' EXIT

python3 -I "$HERE/test_firmware_tool.py"

# the fake device: a vendor tree, a boot partition, an EFS that must never be read
FS=$RUN/device
mkdir -p "$FS/vendor/firmware" "$FS/vendor/lib64/hw" "$FS/vendor/etc/vintf" "$FS/dev/block/by-name"
printf '\0\1\2\3' >"$FS/vendor/firmware/dsp.bin"
printf '\177ELF\2\1\1' >"$FS/vendor/lib64/hw/audio.primary.exynos9999.so"
echo '<manifest><hal><name>android.hardware.audio</name></hal></manifest>' >"$FS/vendor/etc/vintf/manifest.xml"
python3 -I "$HERE/fixtures.py" bootimg "$FS/dev/block/by-name/boot"
echo "IDENTITY" >"$FS/dev/block/by-name/efs"
python3 -I "$HERE/fixtures.py" fdt "$FS/fdt.dtb" "Live board" "test,live-board" "test,soc"

export ADB=$HERE/mock/adb MOCK_FS=$FS MOCK_LOG=$RUN/adb.log
SNAP=$REPO/scripts/firmware-snapshot
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }
fail() { echo "FAIL - $*" >&2; [ -f "$RUN/out.txt" ] && cat "$RUN/out.txt" >&2; exit 1; }

# 1. never without the owner's yes
if "$SNAP" run --out "$RUN/s1" </dev/null >"$RUN/out.txt" 2>&1; then fail "ran without --yes"; fi
grep -q "ask the owner" "$RUN/out.txt" || fail "no 'ask the owner' message"
ok "refuses without --yes when not on a terminal"

# 2. never into a directory git would commit
if "$SNAP" run --yes --out "$REPO/docs/snap-test" >"$RUN/out.txt" 2>&1; then fail "wrote into docs/"; fi
grep -q "not gitignored" "$RUN/out.txt" || fail "no gitignore message"
[ ! -e "$REPO/docs/snap-test" ] || fail "created docs/snap-test"
ok "refuses a directory that is not gitignored"

# 3. no device, an unauthorized device: clear messages
MOCK_STATE=unauthorized "$SNAP" run --yes --out "$RUN/s1" >"$RUN/out.txt" 2>&1 && fail "ran unauthorized"
grep -q "Allow" "$RUN/out.txt" || fail "no 'Allow' hint"
ok "unauthorized device: tells the owner to allow the PC"

# 4. a plain (non-root) snapshot
: >"$MOCK_LOG"
"$SNAP" run --yes --out "$RUN/s1" >"$RUN/out.txt" 2>&1 || fail "snapshot failed"
D=$RUN/s1/SM-T999_T999XXU1AXA1
[ -f "$D/SUMMARY.md" ] || fail "no SUMMARY.md"
grep -q '| Model | SM-T999 |' "$D/SUMMARY.md" || fail "summary has no model"
[ -f "$D/tree/vendor/firmware/dsp.bin" ] || fail "vendor tree missing"
grep -q 'android.hardware.audio' "$D/SUMMARY.md" || fail "VINTF HAL missing from the summary"
[ ! -e "$D/partitions" ] || fail "partitions read without --root"
ok "snapshot: props, system facts, vendor tree, summary"

# 5. nothing private in it
if grep -rqE 'R52TESTSERIAL1|aa:bb:cc:dd:ee:ff' "$RUN/s1"; then
	grep -rlE 'R52TESTSERIAL1|aa:bb:cc:dd:ee:ff' "$RUN/s1" >&2
	fail "serial or MAC in the snapshot"
fi
ok "no serial number or MAC address written"

# 6. root: live DT and partition images, never EFS
: >"$MOCK_LOG"
MOCK_ROOT=1 "$SNAP" run --yes --root --no-tree --out "$RUN/s2" >"$RUN/out.txt" 2>&1 || fail "root snapshot failed"
D=$RUN/s2/SM-T999_T999XXU1AXA1
[ -s "$D/partitions/boot.img" ] || fail "boot.img not read"
grep -q 'boot.img' "$D/partitions/SHA256SUMS" || fail "no checksums"
grep -q 'test,live-board' "$D/dt.txt" || fail "live DT not decoded"
grep -q 'test,board' "$D/dt/dtbs.txt" || fail "boot image DTB not carved"
grep -q 'efs' "$MOCK_LOG" && fail "EFS was touched"
grep -rq R52TESTSERIAL1 "$RUN/s2" && fail "serial in dmesg"
ok "root: partitions (allow-list only), live DT, boot DTB; EFS untouched"

# 7. an identity partition in the allow-list is refused
cfg=$RUN/config.toml
sed 's/^snapshot_partitions = .*/snapshot_partitions = ["boot", "efs"]/' "$REPO/config.toml" >"$cfg"
CONFIG=$cfg "$REPO/scripts/config" check >"$RUN/out.txt" 2>&1 && fail "config check accepted efs"
if CONFIG=$cfg MOCK_ROOT=1 "$SNAP" run --yes --root --no-tree --out "$RUN/s3" >"$RUN/out.txt" 2>&1; then
	fail "snapshot read efs"
fi
grep -q "refusing to read efs" "$RUN/out.txt" || fail "no refusal message"
ok "efs in firmware.snapshot_partitions: config check and the snapshot refuse"

echo "firmware tests: $pass passed"
