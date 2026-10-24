# Working on the SM-T570 with several sessions at once

One tablet, one laptop, several Claude sessions. These rules keep them from
breaking each other's work or the user's data. Coordinator: the session
"PostmarketOS duranium bootloader unlock" (message it before anything in
section 1).

## 1. The tablet (one device, the user's daily system)

- **Disruptive actions need the device lock and a heads-up to the
  coordinator:** reboot, Download mode, flashing, `scripts/duranium-boot`,
  `scripts/duranium-update`, rmmod/insmod of a loaded driver, register pokes
  that change hardware state (display, PMIC, clocks, GPIOs), killing
  system services. Take the lock for the whole action:
  `flock build/device.lock <command>` (or `exec 9>build/device.lock; flock 9`
  in a script). Read-only console use (`cat`, `dmesg`, `peek`) only needs the
  usual `build/tab.lock` that scripts/tab already takes.
- **Never full-reinstall Duranium** (`scripts/duranium-boot --wipe-user-data`,
  install-to-userdata.sh): it erases the user's encrypted root. Deliver
  images only with `scripts/duranium-update` (A/B slots, hash-checked,
  boot-counted; the booted version stays as fallback).
- The user types the disk passphrase on every boot; a reboot interrupts them.
  Batch reboots, tell the user before one.
- Exactly one `scripts/devd.sh` runs (the coordinator's). Do not start another.
- Tell the user only to do physical things (passphrase, buttons, looking at
  the screen).

## 2. Builds (one laptop that overheats)

- All kernel / package / image builds hold `build/kbuild.lock` (scripts
  already do). One heavy build at a time; keep `scripts/thermal-guard` running.
- **Memory (16 GB RAM, the laptop OOM-killed the desktop app on
  2026-10-22):** every heavy job holds `build/kbuild.lock`, not only builds:
  Ghidra/`rea` analysis and decompile batches (the JVM takes up to 4 GB),
  mkosi, podman builds, big `make` runs. Use `-j8` at most for make. Do not
  leave JVMs, dev servers or other large processes running when idle.
  zram is RAM-backed and is not a safety net; a 16 GB disk swapfile
  (/var/swap/swapfile, priority 10) and vm.min_free_kbytes=131072 are.
- QEMU test VMs (tests/virt) hold `build/vm.lock` instead (one VM at a time,
  ≤ 3 GiB, nice 10, start only with ≥ 4 GiB available, powered off below 1.5 GiB).
- Kernel work happens on your own branch in your own worktree
  (`git -C src/linux worktree add ../../build/wt/<name> -b drv/<name> integ`,
  out of tree `O=build/wt/<name>-out`). Only the coordinator merges into
  `integ` / `gtactive3wifi` after an on-device test.
- **The Duranium image is built by one session at a time** (the shared
  build/wt/duranium worktree, `mkosi.version` and `mkosi.output`). Current
  image owner (since 2026-10-22 evening): "Camera firmware drivers and OS
  setup", which also runs the user's test campaign. Others
  hand it package/kernel changes instead of building images themselves.
  2026-10-24 10:59: "Suspend, updates, cores" built one local Phosh image
  there with the coordinator's OK (26102307~test1 = kernel r23 + device
  r46, `mkosi.version` left at 26102307~test1; the 26102219~test4 outputs
  were removed) and handed the worktree back.
- The pmaports worktree (build/wt/pmaports-duranium) is shared: commit your
  aport change right away and bump pkgrel; never leave edits uncommitted.
- The main checkout is shared too: when a push is rejected, `git pull
  --rebase`, never `git reset` to origin/main (a reset dropped another
  session's unpushed commits on 2026-10-24).

## 3. Reporting

- When you have something to test on the device or to merge, message the
  coordinator with: branch, commits, what to test, how to recover if it fails.
- Proprietary material (firmware/, extracted blobs, decompiled code, keys,
  serials, MACs) is never committed.
