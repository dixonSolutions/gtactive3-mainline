#!/bin/bash
# Persistent flasher: whenever the tablet shows up in Download mode, flash the
# current build/images/boot-mainline.img to BOOT. Log: logs/devd.log
P=$(cd "$(dirname "$0")/.." && pwd)
IMG=$P/build/images/boot-mainline.img
mkdir -p "$P/logs"
exec >>"$P/logs/devd.log" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
log "devd started"
while true; do
	until lsusb | grep -q "04e8:685d"; do sleep 1; done
	for i in $(seq 1 20); do heimdall detect >/dev/null 2>&1 && break; sleep 1; done
	Q=$P/build/images/recovery-queue.img
	if [ -e "$Q" ]; then
		log "Download mode: flashing BOOT $(sha256sum "$IMG" | cut -c1-12) + RECOVERY $(sha256sum "$Q" | cut -c1-12)"
		heimdall flash --BOOT "$IMG" --RECOVERY "$Q" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
		rm -f "$Q"
	else
		log "Download mode: flashing $(sha256sum "$IMG" | cut -c1-12)"
		heimdall flash --BOOT "$IMG" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
	fi
	log "flash done"
	# wait for the device to leave Download mode before looking again
	while lsusb | grep -q "04e8:685d"; do sleep 1; done
done
