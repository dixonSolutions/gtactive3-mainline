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
- Kernel work happens on your own branch in your own worktree
  (`git -C src/linux worktree add ../../build/wt/<name> -b drv/<name> integ`,
  out of tree `O=build/wt/<name>-out`). Only the coordinator merges into
  `integ` / `gtactive3wifi` after an on-device test.
- **The Duranium image is built by one session at a time** (the shared
  build/wt/duranium worktree, `mkosi.version` and `mkosi.output`). Current
  image owner: "Duranium image: bake in today's live tablet fixes". Others
  hand it package/kernel changes instead of building images themselves.
- The pmaports worktree (build/wt/pmaports-duranium) is shared: commit your
  aport change right away and bump pkgrel; never leave edits uncommitted.

## 3. Reporting

- When you have something to test on the device or to merge, message the
  coordinator with: branch, commits, what to test, how to recover if it fails.
- Proprietary material (firmware/, extracted blobs, decompiled code, keys,
  serials, MACs) is never committed.
