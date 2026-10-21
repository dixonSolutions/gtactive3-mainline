# SM-T570 → postmarketOS (Nura) Duranium: plan

## Phase 0: access (now)
- [x] (2026-10-21) Charge > 50 %, unlock bootloader in Download mode, finish setup online,
      confirm "Bootloader is already unlocked" (VaultKeeper check)
- [ ] Stock firmware T570XXSFEYI1 / XSA → `firmware/` (Bifrost 2.1.4, serial <serial>)
- [ ] Samsung kernel source for SM-T570 (opensource.samsung.com) → `firmware/`
- [ ] Back up stock BOOT, RECOVERY, VBMETA, DTBO from the AP tar; flash vbmeta with flags=2
- [ ] Magisk-patched BOOT → root over adb → dump efs/sec_efs, live /proc/device-tree, dmesg,
      touch chip ID, Wi-Fi chip ID

## Phase 1: first Linux boot with USB debugging (downstream kernel)
- [ ] pmbootstrap device package `samsung-gtactive3wifi` + `linux-samsung-gtactive3wifi`
      (Samsung 4.9 kernel, CONFIG_USB_CONFIGFS_RNDIS, framebuffer)
- [ ] Flash to RECOVERY (Android stays on BOOT as fallback)
- [ ] USB networking 172.16.42.1 → SSH. Claude works on the device from here.

## Phase 2: mainline bring-up (uniLoader on BOOT or RECOVERY)
- [x] uniLoader board `gtactive3wifi` (src/uniLoader, branch gtactive3wifi)
- [x] DTS `exynos9810-gtactive3wifi.dts` drafted (src/linux, branch gtactive3wifi)
- [ ] Verify fb base / memory / key GPIOs from stock DT → initramfs shell on screen
- [ ] Drivers, in order: CMU clocks + power domains → UFS → USB (DWC3 + PHY, gadget
      networking) → S2MPS18 regulators → TMU thermal → MAX77705 charger/fuel gauge (upstream)
      → SM5504 (upstream) → Himax SPI touch → Wacom W90xx pen (try wacom_w9000)
- [ ] Mainline pmOS install (systemd), USB SSH on mainline

## Phase 3: Duranium
- [ ] U-Boot exynos-mobile: add Exynos 9810 + gtactive3wifi DT, blkmap, EFI
- [ ] U-Boot wrapped in boot.img → BOOT; UKI from GPT in userdata
- [ ] Duranium image for samsung-gtactive3wifi

## Phase 4: the rest
Wi-Fi (PCIe + brcmfmac), Bluetooth, Panfrost GPU, DPU/DSI display + backlight, audio
(rt5665 + ABOX), NFC. Cameras / sensor hub / fingerprint: unlikely.
