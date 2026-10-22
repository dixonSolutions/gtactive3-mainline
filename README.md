# Mainline Linux / postmarketOS on the Samsung Galaxy Tab Active3 (SM-T570)

Bring-up of mainline Linux on the Wi-Fi Galaxy Tab Active3 (`gtactive3wifi`,
Exynos 9810), with the goal of running postmarketOS Duranium.

## Status

| Area | State |
|---|---|
| Boot chain (S-Boot → uniLoader → Linux 7.3) | ✅ boots from BOOT |
| Framebuffer console (simplefb @ 0xca000000) | ✅ |
| GPIO keys (7) | ✅ |
| Memory (3.6 GiB) | ✅ |
| Little cores (4× A55) | ✅ |
| Big cores (4× Mongoose M3) | ❌ don't come online yet |
| USB 2.0 device mode (DWC3 + 9810 PHY), NCM networking | ✅ |
| Reboot into Download mode from Linux (PMU INFORM3) | ✅ |
| MAX77705 USB data switch | ✅ (bit-banged I2C for now) |
| UFS storage (64 GB Micron, HS-G3 x2, all 5 LUNs, stock GPT) | ✅ |
| HSI2C (USI) | ⚠️ times out, being worked on |
| Clocks, PMIC, thermal, display, touch, pen, Wi-Fi, audio | ⏳ |

## Layout

- `patches/linux`, `patches/uniLoader`: our commits as patch series (base in `BASE`)
- `configs/`: kernel config fragment and initramfs list template
- `initramfs/init.c`: bring-up init (kernel nolibc): USB gadget, debug console
- `scripts/`: build, package, flash loop (`devd.sh`), console client (`tab`)
- `pmos/`: what we maintain for postmarketOS Duranium (aports incl. the kernel,
  duranium-build patches, the image signing key), exported by `scripts/pmos-export`
- `ci/`, `.github/workflows/images.yml`: builds the images when postmarketOS
  publishes or `pmos/` changes, publishes them as GitHub releases, which is where
  the tablets update from: see [docs/RELEASES.md](docs/RELEASES.md)
- `HARDWARE.md`: hardware map from the stock firmware, `PLAN.md`: roadmap

## Install

On a Linux PC, with the tablet on USB:

```
./setup.sh --stock-ap AP_<your firmware>.tar.md5
```

It first only puts our Linux into BOOT (Android stays as it is, `./setup.sh
undo` brings it back), then offers a full Android backup and the install.
Step by step, requirements and the way back to Android:
[docs/INSTALL.md](docs/INSTALL.md).

## Downloads and updates

Images (Phosh, GNOME; release and development channels) are in the
[releases](https://github.com/dixonSolutions/gtactive3-mainline/releases), rebuilt
automatically on top of each postmarketOS publish. Installed tablets update
from there with `updatectl update` (A/B, signed, automatic rollback). Vendor
firmware is not included. [docs/RELEASES.md](docs/RELEASES.md) explains it all.

## Development loop

```
scripts/build.sh            # init + kernel + modules → build/images/boot-mainline.img
scripts/devd.sh &           # flashes BOOT whenever the tablet is in Download mode
scripts/tab reboot download # tablet reboots, gets flashed, boots, USB is back in ~35 s
scripts/tab dmesg           # debug console over IPv6 link-local (fe80::57:aff:fe00:1)
```

Stock firmware, keys and decrypted images are never committed.
