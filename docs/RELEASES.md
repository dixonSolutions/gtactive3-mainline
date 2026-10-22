# Releases and updates

The project publishes postmarketOS **Duranium** images for the Galaxy Tab
Active3 (SM-T570) itself, and the tablets update from this repository. We
maintain the kernel, the drivers and the device packages. postmarketOS
maintains everything else, and our images follow theirs automatically.

Official record of what is published (versions, files, sizes, sha256,
signature key): **https://dixonsolutions.github.io/gtactive3-mainline/**
(machine-readable: [`releases.json`](https://dixonsolutions.github.io/gtactive3-mainline/releases.json)).
To install, see [INSTALL.md](INSTALL.md).

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
changes `pmos/`, `ci/` (except `ci/pages`, `ci/bootchain/`) or the workflow,
and on demand ("Run workflow": optionally forced, optionally with a
`min_version`).

1. **state** (`ci/state`): reads postmarketOS's newest published Duranium
   version (`https://duranium.nura.eco/images/mkosi.version`, their weekly
   image build; if their server is down, the base of the last build) and
   hashes what makes our images (`pmos/`, `ci/{prepare,channels,publish,check-image}`,
   `images.yml`). It builds when a channel this run would publish does not
   carry that fingerprint yet (release notes, `Fingerprint:` line). The new
   version is `YYMMDDNN`, above every version any channel published and
   above `MIN_VERSION` (input, else the repository variable of that name).
2. **packages**: `ci/prepare` clones upstream duranium-build and pmaports at
   their newest commit, applies our patches (if upstream moved in a way that
   conflicts, it builds on the recorded `BASE` and warns) and adds our
   aports, never replacing upstream ones. Then it builds our packages
   (`build-apks.sh`, as on the laptop; the kernel is cached until its aport
   changes).
3. **image**, four in parallel (`ci/channels`): `build-image.sh` with
   `--profile=compressed`, for each UI (Phosh, GNOME) and channel. The
   release channels are only built for a device-verified export (below).
4. **check** (`ci/check-image`): inside the built `/usr` and UKI, the
   sysupdate keyring must hold exactly our key, every transfer must fetch
   from this channel's release, `update-channel` must name it, the UKI must
   carry the version; a release image must not contain any part of the USB
   debug layer (packages, `/usr`, initrd), a dev image must.
5. **publish** (`ci/publish`): uploads the version to its channel's GitHub
   release, then a new `SHA256SUMS` (this version and the previous one,
   `KEEP=2`) signed with the project key (`SHA256SUMS.gpg`, secret
   `SYSUPDATE_SIGNING_KEY`), fetches both back from the public URL and
   verifies them like a tablet would, and only then deletes every older
   version's files. It refuses a version that is not `YYMMDDNN`, a version
   older than one the channel has, and a channel whose current manifest is
   not signed by our key.
6. **pages** (`.github/workflows/pages.yml`, `ci/pages`): regenerates the
   release records after every images / bootchain run, every 6 hours and on
   demand.

A tablet in the middle of an update never loses its files: the previous
version stays complete in the release until the next-but-one publish. The
only window is the second between replacing `SHA256SUMS` and
`SHA256SUMS.gpg`, in which a check fails the signature and is retried later.

## Channels

One GitHub release per channel. The tag is what sysupdate looks for
(`%M_%W_%w` = image id, UI, release):

| Channel (release tag) | For |
|---|---|
| `samsung-gtactive3wifi_phosh_edge` | everyone, Phosh |
| `samsung-gtactive3wifi_gnome_edge` | everyone, GNOME |
| `samsung-gtactive3wifi_phosh_edge-dev` | development tablets: + USB debug layer |
| `samsung-gtactive3wifi_gnome_edge-dev` | development tablets: + USB debug layer |

The **dev** images add `duranium-usb-debug` + `-adb` (USB network with a
root shell, ssh, adb and the bring-up register console, **no password**).
Never use them on a tablet that strangers can plug a cable into. The dev
channels are GitHub pre-releases. The boot-chain payload (uniLoader +
U-Boot for the BOOT partition, used by the installer) has its own release,
`samsung-gtactive3wifi_bootchain`, signed with the same key and built by
its own workflow (`bootchain.yml`, `ci/bootchain/`); `releases.json` lists
it under `bootchain`.

Every image carries, from `contrib/samsung-gtactive3wifi/mkosi.finalize`:

- `/usr/lib/sysupdate.d/*.transfer` sourcing
  `https://github.com/dixonSolutions/gtactive3-mainline/releases/download/<channel>/`
  (upstream's transfers with only `Path=` rewritten: usr + verity into the
  inactive A/B slot, the UKI with boot counting `+2-0`, sysexts/confexts
  behind the disabled `dev-tools` / `waydroid` features)
- `/usr/lib/systemd/import-pubring.pgp` holding only
  `pmos/sysupdate-public-key.asc` (fingerprint
  `D0FE 850A F01A 4783 1B6E  F808 5831 61CE 787F F5B5`), so a tablet only
  installs what this project signed (`Verify=` stays on)
- `/usr/lib/gtactive3wifi/update-channel` (also printed by
  `duranium-set-channel`; there is no staging channel)

The 26102201 images (the first two pre-releases) had **no keyring** (gpg
under keyboxd ignored `--keyring` in CI) and cannot update with sysupdate;
tablets running them need one `scripts/duranium-update` to a newer image.

## Versions

- Published versions are `YYMMDDNN` and only ever grow.
- Local builds use the same scheme (`mkosi.version`). A tablet running a
  local build that is newer than everything published does not take a
  remote update until a newer one is published: set the repository
  variable `MIN_VERSION` (or the `min_version` input) to the newest local
  version tablets run. Currently `MIN_VERSION=26102213`.
- Local **test** builds use `<L+1>~test<N>`, where L is the newest
  published version (any channel): `~` sorts below the plain version, so
  the test build is newer than what is installed and every future
  published version (>= L+1) replaces it:

  ```
  $ systemd-analyze compare-versions 26102215~test1 26102215
  26102215~test1 < 26102215
  $ systemd-analyze compare-versions 26102215~test1 26102214
  26102215~test1 > 26102214
  ```

### Local test updates

`setup.sh update --next-test-version` prints the version to build with,
`setup.sh update --test [DIR] [VERSION]` installs it (both from the
installer, docs/INSTALL.md; it uses `scripts/duranium-update`). The image
must be **built** with that version (`echo 26102215~test1 > mkosi.version`
in duranium-build before `build-image.sh`), never renamed afterwards:
sysupdate protects the booted version by the `IMAGE_VERSION` in its
os-release (`ProtectVersion=%A`), which has to match the partition labels.
The update lands like a sysupdate one (partitions `duranium_<V>_usr` /
`_vty`, UKI `samsung-gtactive3wifi_<ui>_edge_<V>+2-0.efi`), so on the
tablet:

```
updatectl list        # 26102215~test1 current, 26102214 installed
updatectl check       # nothing until CI publishes 26102215 (or newer)
updatectl update      # then: 26102215 replaces the slot of the older version
```

Test builds never touch `/etc/sysupdate.d` or the channel.

## On the tablet

```sh
updatectl check          # what the channel offers
updatectl update         # A/B: new /usr + UKI into the inactive slot
reboot                   # boot counting: if the new version does not boot
                         # twice, systemd-boot goes back to the old one
```

To make room, sysupdate first drops the installed version that is not
booted (its slot and UKI), then writes the new one; the booted version is
never touched (`ProtectVersion=%A`). While it writes, it marks the target
slot as partial (its GPT type changes to a derived one), so a half-written
slot never boots. After a
failed or interrupted update, retrying the same version is refused
("already acquired and partially installed"): run
`/usr/lib/systemd/systemd-sysupdate vacuum` (the slot goes back to
`_empty`), then update again. Once a newer version is published, the next
update clears the partial slot by itself. Signature or checksum failures
(tampered or half-uploaded files) end the same way.

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

Duranium lives in a GPT (4096-byte sectors) nested inside the Android
`userdata` partition and boots through uniLoader + U-Boot in BOOT. The full
disk image `<channel>_<version>.raw.zst` is in every release; installing it
**erases** an existing Duranium's user data. Installed tablets only ever
update. See [INSTALL.md](INSTALL.md).

## Release records (GitHub Pages)

`ci/pages OUT` writes `releases.json`, `channels/<id>.json`, `index.html`
and `sysupdate-public-key.asc`; `pages.yml` deploys them with
`actions/deploy-pages` (Pages source: GitHub Actions). Only what a tablet
would accept is listed: a channel's versions, files and sha256 values come
from its `SHA256SUMS` after `gpgv` verified it with our key; sizes and URLs
from the release assets. `releases.json` (schema 1, consumed by the
installer; new fields are only ever added):

```
{"schema": 1, "generated": "<iso8601>", "repo": "dixonSolutions/gtactive3-mainline",
 "channels": [{"id": "samsung-gtactive3wifi_phosh_edge-dev", "ui": "phosh",
   "flavour": "release" | "dev", "title": "Phosh", "description": "...",
   "prerelease": bool, "verified": bool, "latest": "<version>",
   "versions": [{"version": "26102214", "date": "<iso8601>",
     "files": [{"name", "size", "sha256", "url",
       "kind": "uki" | "usr" | "usr-verity" | "install-raw" | "sysext" |
               "confext" | "manifest" | "signature"}]}]}],
 "bootchain": {"tag", "prerelease", "date", "files": [{"name", "size", "sha256", "url"}]}}
```

`verified` = built from an export that passed on the device (release notes
line `Verified on the device:`); `bootchain` only when that release exists.

## Maintainer loop

1. Change the kernel / a driver / the device package as usual (src/linux
   branches, build/wt/pmaports-duranium, build/wt/duranium), test on the
   tablet with `scripts/duranium-update`.
2. Export only kernels / drivers the device coordinator (docs/COORDINATION.md)
   reported as passed on the device; the integration branch for that is
   `integ/gtactive3wifi`, `cand/*` are candidates. `scripts/pmos-export`,
   review `git diff pmos/`, commit, push: the push builds and publishes the
   **dev channels only**, as pre-releases. A fix to the image build or the
   update server alone: `ONLY=duranium-build scripts/pmos-export` (the
   exported aports and kernel stay as they are).
3. When the coordinator confirms that exact export on the device:
   `scripts/pmos-verify "what passed"`, commit, push. `pmos/VERIFIED` names
   the aports and duranium-build trees; only an export named there is built
   for and published to the public release channels. Any later export goes
   to the dev channels only until it is verified again.
4. If a run warns that our duranium-build patches no longer apply upstream:
   rebase `build/wt/duranium` (branch `gtactive3wifi`) on `origin/main`,
   export, push. If upstream pmaports gained one of our aport names, the run
   fails in `ci/prepare`: drop ours. If upstream pmaports moved in a way that
   breaks our packages, the packages job fails and nothing is published
   (the channels keep their current versions); fix the aport, export.

Check a local build like CI does (no sudo; `fsck.erofs --extract` the
`usr` partition first): `USR_TREE=<extracted usr> ci/check-image
build/wt/duranium/mkosi.output/<image id> <version> dev <channel tag>`.

Signing key: `build/secrets/sysupdate-gnupg` on the laptop (never
committed; the revocation certificate is next to it), and the repository
secret `SYSUPDATE_SIGNING_KEY`. Losing it means tablets need an image with a
new key installed by hand, so keep a backup.
