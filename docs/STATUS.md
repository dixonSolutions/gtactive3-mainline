# SM-T570 (Galaxy Tab Active3 Wi-Fi): hardware status, strictly

"Works" means **tested on the device** at that level. Two levels:

- **Bring-up**: our test Linux (nolibc init, drivers loaded by hand, console tools).
- **Duranium**: postmarketOS Duranium + GNOME as the user uses it, driven by
  the normal userspace (udev, NetworkManager, PipeWire, Mutter).

Only a **Duranium ✔** counts as done. Everything else is work.

Legend: ✔ verified · ◐ partly / with caveats (stated) · ✘ broken or not working ·
— not built yet · ? not tested at that level.

| Block (stock spec) | Driver / state | Bring-up | Duranium | What is left |
|---|---|---|---|---|
| **CPU** Exynos 9810: 4× Mongoose M3 (2.7 GHz) + 4× Cortex-A55 (1.9 GHz) | A55 ×4 via PSCI. M3 ×4: powered by EL3 but cluster 1 hangs the bus on power-up | ◐ 4 of 8 cores | ◐ 4 of 8 cores | ACPM DVFS init (ECT/fvmap) so cluster 1 has a clock, then the PMU wake-event sequence (found), then online 4-7 |
| **CPU frequency** | none: clocks as S-Boot set them; ACPM DVFS reads 0 kHz (DVFS not initialised) | ✘ | ✘ | ACPM DVFS (FREQ_REQ on channel 5) + fvmap/ECT, cpufreq driver |
| **GPU** Mali-G72 MP18 | panfrost probes, runs jobs, fixed 260 MHz (S-Boot level) | ◐ jobs run | ✘ not used: GNOME renders in software | GPU via the new KMS driver + Mesa kmsro (built, untested in GNOME); then GPU DVFS through ACPM |
| **RAM** 4 GB LPDDR4X | 3.9 GiB usable; 128 MiB CMA added for scanout | ✔ | ✔ (boots, 2 GB+ in use) | MIF DVFS (bandwidth) later |
| **Storage** 64 GB UFS 2.1 | ufs-exynos; 32-bit DMA, inline crypto/FMP PRDT format | ✔ (byte-exact 6.9 GB writes) | ✔ (boots, verity /usr, LUKS root) | — |
| **microSD** | not wired up (FSYS1 MMC, clocks) | — | — | DT + dw_mmc-exynos + clocks |
| **Display** 8.0" 1200×1920 TFT, Himax HX83102E TDDI, dual-link DSI | new `exynos` KMS driver: takes over DECON window 5 / IDMA_G0, page flips at vsync | ✔ fbcon on hardware scanout, clean | ✘ **pixelated/glitchy** (old simpledrm + software path; the new driver is not in a booted Duranium yet) | boot it in Duranium, verify GNOME on the GPU (screenshots via debugfs scanout); real panel/DSI power control (blank/unblank, DPMS) |
| **Backlight** | DSIM DCS 0x51, both links, 0-3977 | ◐ values accepted; brightness change not visually confirmed | ✘ no slider in GNOME (needs a DSI connector, now provided) | verify slider + visible change |
| **Rotation** (manual) | Mutter software rotation | ? | ? (reported broken) | verify with the KMS driver |
| **Auto-rotate** (accelerometer) | behind the BCM4773 sensor hub (proprietary protocol) | — | — | sensor hub protocol (RE notes in docs/re, local) |
| **Touch** Himax HX83102E (SPI) | detected; frame realignment; 10 MHz | ✔ (user drags: 0 bad frames / 1400) | ◐ "very poor" before the fix; fixed driver not yet in a booted Duranium | verify in GNOME |
| **S Pen** Wacom W9019 (I2C) | wacom_w9000 + W9019 variant | ◐ device registers, no pen test | ? | pen test in GNOME (hover/pressure) |
| **Keys** Power, Vol+ | gpio-keys | ✔ | ✔ | — |
| **Keys** Home, Recent | gpio-keys | ✔ events seen | ✘ no action (Recent code 580 > XKB range; Home unbound) | fixed (KEY_SCALE + GNOME bindings), in the next image |
| **Keys** Back | gpio-keys | ✔ | ✔ (user) | — |
| **Keys** Vol−, Active | gpa0-4/5 never change level | ✘ | ✘ | find the real line: scan all GPIO/EINT/PMIC while held (needs a human press once) |
| **Hall sensor** (cover) | gpio-keys SW_LID | ✔ polarity | ? | — |
| **Vibrator** | gpio-vibrator (GPG3-6) | ✔ (FF rumble toggles the pin, user confirmed off state) | ◐ "vibrating like crazy" = haptics on bogus touches (touch fixed) | verify in GNOME |
| **Flash LED** RT8547 | leds-rt8547 | ◐ binds; no light test | ? | torch test |
| **Wi-Fi** BCM4375 (802.11ax, PCIe) | pcie-exynos9810 + brcmfmac (BCM4375 IDs, OTP nvram, host_cap fix) | ✔ WPA2-PSK, DHCP, DNS, HTTP | ✘ **no Wi-Fi in GNOME settings** (driver/firmware not up in Duranium: to diagnose) | find why it does not load in Duranium; RF is ~15 dB weaker than the laptop (5 GHz front end?) |
| **Bluetooth** BCM4375 (UART) | hci_uart bcm + samsung_tty USI | ✔ hci0, patch loaded | ? | test in GNOME (scan/pair) |
| **NFC** S3FWRN5 | nci + s3fwrn5_i2c | ◐ nfc0 registers; LDO41/clock not handled | ? | regulator + clock, neard test |
| **Audio** A-Box + RT5665 codec + RT5510 amp, speaker, 3.5 mm jack, mics | firmware-less A-Box, machine driver, UCM profile (new) | ◐ both PCMs stream; audibility unconfirmed | ? (no UCM until now) | verify speaker/headphones/mic in GNOME; jack detection (JD1+JD2 mode) |
| **USB-C** charging / data | MAX77705 charger + USB-C BC1.2 input, DWC3 gadget | ✔ (SDP 475 mA, charging) | ◐ charging; host mode untested | USB host/OTG role switching (SM5504 role switch missing) |
| **Battery** 5050 mAh | max17042 fuel gauge | ✔ capacity/voltage/temp | ? (GNOME battery indicator) | verify in GNOME |
| **Thermal** | TMU 8 zones | ✔ | ? | cooling via cpufreq (needs DVFS) |
| **PMIC** S2MPS18 | ACPM read-only regulators | ◐ read-only | ◐ | regulator control through ACPM (LDO40/41 for grip/NFC) |
| **Grip sensor** A96T3x6 | driver, bus at 100 kHz | ✘ needs LDO40 | ? | PMIC regulator control |
| **Pogo pins** SM5504 MUIC | extcon-sm5502 | ✘ probe fails (no USB role switch) | ? | dwc3 role switch |
| **Cameras** S5K3L6 8 MP rear, GC5035 5 MP front | none (no FIMC-IS/CSIS in mainline) | — | — | entire camera pipeline |
| **Sensors** accel/gyro/mag/light/proximity | behind BCM4773 sensor hub | — | — | sensor hub protocol |
| **GPS** | BCM4773 GNSS | — | — | GNSS protocol |
| **Fingerprint** | TrustZone-owned | — | — | not reachable from Linux |

## postmarketOS (Duranium) integration

| Piece | State |
|---|---|
| Boot chain S-Boot → uniLoader → U-Boot → systemd-boot → UKI | ✔ boots GNOME; watchdog + "chain died" fallback tested |
| Immutable /usr (EROFS + dm-verity), A/B slots, LUKS root via systemd-repart | ✔ first boot creates the root (needed BLK_DEV_WRITE_MOUNTED) |
| USB debug layer (console 23, shell 2323, ssh 22) in the booted system | ✘ died after boot (gadget re-enumeration); fixed in the next image (udev restart + adb off), dead-man reboot as safety net |
| Wi-Fi profile, dev SSH key | baked into local dev images only (never committed) |
| GNOME on the GPU | ✘ (software rendering); next image has the KMS driver |
| Hardware keys in GNOME | ✘ Home/Recent; fixed in the next image |
| Audio (PipeWire/UCM) | next image (untested) |
| Updates (sysupdate) instead of 6.9 GB reinstalls | not set up yet |
| distrobox / podman / brew | queued check (dev-tools sysext) |
