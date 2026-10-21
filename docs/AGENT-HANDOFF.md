# Agent handoff: SM-T570 → postmarketOS Duranium (read this first)

Written 2026-10-21 ~19:50 AEDT by the lead agent before a context compaction.
If you are the agent reading this after compaction: **you are the lead**. You
coordinate, integrate, flash the tablet and test every change on the device
yourself, autonomously, overnight. Keep going until the mission is met.

## Who / what

- Device: Samsung Galaxy Tab Active3 Wi-Fi, **SM-T570** "gtactive3wifi", Exynos 9810
  (4× A55 + 4× Samsung M3 big cores, Mali-G72 MP18), hw_rev 4, bootloader
  T570XXSFEYI1 (unlocked, KnoxGuard cleared). The serial is never published.
- Repo: `/home/borysthebear/Projects/gtactive3-mainline` = public
  github.com/dixonSolutions/gtactive3-mainline (git identity: dixonSolutions,
  repo-local). Commit in small chunks, end messages with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, push `main`.
- **Mission (user's words, condensed):** postmarketOS **Duranium** (immutable,
  systemd, UKI + systemd-boot, A/B sysupdate) booting with the **GNOME UI only**
  (`postmarketos-ui-gnome` → `postmarketos-base-ui-gnome-duranium`; no Phosh, no
  Plasma), every piece of hardware working and verified on the device, drivers
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
6. The user stopped all background sub-agents; do NOT relaunch agents unless
   the user asks. Work yourself.
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
| UFS DMA | **must be 32-bit** (EXYNOS_UFS_OPT_DMA_32BIT): with buffers above 4 GiB every transfer is a System Bus Fatal Error; this hung the first Duranium boot |
| Wi-Fi (BCM4375 B1, PCIe ch0) | **works**: PCIe Gen2 x1 link, [14e4:4475], brcmfmac fw 18.41.117, wlan0 scans 2.4+5 GHz. Connect test needs the laptop's network: `scripts/wifi-push-creds` (user runs it; passphrase never printed), then `scripts/wifi-test connect` |
| Bluetooth (BCM4375 on UART_BT) | **works**: hci0, BCM4375B1 SEMCO, patch RAM build 0171 |
| Audio (A-Box + RT5665 + RT5510) | card registers, headset jack input, both PCMs stream (pcm-tone, 48 kHz); audibility not yet confirmed by a human |
| S Pen (Wacom W9019, HSI2C_23) | **works**: input "Wacom W9019 Digitizer" 17222x10764 |
| NFC (S3FWRN5, HSI2C_20) | nfc0 registers (load rfkill first); NCI init untested |
| Vibrator, flash LED (RT8547), hall sensor | drivers bind; hall polarity correct (open = 1) |
| Grip sensor (A96T3x6, HSI2C_34) | bus now 100 kHz (10 kHz could not be divided); needs S2MPS18 LDO40 (read-only PMIC) |
| SM5504 pogo MUIC | probe fails: no USB role switch on dwc3 yet |
| Touch (SPI21, Himax HX83102E) | **chip detected (ID 83102e)** after byte-wide bus access + burst like Samsung's driver; IRQ fires; idle frames fail the plain checksum, needs a real finger test |
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
