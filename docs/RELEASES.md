# Releases and updates

The project publishes postmarketOS **Duranium** images for the Galaxy Tab
Active3 (SM-T570) itself, and the tablets update from this repository. We
maintain the kernel, the drivers and the device packages. postmarketOS
maintains everything else, and our images follow theirs automatically.

## Who maintains what

| Piece | Where | Who |
|---|---|---|
| Kernel (mainline + our Exynos 9810 / SM-T570 drivers) | `pmos/aports/device/testing/linux-postmarketos-exynos9810` = torvalds/linux at `_base` + `gtactive3wifi.patch` | us |
| Device package (deviceinfo, early boot, UCM, defaults), USB debug layer, two GNOME Shell extensions | `pmos/aports/` | us |
| duranium-build changes (device hook, build scripts) | `pmos/duranium-build/*.patch` on upstream `BASE` | us |
| Image builder (mkosi config, A/B layout, first boot, sysupdate) | upstream duranium-build `main` | postmarketOS |
| Every other package, every UI | postmarketOS + Alpine binary repositories | postmarketOS |

## How a release happens

`.github/workflows/images.yml` runs every day (17:30 UTC), on every push that
changes `pmos/`, `ci/` or the workflow, and on demand ("Run workflow",
optionally forced).

1. **state** (`ci/state`): reads postmarketOS's newest published Duranium
   version (`https://duranium.nura.eco/images/mkosi.version`, their weekly
   image build) and hashes what we maintain. If no channel was published
   with that fingerprint yet, it builds; the new version is `YYMMDDNN`, above
   every version published before.
2. **packages**: `ci/prepare` clones upstream duranium-build and pmaports at
   their newest commit, applies our patches (if upstream moved in a way that
   conflicts, it builds on the recorded `BASE` and warns) and adds our
   aports, never replacing upstream ones. Then it builds our packages
   (`build-apks.sh`, as on the laptop; the kernel is cached until its aport
   changes).
3. **image**, four in parallel (`ci/channels`): `build-image.sh` with
   `--profile=compressed`, for each UI (Phosh, GNOME) and channel.
4. **publish** (`ci/publish`): uploads the version to its channel's GitHub
   release, writes a new `SHA256SUMS` (this version and the previous one),
   signs it with the project key (`SHA256SUMS.gpg`, the secret
   `SYSUPDATE_SIGNING_KEY`) and prunes older files.

## Channels

One GitHub release per channel. The tag is what sysupdate looks for
(`%M_%W_%w` = image id, UI, release):

| Channel (release tag) | For |
|---|---|
| `samsung-gtactive3wifi_phosh_edge` | everyone, Phosh |
| `samsung-gtactive3wifi_gnome_edge` | everyone, GNOME |
| `samsung-gtactive3wifi_phosh_edge-dev` | development tablets: + USB debug layer |
| `samsung-gtactive3wifi_gnome_edge-dev` | development tablets: + USB debug layer |

The **dev** images add `duranium-usb-debug` (USB network with a root shell,
ssh, adb and the bring-up register console, **no password**). Never use them
on a tablet that strangers can plug a cable into.

Every image carries, from `contrib/samsung-gtactive3wifi/mkosi.finalize`:

- `/usr/lib/sysupdate.d/*.transfer` sourcing
  `https://github.com/dixonSolutions/gtactive3-mainline/releases/download/<channel>/`
- `/usr/lib/systemd/import-pubring.pgp` holding only
  `pmos/sysupdate-public-key.asc` (fingerprint
  `D0FE 850A F01A 4783 1B6E  F808 5831 61CE 787F F5B5`), so a tablet only
  installs what this project signed
- `/usr/lib/gtactive3wifi/update-channel`

## On the tablet

```sh
updatectl check          # what the channel offers
updatectl update         # A/B: new /usr + UKI into the inactive slot
reboot                   # boot counting: if the new version does not boot
                         # twice, systemd-boot goes back to the old one
```

The root partition (user, settings, files, `/var/lib/firmware`) is never
touched by an update. Switching UI is an update too: in one boot, replace
the `/etc/os-release` symlink with a copy of `/usr/lib/os-release` that has
the other `VARIANT_ID` (`phosh`, `gnome`), run `updatectl update`, reboot
(the new /usr brings its own os-release, and boot relinks it).

### Firmware

Samsung's firmware cannot be redistributed, so images contain none. Extract
it from your own stock firmware (`tools/extract-stock-fw.sh`, firmware
T570XXSFEYI1) and install it once with `scripts/firmware-to-tablet` (or
`--tar` and copy by hand). It goes to `/var/lib/firmware`, which the kernel
searches first and which updates never touch. Without it, Wi-Fi, Bluetooth,
the audio DSPs, NFC and the S Pen do not work.

### First install

Duranium lives in a GPT nested inside the Android `userdata` partition and
boots through uniLoader + U-Boot in BOOT (see
`build/wt/duranium/contrib/samsung-gtactive3wifi/README.md` in a dev
checkout, or `pmos/duranium-build/`). The full disk image
`<channel>_<version>.raw.zst` is in every release; writing it
(`install-to-userdata.sh`) **erases** an existing Duranium's user data.
Installed tablets only ever update. A self-service installer for new
owners (boot image built from their stock boot.img) is not published yet.

## Maintainer loop

1. Change the kernel / a driver / the device package as usual (src/linux
   branches, build/wt/pmaports-duranium, build/wt/duranium), test on the
   tablet with `scripts/duranium-update`.
2. When it passed: `scripts/pmos-export`, review `git diff pmos/`, commit,
   push. The push builds and publishes.
3. If a run warns that our duranium-build patches no longer apply upstream:
   rebase `build/wt/duranium` (branch `gtactive3wifi`) on `origin/main`,
   export, push. If upstream pmaports gained one of our aport names, drop
   ours.

Signing key: `build/secrets/sysupdate-gnupg` on the laptop (never
committed; the revocation certificate is next to it), and the repository
secret `SYSUPDATE_SIGNING_KEY`. Losing it means tablets need an image with a
new key installed by hand, so keep a backup.
