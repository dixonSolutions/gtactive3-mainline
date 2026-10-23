# Installing postmarketOS Duranium on the Galaxy Tab Active3 (SM-T570)

`./setup.sh` installs postmarketOS Duranium (Phosh or GNOME) on a Samsung
Galaxy Tab Active3 **Wi-Fi (SM-T570)** from a Linux PC, over the USB cable.
It guides you through every step, waits for you where you have to press
buttons on the tablet, and can always put Android back.

It is a development port: read [STATUS.md](STATUS.md) for what works.

## In short

```sh
git clone https://github.com/exynos-linux/gtactive3-mainline
cd gtactive3-mainline
./setup.sh --stock-ap ~/Downloads/AP_T570XXSFEYI1_....tar.md5
```

Re-running `./setup.sh` always continues where it stopped.

## How it works: two stages

| Stage | What changes on the tablet | Android afterwards | Back to Android |
|---|---|---|---|
| Bootloader unlock (Samsung's own step, only if locked) | **Samsung erases the tablet** (factory reset) | empty, as new | - |
| **1. Try** (`./setup.sh`) | only the BOOT partition: it gets our Linux (the "live environment") | untouched: system, apps, files | `./setup.sh undo`: exactly as before |
| **2. Install** (`./setup.sh install`, from the live environment) | Android's data partition is erased, Duranium is written into it | system still there, data gone | `./setup.sh restore-android-backup` (your backup) or `restore-android` (empty Android) |

Nothing of Android is erased until you choose **Install** and confirm it
twice: by typing `ERASE` on the PC and by pressing **Power** on the tablet.
Before that you can make a byte-exact backup of all of Android to your PC.

Duranium lives in a disk nested inside Android's `userdata` partition and
starts through our boot chain in BOOT (uniLoader, U-Boot, systemd-boot).
Android's system partitions, the recovery and Samsung's bootloader are not
changed. The installer never writes the partitions that hold the tablet's
identity and boot security (EFS, PARAM, PERSISTENT, VBMETA, the bootloader,
...): it refuses that in code, before every write.

## What you need

- A Samsung Galaxy Tab Active3 **SM-T570** (Wi-Fi). Not the LTE models
  (SM-T575/T577). Tested with firmware **T570XXSFEYI1** (bootloader revision
  F), hardware revision 4.
- A Linux PC (Fedora, Debian, Ubuntu, Arch, Alpine, ...) with these tools;
  `./setup.sh doctor` checks them and prints the install command:

  | Fedora | Debian / Ubuntu | Arch |
  |---|---|---|
  | `sudo dnf install android-tools heimdall curl gnupg2 zstd lz4 python3 openssl mtools e2fsprogs usbutils iproute` | `sudo apt install adb heimdall-flash curl gnupg zstd lz4 python3 openssl mtools e2fsprogs usbutils iproute2` | `sudo pacman -S android-tools heimdall curl gnupg zstd lz4 python openssl mtools e2fsprogs usbutils iproute2` |

- A USB **data** cable (charge-only cables do not work) and a USB port on
  the PC itself (hubs often drop the connection in Download mode).
- Your tablet's **stock firmware** for SM-T570 in the version the tablet runs
  (Settings > About tablet > Software information > Build number), from
  SamFW, Frija, Bifrost or samloader. You need the `AP_....tar.md5` file
  (inside the downloaded zip). Samsung's files cannot be shipped with this
  project; the installer needs them for:
  - your **stock boot image**, kept on your PC: `undo` puts it back, and our
    BOOT image is built around its device tree,
  - the **vendor firmware** for Wi-Fi, Bluetooth, audio, NFC and the S Pen
    (when Android does not let the installer copy it directly).
  Or let the installer download it from Samsung: `./setup.sh
  --download-stock` (needs `tools/auth_param.dat` from
  [Bifrost](https://github.com/zacharee/Bifrost),
  `common/src/commonMain/composeResources/files/auth_param.dat`; your
  tablet's serial number goes to Samsung's server only, as with Samsung's
  own tools).
- Free space on the PC: about 10 GB for downloads, plus room for backups
  (the full Android backup is about as big as the data Android uses).
- About an hour, most of it waiting.

## Stage 1: try it

1. On the tablet: **Settings > About tablet > Software information**, tap
   **Build number** 7 times. Then **Settings > Developer options**: switch
   on **USB debugging** (and **OEM unlocking**, if it is there).
2. Plug the tablet into the PC and run `./setup.sh --stock-ap AP_....tar.md5`.
3. The tablet asks **"Allow USB debugging?"**: tick "Always allow" and tap
   Allow.
4. The installer reads the model, firmware and lock state and tells you
   what to do. If the bootloader is **locked**, it walks you through
   Samsung's unlock (see below).
5. It saves your stock boot image and the vendor firmware on the PC, gets
   our boot chain (signed, checked) and builds your BOOT image.
6. It restarts the tablet into **Download mode** and flashes BOOT. Then:
   - the orange/yellow warning "The bootloader is unlocked and software
     integrity cannot be guaranteed": normal, it continues by itself;
   - white text on black, "Galaxy Tab Active3 - mainline Linux is alive":
     the **live environment**. The PC talks to it over the USB cable.
7. A menu: back up Android, install Duranium, go back to Android, or stop.

### The bootloader unlock (only if it is locked)

Samsung's unlock **erases everything on the tablet**. The installer first
offers to copy your photos, downloads, documents, music and videos to the
PC (or to the tablet's microSD card, which the unlock does not erase) and
lists your apps. App data, accounts and passwords cannot be backed up
without root. Then:

1. Type `UNLOCK` on the PC.
2. Power the tablet off.
3. Hold **Volume Up + Volume Down** and plug in the USB cable.
4. At the warning screen, **long-press Volume Up** ("Device unlock mode"),
   then press **Volume Up** to confirm.
5. The tablet erases itself and restarts. Go through Android's setup quickly
   but **connect to Wi-Fi**: Samsung's KnoxGuard check needs the internet.
6. Again: Build number x7, Developer options > USB debugging, allow the PC.
   The installer notices and continues.

If **OEM unlocking** is missing in Developer options: connect to Wi-Fi, set
date and time to automatic, check for software updates, restart and look
again. If it never appears, the tablet is probably carrier- or
company-managed and cannot be unlocked.

## Stage 2: from the live environment

### Full Android backup (recommended before installing)

`./setup.sh backup-android` (or menu item 1) reads Android's `userdata`
and `metadata` partitions byte for byte into
`~/gtactive3-backups/android-raw-<date>/` (zstd-compressed), plus a
read-only copy of `efs`/`sec_efs` (your tablet's identity data, for your
safety only: never shared, never written back by the installer). Unused
space compresses away; the encrypted data does not, so expect roughly the
size Android said it uses. Reading the 52 GB partition over USB takes
20-40 minutes.

The backup only works on **this** tablet (Android's encryption keys are in
its secure hardware). `./setup.sh restore-android-backup [DIR]` puts it
back and starts Android exactly as it was, with apps and data.

### Install Duranium

`./setup.sh install` (or menu item 2):

1. Choose the image: **Phosh** (recommended, the default: a touch-first
   shell made for phones and tablets) or **GNOME**, **release** or **dev**. Dev
   images run a root shell, ssh and adb on the USB cable **without a
   password**: only for development tablets. Images marked "not yet
   confirmed on a device" have not passed the on-device test yet.
2. The image is downloaded (resumable), its signature checked against the
   project key (`pmos/sysupdate-public-key.asc`, fingerprint
   `D0FE 850A F01A 4783 1B6E F808 5831 61CE 787F F5B5`) and unpacked. Your
   vendor firmware is added to the image's boot partition.
3. Confirm: type `ERASE` on the PC, then press **Power** on the tablet
   (Volume Up cancels; nothing is changed).
4. Android's data partition is erased, the image is written and read back
   for checking, BOOT gets the Duranium boot chain.
5. First start, 5-10 minutes: U-Boot, systemd-boot, the postmarketOS logo.
   The first start creates the encrypted root partition. Then choose your
   **disk passphrase** (asked at every start) and your user.

Wi-Fi, Bluetooth and audio need the vendor firmware: the installer puts it
on the image's boot partition (`/boot/gtactive3wifi-firmware.tar.zst`) and
Duranium moves it into `/var/lib/firmware` at the first start, before the
drivers load (updates never touch it). If Wi-Fi is missing after setup, copy
`~/.local/state/gtactive3-setup/firmware/firmware.tar` to the tablet (USB
stick) and run in a terminal:

```sh
sudo tar -xf firmware.tar -C /var/lib/firmware --no-same-owner
sudo reboot
```

On dev images the installer checks this over USB and installs it itself
(`./setup.sh firmware` does it again).

## Going back to Android

| Situation | Command | Result |
|---|---|---|
| Stage 1 (Duranium not installed) | `./setup.sh undo` | stock boot image back; Android starts exactly as before |
| You have a full backup | `./setup.sh restore-android-backup` | Android exactly as it was when you backed it up |
| No backup | `./setup.sh restore-android` | Duranium erased; Android's data partition is formatted (as Samsung formats it) and Android starts its first-time setup |
| Temporarily, Duranium installed | `./setup.sh undo`, later `./setup.sh redo` | **careful**, see below |

**Never use "Factory data reset" from Samsung's recovery menu**, and do not
accept Android's offer to reset. On these tablets it sets **KnoxGuard** back
to "Prenormal": Download mode then refuses every non-Samsung image ("Only
official released binaries are allowed to be flashed") until the tablet has
checked in with Samsung over the internet. `restore-android` avoids it: it
formats Android's data from our Linux instead.

`undo` after installing Duranium flashes the stock boot image, but Android's
data partition then holds Duranium, so Android stops with "Can't load
Android system" and offers a factory reset: refuse it, put Duranium back
with `./setup.sh redo`, or use `restore-android`. The installer asks you to
type `UNDO` in that case.

**Full stock firmware**: if Android's system was erased (on tablets
prepared by hand, or after `gtactive3wifi-claim-android-space`; the
installer never erases it), flash your complete stock
firmware: Odin on Windows (BL, AP, CP, HOME_CSC), or heimdall with every
image from the AP file. Never flash a modified `vbmeta`: the bootloader
then stops in Download mode without USB.

## Updates

Installed tablets update themselves from this project's releases (A/B: the
running version stays as the fallback; a version that fails to start twice
is dropped automatically):

```sh
sudo updatectl update   # on the tablet, then restart
./setup.sh update       # from the PC, dev images (USB console)
```

Your files, settings and the vendor firmware are on the encrypted root and
are never touched by updates. Switching between Phosh and GNOME is an
update too, see [RELEASES.md](RELEASES.md).

### Testing your own build

For developers: `./setup.sh update --next-test-version` prints the version
to build a test image with (`<newest published + 1>~test<N>`, e.g.
`26102215~test1`). Build it with that version (`mkosi --image-version`,
never rename a build), then `./setup.sh update --test [mkosi.output dir]`
installs it as a one-off A/B update through `scripts/duranium-update`. `~`
sorts below the plain version, so the next official update replaces the
test build; the tablet's update channel is not changed (the installer
checks it before and after).

## More space: Android's system partitions (optional)

Duranium lives in Android's data partition; Android's own operating system
stays on the tablet unused, so that `./setup.sh restore-android` can start
it again. If you will not go back to Android, its `super` partition
(7.13 GB: system, vendor, product) can become extra encrypted storage. On
the tablet, in a terminal:

```sh
sudo gtactive3wifi-claim-android-space --dry-run   # what it would do
sudo gtactive3wifi-claim-android-space             # type ERASE-ANDROID, then your disk passphrase
```

**This erases Android's operating system.** Afterwards only a complete
stock firmware flash (Odin: BL, AP, CP, HOME_CSC) brings Android back;
`./setup.sh restore-android` and Samsung's recovery cannot. Duranium and
your files are not touched.

- The space is a LUKS2-encrypted ext4 volume on `/var/mnt/android-space`
  with a folder for you, linked as `~/android-space`. Its passphrase is
  your disk passphrase (checked before anything is changed); at every
  start a key file on the encrypted root unlocks it, and the boot never
  waits for it or asks for it if it is missing (`nofail`).
- `--with-prism` also claims `prism` (0.63 GB, Samsung's CSC data) as a
  second volume on `/var/mnt/android-space-prism`. The bootloader checks
  prism's signature block at every start, so that part of it is kept
  byte for byte (checked after formatting).
- `--containers` puts your podman and distrobox images and containers
  (normally `~/.local/share/containers`, on the root) on the new volume.
  Not the default: containers then need that volume, and existing images
  are not moved (pull them again).
- `--status` shows the state; `--undo` stops using it (the data stays and
  your passphrase still opens it); `--undo --wipe` erases it for good.
- After a reset of the root partition (all settings gone), running it
  again attaches the existing volume without formatting.

Only partitions named `super` and `prism` on the internal storage are ever
written; EFS, the bootloaders, param, persistent, vbmeta, BOOT, RECOVERY
and the rest are never touched. Tests: `tests/claim-space/run.sh` (and
`busybox.sh` for BusyBox ash).

## Commands

| Command | |
|---|---|
| `./setup.sh` | the guided install; continues where it stopped |
| `./setup.sh live` | stage 1 only |
| `./setup.sh backup-android` / `restore-android-backup [DIR]` | full Android backup / restore |
| `./setup.sh install` | stage 2: install Duranium |
| `./setup.sh undo` / `redo [linux\|chain]` | stock boot image back / ours back |
| `./setup.sh restore-android` (= `uninstall`) | erase Duranium, Android starts fresh |
| `./setup.sh wipe` | fresh install over an existing Duranium (type `WIPE`) |
| `./setup.sh update [--test ...]` | updates |
| `./setup.sh firmware [--export FILE]` | (re)install the vendor firmware |
| `./setup.sh backup-files` | copy Android's files over adb |
| `./setup.sh prepare` | only rebuild your BOOT images (e.g. after a new boot-chain release) |
| `./setup.sh status` / `doctor` | what is connected, versions, slots / + PC checks |

Options: `--stock-ap FILE`, `--stock-zip FILE`, `--stock-boot FILE`,
`--download-stock`, `--firmware-dir DIR`, `--channel ID`, `--version V`,
`--image FILE` (a local image, no signature check), `--payload DIR|TAR`,
`--serial SERIAL`, `--dry-run` (show every action, change nothing),
`--verbose`, `--yes` / `--yes-wipe` (non-interactive). `./setup.sh --help`.

## Buttons

| What | How |
|---|---|
| Force restart | hold **Power + Volume Down** for 7-10 s |
| Download mode | force restart, then at once hold **Volume Up + Volume Down** and plug in USB; press Volume Up at the warning |
| Leave the live environment | **Volume Up** restarts it into Download mode |

## Troubleshooting

- **adb shows no device**: USB debugging off, charge-only cable, or no USB
  rules: `./setup.sh doctor` offers to install
  `scripts/installer/udev/60-gtactive3-samsung.rules`.
- **"unauthorized"**: accept the prompt on the tablet; no prompt? replug,
  or Developer options > Revoke USB debugging authorisations.
- **The live environment does not answer**: the PC must bring up the
  tablet's USB network (`ip link` shows a new interface with the cdc_ncm
  driver); `./setup.sh status` explains what it sees and offers
  `sudo ip link set <if> up`.
- **"An error has occurred while updating the device software"** in
  Download mode: KnoxGuard blocks custom images, or the USB connection
  dropped. Look at the small text at the top of the Download mode screen:
  `KG STATE: Prenormal` means: restart into Android (Power + Volume Down),
  stay online on Wi-Fi for 10 minutes, restart once, try again. Otherwise
  use another USB port/cable. Download mode always works, and `./setup.sh
  undo` puts your stock boot image back.
- **Duranium does not start**: after a failed start the boot chain falls
  back to our Linux (white text). `./setup.sh status` tells you what runs.
- **Logs**: every run writes `~/.local/state/gtactive3-setup/log/`.

## Files on your PC

| Where | What |
|---|---|
| `~/.local/state/gtactive3-setup/` (`GTA3_STATE_DIR`) | progress (`state.env`), logs, your stock boot/recovery images, vendor firmware, your BOOT images and the local key for their footer |
| `~/.cache/gtactive3-setup/` (`GTA3_CACHE_DIR`) | downloads (safe to delete) |
| `~/gtactive3-backups/` (`GTA3_BACKUP_DIR`) | your backups |

The serial number is never stored (only a hash, to recognise the tablet).
Samsung's firmware and your backups stay on your PC: do not share them.

## For developers

- Everything lives in `scripts/installer/` (`setup.sh` only starts it);
  tests: `tests/installer/run.sh` (a fake tablet; no device, no network).
- The boot chain payload (uniLoader + U-Boot + our bring-up Linux, all GPL,
  no Samsung files) is built by `ci/bootchain/build` and published by
  `.github/workflows/bootchain.yml` to the release
  `samsung-gtactive3wifi_bootchain` with a signed SHA256SUMS. The installer
  packs it with the owner's stock DTB and header exactly as
  `scripts/mkboot-chain.sh` does (byte-identical before the AVB footer).
- `--image FILE.raw[.zst]` and `--payload DIR` take local builds.

## Remote access without the USB cable (testing)

Dev images keep their debug console, shell and ssh on the USB link only.
To reach a tablet over Wi-Fi (also behind enterprise networks that isolate
clients, and next to a VPN on the PC), join it to your Tailscale tailnet:
log in, connect to Wi-Fi, open Console and run

    wget -qO- https://exynos-linux.github.io/gtactive3-mainline/remote | sudo sh

Scan the QR code it shows with a phone signed in to your tailnet and
approve the tablet; then `tailscale ssh root@gtactive3` from the PC. The
script (`scripts/tablet-remote`) installs the official static Tailscale
build (pinned version and sha256) under /var/lib/gtactive3wifi/tailscale
with a unit in /etc, in userspace networking mode; its header says how to
remove it. The disk passphrase at boot still has to be typed on the tablet
(no network before the root is unlocked).
