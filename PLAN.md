# SM-T570 → postmarketOS Duranium: plan

Goal: postmarketOS **Duranium** (immutable, systemd, UKI + systemd-boot, A/B
systemd-sysupdate) with a complete GUI and every piece of hardware working, plus a
USB debug layer (NCM gadget + root console) that is on by default for development
and can be disabled.

Work is split into layers. Each layer is built by parallel agents in their own
branches (`drv/<track>` in src/linux, worktrees under build/wt/), reviewed by an
independent agent, then integrated and tested live on the device, one layer at a
time, through the USB console. A layer is only merged into `gtactive3wifi` after
its live test passes.

Rule for every test: a failure must come back to the USB console without anyone
touching the tablet (reset → Download mode → automatic reflash, or watchdog reset
→ BOOT). No boot stages on RECOVERY.

## Next three steps (2026-10-24)

1. Wi-Fi recovery after a BCM4375 firmware crash (driver reload or PCIe
   power cycle) so the tablet stays reachable; session "BCM4375 Wi-Fi
   firmware crash after boot".
2. Device-verify the cand/1031 (r22) export in the booted UI's image and
   record it with `scripts/pmos-verify`, so release channels get a build.
3. Battery life: C2 residency in long idle (r41), deep sleep
   (drv/deepsleep), then a cable-out drain measurement with the owner.

The layer lists below are the original bring-up plan; docs/STATUS.md says
what is verified today.

## Done
- [x] Bootloader unlock, KnoxGuard cleared, stock firmware T570XXSFEYI1 downloaded
- [x] S-Boot → uniLoader (BOOT) → mainline Linux 7.3, automated flash/boot loop (~33 s)
- [x] USB NCM gadget + debug console with the cable never unplugged (MAX77705 switch)
- [x] UFS HS-G3 x2, simple-framebuffer console, gpio-keys, pstore
- [x] Cluster-0 watchdog reset measured (PMU 0x408/0x40c bit 24); WDT reset boots BOOT

## Layer 0: safety net
- [ ] Linux watchdog (s3c2410_wdt Exynos 9810 variant), kicked by init — track `wdt`
- [ ] uniLoader dual payload: U-Boot primary, bring-up Linux fallback on watchdog
      reset or Volume Down — track `chainload`

## Layer 1: boot chain and storage
- [ ] U-Boot as uniLoader payload: UFS, blkmap over userdata, EFI, systemd-boot — `chainload`
- [ ] Nested GPT in userdata (sda31) visible to Linux / systemd in the initrd — `duranium`
- [x] (2026-10-21) Android wiped by UFS discard: metadata, super, cache, userdata (approved 2026-10-21: userdata + Android OS partitions; never
      efs, sec_efs, param, up_param, persistent, bootloader partitions, RPMB)

## Layer 2: Duranium image
- [ ] device-samsung-gtactive3wifi + linux-postmarketos-exynos9810 packages — `pmos`
- [ ] mkosi device support, UKI with embedded DTB, phosh/plasma-mobile — `duranium`
- [ ] `duranium-usb-debug` package/sysext: NCM gadget, root console, SSH, initrd too
- [ ] Vendor firmware extracted from the stock package (never committed) — `firmware`

## Layer 3: what the GUI needs
- [ ] Display via simpledrm, rotation, backlight brightness — `display`
- [ ] Touch: SPI controller + Himax HX83102E — `touch`
- [ ] I2C buses (HSI2C/USI) — `hsi2c`; Wacom pen — `misc`

## Layer 4: power and CPU
- [ ] S2MPS18 (SPEEDY), MAX77705 charger + fuel gauge, TMU thermal — `power`
- [ ] Big cores, clock driver, then cpufreq — `cpu`

## Layer 5: acceleration and connectivity
- [ ] Mali-G72 Panfrost — `gpu`
- [ ] Wi-Fi (Exynos PCIe + brcmfmac), Bluetooth (UART, hci_bcm) — `wifi`

## Layer 6: the rest
- [ ] Audio (ABOX, RT5665, RT5510) — `audio`
- [ ] MUIC SM5504, hall sensor, jack, vibrator, keys, NFC (S3FWRN5), grip sensor,
      accelerometer/light sensors — `misc`
- [ ] Fingerprint, GPS, cameras: research first (feasibility documented by `misc`)
