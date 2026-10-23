# Firmware and reverse engineering (never break these)

- **Samsung's files stay on the owner's PC.** Stock packages, device
  snapshots, unpacked partitions and everything REA/Ghidra produces live
  under `firmware.dir` (config.toml, gitignored) and nowhere else: never in
  git, CI, releases, issues, pull requests, artifacts or pastes. Before a
  commit, `git status --porcelain` shows nothing from there.
- **Ask the owner first**, in chat, before a snapshot (it reads their
  device) and before a decompile run (proprietary code, an hour of CPU).
  One yes covers that one run; the scripts take `--yes` only after it.
- **Snapshots are read-only.** No writes to the device, no installs, no
  rooting, Magisk or bootloader unlock done by an agent. `--root` only when
  the owner already has root and agrees to its use.
- **Identity partitions are never read**: efs, sec_efs, persistent, param
  and the rest of `NEVER_READ` (scripts/config, scripts/firmware-snapshot).
  Extend that list, never shorten it.
- **Private data is removed**: serial number, MAC addresses, IMEIs and
  account data never leave the PC. The scripts redact them; anything
  collected by hand goes through `scripts/firmware-tool redact` first.
- **Decompile for interoperability only, publish only our own words.**
  `docs/re/` holds facts about interfaces and behaviour (register offsets,
  message formats, command sequences, load addresses, file formats), each
  with its source (binary + function or address). Never decompiled code,
  never more than identifiers and constants copied, never a translated
  function. Drivers are written from `docs/re/`, public documentation and
  Samsung's GPL kernel source.
- Samsung's GPL kernel source is GPL, not a blob: port from it with
  attribution like any GPL code.
- Firmware files the drivers load reach the device from the owner's own
  stock firmware (the installer), never from our releases.
