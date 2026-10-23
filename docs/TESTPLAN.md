# On-device test plan (SM-T570 Duranium)

The test cases for `/test-new-remote-and-drivers`
(.claude/skills/test-new-remote-and-drivers/SKILL.md). Each case has an id,
what it needs, the commands, what PASS looks like and what to do when it
fails. "Console" = `scripts/tab "<cmd>"` (TCP 23); "shell" = ssh with
`build/secrets/duranium-dev-ed25519` or `run /bin/sh script` over the
console. 👆 = needs the user's hands (batch these, see the skill §1).

Results go to `logs/test-runs/<run>/results.tsv`; docs/STATUS.md is updated
from them (only a Duranium ✔ counts).

## Under test now

| Piece | Version / branch | Built by |
|---|---|---|
| Kernel candidate | (lead fills in: cand/10xx + merged drv/* branches, aport pkgrel) | lead |
| Device package | (pkgrel) | platform |
| Images | Phosh `samsung-gtactive3wifi_phosh_edge_<ver>`, GNOME `..._gnome_edge_<ver>` | lead / CI |

## A. Laptop gates (no tablet)

| id | what | command | PASS |
|---|---|---|---|
| A1 | installer suite | `tests/installer/run.sh` | all cases pass |
| A2 | Phosh image in QEMU | `tests/virt/run.sh <phosh raw> --ui phosh` | summary PASS, screenshot shows Phosh |
| A3 | GNOME image in QEMU | `tests/virt/run.sh <gnome raw> --ui gnome` | summary PASS, screenshot shows GDM/GNOME |
| A4 | CI | `gh run list -w images.yml -L 3` | newest run green, releases updated |
| A5 | release index | `curl -fsS https://exynos-linux.github.io/gtactive3-mainline/releases.json` | lists every channel's newest version; `./setup.sh` verifies its SHA256SUMS signature |

## B. Boot and baseline (every new image)

| id | what | how | PASS | on failure |
|---|---|---|---|---|
| B1 | A/B delivery | `UI=phosh scripts/duranium-update <ver>` | hashes match on the tablet, UKI `+2-0` in the ESP | read the script's output; nothing is lost, the old slot still boots |
| B2 | boot 👆 passphrase | reboot, user types passphrase | console answers, IMAGE_VERSION = new | boot counting falls back after 2 tries; `scripts/tab ulog`, pstore |
| B3 | health | `scripts/duranium-check $R/shots/b3.png` | `systemctl is-system-running` running (or degraded only by known QEMU-free units), no new failed units, Phosh (phoc+phosh) or gdm+gnome-shell running | journal errors → fix |
| B4 | GUI | look at the screenshot | lock screen / home screen drawn cleanly | display/GPU cases |

## C. Existing hardware regression (each new kernel)

| id | block | how | PASS |
|---|---|---|---|
| C1 | Wi-Fi | `nmcli -t device`, `ping -c3 1.1.1.1` over wlan0 | connected, 0% loss |
| C2 | Bluetooth | `bluetoothctl show`, `bluetoothctl --timeout 15 scan on` | powered, devices found |
| C3 | Touch 👆 | evtest on the Himax device while the user drags | ≥100 events, no bad frames in dmesg |
| C4 | S Pen 👆 | evtest on "Wacom W9019 Digitizer", hover + press | BTN_TOOL_PEN, pressure changes |
| C5 | Keys 👆 | evtest gpio-keys: Power, Vol+, Home, Back, Recent | each key down/up seen |
| C6 | Audio 👆 | `speaker-test -c2 -t sine -l1` / pw-play; user confirms speaker + headphones | user hears both |
| C7 | Battery/charger | `/sys/class/power_supply/*/{capacity,current_now,status,temp}` | sane values, charging on USB |
| C8 | Thermal | `/sys/class/thermal/thermal_zone*/temp` | all < 70 °C idle |
| C9 | GPU | `glxinfo -B`/`eglinfo` in the session: panfrost; fault count in dmesg | renderer Mali-G72 (Panfrost), 0 MMU faults |
| C10 | Backlight 👆 | set brightness 10 %, 100 % | the user sees the change; sysfs follows |

## D. New work

Order: D1 (containers, memory) and D2 (power) need only the new image; D3
(PMIC writes) gates D4-D6 (it is the first ACPM regulator write on this
board); cameras (D7) after D3. Suspend (D8) and the update remote (D9) and
installer (D10) sections follow.

### D1. Containers and memory (device package r28+, PLATFORM)

| id | how | PASS |
|---|---|---|
| D1.1 | Wi-Fi off; as root `/usr/libexec/gtactive3wifi/containers-selftest` | all PASS, exit 0; podman info `overlay cgroups-v2 crun netavark rootless=false` |
| D1.2 | user logged in: `u=$(cat /etc/default_user); systemd-run --machine=$u@ --user --wait --pipe /usr/libexec/gtactive3wifi/containers-selftest` | all PASS, `rootless=true`, the user's subuid line shown (ratrad:100000:65536 exists) |
| D1.3 | `cat /sys/kernel/mm/lru_gen/enabled; swapon --show; cat /sys/block/sda/queue/scheduler; oomctl; sysctl kernel.panic vm.swappiness; grep -o workqueue.power_efficient=1 /proc/cmdline; systemctl is-enabled ModemManager` | lru_gen non-zero, zram0 zstd ~5.8G prio 300, `[mq-deadline]`, user@ 80 % limit, 10 / 180, present, disabled |
| D1.4 | `getfattr -n user.oomd_avoid <cgroup of mobi.phosh.Shell.service or org.gnome.Shell@...>` | `"1"` |
| D1.5 👆 | user opens ~8 apps (Firefox 5 tabs, Settings, Console, Files, Text Editor); watch `/proc/pressure/{memory,cpu,io}`, `/sys/block/zram0/mm_stat`, `journalctl -u systemd-oomd` | some avg10 < 20 %, compression ~3x, the shell never killed |
| D1.6 | `powerprofilesctl set power-saver` → policy0 scaling_max_freq 1456000; `balanced` → 1950000; in performance `vm.swappiness` stays 180 | as stated |
| D1.7 | Home / Recent keys 👆 in Phosh | overview opens |

On failure: `journalctl -u gtactive3wifi-container-images` (+ `--user`),
`lsmod | grep -E 'nf_tables|veth|tun'`; a user without subuid:
`usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>`.

### D2. Power draw (each new kernel/image)

Screen on idle (Wi-Fi associated) and blanked, on the laptop USB port: 10 ×
60 s averages of `/sys/class/power_supply/max170xx_battery/current_now` and
the arch_timer delta in /proc/interrupts over 60 s blanked. Compare with
the baseline (26102209: 214 mA on / 184 mA blanked, coordinator; net
current on USB in logs/test-runs/20261022-baseline/facts.log).

### D3. PMIC regulator writes (drv/hwgaps + drv/cam, HWGAPS/CAMERA)

First ever ACPM PMIC write on this board. Bring-up kernel first (device
lock, coordinator rules), base DTB:
- console comes up; dmesg: S2MPS18 registers 45 regulators, no -EPERM;
  ~30 s later "disabling" for unused whitelisted LDOs (LDO2/31/40/41 and
  the camera LDOs) only. `cat /sys/class/regulator/*/{name,state,microvolts}`.
- PASS = no hang, only whitelisted rails change. Hang/crash → reset →
  Download mode → devd → boot-good after 3x.
- Duranium kernels before D3 passes boot with `regulator_ignore_unused`.

### D4. Grip sensor and NFC (HWGAPS)

- Grip: `modprobe a96t3x6` → "fw 0x.. vendor 0x.. model 0x..",
  VDD_GRIP_3P0 enabled at 3000000 µV, `in_proximity*_raw` changes 👆 (hand
  near the edge); rmmod turns LDO40 off.
- NFC (chip is an S3NRN4V): NEVER provide `sec_s3fwrn5_firmware.bin` (would
  run the S3FWRN5 flasher on this chip). `modprobe s3fwrn5_i2c` → nfc0,
  VDD_NFC_1P8 1.8 V, `peek 0x14060a0c` bit 0 = 0; `nfctool -d nfc0 -1`
  → NCI reset/init in dmesg without a "fw file" request; `nfctool -d nfc0 -p`
  polling (a tag 👆; RF tuning not loaded, reading may fail: BLOCKED is OK).

### D5. microSD (HWGAPS) 👆 card inserted

Stage 0 read-only peeks (CMU/PMU/GPIO) from docs in the HWGAPS report
(scripts in logs); then `modprobe dw_mmc-exynos mmc_block` →
"mmc0: new ultra high speed SDR104 SDHC/SDXC card", mmcblk0p*; `dd` 64 MB
read rate; remove/reinsert 👆 → removed / re-detected. Tuning failure → DTB
without `sd-uhs-sdr104`, then without `sd-uhs-sdr50`. In Phosh: automount.

### D6. Flashlight, OTG

- Torch: Phosh flashlight toggle 👆 → `/sys/class/leds/white:flash/brightness`
  1-6 and the user sees the LED.
- OTG (later, separate kernel with USB_DWC3_DUAL_ROLE + `-otg` DTB): see the
  HWGAPS stage 5 plan; the user unplugs the laptop, attaches an OTG stick,
  re-plugs; the console must come back in device mode. Not in Duranium until
  it passes.

### D7. Cameras (drv/cam, CAMERA) - docs/CAMERA.md has every command

- A1 read-only pre-check: PASS on 26102209 (ISPPRE 0xf, PHY isolation 1/1,
  CSIS 0x05010000 ×2, CIS_CLK as documented). SysMMU 0x16310000 bit 0 not
  read yet (could be gated): read it in the bring-up before streaming.
- A2-A7 bring-up: CSIS probe, sensor IDs 0x30c6 / 0x5035, colour bars
  (`tools/v4l2-grab`, `tools/bayer2png.py`, look at the PNG), real scene,
  black level, full resolution, front camera, rmmod.
- B Duranium: blacklist the three modules for the first boot, modprobe by
  hand, repeat; C `cam -l`, `cam -c 1 --capture=10`; D Snapshot in Phosh
  (screenshot, rotation).

### D9. Update remote (GitHub releases, RELEASE)

Local images 26102209-26102213 point sysupdate at postmarketOS and/or lack
the keyring: the first move to a CI image is a `scripts/duranium-update`
(release files: `zstd -d` the usr / verity `.raw.zst` next to the `.efi`,
`OUT=<dir> UI=phosh EXTENSIONS="" scripts/duranium-update <ver>`).

| id | how | PASS |
|---|---|---|
| D9.1 | `cat /usr/lib/gtactive3wifi/update-channel; ls -l /usr/lib/systemd/import-pubring.pgp; grep ^Path= /usr/lib/sysupdate.d/*usr.transfer` | `..._<ui>_edge-dev`, keyring present, Path = our GitHub `-dev` release |
| D9.2 | `updatectl check` / `systemd-sysupdate list` | the newest published -dev version is offered |
| D9.3 | `systemd-sysupdate update` | "Successfully installed update"; inactive pair `duranium_<v>_usr/_vty`; ESP `..._<v>+2-0.efi` (vacuum on failure; the booted slot is never touched) |
| D9.4 | reboot (tab-unlock) | IMAGE_VERSION = new; `systemctl status systemd-bless-boot` ok and the UKI loses `+N-M` (if not: blessing broken, note it) |
| D9.5 | rollback: boot the old entry / let the new one fail twice | systemd-boot falls back, old version intact |
| D9.6 | `~test`: build `<L+1>~test1` (L = newest published), `./setup.sh update --test build/wt/duranium/mkosi.output <ver>`, reboot | `updatectl list` shows it current; after the next CI publish, `check` offers that version and `update` replaces the test build |

### D10. Installer suite (INSTALLER)

On the user's tablet (unlocked, Duranium dev, Android super wiped):

| id | how | PASS |
|---|---|---|
| D10.1 | `./setup.sh status` | "Duranium (dev image, USB console)", image/kernel/slots/boot entries/firmware count (PASS 2026-10-22 after the IMAGE_ID fix) |
| D10.2 | `./setup.sh update --next-test-version` | `<newest published+1>~test1` |
| D10.3 | `./setup.sh update --test ...` | see D9.6 |
| D10.4 | live environment from the CI payload: stop devd, `./setup.sh prepare --stock-boot firmware/stock/boot.img --payload build/scratch/installer/bootchain-out --firmware-dir firmware/extracted/linux-firmware/lib/firmware`, `./setup.sh redo linux --yes` | white text console, status "live environment", userdata 51.7 GiB; recovery: Power+Vol- then Download mode, `heimdall flash --BOOT build/images/boot-good.img` |
| D10.5 | `./setup.sh redo chain --yes` | U-Boot → systemd-boot → Duranium passphrase; then the bootchain workflow may run with publish=true |
| D10.6 | optional `GTA3_BACKUP_DIR=<60 GB free> ./setup.sh backup-android` | raw backup, hashes match |

Never on the user's tablet without their explicit OK: `install`, `wipe`,
`restore-android`, `restore-android-backup`, `undo`.

## E. Test helpers

- `GTA3_PASSWORD=<ClaudeKeys placeholder> scripts/tab-unlock` answers the
  disk passphrase prompt over the console (initrd, systemd-reply-password).
- `GTA3_PASSWORD=... scripts/tab-login [USER]` logs in at GDM or phrog
  (tools/uinput-type virtual keyboard).
- `GTA3_PASSWORD=... scripts/tab-checkpw` checks a secret against the LUKS
  root and the account without using it.
- `scripts/notify-user` + PushNotification for anything physical.
