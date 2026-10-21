#!/bin/bash
# Wait for the tablet in Download mode, then flash an image to a partition.
# usage: flash-when-ready.sh PARTITION IMAGE
set -u
part=$1 img=$2
until lsusb | grep -q "04e8:685d"; do sleep 1; done
for i in $(seq 1 20); do heimdall detect >/dev/null 2>&1 && break; sleep 1; done
echo "[$(date +%T)] Download mode, flashing $img to $part"
heimdall flash --"$part" "$img" 2>&1 | grep -E "successful|ERROR|Failed|Rebooting"
echo "[$(date +%T)] done"
