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
| **Battery** 5050 mAh | max17042 fuel gauge; temperature from the battery NTC (AP ADC ch1) | ✔ capacity/voltage; temp: was a stale 29.5 °C (FG in host-temperature mode), now the NTC | ◐ NTC + temperature policy verified with test modules on 26102209; ADC driver + DT not booted yet (drv/battemp) | boot drv/battemp; wall-charger measurement |
| **Thermal** | TMU 8 zones; battery/charger/USB NTCs (exynos_adc 9810 + generic-adc-thermal) | ✔ TMU | ◐ NTC zones via test module | cooling via cpufreq (needs DVFS) |
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

## DVFS findings (2026-10-22, bring-up #76/#77, measured)

- cpufreq-dt + clk-acpm accept every rate, but the CPU PLL
  (PLL_CON0_PLL_CPUCL0 @ 0x1d000140, F = 26 MHz * M / (P * 2^S)) stays at
  1053 MHz (M=243 P=3 S=1) and a CPU-bound loop runs at the same speed at
  208, 1053 and 1950 MHz: **DVFS has no effect yet**.
- Cause 1: ACPM channel 5 (DVFS) is interrupt mode (ap_poll 0) and the
  mainline driver rejects it (-EOPNOTSUPP, "Interrupt mode not supported").
- Cause 2: forcing polling sends the request, but channel 5 has q_len 1
  (all queue pointers 0), and the "next TX front != RX front / TX rear"
  checks (mainline and Samsung acpm_ipc.c alike) never allow a send:
  "RX front can not keep up with TX front". Stock does send DVFS on channel
  5 (cal-if: dvfs_cpucl0 is an ACPM vclk -> acpm_ipc_send_data(5)), so its
  runtime queue state or path differs; next: dump channel 5 SRAM under the
  stock kernel or trace acpm_ipc_send_data's q_len 1 behaviour.
- The force-polling patch was reverted (each request would block until the
  TX timeout).

## Night Light (2026-10-22, 26102205, measured)

- The window scans out from IDMA_VGRF (moved at probe) without problems.
- Turning Night Light on (GNOME 2700 K, gamma LUT -> VGRF HDR gamut matrix
  with HDR_ON|GM_ON, EOTF/TM off) turned the screen green and garbled; from
  that moment the HX83102E TDDI reported bad touch checksums (`ec ec ...`
  frames) and the panel went dark: the colour write broke the video stream
  and the panel side of the TDDI faulted. Only a reboot (S-Boot panel init)
  recovered it.
- Next: program the HDR block only between frames (frame-done / shadow
  update window, as Samsung's dpp_reg does), test the EOTF+GM+TM path with
  linear curves in the bring-up kernel first, and do not expose GAMMA_LUT to
  GNOME again until a warm tint is confirmed by eye.

## Battery temperature and charging limits (2026-10-22, measured on 26102209)

Branch `src/linux drv/battemp` (not merged into gtactive3wifi yet: the DT/ADC
driver path has not been booted). Kernel aport refreshed to it (pkgrel 9).

- **AP ADC** (0x14230000, CMGP, SPI 8, vendor "exynos-adc-v3"): CON1 0x00
  (bit 2 soft reset, bit 1 release, bit 0 start), CON2 0x04 (C_TIME<<4 | ch),
  DAT 0x08 (bit 31 = done, 12-bit), INT_EN 0x10, INT_ST 0x14, VER 0x20 = 0x144.
  Poked live: conversions on every channel. New compatible
  `samsung,exynos9810-adc` (12 channels, two CMGP bus clocks).
- **NTCs** (stock sec-battery tables, `battery,*_temp_table_adc`):
  ch1 battery, ch3 charger, ch4 USB connector, ch6 backlight (not used),
  ch11 "in-bat" voltage (reads ~4.07 V by the stock table while the gauge says
  3.80 V: not used). Live, room temperature, laptop USB (SDP 475 mA):

  | | raw | °C |
  |---|---|---|
  | battery (ch1) | 1995 | 25.0-26.0 |
  | charger (ch3) | 1649 | 31.8-34.8 |
  | USB (ch4) | 1996 | 25.5 |
  | CPU little (TMU) | | 39-46 |

  3 min of 4-core busy loops (the log was cut by a reboot from another
  session): CPU 43.4 -> 46.3 °C, charger NTC 33.9 -> 34.8 °C,
  battery NTC 25.9 -> 25.8 °C, i.e. the battery channel does not follow the
  SoC. (The A55s run at a fixed clock without DVFS, so the load heats little;
  the warming-while-charging check needs a wall charger, still open.)
- **Fuel gauge**: CONFIG = 0x0314, TEX = 1: TEMP is written by the host and
  was stuck at 29.6 °C from the vendor kernel. max17042 now writes the
  battery-thermal temperature every 10 s: reported 25.6 °C (NTC 25.7 °C).
- **Charger policy** (max77705_charger, battery-thermal zone, 10 s poll),
  stock values: < 0 °C off, 0-5 °C 450 mA, 5-15 °C 1.15 A, 15-42 °C battery
  limits (3.1 A, 4.26 V), 42-50 °C 1.75 A, >= 50 °C off; 4.05 V float outside
  15-42 °C; 2 °C recovery margin. Charger NTC >= 46 °C (44 °C recovery): input
  1 A, charge 1.25 A. Without a readable zone: the old 1.5 A input and charge
  caps. Verified on the real charger with faked zone temperatures (all steps,
  both hysteresis directions, charger-hot on/off): status Not charging +
  health Overheat/Cold when off, Warm/Cool when reduced.
- **Input current**: max77705_usbc_psy no longer caps (Type-C Rp 3.0 A ->
  3 A, DCP 1.8 A, CDP 1.5 A, SDP 475 mA).
- **Not measured yet**: charge current from a wall charger (needs the cable
  moved from the laptop), and raising the charge current on the battery: the
  automatic permission check refused that step, so it waits for the user.
