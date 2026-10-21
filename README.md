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
| HSI2C (USI) | ⚠️ times out, being worked on |
| Clocks, UFS, PMIC, thermal, display, touch, pen, Wi-Fi, audio | ⏳ |

## Layout

- `patches/linux`, `patches/uniLoader`: our commits as patch series (base in `BASE`)
- `configs/`: kernel config fragment and initramfs list template
- `initramfs/init.c`: bring-up init (kernel nolibc): USB gadget, debug console
- `scripts/`: build, package, flash loop (`devd.sh`), console client (`tab`)
- `pmos/`: postmarketOS device package (work in progress)
- `HARDWARE.md`: hardware map from the stock firmware, `PLAN.md`: roadmap

## Development loop

```
scripts/build.sh            # init + kernel + modules → build/images/boot-mainline.img
scripts/devd.sh &           # flashes BOOT whenever the tablet is in Download mode
scripts/tab reboot download # tablet reboots, gets flashed, boots, USB is back in ~35 s
scripts/tab dmesg           # debug console over IPv6 link-local (fe80::57:aff:fe00:1)
```

Stock firmware, keys and decrypted images are never committed.
