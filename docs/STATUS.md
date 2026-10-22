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
| **CPU frequency** | cpufreq-dt on the ACPM DVFS clock, requests on ACPM channel 0 (drv/dvfs2); APM sets the voltage | ✔ A55 208-1950 MHz, PLL measured, schedutil | ? (next kernel; image blacklists cpufreq-dt until then) | boot it in Duranium; M3 cluster with the big cores |
| **CPU idle** | PSCI core power-down C2 (stock: 0x10000) + flexpmu hints (drv/dvfs2) | ◐ psci_idle registers, hotplug core power-down verified | ✘ C2 disabled in the DT: cores in C2 are never woken (26102210 hang) | C2 wake-up path (PMU wake events) |
| **GPU** Mali-G72 MP18 | panfrost probes, runs jobs, fixed 260 MHz (S-Boot level) | ◐ jobs run | ✘ not used: GNOME renders in software | GPU via the new KMS driver + Mesa kmsro (built, untested in GNOME); then GPU DVFS through ACPM |
| **RAM** 4 GB LPDDR4X | 3.9 GiB usable; 128 MiB CMA added for scanout | ✔ | ✔ (boots, 2 GB+ in use) | MIF DVFS (bandwidth) later |
| **Storage** 64 GB UFS 2.1 | ufs-exynos; 32-bit DMA, inline crypto/FMP PRDT format | ✔ (byte-exact 6.9 GB writes) | ✔ (boots, verity /usr, LUKS root) | — |
| **microSD** | dw_mmc-exynos (exynos9810-dw-mshc → exynos7), CMU_FSYS1 SD clocks, vmmc LDO31 / vqmmc LDO2 (drv/hwgaps) | ? | ◐ driver probes (26102219~test2), card detect + insert untested | insert a card: SDR104 tuning, read rate, hotplug |
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
| **Thermal** | TMU 8 zones; battery/charger/USB NTCs (exynos_adc 9810 + generic-adc-thermal) | ✔ TMU | ◐ NTC zones via test module | LITTLE zone: cpufreq cooling bound to a passive 86 C trip (bring-up; not yet driven by real heat) |
| **PMIC** S2MPS18 | ACPM: read-only except a whitelist of LDOs (camera, SD, grip, NFC) | ◐ | ✔ LDO switching through ACPM works (camera rails on for the sensor ID read and off again, LDO40 3.0 V, LDO41 1.8 V; 26102219~test2, 2026-10-23) | drop regulator_ignore_unused after a longer run |
| **Grip sensor** A96T3x6 | driver, bus at 100 kHz, VDD_GRIP_3P0 = LDO40 | ✘ needs LDO40 | ◐ probes: fw 0x01 vendor 0xab model 0x50 (was no response) | proximity values with a hand near the edge (user) |
| **Pogo pins** SM5504 MUIC | extcon-sm5502 | ✘ probe fails (no USB role switch) | ? | dwc3 role switch |
| **Cameras** S5K3L6 8 MP rear, GC5035 5 MP front | exynos9810-csis raw capture (16-bit RAW10 words) + s5k3l6 + gc5035 (drv/cam), libcamera simple pipeline + SoftISP | — | ◐ both sensors probe and stream at 30 fps; rear test pattern = exact colour bars (64..1023); libcamera registers both, PipeWire shows Built-in Front/Back Camera (2026-10-23) | Snapshot in a lit room (user); libcamera sensor helpers (patches/libcamera/0002) |
| **Sensors** accel/gyro/mag/light/proximity | behind BCM4773 sensor hub | — | — | sensor hub protocol |
| **GPS** | BCM4773 GNSS | — | — | GNSS protocol |
| **Fingerprint** | TrustZone-owned | — | — | not reachable from Linux |

## postmarketOS (Duranium) integration

| Piece | State |
|---|---|
| Boot chain S-Boot → uniLoader → U-Boot → systemd-boot → UKI | ✔ boots GNOME; watchdog + "chain died" fallback tested |
| Immutable /usr (EROFS + dm-verity), A/B slots, LUKS root via systemd-repart | ✔ first boot creates the root (needed BLK_DEV_WRITE_MOUNTED) |
| USB debug layer (console 23, shell 2323, ssh 22) in the booted system | ✘ died after boot (gadget re-enumeration); ✔ (udev restart + adb off); no boot/shutdown deadlines any more (U-Boot stops the watchdog, systemd pets it at runtime only) |
| Wi-Fi profile, dev SSH key | baked into local dev images only (never committed) |
| GNOME on the GPU | ✘ (software rendering); next image has the KMS driver |
| Hardware keys in GNOME | ✘ Home/Recent; fixed in the next image |
| Audio (PipeWire/UCM) | next image (untested) |
| Updates instead of 6.9 GB reinstalls | ✔ `scripts/duranium-update` (A/B usr + verity, UKI with boot counting, dev-tools sysext/confext per version in /var/lib/duranium-extensions) |
| Update server (GitHub releases, signed, sysupdate) | ✔ the tablet installed GNOME 26102218 from gnome_edge-dev with its own systemd-sysupdate; Phosh 26102217 booted and was blessed (boot counting through U-Boot EFI works); a broken-off download leaves the slot partial, recovered by vacuum (device r34 does it automatically) |
| Suspend | ✔ suspend to idle (PSCI 0.1: the only state), 15 s sleep woken by the SoC RTC alarm, UFS powered down and relinked, USB console back; Wi-Fi is unloaded around sleep (brcmfmac PCIe D3 fails); power-key wake and battery drain still to measure; logind suspend stays off until the wake path is marked proven |
| Hang recovery | ✔ watchdog handed over by U-Boot (82.6 s) and kept by the kernel; a deliberate lockup reset the board, the fallback Linux restarted Duranium after 15 s, disk unlocked; 3.5 min at the passphrase prompt causes no reset |
| distrobox / podman / brew | ✔ podman in every image with Alpine 3.24.3 preinstalled (device -containers): root self-test all PASS offline (26102219~test2); distrobox in the dev-tools sysext (26102209) |

## CPU DVFS and idle (2026-10-22, measured)

Earlier (bring-up #76/#77): cpufreq-dt + clk-acpm accepted every rate but
the PLL stayed at 1053 MHz, because requests went to ACPM channel 5.

- **Channel 5 is the wrong channel.** APM SRAM channel table (framework
  header at SRAM + 0x7f00): ch5 is type 2 (buffer), q_len 1, ap_poll 0,
  the DVFS plugin's APM-to-AP notification buffer (stock registers a MIF
  callback on it). Stock sends FREQ_REQ on **channel 0**: cal-if asks
  acpm_ipc_request_channel() for the clock-controller node, which has no
  acpm-ipc-channel, the lookup fails and ch_num stays 0. Ch0: same plugin
  (owner 0x10), queue, q_len 15, 16-byte messages, polled.
- Hand-made FREQ_REQ on ch0 (console pokes, Duranium 26102208): PLL
  1053 -> 949 -> 832 -> 949 -> 455 -> 1053 MHz; requests are rounded down
  to a table level; FREQ_GET answers 0 (stock caches rates too).
- Fix: clk-acpm exynos9810 mbox_chan_id 5 -> 0. Bring-up, cpufreq-dt policy0
  (CPUs 0-3), userspace governor, PLL_CON0_PLL_CPUCL0 read back + a
  4-instruction dependent loop:

  | requested | PLL | loop |
  |---|---|---|
  | 208 MHz | 208 MHz | 51 Miter/s |
  | 455 MHz | 455 MHz | 113 Miter/s |
  | 1053 MHz | 1053 MHz | 262 Miter/s |
  | 1456 MHz | 1456 MHz | 363 Miter/s |
  | 1950 MHz | 1950 MHz | 487 Miter/s |

  schedutil: 1950 MHz within 250 ms of load, back down when idle (2254
  transitions in ~4 min). Thermal: cooling_device cpufreq-cpu0 (12 states)
  bound to the cpu-little-thermal passive trip at 86 C (stock LITTLE alerts
  76-101 C); not exercised (40 C, no THERMAL_EMULATION).
- CPU idle: stock uses only C2 (PSCI power_state 0x10000) per core and no
  A55 cluster power-down. Before CPU_SUSPEND/CPU_OFF stock writes
  CPU_INFORM(cpu) = 1 (PMU + 0x860 + 4n), sets the CPU's bit in pmu-intr-gen
  (0x14070000) GRP2_INTR_BID_ENABLE and PMU + 0x7f08, clears its GRP1
  pending bit; the A55 cores are bits 4-7. Same scheme as mainline's gs101
  code in exynos-pmu.c, extended for 9810. CPU3 hotplug: PMU
  CLUSTER0_CPU3_STATUS 0x0f -> 0x00 (core off) -> 0x0f, CPU3 runs again.
- C2 was **not entered** in the bring-up: its config was HZ_PERIODIC
  without HIGH_RES_TIMERS, so there is no tick broadcast (no global timer
  in the DT; the hrtimer broadcast needs a oneshot tick) and cpuidle never
  picks a timer-stop state. Bring-up config now has NO_HZ_IDLE +
  HIGH_RES_TIMERS (the Duranium kernel already does). The v2 test kernel
  was built but not booted (reboot not approved in that window): C2
  residency in long idle is still to be measured, in the next Duranium
  kernel. Later: the MCT (0x10040000, stock clockevent) as a real broadcast
  timer so all four cores can power down at once.
- MCT (branch `drv/mct`, not merged): DT node (SPI 466-477, oscclk + CMU_PERIS
  MCT_PCLK), CMU_PERIS registered early (CLK_OF_DECLARE: the MCT probes in
  time_init). Mainline arm64 rates the MCT locals and FRC below the arch
  timer, so the arch timer stays tick + clocksource and only mct-comp (no
  C3STOP) is meant as the broadcast device; stock instead ticks on the MCT
  locals. Measured: the MCT is clocked (CMU gate CG_VAL=1, Q-channel off;
  G_CNT counts at 26 MHz). Bring-up boot with C2 + MCT **hung at 0.85 s**
  (pstore): CPUs 0-2 entered C2 and never answered IPIs, CPU3 alone kept
  running. A core in C2 is not woken even by an SGI, so the C2 wake path
  (GIC -> PMU/APM handshake) is broken, independent of the timer. The
  bring-up watchdog is armed only by init, so an initcall-time hang never
  resets. Still open: broadcast = mct-comp with C2 off, then C2 per core.
- Battery current in the bring-up (USB SDP input, console idle, no C2):
  net -6 mA (gauge, 20 s average). Duranium (coordinator): 214 mA screen
  on, 184 mA blanked.

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
driver path has not been booted). Two stages:
- stage 1, `drv/battemp-stage1` (cd9acc24f): ADC, NTC zones, temperature
  steps, gauge temperature; the 1.5 A charge and input caps stay on. The
  kernel aport (pkgrel 9) is built from this.
- stage 2, the last commit (de8bff2c3): the caps apply only while the
  temperature is not monitored, so charging uses 3.1 A CC and up to 3 A input.
  Needs the user's OK in the coordinator session after stage 1 has been
  checked on the device.

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
- **Charger policy** (max77705_charger, battery-thermal zone, 10 s poll; stage 2 values),
  stock values: < 0 °C off, 0-5 °C 450 mA, 5-15 °C 1.15 A, 15-42 °C battery
  limits (3.1 A, 4.26 V), 42-50 °C 1.75 A, >= 50 °C off; 4.05 V float outside
  15-42 °C; 2 °C recovery margin. Charger NTC >= 46 °C (44 °C recovery): input
  1 A, charge 1.25 A. Without a readable zone (and always in stage 1): the
  old 1.5 A input and charge caps. Verified on the real charger with faked zone temperatures (all steps,
  both hysteresis directions, charger-hot on/off): status Not charging +
  health Overheat/Cold when off, Warm/Cool when reduced.
- **Input current** (stage 2): max77705_usbc_psy no longer caps (Type-C Rp 3.0 A ->
  3 A, DCP 1.8 A, CDP 1.5 A, SDP 475 mA).
- **Not measured yet**: charge current from a wall charger (needs the cable
  moved from the laptop), and raising the charge current on the battery: the
  automatic permission check refused that step, so it waits for the user.
