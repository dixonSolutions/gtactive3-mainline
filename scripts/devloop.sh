#!/bin/bash
# Host side of the automated test loop for the SM-T570 mainline port.
#
#   tablet in Download mode -> flash build/images/boot-mainline.img to BOOT
#   -> tablet boots it -> wait for the USB NCM gadget -> talk to the debug
#   console over IPv6 link-local -> save dmesg to logs/.
#
# The bring-up init reboots into Download mode by itself when no host shows up
# within 60 s, and every panic/reset lands in Download mode, so a failed build
# comes straight back here for the next attempt.
#
# usage: devloop.sh [once]      (default: run one flash+test cycle)
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
IMG=$P/build/images/boot-mainline.img
LOGS=$P/logs
TABLET_LL=fe80::57:aff:fe00:1
mkdir -p "$LOGS"

log() { echo "[$(date +%T)] $*"; }

wait_download() {
	log "waiting for Download mode"
	until lsusb | grep -q "04e8:685d"; do sleep 1; done
	for i in $(seq 1 20); do heimdall detect >/dev/null 2>&1 && return 0; sleep 1; done
	return 1
}

flash() {
	log "flashing $(basename "$IMG") ($(sha256sum "$IMG" | cut -c1-12)) to BOOT"
	heimdall flash --BOOT "$IMG" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
}

# The NCM gadget shows up as a cdc_ncm network interface on the host.
gadget_iface() {
	for d in /sys/class/net/*; do
		[ -e "$d/device/driver" ] || continue
		case "$(basename "$(readlink -f "$d/device/driver")")" in
		cdc_ncm) basename "$d"; return 0 ;;
		esac
	done
	return 1
}

console() {	# console IFACE "cmd1" "cmd2" ... -> prints replies
	local ifc=$1; shift
	python3 -I - "$TABLET_LL%$ifc" "$@" <<'EOF'
import socket, sys, time
addr, cmds = sys.argv[1], sys.argv[2:]
s = socket.create_connection((addr, 23), timeout=10)
s.settimeout(3)
def drain():
    buf = b""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            buf += d
    except socket.timeout:
        pass
    return buf.decode(errors="replace")
drain()
for c in cmds:
    s.sendall((c + "\n").encode())
    time.sleep(0.5)
    sys.stdout.write(drain())
EOF
}

cycle() {
	wait_download || { log "Download mode not responding"; return 1; }
	flash
	log "waiting up to 90 s for the USB gadget"
	local ifc=""
	for i in $(seq 1 90); do
		ifc=$(gadget_iface) && break
		sleep 1
	done
	if [ -z "$ifc" ]; then
		log "RESULT: no USB gadget (tablet will return to Download mode)"
		return 2
	fi
	log "gadget up on $ifc"
	for i in $(seq 1 20); do
		ping -6 -c1 -W1 "$TABLET_LL%$ifc" >/dev/null 2>&1 && break
		sleep 1
	done
	local f=$LOGS/dmesg-$(date +%Y%m%d-%H%M%S).txt
	console "$ifc" dmesg > "$f"
	log "RESULT: USB debug console working, dmesg saved to $f ($(wc -l < "$f") lines)"
}

cycle
