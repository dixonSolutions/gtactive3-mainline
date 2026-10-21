#!/bin/bash
# Persistent flasher: whenever the tablet shows up in Download mode, flash the
# current build/images/boot-mainline.img to BOOT. Log: logs/devd.log
# Loop guard: if the same image comes back to Download mode 3 times within
# 3 minutes it is crash-looping; flash build/images/boot-good.img instead
# (and keep doing so) until boot-mainline.img changes.
P=$(cd "$(dirname "$0")/.." && pwd)
IMG=$P/build/images/boot-mainline.img
mkdir -p "$P/logs"
exec >>"$P/logs/devd.log" 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
GOOD=$P/build/images/boot-good.img
log "devd started"
declare -a hist=()
bad=""
while true; do
	until lsusb | grep -q "04e8:685d"; do sleep 1; done
	for i in $(seq 1 20); do heimdall detect >/dev/null 2>&1 && break; sleep 1; done
	h=$(sha256sum "$IMG" | cut -c1-12)
	now=$(date +%s)
	hist+=("$now $h")
	n=0
	for e in "${hist[@]}"; do
		set -- $e
		[ "$2" = "$h" ] && [ $((now - $1)) -le 180 ] && n=$((n + 1))
	done
	[ ${#hist[@]} -gt 20 ] && hist=("${hist[@]: -20}")
	if [ "$bad" != "$h" ] && [ "$n" -ge 3 ] && [ -e "$GOOD" ] &&
	   [ "$h" != "$(sha256sum "$GOOD" | cut -c1-12)" ]; then
		bad=$h
		log "LOOP: $h back in Download mode $n times in 180 s, using boot-good.img until it changes"
	fi
	FL=$IMG
	if [ "$bad" = "$h" ]; then FL=$GOOD; fi
	Q=$P/build/images/recovery-queue.img
	if [ -e "$Q" ]; then
		log "Download mode: flashing BOOT $(sha256sum "$FL" | cut -c1-12) + RECOVERY $(sha256sum "$Q" | cut -c1-12)"
		heimdall flash --BOOT "$FL" --RECOVERY "$Q" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
		rm -f "$Q"
	else
		log "Download mode: flashing $(sha256sum "$FL" | cut -c1-12)"
		heimdall flash --BOOT "$FL" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
	fi
	log "flash done"
	# wait for the device to leave Download mode before looking again
	while lsusb | grep -q "04e8:685d"; do sleep 1; done
done
