#!/bin/bash
# Queued check (run from scripts/duranium-queue once Duranium is up): podman
# offline with the preinstalled Alpine image (device-samsung-gtactive3wifi-
# containers), rootful and rootless; then distrobox and Homebrew (inside a
# glibc distrobox; Duranium is musl), which need Wi-Fi for the image pulls.
# Over ssh with the local dev key.
P=$(cd "$(dirname "$0")/../.." && pwd)
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $P/build/secrets/duranium-dev-ed25519 root@fe80::57:aff:fe00:1%$(for d in /sys/class/net/*; do [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = cdc_ncm ] && basename "$d"; done | head -1)"
r() { echo "\$ $*"; timeout 1800 $SSH "$@" 2>&1 | tail -25; echo "(exit ${PIPESTATUS[0]})"; }

# offline self-test: root, then the first-boot user in their own session
# (systemd --user must be running: logged in on the screen)
r '/usr/libexec/gtactive3wifi/containers-selftest'
r 'u=$(cat /etc/default_user); loginctl list-sessions --no-legend; systemd-run --machine="$u@" --user --wait --pipe --quiet /usr/libexec/gtactive3wifi/containers-selftest'
r 'systemctl status --no-pager gtactive3wifi-container-images.service | head -5; u=$(cat /etc/default_user); systemctl --machine="$u@" --user status --no-pager gtactive3wifi-container-images.service | head -5'

r 'systemd-sysext list; systemd-sysext status'
# dev-tools sysext: enable it if it is not merged yet
r 'systemd-sysext list 2>/dev/null | grep -q dev-tools && { command -v podman || (importctl --help >/dev/null 2>&1; ls /var/lib/extensions /usr/lib/extensions 2>/dev/null; systemd-sysext refresh); }; command -v podman distrobox'
r 'nmcli -t -f DEVICE,STATE,CONNECTION device; ping -c 3 -W 3 1.1.1.1 | tail -1'
r 'podman info --format "{{.Host.Arch}} {{.Host.CgroupsVersion}} {{.Host.OCIRuntime.Name}} {{.Store.GraphDriverName}}"'
r 'podman run --rm docker.io/library/alpine:latest uname -a'
r 'distrobox create --yes --name brewbox --image registry.fedoraproject.org/fedora-toolbox:latest'
r 'distrobox enter brewbox -- bash -lc "cat /etc/os-release | head -2; ldd --version | head -1"'
r 'distrobox enter brewbox -- bash -lc "sudo dnf -y -q install git gcc make procps-ng curl file >/dev/null && NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" >/tmp/brew-install.log 2>&1; tail -3 /tmp/brew-install.log; eval \$(/home/linuxbrew/.linuxbrew/bin/brew shellenv) && brew --version && brew install hello && hello"'
