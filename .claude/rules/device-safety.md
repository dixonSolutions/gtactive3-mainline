# Device safety (never break these)

- **Never strand the device.** Every boot test must come back to the USB
  console, to the previous version (boot counting) or to Download mode
  without a human. Before a test, know how it returns and how you will see
  that it failed. If it cannot return on its own, say so and ask first.
- **Never wipe a set-up device's root.** No full reinstall of a device that
  is in use: deliver changes as A/B updates (new /usr + verity into the
  inactive slot, UKI with boot counting, root untouched). A reinstall only
  on the owner's explicit request, with a warning that their data goes.
- **Protected partitions are never written** by anything: `installer.
  protected` in config.toml (EFS, PARAM, PERSISTENT, BOOTLOADER, VBMETA,
  ...). An unsigned vbmeta leaves S-Boot stuck in Download mode; EFS holds
  the device's identity and calibration. Extend the list, never shorten it.
- **Never use Samsung recovery or a factory reset** as part of a flow: it
  can re-arm KnoxGuard. The installer's way back to Android is its own
  (`./setup.sh undo` / `restore-android`).
- Only one session drives the device at a time (flash, reboot, recovery).
  If docs/AGENT-HANDOFF.md names a coordinator, device tests go through it.
- Ask the owner only for physical actions (a key press, a cable, looking at
  the screen), one at a time, saying exactly what to do and what to look
  for. Verify everything else yourself (console, journal, compositor
  screenshots over D-Bus).
- The owner's data, serial number, firmware and stock images never leave
  their PC and never enter git.
