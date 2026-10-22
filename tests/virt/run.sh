#!/bin/sh
# QEMU smoke and integration test of a Duranium image, headless, without
# the tablet: edk2 -> systemd-boot -> UKI -> first boot (repart, LUKS root,
# f0rmz) -> Phosh/GNOME greeter -> login -> journal/units -> debug layer ->
# podman -> optional A/B update + boot counting + rollback.
#
#   tests/virt/run.sh IMAGE [options]
#     IMAGE  <id>_<version>.raw[.zst] (a local mkosi.output build or a
#            download), or gh:TAG[@VERSION] for a published release, e.g.
#            gh:samsung-gtactive3wifi_phosh_edge-dev
#   options (harness.py check --help):
#     --ui phosh|gnome         default: from the image name
#     --update DIR:VERSION     A/B update to VERSION served from DIR
#                              (mkosi.output/<id>, or build/virt/dl/TAG after
#                              fetch-release.sh TAG VERSION all)
#     --interrupt              update via systemd-sysupdate.service, first usr
#                              download cut off: the retry must recover
#     --rollback               then break the new version, expect a fallback
#     --kernel auto|none|PATH  kernel for the UKI (auto: build a virt Image
#                              when the image's kernel lacks virt.config)
#     --no-ui --keep --keep-disk --boot-timeout S --mem MiB --ssh-port N
#
# Results: build/virt/runs/<run>/{results.json,log.txt,serial.log,shots/*.png}
# Exit status 0 = PASS (no check failed; "warn" = unexpected journal lines or
# failed units to look at). One VM at a time (build/vm.lock), started only
# with 4 GiB available, powered off below 1.5 GiB (docs/COORDINATION.md).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 2; }
img=$1
shift
case $img in
gh:*)
	tag=${img#gh:}
	ver=
	case $tag in *@*) ver=${tag#*@}; tag=${tag%@*} ;; esac
	img=$(sh "$HERE/fetch-release.sh" "$tag" "$ver")
	;;
esac
sh "$HERE/setup-host.sh" >/dev/null
exec python3 -I "$HERE/harness.py" check "$img" "$@"
