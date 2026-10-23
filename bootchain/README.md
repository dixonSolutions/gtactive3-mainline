# bootchain: the BOOT partition payload (optional, per device)

Samsung's S-Boot loads an Android boot image from BOOT. The ports put a
small chain there instead:

    S-Boot -> loader (uniLoader) -> U-Boot -> systemd-boot -> Duranium UKI
                                  \-> bring-up Linux (fallback, live env)

- `build.sh`: builds the payload (see its header); `ci/bootchain/build`
  runs it and checks the result
- `u-boot/`, `uniLoader/`: the vendored sources, with every SoC and board
  of the exynos-linux ports. A fix here reaches every device repo through
  GitHub's Sync fork. The board is picked by `bootchain.u_boot_defconfig`,
  `uniloader_defconfig` and `dtb` in config.toml
- `bringup.config`, `initramfs.list.in`: the bring-up Linux (kernel config
  fragment, initramfs file list)
- the payload is published as the `bootchain.tag` release, signed like the
  images; the installer packs it with the owner's stock DTB and header
  values into their BOOT image (`scripts/installer/lib/bootimg.sh`)

Seeded from the first port: U-Boot = chiffathefox/u-boot dec4927 + 18
patches, uniLoader = ivoszbg/uniLoader a459fb4 + 9 patches (Exynos 9810
board, watchdog, chainload fallback, EFI boot from userdata). A new board:
its defconfig and DT in both trees, committed to device-template first.

Set `bootchain.enabled = true` in config.toml once `build.sh` works for
the device (it also needs `initramfs/init.c`, see initramfs/README.md). No
Samsung file ever goes into the payload.
