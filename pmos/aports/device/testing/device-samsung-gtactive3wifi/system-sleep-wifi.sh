#!/bin/sh
# systemd-sleep hook: the BCM4375's PCIe D3 handshake fails in brcmfmac
# (pci_pm_suspend: brcmf_pcie_pm_enter_D3 returns -5, measured on the
# tablet), which aborts every suspend. Unload the driver before sleep and
# load it again afterwards: NetworkManager reconnects within ~15 s. No
# Wake-on-WLAN until the D3 path works.
set -eu
mark=/run/gtactive3wifi/brcmfmac-unloaded

case "$1" in
pre)
	if grep -q '^brcmfmac ' /proc/modules; then
		mkdir -p "${mark%/*}"
		: > "$mark"
		modprobe -r brcmfmac_wcc brcmfmac
	fi
	;;
post)
	if [ -e "$mark" ]; then
		rm -f "$mark"
		modprobe brcmfmac
	fi
	;;
esac
