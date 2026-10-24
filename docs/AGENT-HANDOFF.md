# Agent handoff: SM-T570 → postmarketOS Duranium (read this first)

Written 2026-10-21 ~19:50 AEDT by the lead agent before a context compaction.
If you are the agent reading this after compaction: **you are the lead**. You
coordinate, integrate, flash the tablet and test every change on the device
yourself, autonomously, overnight. Keep going until the mission is met.

## State 2026-10-24 17:05 (session "Audio fixes", side session of the coordinator)

- Owner's audio report on r24: phantom headphones (default sink
  Headphones, system sound lost), microphone "a blip, then silence".
  Causes: no jack detection in r24 (jd-src 0) plus a saved Headphones
  default; MICVDD (S2MPS18 LDO36) never switched on: sec-acpm allowed the
  write, but s2mps11.c still gave LDO36 the read-only ops. The blip was a
  ~100 ms power-up thump of the mic path.
- Live on the tablet until the next reboot (logs/test-runs/2026-10-24-audio):
  micldo test module (LDO36 on), live snd-soc-rt5665 (jd_src=2, IRQ gpa2-2,
  amic_delay=150) + new card module, jack UCM bind-mounted over
  /usr/share/alsa/ucm2/conf.d/gtactive3 (all in /var/tmp/audio-fix;
  `systemd-run sh /var/tmp/audio-fix/test.sh restore` undoes the modules and
  the UCM). The owner heard the speaker and recorded their voice.
- Permanent, handed to the coordinator and "Mainline boot image testing"
  for cand/1035 / r25: src/linux drv/audio-fix 7e3507579 (worktree
  build/wt/audio-fix; drv/jack and drv/audio2 superseded) and device r48
  (pmaports a5e035f, UCM JackControl/JackHWMute).
- Waits for the owner: plug and unplug headphones (owner.sh plug/unplug),
  then TESTPLAN D11 on r25 as booted. Follow-up: callaudiod aborts and
  xdg-desktop-portal segfaults whenever PipeWire is restarted (upstream
  behaviour, only seen with test restarts).
- Next three steps: unchanged, see PLAN.md "Next three steps".

## State 2026-10-24 16:50 (session "Animated screen rotation in phoc")

- The black frame on each rotation is phoc's modeset shield (userspace).
  A phoc patch turns the last frame into the new orientation instead
  (fit + darkened backdrop, 280 ms, then a fade): headless phoc on the
  tablet PASS on r24, phoc `meson test` 80/80 (logs/test-runs/
  2026-10-24-phoc-rotate). The user decided no userspace forks in our
  images, so it goes upstream only: MR branch output-shield-rotate in
  build/phoc/phoc-upstream (3 commits on phoc main), text in
  build/phoc/MR.md; nothing posted.
- Unmerged, keep or delete: pmaports branch phoc-rotate (temp/phoc,
  build/wt/pmaports-phoc), repo branch phoc-rotate (ci/build-native + arm64
  job, build/wt/main-phoc). Test files on the tablet in /run/phoctest
  (gone at the next reboot); /usr/bin/phoc not touched.
- Next three steps: unchanged, see PLAN.md "Next three steps".
- Waits for the owner: submit the phoc MR from their gitlab.gnome.org
  account (or say no); whether they want a live trial in their session
  (logs out once).

## State 2026-10-24 15:05 (session "Mainline boot image testing", cameras)

- The user asked for: all cores and both "GPUs" with activity (verified,
  see STATUS; Resources' first "GPU" is the DPU, card0, no render engine,
  so always idle), rotation (manual works, auto via the sensor hub
  session), and better cameras (focus, frame rate, quality).
- Rear camera fixed (missing since r21, DT 3b4f3e2d4 in cand/1033).
- Live test stack on the tablet, survives reboots on purpose:
  /var/lib/gta3-libcamera (libcamera 0.7.2 + aport patches 0001-0009 +
  build/scratch/camera/deliver/libcamera-aport/0010-0012, built in
  localhost/lcbuild-arm64 from build/scratch/camera/lc-src, incremental:
  build/scratch/camera/lcbuild/inc.sh), tuning in .../tuning/simple
  (AGC target 1.8, rear Af block), selected by user systemd drop-ins
  ~ratrad/.config/systemd/user/{pipewire,wireplumber}.service.d/
  gta3-libcamera.conf. Redeploy: build/scratch/camera/redeploy-lc.sh
  (restarts PipeWire and the portals, which die with it). To leave the
  test: remove both drop-ins and restart.
- csis 64de959b7 (cacheable buffers, IRQ burst guard) runs as a live
  module on r23; r24 does not carry it yet (coordinator has the commit).
- Next for cameras: AF/exposure on real scenes with the user, rear CCM/AWB,
  then 0010-0012 into the libcamera aport (pkgrel bump) and the drop-ins
  out (coordinator's condition).
- Never run `cam` while Snapshot streams: both receivers share /dev/media0
  and the second pipeline broke the first stream (front ERR_OVER loop).

## State 2026-10-24 14:02 (session "Auto-rotate: BCM4775 sensor hub accelerometer")

- Auto-rotate works on the tablet (live): r23's bcm4775_shub boots the
  hub, but the hub found no sensors because S2MPS18 LDO35/42/43 (stock
  always-on) were off. A test module (build/dkmod/shubldo, only those three
  LCTRL registers, the user's go, device lock, coordinator told) switched
  them on at 13:48; after `echo 1 > /sys/kernel/debug/spi1.0/boot` and an
  iio-sensor-proxy restart, Phosh rotates when the user turns the tablet
  (~1 s, no animation: iio-sensor-proxy's 700 ms read interval, phoc).
  Evidence: logs/test-runs/2026-10-24-shub; STATUS.md Auto-rotate/Sensors.
- The rails stay on only until the next reboot. Permanent fix: src/linux
  `drv/shub3` 9655ab5e4 on cand/1032 (worktree build/wt/shub3), handed to
  the coordinator for the next export; retest D8 (TESTPLAN.md) after the
  A/B update boots.
- Next three steps: unchanged, see PLAN.md "Next three steps".
- Waits for the owner: proximity "near" test (cover the sensor) when
  convenient.

## State 2026-10-24 14:10 (coordinator)

- Tablet: IMAGE_VERSION 26102401, kernel #24 (r23), all eight CPUs online,
  Wi-Fi up. Auto-rotate works live with LDO35/42/43 switched on by a test
  module (logs/test-runs/2026-10-24-shub); the rear camera EEPROM answered
  with LDO45 (live test by "Mainline boot image testing").
- Kernel candidate cand/1033 (adfe545e7) = cand/1032 + drv/shub3 9655ab5e4
  (sensor rails, stock voltages) + drv/cam 3b4f3e2d4 (EEPROM vcc = LDO45).
  drv/wifi-recover stays out until its live-swap test.
- The user asked for r24 published and installed: "Suspend, updates,
  cores" owns the export (pmos-export, CI publishes) and a local Phosh build
  + scripts/duranium-update over USB; the coordinator asks the user before
  the reboot. After the boot: TESTPLAN D8, rear camera in Snapshot, then
  the suspend/RTC/touch test, the Wi-Fi live-swap (gate "#25"), and phoc's
  step 2 (session restart), one at a time.
- scripts/duranium-update has an uncommitted 3-line change in the main
  checkout from another session.

## State 2026-10-24 16:10 ("Suspend, updates, cores": export owner for r23-r25)

- Tablet: r24 local 26102402~test1 (kernel cand/1033 #25, device r46),
  booted 15:52 and blessed; 26102401 (CI r23) is the fallback. CI also
  published 26102402 (same r24). First r24 boot attempt (15:37) hung, the
  watchdog did not reset it, forced restart: docs/STATUS.md Hang recovery,
  TESTPLAN B5 counter. No pmos-verify for r24.
- Verified on the device today: all eight CPUs + gpu_busy_percent (r23,
  26102401), D8 auto-rotate (r24, user). Not yet: screen-off suspend +
  HX83102E restart after sleep + Active key hold (scripts ready, waits for
  the coordinator after the camera retest).
- In flight for r25: drv/bootreason (build/wt/bootreason, 2 commits on
  cand/1033: PMIC power-on/off sources + RST_STAT logged at boot), device
  r47 (pmaports ece1619: exynos9810_c2=0), plus the camera session's
  drv/cam fix when handed over. CI keeps the kernel ccache now (2a7c815a);
  scripts/pmos-export refuses sums out of source order (3481da96).
- Next three steps: (1) r25 = cand/1034 + device r47, export, local build,
  A/B install, one reboot; (2) suspend/touch/Active-key test on it;
  (3) count clean boots (B5) to 5, then pmos-verify.

## State 2026-10-24 09:45 (coordinator "PostmarketOS duranium bootloader unlock")

- Repo: exynos-linux/samsung-gtactive3wifi, values in config.toml
  (scripts/config), device-template skills and rules (be17aaf).
  scripts/notify-user is silent by default now (0b9a46d; `--sound` only if
  the user asks again).
- Kernel exports since the entry below (pmos/, newest last): cand/1028 r19
  (panel powered down on blank), cand/1029 r20 (all eight CPUs:
  drv/bigcores-b), cand/1030 r21 + device r44 (camera fixes and tuning),
  cand/1031 r22 (panfrost gpu_busy_percent), cand/1032 r23 + device r45
  (suspend on screen off, touch after sleep). Device r39 (Phosh suspend,
  blank 3 min, suspend 10 min), r41 (C2 idle on by default). Local image
  version in build/wt/duranium: 26102219~test4. pmos/VERIFIED does not
  exist yet: release channels get nothing until an on-device pass of an
  export (scripts/pmos-verify).
- Tablet: on the dock, charging (52 %). The BCM4375 firmware crashed at
  08:51 (session "BCM4375 Wi-Fi firmware crash after boot") and the tablet
  was unreachable; at 09:13 it rebooted (a himax touch module swap by
  "Suspend, updates, cores", not the Wi-Fi crash) and the user unlocked it. Booted:
  Phosh 26102304 (CI), kernel #19 (built 2026-10-23 04:42), `maxcpus=4` on
  the command line (big cores unused in this image). Wi-Fi came back by
  itself after the reboot (brcmfmac at 74 s, firmware 18.41.117), USB
  console and Tailscale both up. The user is on the tablet: nothing that
  reboots or may panic it without asking them first.
- In flight: the Wi-Fi session works offline on why the firmware crashed
  and on a recovery path that needs no human; its driver-reload test is on
  hold and gets slotted at a quiet moment (with the next A/B reboot).
  Update 09:55: the user said go; the Wi-Fi session tests its
  gtactive3wifi-wifi-recover.service (stage A brcmfmac-only reload, stage
  B controller remove) under build/device.lock. Next: one A/B update
  straight to r23 (kernel cand/1032 + device r46, CI images run
  40033972155, which replaced 40032957684), skipping r22, so the user
  types the passphrase once; the user runs `sudo updatectl update` and
  reboots. Update 10:30: the Wi-Fi recovery test PASSED (both stages, no
  oops); its service is device r46 (83cea320), in that run. The user
  installed 26102305 into the spare slot and was told not to boot it.
  drv/wifi-recover (bfae8d748) waits for a live test on r23, then
  cand/1033.
- Next three steps (same as PLAN.md): see PLAN.md "Next three steps".
- Waits for the owner: a console route (USB cable to the laptop, or the
  tablet back on Wi-Fi) when the Wi-Fi session needs it; charging current
  3.1 A (stage 2) yes/no; Night Light toggle in Settings -> Displays;
  power-key wake from suspend; battery drain with the cable out.

## State 2026-10-23 00:40 (lead: test campaign session "Camera firmware drivers and OS setup")

- Tablet: slot A = GNOME 26102218 (CI, gnome_edge-dev, installed by the
  tablet's own systemd-sysupdate), slot B = Phosh 26102219~test2 (local,
  kernel r14 cand/1023, device r33), booted and blessed. BOOT = new chain
  (U-Boot drv/bootchain2: wdt_handover=keep 82.6 s, off-mode charging
  screen, fallback-Linux auto-restart); previous chain in
  build/images/boot-chain-prev.img. /etc/modprobe.d/gta3-firstboot-test.conf
  on the tablet is useless (initrd loads those drivers) and can go.
- Kernel candidates: cand/1023 = cand/1022 + drv/suspend + drv/cam +
  drv/hwgaps (tested), cand/1024 = + drv/cam e8606290d (RAW10 in 16-bit
  words, tested as a live module) = aport r15 (building). C2 stays off.
- Device package r35 (pmaports-duranium): suspend gate + Wi-Fi unload hook,
  camera conf, firmware import from the ESP, podman + Alpine, tuning,
  switch-ui, sysupdate retry with vacuum, deadline reboot fix.
- Images: build-image.sh asks for the PipeWire audio backend (pmaports.py
  ignores _pmb_select: images had pulseaudio). Local test builds are
  numbered <newest published+1>~test<N> (mkosi.version); CI publishes
  YYMMDDNN to the -dev channels; nothing is in pmos/VERIFIED yet.
- Results: logs/test-runs/2026102{2,3}-*/results.tsv, docs/STATUS.md,
  docs/TESTPLAN.md. Unattended reboots: scripts/tab-unlock (ClaudeKeys
  DISK_ENCRYPT_AND_USER_PASSWD = disk passphrase; not the login password).
- Waiting for the user (physical): power-key wake from suspend, battery
  drain with the cable out, camera in daylight (Snapshot), microSD card,
  NFC tag, touch/pen/audio/backlight looks, Night Light (needs login).

## State 2026-10-22 afternoon (coordinator)

- Tablet: GNOME 26102209 is the known-good version. 26102210 (kernel r11)
  hung at boot in C2 and was marked bad by boot counting. At ~13:54 the
  "MCT" session's RECOVERY test kernel hung the tablet with no USB: the user
  must force-reset; its RECOVERY backup (sha256 4412b2b8...) is in that
  session's scratchpad (2107732b.../scratchpad/recovery-backup.img).
- Kernel candidate: src/linux `cand/1022` = integ + drv/gpu-ui (AArch64 Mali
  page tables: GPU memory test 0/230 failures, MMU IRQ unmask, DPU refuses
  foreign dma-bufs) + drv/dvfs2 (ACPM DVFS on channel 0, PLL measured
  208-1950 MHz; CPU idle) + drv/blank (backlight off on screen blank) +
  drv/battemp-stage1 (ADC NTC zones, 1.5 A caps) + C2 disabled in the board
  DT. Package r12 (build/wt/duranium-localpkgs); r9-r11 in build/wt/held-apks
  (never use). Merge cand/1022 into integ/gtactive3wifi after r12 boots fine.
- Images: the image session builds GNOME 26102212 + Phosh 26102213 on r12
  with device r23. Deliver with scripts/duranium-update (also works from the
  initrd prompt now; extensions are skipped there).
- Night Light works through the HX83102E panel's own digital gamma (DCS
  0xC1 banks 1-3), NOT the DPU HDR block (that garbled the picture and once
  faulted the panel).
- Open: C2 wake-up (PMU wake events / MCT broadcast; CPU-idle + MCT
  sessions), big cores (cluster powers on via GRP1, core never runs:
  CRP_PM_CC1_0), charging current 3.1 A (waits for the user), cameras
  (drv/cam, first power-up test pending), auto-rotate (sensor-hub session),
  suspend (nobody yet).
- Laptop: 16 GB disk swapfile under zram + vm.min_free_kbytes=131072 after
  an OOM killed the desktop app; heavy jobs hold build/kbuild.lock, -j8.

## Who / what

- Device: Samsung Galaxy Tab Active3 Wi-Fi, **SM-T570** "gtactive3wifi", Exynos 9810
  (4× A55 + 4× Samsung M3 big cores, Mali-G72 MP18), hw_rev 4, bootloader
  T570XXSFEYI1 (unlocked, KnoxGuard cleared). The serial is never published.
- Repo: `/home/borysthebear/Projects/gtactive3-mainline` = public
  github.com/exynos-linux/samsung-gtactive3wifi (moved from dixonSolutions/gtactive3-mainline on
  2026-10-23; git identity: dixonSolutions, repo-local). Its public plumbing
  (repo, update server, Pages, channels, signing key fingerprint, debug tool)
  is in config.toml, read through scripts/config. Commit in small chunks, end messages with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, push `main`.
- **Mission (user's words, condensed):** postmarketOS **Duranium** (immutable,
  systemd, UKI + systemd-boot, A/B sysupdate) with a **GNOME-family UI**
  (`postmarketos-base-ui-gnome-duranium`; never KDE Plasma; the user only
  excluded Plasma). 2026-10-22: **maintain both a GNOME image (`UI=gnome`,
  the daily system / fallback) and a Phosh image (`UI=phosh`, the one to test
  now)**; the user wants several UI download options later, with releases
  rebuilt automatically on new postmarketOS publishes, so the project only
  maintains drivers and kernel: keep device packages UI-neutral. Every piece of hardware working and verified on the device, drivers
  built from Samsung's GPL kernel + stock DT + the reverse-engineered firmware,
  plus a USB debug layer (on in dev builds, removable for release). Long-horizon:
  don't stop, adjust tactics, commit and merge as you go.

## Standing rules from the user (obey)

1. **Never strand the tablet.** Every boot test must come back to the USB console
   without a human. The only access is the USB cable (never unplugged).
   Volume Up in the bring-up init = reboot to Download mode (escape hatch).
2. If something breaks and you can detect it: **adjust, detect, find out why**,
   don't stop and ask. ("keep testing, if it breaks ... adjust, detect it,
   discover why"; "I don't care about the backups".)
3. Verify the GUI **yourself** (gnome-shell/gdm status, Mutter D-Bus
   `org.gnome.Mutter.DisplayConfig.GetCurrentState`, `org.gnome.Shell.Screenshot`
   pulled back with `scripts/tab-get`). Ask the user only for physical input
   (a finger on the touchscreen, pressing keys).
4. Android is **wiped** (sda24 metadata, sda25 super, sda28 cache, sda31 userdata),
   approved and done. Never touch efs/sec_efs (sda1/2), param/up_param (sda3/4),
   persistent (sda17), bootloader LUNs, vbmeta, RPMB. Never a Samsung "factory
   reset" (re-arms KnoxGuard).
5. Never commit Samsung firmware, decompiled code, keys (firmware/keys), the
   serial or the MAC addresses (firmware/device-snapshot). Raw REA/Ghidra output
   stays in gitignored `firmware/re-targets/`; write our own interface docs to
   `docs/re/`.
6. 2026-10-22 the user asked for parallel sessions/agents. Several Claude
   sessions now share the tablet and the laptop: follow docs/COORDINATION.md
   (device lock, A/B updates only, one image builder, memory rules). The
   coordinator session is "PostmarketOS duranium bootloader unlock".
7. Don't use `pkill -f`/`pgrep -f` with patterns that also match your own shell
   command line (it killed/matched our own shells several times). Use PIDs.
8. Some destructive/remote-write actions get blocked by the auto-mode
   classifier: then explain and ask the user.
9. sudo: the user stored a ClaudeKeys secret named SUDO; feed it to `sudo -S`
   on stdin (here-string), never echo/print it.

## Boot chain today (all automated, ~35 s per flash cycle)

S-Boot (Samsung, stock signed vbmeta) → **BOOT partition** (sda12) =
mkbootimg v2 image whose "kernel" is **uniLoader** (src/uniLoader) →
- bring-up: Linux 7.3 (src/linux branch `gtactive3wifi`) + nolibc init
  (`initramfs/init.c`), built by `scripts/build.sh` → `build/images/boot-mainline.img`.
- RECOVERY (sda13) holds the same bring-up Linux (never put new stages there).

`scripts/devd.sh` runs in the background (check with `ps`): whenever the tablet
is in Download mode (USB 04e8:685d) it flashes `build/images/boot-mainline.img`
to BOOT with heimdall (and a one-shot `build/images/recovery-queue.img` to
RECOVERY if present), logging to `logs/devd.log`. The bring-up init arms "any
reset → Download mode" (PMU INFORM3 0x1406080c = 0x12345671), so crashes come
back to devd automatically. `build/images/boot-good.img` = last known-good
bring-up image (ca1898aec3d8); boot-mainline.img is currently that same image.

Console tools (host): `scripts/tab wait N`, `scripts/tab "<cmd>"`,
`scripts/tab-get REMOTE LOCAL [BYTES]`, `scripts/tab-put LOCAL REMOTE`. Wrap in
`flock build/tab.lock …` if anything else might use the console. Tablet =
IPv6 link-local fe80::57:aff:fe00:1 on the cdc_ncm interface (enp0s20f0u5).
Console commands: dmesg, peek, dump, poke, cat (raw stream), write, put, run
PATH [ARGS], insmod, rmmod, ls, i2cw/i2cr (/dev/i2c-0), ulog (U-Boot RAM log at
0x8ff100000, survives resets), evread, discard (Android partitions only),
reboot [download|recovery|normal]. pstore: `/sys/fs/pstore/console-ramoops-0`.

## Hardware status (live-tested on the device unless noted)

| Block | Status |
|---|---|
| UFS (64 GB Micron, HS-G3 x2) | works, loaded at boot |
| USB gadget (DWC3 + PHY, MAX77705 COM_USB via bit-bang) | works, cable always plugged |
| Watchdog (s3c2410_wdt 9810, cluster 0) | works; init arms 30 s + kicks; WDT reset → S-Boot boots BOOT, RST_STAT 0x14060404 bit 24 |
| HSI2C_40 (exynos-usi + i2c-exynos5 9810) | works (MAX77705 0x66 ID 0x05, SM5504 0x14, USB-C 0x25) |
| simpledrm on the S-Boot framebuffer 0xca000000 | works |
| Backlight (DSIM DCS 0x51, both links) | driver accepts 0..3977; visual confirmation pending |
| TMU thermal (8 zones) | works |
| ACPM + S2MPS18 read-only (45 regulators, PMIC ID 0x09) | works |
| MAX77705 charger + fuel gauge (simple-mfd-i2c) + hwmon | works; **USB-C/BC1.2 input detection** (max77705_usbc_psy, drv/power) feeds the charger's input limit (SDP 475 mA on the laptop port: the battery drains ~50-130 mA under load, watch it); driver caps fast charge at 1.5 A; battery temp 29.5 °C reads |
| Panfrost (Mali-G72 0x6221 r0p1) | probes, runs jobs; GPU power-domain link dropped while CONFIG_PM=n |
| UFS after U-Boot | **root cause of the hung Duranium initrd**: U-Boot's exynos UFS driver makes the FMP SMC that sets DESCTYPE 3 (128-byte PRDT entries, needed for U-Boot's own transfers after its host reset). Linux without inline crypto used 16-byte entries -> every multi-entry PRDT read at the wrong stride -> IS.SBFES bus faults. Fix: CONFIG_SCSI_UFS_CRYPTO=y + BLK_INLINE_ENCRYPTION (Linux sets the same format itself; AES-256-XTS keyslots appear). Also a 32-bit UFS DMA mask like Samsung's (harmless). Asking the SMC for DESCTYPE 0 in U-Boot breaks U-Boot's DMA entirely. |
| Wi-Fi (BCM4375 B1, PCIe ch0) | **works with WPA2-PSK** (user's network): needed brcmfmac to write host_cap (IPC API version) into the shared area, else the 18.41 firmware never consumed RX buffers (no EAPOL). DHCP, DNS, HTTP ok; some loss at -80 dBm. Creds: `scripts/wifi-push-creds --cache` (user ran it) -> build/secrets/{wpa_supplicant.conf,wifi.nmconnection}; tests: `scripts/wifi-test`, /run/wpa.sh + /run/route.sh pattern (console `run` passes few args, use scripts) |
| Bluetooth (BCM4375 on UART_BT) | **works**: hci0, BCM4375B1 SEMCO, patch RAM build 0171 |
| Audio (A-Box + RT5665 + RT5510) | card registers, headset jack input, both PCMs stream (pcm-tone, 48 kHz); audibility not yet confirmed by a human |
| S Pen (Wacom W9019, HSI2C_23) | **works**: input "Wacom W9019 Digitizer" 17222x10764 |
| NFC (S3FWRN5, HSI2C_20) | nfc0 registers (load rfkill first); NCI init untested |
| Vibrator, flash LED (RT8547), hall sensor | drivers bind; vibrator polarity confirmed by the user (low = off); "vibrating like crazy" in GNOME was haptic feedback on bogus touches (fixed by the touch fix); hall polarity correct (open = 1) |
| Grip sensor (A96T3x6, HSI2C_34) | bus now 100 kHz (10 kHz could not be divided); needs S2MPS18 LDO40 (read-only PMIC) |
| SM5504 pogo MUIC | probe fails: no USB role switch on dwc3 yet |
| Touch (SPI21, Himax HX83102E) | **works** (user-tested drags): byte-wide bus access + burst for the ID; event frames sometimes start one byte early (in the dummy byte) -> read it too and pick the alignment with a valid checksum (0 bad frames in 1400); SPI at 10 MHz (at 7 MHz MISO sampled 1 bit late after re-probe) |
| Keys | Home/Back/Recent/Power/Vol+ work. **Vol− and Active: gpa0-4/5 never change level even when held** (user confirmed) → wired elsewhere on hw_rev 4 |
| Big cores, cameras, sensors (BCM4773 hub), GPS, fingerprint | not done (cameras/sensors/FP blocked, see docs/re locally) |

Kernel branches: `src/linux` `gtactive3wifi` = live-tested; `integ` =
integration. Driver worktrees: `build/wt/{touch,power,cpu,wifi,audio,gpu,misc,...}`
(branch `drv/<track>`). Previous agent reports: `build/team/prev-*.json`.

## Boot chain to Duranium

**2026-10-21 20:51: the full chain booted Duranium** (S-Boot -> uniLoader ->
U-Boot -> systemd-boot -> UKI, postmarketOS kernel, verity /usr; the debug
console on port 23 answered inside it). It then hung in the initrd on UFS
DMA above 4 GiB (fixed in the kernel, image rebuild pending at the time of
writing). Loop protection is in place and tested:
- uniLoader: record stage 4 (jumped) on entry -> fallback Linux once; U-Boot
  sets stage 7 in board_quiesce_devices() at the OS handover.
- To leave a hung Duranium: `scripts/tab "poke 0x8ff1ff04c 4"` then
  `scripts/tab "write /proc/sysrq-trigger b"` (console reboot calls sync(),
  which hangs if the disk does). The next run boots the fallback Linux.
- devd.sh: same image back in Download mode 3x in 3 min -> boot-good.img.

(History below.)

uniLoader **dual payload** (`build/wt/uniloader`, branch `drv/chainload`) +
U-Boot (`build/wt/u-boot`, branch `drv/chainload`), packed by
`scripts/mkboot-chain.sh` (MODE=chain|linux|wdt-test →
`build/images/boot-chain*.img`; it never writes boot-mainline.img).
uniLoader: if RST_STAT bit 24 (watchdog reset) → boot the fallback bring-up Linux;
else set INFORM3=download, arm the cluster-0 watchdog (~82 s), jump to U-Boot.

- **wdt-test PASSED** (19:40): armed, reset after ~90 s, fallback Linux came
  back by itself, RST_STAT 0x01000000.
- **Real chain FAILED** (19:42): U-Boot crashed ~3 s in: synchronous abort,
  NULL `gd->jt` in `console_setfile()` (common/console.c), because
  `input_stdio_register()` assigned stdin=button-kbd during `stdio_add_devices()`
  before `jumptable_init()`. With INFORM3=download every crash went to Download
  mode and devd reflashed the same image: a **flash loop** (stopped by copying
  boot-good.img to boot-mainline.img).
  - **Fixed in U-Boot** (commit 382fdf18 on drv/chainload). Not rebuilt/tested yet.
  - **TODO before the next chain test (loop protection):**
    1. devd.sh: if the same image is flashed ≥3 times within ~3 min, flash
       `boot-good.img` instead and log it.
    2. uniLoader: a "chain attempt pending" marker in RAM (the handoff area
       0x8ff1ff000 survives resets and Download mode, as ulog showed); if set on
       entry → boot the fallback and clear it; U-Boot clears it right before
       `bootefi`.
  - Then `MODE=chain scripts/mkboot-chain.sh`, `cp build/images/boot-chain.img
    build/images/boot-mainline.img`, reboot download, watch, read `ulog` from the
    fallback Linux. Restore boot-good.img into boot-mainline.img afterwards.
  - The Volume Down escape in uniLoader does not work (pin dead, see keys).

## Duranium image (in progress)

- Trees: `build/wt/duranium` (duranium-build, branch gtactive3wifi),
  `build/wt/pmaports-duranium` (pmaports, branch duranium-gtactive3).
- Build: `cd build/wt/duranium && UI=gnome sh contrib/samsung-gtactive3wifi/build-image.sh`
  (`SKIP_APKS=1` reuses the packages in `build/wt/duranium-localpkgs`; single
  packages: `sh contrib/samsung-gtactive3wifi/build-apks.sh main/duranium-usb-debug
  device/testing/device-samsung-gtactive3wifi`). Logs: `logs/duranium-build-N.log`.
  After kernel changes: `contrib/.../kernel/refresh-aport.sh` (snapshots src/linux
  gtactive3wifi into the distfiles cache, regenerates the config, rewrites checksums).
- Fixed so far: podman entrypoint override, abuild key trust (-i), target strip,
  static usb-prep helper, kernel from a branch snapshot, local source copy,
  SELinux (`--security-opt label=disable`).
- **Current failure (attempt 8, exit 3):** apk "unable to select packages":
  `device-samsung-gtactive3wifi-bootimg` requires `uniloader-samsung-gtactive3wifi`
  and `firmware-samsung-gtactive3wifi-bootdtb` (not built). Duranium boots via
  EFI/UKI, so stop the -bootimg subpackage from being installed in Duranium (drop
  it or its install_if), or build those two aports (src/pmaports branch gtactive3wifi).
- Debug layer in the image: `duranium-usb-debug` (NCM gadget, same IDs/addresses as
  the bring-up; busybox root shell on **TCP 2323**; ssh; klog; watchdog),
  `duranium-usb-debug-adb` (adbd on FunctionFS: `adb shell`), and the **bring-up
  register console on TCP 23** (`gta3-console`, built from initramfs/init.c with
  `-DCONSOLE_STDIO -include initramfs/console-libc.h`, socket-activated) in the
  device package's -initramfs subpackage, so scripts/tab keeps working in Duranium.
  Off switches: drop the packages (release), `duranium.usb_debug=0` /
  `duranium.usb_debug_adb=0` on the cmdline, disable `duranium-usb-debug.target`.
- Disk: GPT with 4 KiB sectors written at LBA 0 of /dev/sda31 (nested). U-Boot
  exposes it via blkmap; the initrd via a udev rule
  (90-gtactive3wifi-nested-gpt.rules). Installer:
  `contrib/samsung-gtactive3wifi/install-to-userdata.sh` (streams over the console).
- Host cross toolchain for user space: aarch64-linux-gnu-gcc +
  sysroot-aarch64-fc44-glibc (`--sysroot=/usr/aarch64-redhat-linux/sys-root/fc44`,
  needs an empty libatomic_asneeded.a, see build/console/lib).

## Firmware / reverse engineering

- Stock firmware + vendor files: `firmware/extracted/` (INDEX.md),
  `firmware/fs/<part>`. Wi-Fi chip = BCM4375 B1.
- REA (`~/.local/bin/rea`; `source ~/tools/rea-env.sh` for Ghidra 12.1.4 + JDK 21)
  decoded 30 targets (ABOX SRAM/DRAM/IVA, audio HALs, camera HALs, sensor hub
  firmware + HALs, GNSS, fingerprint): `firmware/re-targets/INDEX.md`.
- T570-family GPL kernel: `build/ref/gtactive3cs` (lineage-12.1);
  Galaxy S9 downstream: `src/samsung-9810-ref`.

## Duranium boot status (2026-10-22 00:30)

GNOME initial-setup screens appeared on the panel (user saw them) with
image 14 (kernel r2). Issues found and fixed on the way:
- UFS FMP PRDT format after U-Boot -> SCSI_UFS_CRYPTO=y
- systemd-repart EBUSY mounting the new LUKS root -> BLK_DEV_WRITE_MOUNTED=y
- in the booted system only sshd listened (no key) -> sockets IgnoreOnIsolate
  + duranium-debug-sockets.service; dev key: build/secrets/duranium-dev-ed25519
  (public half via local extra tree build/duranium-extra, never committed),
  `ssh -i build/secrets/duranium-dev-ed25519 root@fe80::57:aff:fe00:1%enp0s20f0u5`
- Wi-Fi profile baked as /usr/lib/NetworkManager/system-connections/wifi-dev.nmconnection
  (local extra tree only). Build with:
  `MKOSI_CONTAINER_ARGS="-v $X:$X:ro" SKIP_APKS=1 UI=gnome sh contrib/samsung-gtactive3wifi/build-image.sh --extra-tree=$X`
- If locked out of a booted Duranium: ask the user for Power+VolDown 10 s, then
  VolUp+VolDown while plugging USB = Download mode (devd flashes boot-mainline.img;
  keep that = boot-good.img while testing).

## Next steps, in order

1. Loop protection (devd + uniLoader marker), rebuild the chain with the U-Boot
   fix, test; iterate with `ulog` until U-Boot reaches `bootefi`.
2. Fix the -bootimg dependency, build the GNOME Duranium image, check its layout.
3. Install into sda31, boot U-Boot → systemd-boot → UKI; verify over the console
   (port 23), adb and ssh; verify GNOME yourself (screenshot).
4. Touch (ID 0), keys (Vol−/Active), GPU acceleration in GNOME, big cores,
   Wi-Fi, audio, the rest: each live-tested, merged into `gtactive3wifi`, patches
   exported (`scripts/export-patches.sh`), pushed.
5. Keep PLAN.md / HARDWARE.md updated. Report to the user in the morning: what
   works (with evidence), what doesn't, and a short list of finger tests.

## Releases and the update server (2026-10-22)

GitHub is the update server: `.github/workflows/images.yml` rebuilds Phosh +
GNOME images (release and `-dev` channels) when postmarketOS publishes a new
Duranium build (checked daily) or `pmos/` changes, and publishes each channel
as a GitHub release with a signed SHA256SUMS. Images point sysupdate there
and trust only `pmos/sysupdate-public-key.asc` (key + revocation cert:
`build/secrets/sysupdate-gnupg`, repo secret `SYSUPDATE_SIGNING_KEY`).
**Release gate:** run `scripts/pmos-export` (then commit + push) only after
an on-device test; CI publishes exactly what is in `pmos/`. Images carry no
vendor firmware: it goes to `/var/lib/firmware` (`scripts/firmware-to-tablet`).
`build-image.sh CHANNEL=dev` (default) = with the USB debug layer;
`CHANNEL=release` = without. Details: docs/RELEASES.md.
