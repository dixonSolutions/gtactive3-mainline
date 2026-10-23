---
name: firmware-re
description: Get facts out of the device's stock Android firmware - snapshot the running Android over adb, unpack a stock firmware package, decompile vendor binaries and DSP/MCU firmware with REA + Ghidra - and write what is learnt to docs/re/ under the licensing rules. Use when a driver needs something only the vendor blobs know (firmware load addresses, HAL ioctl or register sequences, mailbox message formats, calibration file layouts), when docs/HARDWARE.md needs data from the device, or when the user asks to snapshot, dump, extract or decompile firmware.
---

# Firmware facts and reverse engineering

Rules: `.claude/rules/firmware.md` (Samsung's files never leave the PC,
ask the owner first, read-only, identity partitions never read, publish
only our own words). Details: `docs/FIRMWARE.md`. Paths come from
`config.toml` `[firmware]` (`scripts/config get firmware.re_dir`).

## Which source answers the question

| Question | Look in |
|---|---|
| Which chip, bus, address, IRQ, GPIO, regulator | stock DT: `<stock_dir>/<ver>/dt/*.dts`, or the live one `<snapshot_dir>/<dev>/system/device-tree.dts` (`--root`) |
| What the stock driver does | Samsung's GPL kernel source (not a blob: port from it with attribution) |
| Which firmware file a driver loads | the GPL source, then `SUMMARY.md` "Firmware files" |
| Clocks, pin muxing, voltages at runtime | snapshot `--root`: `clk-summary.txt`, `pinmux.txt`, `regulator-summary.txt` |
| How userspace drives the hardware (HAL ioctls, sysfs writes, mixer paths) | decompile the HAL; also `vendor/etc` configs in the tree |
| How a DSP/MCU firmware is laid out or talks to Linux | decompile the firmware (raw: needs CPU + load address) |

Prefer the cheapest source: text files and the DT before Ghidra.

## Getting the files (ask first)

- Device attached: `scripts/firmware-snapshot doctor`, then, after the
  owner's yes, `scripts/firmware-snapshot run --yes` (`--root` only if
  they have root and agree; `--no-tree` for facts only). Physical steps for
  the owner: Developer options (tap Build number seven times), USB
  debugging on, cable in, Allow on the device.
- Stock package: `scripts/firmware-extract --yes PACKAGE` (zip or
  AP_*.tar.md5), in the background.

## Decompiling (ask first)

```
scripts/firmware-decompile doctor                   # REA, Ghidra, JDK 21 (doctor --write-env)
scripts/firmware-decompile targets audio            # candidates
scripts/firmware-decompile targets audio --add      # into <re_dir>/targets.txt
scripts/firmware-decompile run --yes [NAME...]      # background; INDEX.md when done
scripts/firmware-decompile search NAME 'regex'      # function names ("strings" as 3rd arg: strings)
scripts/firmware-decompile fn NAME func_or_0xaddr   # one function -> decomp/NAME/func.c
```

- Find the binary first: `grep -rl --include='*.so' 'string from dmesg'
  <tree>`; the VINTF manifest and init `.rc` files name the services.
- Raw firmware (no ELF header): add the line to `targets.txt` by hand with
  `--target-format raw-binary --architecture arm|arm64 --entry-point 0x...`.
  The load address is in the stock DT (reserved-memory, the device's
  `reg`) or in the loading driver. Thumb-only Cortex-M images may decode
  better wrapped in a minimal ELF with the right entry point.
- Strings and function names (`search`) answer most questions before any
  decompiled function is read. Each Ghidra start takes ~30 s: batch
  lookups.
- Big targets: `GHIDRA_MAXMEM` (re-env.sh), and `--jobs 1`.

## Writing it down

`docs/re/<subsystem>.md` (format in `docs/re/README.md`): what the
hardware or firmware expects, in our own words, each fact with its source
("audio.primary.<soc>.so, set_route() @0x4a10"). Register offsets,
command IDs, message layouts, sequences and timing are facts; decompiled
code, pseudo-code that mirrors it line by line and copied tables are not.
The driver is then written from that note, the GPL source and public
documentation. Link the note from docs/HARDWARE.md and docs/AGENT-HANDOFF.md.

Before finishing: `git status --porcelain` lists nothing under the
firmware directories.
