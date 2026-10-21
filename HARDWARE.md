# Galaxy Tab Active3 Wi-Fi (SM-T570, gtactive3wifi): hardware notes

Collected over ADB from stock Android on 2026-10-21 (before the unlock).

## Identity
- Model SM-T570, region XSA, serial <serial>
- Firmware / bootloader: T570XXSFEYI1 (bootloader rev F = 15), Android 13, patch 2025-10-01
- Kernel: 4.9.191 downstream
- SoC: Exynos 9810 (universal9810), 4x Samsung M3 + 4x A55, Mali-G72, 3.6 GB RAM
- Display: 1200x1920, 320 dpi
- Storage: UFS (sda..sde), userdata 52 GB

## Partitions (non-A/B, dynamic `super`)
boot=sda12, recovery=sda13, vbmeta=sda22, vbmeta_samsung=sda23, dtbo=sda10,
super=sda25, userdata=sda31, efs=sda1, sec_efs=sda2, param=sda3, up_param=sda4,
persistent=sda17, misc=sda18, metadata=sda24, cache=sda28. Also cpefs=sdd1.

## Devices by bus (driver names from sysfs)
| Bus addr | Driver | Function |
|---|---|---|
| i2c 0-002d | S5K3L6 | rear camera |
| i2c 1-0037 | GC5035 | front camera |
| i2c 2-0058 | fimc_is_eeprom_i2c | camera eeprom |
| i2c 3-001b | rt5665 | audio codec |
| i2c 4-0034 | rt5510 | speaker amp |
| i2c 5-0027 | sec-nfc | NFC (S.LSI, fw 6.2.9) |
| i2c 6-0056 | wacom_w90xx | S Pen digitiser |
| i2c 7-0020 | A96T3X6_WIFI | grip sensor |
| i2c 8-0014 | sm5504 | MUIC / USB switch |
| i2c 8-0066 (+0x25,0x36,0x62,0x69) | max77705 | PMIC/charger/fuel gauge/USB-PD |
| i2c 9-0000 (+0x01,0x02,0x0f) | s2mps18 | main PMIC |
| spi1.0 | egis_fingerprint | fingerprint |
| spi7.0 | p3 | eSE (NFC secure element) |
| spi17.0 | dbmd_4_8-spi | DSP Group voice DSP |
| spi20.0 | brcm gps spi | GPS |
| spi21.0 | himax_tp | touchscreen (input1) |
| PCIe | dhd (Broadcom FullMAC) | Wi-Fi, chip unconfirmed (likely BCM4361) |

Input: sec_touchscreen (spi21.0), sec_e-pen (6-0056), gpio_keys, hall, headset jack.
Power supplies: max77705-charger, max77705-fuelgauge, pogo, wireless, otg.

## Blocked by SELinux (get from stock firmware or root)
/proc/device-tree, of_node/compatible, dmesg, /proc/cmdline, /vendor/firmware,
touch chip ID (`get_chip_name` via /sys/class/sec/tsp/cmd), pen firmware version.

## From the stock firmware (T570XXSFEYI1)
Boot image: Android header v2, page 2048, base 0x10000000 (kernel +0x8000,
ramdisk +0x1000000, tags +0x100), DTB embedded (one SoC DTB, 189 KB).
DTBO: 6 overlays, hw_rev 0..4 and 5..0xff ("GTACTIVE3WIFI EUR OPEN 04" = retail).
Partition sizes (PIT, 4 KiB blocks): BOOT 59 MB, RECOVERY 68 MB, VBMETA 64 KB.
vbmeta lives in the **BL** tar, not AP. It hash-verifies boot directly and
chains recovery, dtbo, prism, optics.

Unsigned vbmeta (flags=2, no key) is refused by S-Boot rev F:
"AVB failed ... OK_NOT_SIGNED (3)" → stuck in Odin mode with no USB.

| Block | Stock compatible | Address | Notes |
|---|---|---|---|
| Bootloader framebuffer | exynos,fb_handover | 0xca000000, 20 MB | **not** 0xcc000000 like S9 |
| Display | samsung,exynos9-decon (decon_f) + exynos9-dsim | 0x16030000 | panel Himax **HX83102E** (TDDI: display + touch) |
| Clocks | samsung,exynos9810-clock | 0x15a80000 | downstream uses CAL (cal-if) tables |
| USB | samsung,exynos-dwusb + synopsys,dwc3 | 0x10c00000, IRQ 244 | |
| USB PHY | samsung,exynos-usbdrd-phy (phy_version 0x300) | 0x11100000, 0x110a0000, 0x110b0000 | ext_xtal refclk |
| UFS | samsung,exynos-ufs | 0x11120000 (+0x11121100, 0x11110000, 0x11130000), IRQ 242 | |
| PMIC bus | samsung,exynos-speedy | 0x141c0000 | S2MPS18 sits on SPEEDY, not I²C; ACPM also talks to it |
| Thermal | samsung,exynos9810-tmu ×4 | 0x10070000 (BIG) … | |
| GPU | arm,mali | | Mali-G72 |
| Wi-Fi | samsung,exynos-pcie (pcie1) | 0x116b0000 | |

Keys (DTBO hw_rev 5): vol- gpa0-4, vol+ gpa0-3, power gpa2-4, home gpa3-5,
back gpg3-0, recent gpg3-1, "Active" key gpa0-5.

## KnoxGuard / flashing lessons (2026-10-21)
- After the unlock, the first custom flash (unsigned vbmeta) was *accepted* by Download mode.
- Magisk boot + stock vbmeta → bootloop after the unlock warning. Recovery wipe did not fix it.
- **The recovery "factory reset" re-armed KnoxGuard**: `dumpsys knoxguard_service` shows
  `setPreNormalStateToRpmb: true` at the wipe and `vaultState :Prenormal` afterwards.
  In Prenormal, Download mode refuses non-Samsung images ("Only official released
  binaries are allowed to be flashed(VBMETA)") and the Heimdall session hangs at the end,
  leaving "An error has occurred while updating the device software" until a clean
  flash of official images (stock BOOT + VBMETA) completes.
- KG only leaves Prenormal after enrolling with Samsung over the internet (checks every 3 min).
- **Never factory-reset from recovery again.** Restore with official BOOT+VBMETA instead.
- Hardware revision: `ro.revision=4` → DTBO entry `dtbo-4` ("EUR OPEN 03").
- dtbo-4 vs dtbo-5: only the speaker amp differs (rev 4 = Richtek RT5510 on hsi2c, matches
  the live 4-0034 rt5510; rev 5 = TI TAS2562, which has an upstream driver). Framebuffer
  (0xca000000) and all seven key GPIOs are identical, so the mainline DTS is right for both.
