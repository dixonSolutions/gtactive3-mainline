# config.toml reference

`config.toml` is the port's public configuration: every device-specific
value the plumbing needs. Read it with `scripts/config` (never parse it
yourself):

```
scripts/config check            # validate (CI runs it first)
scripts/config get device.id    # one value; lists one per line
scripts/config shell            # CFG_* assignments: eval "$(scripts/config shell)"
scripts/config json             # everything, derived values filled in
scripts/config channels         # "ui flavour tag" per update channel
scripts/config matrix           # the image job matrix (GitHub Actions)
```

In shell, a key `section.key` is `CFG_SECTION_KEY` (lists space separated,
booleans `true`/`false`), e.g. `CFG_DEVICE_ID`, `CFG_UI_PHOSH_TITLE`.
**derived** keys may be left empty; `scripts/config` computes them and
nothing else does. `CONFIG=path` reads another file; in CI
`GITHUB_REPOSITORY` replaces `project.repo`, so a fork publishes to itself.

Everything here is public (published as `device.json`). Secrets are
repository secrets: `SYSUPDATE_SIGNING_KEY` (the image signing key),
optionally `SITE_DISPATCH_TOKEN` (tells the org site to rebuild).

## schema

`1`. Bumped only with a migration note here.

## [project]

| Key | Type | Meaning |
|---|---|---|
| `template` | bool | `true` only in device-template itself: CI checks, builds nothing. `scripts/init-device` sets `false`. |
| `repo` | `owner/name` | the GitHub repo; derives `owner`, `name`, `update.base`, `update.pages` |
| `title` | string | shown on the site and in records |
| `maintainers` | list | GitHub handles |
| `community` | URL | Discord invite (or another chat) |
| `license` | SPDX id | the port's own code |
| `owner`, `name` | derived | from `repo` |

## [device]

| Key | Type | Meaning |
|---|---|---|
| `vendor`, `codename` | `[a-z0-9]+` | postmarketOS naming; `id` = `<vendor>-<codename>` (derived) |
| `name` | string | marketing name without the vendor, e.g. `Galaxy Tab Active5` |
| `models` | list | model numbers, e.g. `["SM-X306B", "SM-X300"]` |
| `form_factor` | `tablet`, `phone`, `other` | |
| `arch` | `aarch64` | the only one supported |
| `soc` | `[a-z0-9]+` | as in the kernel's DT names, e.g. `exynos1380` |
| `soc_name` | string | e.g. `Exynos 1380` |
| `status` | `bring-up`, `testing`, `stable` | shown on the site |
| `id`, `package`, `aport` | derived | `<vendor>-<codename>`, `device-<id>`, its aport path |

## [android]

What the installer checks on stock Android.

| Key | Type | Meaning |
|---|---|---|
| `product_device` | string | `ro.product.device` |
| `firmware_pattern` | regex | Samsung firmware version in file names / `ro.build.PDA` |
| `tested_firmware` | string | the firmware the boot chain was tested on (warning on others) |
| `tested_bootloader_rev` | string | its bootloader revision |
| `fus_model` | string | model for Samsung's firmware server download; empty = not offered |
| `userdata_f2fs_options` | string, ≤ 5 words | `mkfs.f2fs` options that recreate stock userdata for `restore-android`; empty = refused |
| `userdata_f2fs_features` | hex | the stock f2fs superblock feature word, e.g. `0x499`; set together with the options |

## [firmware]

Where the firmware tools keep Samsung's files on a developer PC
([FIRMWARE.md](FIRMWARE.md)). Paths are relative to the repo and must be
gitignored: `scripts/config check` fails on one git would commit.

| Key | Type | Meaning |
|---|---|---|
| `dir` | path | the root, default `firmware` (in `.gitignore`) |
| `snapshot_dir` | derived | `<dir>/snapshot`: `scripts/firmware-snapshot` (the running Android, over adb) |
| `stock_dir` | derived | `<dir>/stock`: `scripts/firmware-extract` (a stock firmware package) |
| `re_dir` | derived | `<dir>/re`: `scripts/firmware-decompile` (REA + Ghidra output) |
| `snapshot_partitions` | list | partitions (by-name) `firmware-snapshot --root` reads, read-only; identity and key partitions (`efs`, `sec_efs`, `persistent`, `param`, ...) are refused |
| `extract_partitions` | list | logical partitions `firmware-extract` takes out of `super.img` |

## [kernel]

| Key | Type | Meaning |
|---|---|---|
| `package` | derived | `linux-postmarketos-<soc>` |
| `aport` | derived | its aport path; the APKBUILD holds `_base`, `_commit` and the patch |

## [images]

| Key | Type | Meaning |
|---|---|---|
| `release` | `edge` or `vYY.MM` | the postmarketOS release followed |
| `uis` | list | postmarketOS UIs to build (`postmarketos-ui-<id>`), one image and channel each |
| `default_ui` | one of `uis` | local builds, installer default |
| `extra_packages` | list | added to every image |
| `dev_packages` | list | added to dev images only (the USB debug layer) |
| `debug_package_regex` | regex | packages a release image must not contain |
| `debug_file_regex` | regex | file name parts a release image must not contain |

## [ui.&lt;id&gt;]

One table per UI in `images.uis`: `title`, `description` (site, records,
installer menus). Missing ones default to the capitalised id.

## [channels]

| Key | Type | Meaning |
|---|---|---|
| `dev` | bool | publish the `-dev` channels (every build) |
| `release` | bool | publish the release channels (device-verified builds only) |
| `keep` | int ≥ 1 | versions per channel (2: the newest and the one before) |

## [upstream]

| Key | Type | Meaning |
|---|---|---|
| `duranium_build` | git URL | postmarketOS's duranium-build |
| `pmaports` | git URL | postmarketOS's pmaports |
| `version_url` | URL | postmarketOS's newest published Duranium version: a change starts a rebuild |

## [update]

| Key | Type | Meaning |
|---|---|---|
| `base` | URL, derived | where devices fetch updates: `https://github.com/<repo>/releases/download/`. Baked into every image: see `.claude/rules/releases.md` before changing it |
| `pages` | URL, derived | the release records: `https://<owner>.github.io/<name>` |
| `public_key` | path | the signing key's public half (`scripts/new-signing-key`) |
| `fingerprint` | 40 hex | its fingerprint (`scripts/new-signing-key` writes it) |
| `channel_file` | path, derived | the file in every image that names its channel: `/usr/lib/<device.id>/update-channel` unless set (a port that shipped another path keeps it) |

## [bootchain]

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | build and publish the boot-chain payload (`bootchain/build.sh`) |
| `tag` | derived | `<device.id>_bootchain` |
| `u_boot_defconfig` | derived | `<codename>_defconfig` in `bootchain/u-boot/configs/` |
| `uniloader_defconfig` | derived | `<codename>_chain_defconfig` in `bootchain/uniLoader/configs/` |
| `dtb` | derived | `exynos/<soc>-<codename>.dtb`, the bring-up Linux's DTB |
| `bringup_config` | path | the bring-up kernel's config fragment (`bootchain/bringup.config`) |
| `f2fs` | bool | mkfs.f2fs in the bring-up initramfs (for `restore-android`) |

## [installer]

| Key | Type | Meaning |
|---|---|---|
| `name` | derived | `<codename>-setup`: state, cache and backup directory names |
| `download_usb` | `vvvv:pppp` | Samsung Download mode USB id |
| `flash_allow` | list | PIT names heimdall may ever write (never a protected one) |
| `boot_partition`, `recovery_partition` | PIT names | |
| `userdata_partition`, `metadata_partition`, `super_partition` | GPT names | as the live environment sees them |
| `main_disk` | string | the main storage's whole disk in the live environment (`sda`, `mmcblk0`); only its partitions are touched |
| `boot_partition_bytes` | int | BOOT's size from the PIT, for the AVB footer; 0 = the installer builds no boot images |
| `sector_size` | 512 or 4096 | logical sector size of the main storage and the image's GPT |
| `backup_readonly` | list | partitions copied read-only into the Android backup, never written back (`efs`, `sec_efs`) |
| `protected` | list, lower case | partitions nothing may ever write. Extend, never shorten |
| `required_firmware` | list | firmware paths (under /lib/firmware) without which the installer stops |
| `firmware_exclude` | list of globs | left out of the firmware bundle |
| `first_boot_extra_mib` | int | space the first boot adds on top of the image (second /usr slot + root minimum) |

## [debug_tool]

The shared USB debug tool ([exynos-linux/usb-debug](https://github.com/exynos-linux/usb-debug)): root console over USB, the host CLI.

| Key | Type | Meaning |
|---|---|---|
| `ask` | bool | `./setup.sh` asks whether to install it, default yes; `false` installs without asking. `--debug-tools` / `--no-debug-tools` decide on the command line |
| `remote` | https URL | where it comes from |
| `version` | tag | pinned release; empty = the main branch |
| `sha256` | 64 hex | of install.sh: setup.sh checks it before running it; empty = no check |
| `setup` | derived | `<remote>/releases/download/<version>/install.sh`, or `<remote>/raw/main/install.sh` without a version. Run as `sh install.sh --yes --device=<device.id> [--version=<v>]` |

## [console]

| Key | Type | Meaning |
|---|---|---|
| `port` | int | the USB debug console (bring-up Linux, dev images) |
| `shell_port` | int | the dev images' root shell |
