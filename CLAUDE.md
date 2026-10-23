# Agent guide: Samsung Galaxy Tab Active3 port (exynos-linux)

postmarketOS Duranium (immutable: systemd, UKI + systemd-boot, A/B
systemd-sysupdate) on the Galaxy Tab Active3 Wi-Fi (SM-T570, Exynos 9810),
with the upstream Linux kernel and our drivers. We maintain the kernel, the
drivers and the device packages; the UIs and the rest of the OS come
unchanged from postmarketOS, rebuilt automatically when postmarketOS
publishes. Repo: exynos-linux/samsung-gtactive3wifi.

Read first: `docs/AGENT-HANDOFF.md` (current state), `docs/COORDINATION.md`
(several sessions, one tablet: the coordinator, the device and build
locks), `docs/STATUS.md` (what works, strictly), `PLAN.md` (what comes
next), `config.toml` (the port's public configuration).

`/status` reports where the port stands, `/continue` picks up the next
priority from it, `/setup` is for starting a new device from
exynos-linux/device-template.

## Where things are (this port predates device-template)

The skills and rules come from exynos-linux/device-template and name its
layout. Here:

| Template | This repo |
|---|---|
| `docs/PLAN.md` | `PLAN.md` |
| `docs/HARDWARE.md` | `HARDWARE.md` |
| the `build-loop` skill | the `gtactive3-build-loop` skill |
| `scripts/build-image` | `cd build/wt/duranium && UI=<ui> sh contrib/samsung-gtactive3wifi/build-image.sh` (the duranium-build worktree with the `pmos/duranium-build` patches; see gtactive3-build-loop) |
| `scripts/kernel-export`, `scripts/aport-checksum` | `scripts/pmos-export` |
| `bootchain/build.sh` | `ci/bootchain/build` |
| the USB console | `scripts/tab*`, `scripts/devd.sh` (exynos-linux/usb-debug replaces them later, its docs/MIGRATION.md) |
| device tests | through the coordinator only (`docs/COORDINATION.md`) |

## Commands

- `scripts/config check` / `get KEY` / `json` / `channels`: the config
  (`ci/check-plumbing` checks no old-home URLs are left)
- `scripts/build.sh`: the bring-up image; `scripts/pmos-export`: kernel and
  aports into `pmos/` for the image CI; `scripts/duranium-update`: A/B
  update of the tablet (device lock, coordinator)
- `bash tests/installer/run.sh`: the installer's offline tests
- `scripts/firmware-snapshot`, `scripts/firmware-extract`,
  `scripts/firmware-decompile`: stock firmware facts and reverse
  engineering, owner's yes first (docs/FIRMWARE.md, the `firmware-re`
  skill); `bash tests/firmware/run.sh`: their offline tests

## Rules

@.claude/rules/device-safety.md
@.claude/rules/config.md
@.claude/rules/builds.md
@.claude/rules/releases.md
@.claude/rules/code.md
@.claude/rules/firmware.md
@.claude/rules/docs.md
