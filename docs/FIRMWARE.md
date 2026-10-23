# Stock firmware: snapshots, extraction, reverse engineering

A port needs facts only the stock firmware has: the device tree, the
partition table, which chips sit on which bus, which firmware files the
drivers load, how the vendor HALs and DSP firmware talk to the hardware.
Three scripts collect them on a developer PC. Coding agents drive them
through the `setup` and `firmware-re` skills, and ask the owner
before each run.

| Script | Reads | Writes (config.toml `[firmware]`) |
|---|---|---|
| `scripts/firmware-snapshot` | the device's running stock Android, over adb, read-only | `snapshot_dir/<model>_<version>/` |
| `scripts/firmware-extract` | a stock firmware package (zip or `AP_*.tar.md5`) | `stock_dir/<version>/` |
| `scripts/firmware-decompile` | binaries from those two, chosen in `targets.txt` | `re_dir/` |

All three refuse to write into a directory git would commit, and
`scripts/config check` refuses such a configuration.

## What is private, and what is published

Everything these scripts write is Samsung's code or data, or identifies
the owner's device. It stays on the PC: the directories are gitignored
and never enter git, CI, releases, issues or chat logs.

- The serial number, MAC addresses and IMEIs are removed from everything
  the snapshot writes (`scripts/firmware-tool redact`).
- Identity and key partitions (`efs`, `sec_efs`, `persistent`, `param`,
  ...) are never read, even with root and even if the configuration
  names them.
- Decompilation is for interoperability: making the hardware work with
  Linux. What we publish is our own description of interfaces and
  behaviour in [re/](re/README.md), never decompiled code. This is the
  kind of use the EU Software Directive (2009/24/EC, art. 6) and the US
  DMCA's interoperability exemption (17 U.S.C. 1201(f)) describe. It is
  not legal advice: when in doubt, publish less.
- Samsung's GPL kernel source is a different case: it is GPL, and we
  port from it with attribution.

## Snapshot: the running stock Android

On the device: Settings > About > Software information > tap **Build
number** seven times; Settings > Developer options > **USB debugging** on;
connect it; tap **Allow** on its screen.

```
scripts/firmware-snapshot doctor       # adb, the device, root: what a run gets
scripts/firmware-snapshot run          # asks, then reads (--yes: already asked)
scripts/firmware-snapshot run --root   # + live DT, dmesg, clocks, pins, regulators, partition images
```

Without root: `getprop`, `/proc` (cpuinfo, partitions, interrupts, ...),
sysfs device lists (I2C, SPI, platform devices, power supplies, thermal
zones, regulators), `dumpsys` for sensors, cameras, display, battery and
audio routing, the partition names, the storage's block size and the
`vendor`, `odm` and `vendor_dlkm` trees with `/system/etc` (the slowest
part; `--no-tree` skips it). With root (Magisk, already set up by the
owner) also: the live device tree (`/sys/firmware/fdt`, decoded to
`.dts`), `dmesg`, debugfs clock/GPIO/pinmux/regulator summaries, the
kernel config and the images of `firmware.snapshot_partitions` (boot,
dtbo, vendor_boot, ...: never identity partitions), with their DTBs.

```
<snapshot_dir>/SM-X306B_X306BXXU1AXB5/
  SUMMARY.md        what is in here: identity, partitions, DT compatibles, buses, firmware, HALs
  props.txt         getprop, redacted
  system/*.txt      /proc, sysfs, dumpsys facts (device-tree.dts, kernel.config with --root)
  tree/             vendor, odm, vendor_dlkm, system/etc
  partitions/       --root: boot.img, dtbo.img, ... + SHA256SUMS
  dt/               --root: the DTBs of those images, as .dtb and .dts
  errors.txt        what could not be read (most of it needs --root)
```

## Extract: a stock firmware package

```
scripts/firmware-extract SM-X306B_..._fac.zip       # or AP_*.tar.md5, or a directory with it
scripts/firmware-extract --parts vendor,odm,system --keep PACKAGE
```

Packages come decrypted from SamFW, Frija, Bifrost or samloader, or from
`./setup.sh --download-stock`. The snapshot's `ro.build.PDA` names the
exact version on the device. Needs `lz4`, `unzip`, `debugfs` (e2fsprogs),
`fsck.erofs` (erofs-utils) for EROFS partitions and `dtc` for `.dts`
files; about 10 GB free while it runs.

```
<stock_dir>/X306BXXU1AXB5/
  SUMMARY.md  SOURCE.txt
  images/     boot, dtbo, vendor_boot, vbmeta, ... (.img)
  fs/         vendor, odm, vendor_dlkm trees (firmware.extract_partitions)
  dt/         every DTB/DTBO as .dtb + .dts, the stock kernel, kernel.config, boot-info.txt
```

## Decompile: REA + Ghidra

[REA](https://www.npmjs.com/package/rea-agents) (MIT) drives
[Ghidra](https://github.com/NationalSecurityAgency/ghidra) (Apache-2.0)
headless; neither ships with the port. Install REA
(`npm install -g rea-agents`), Ghidra 12 or newer and a JDK 21, then:

```
scripts/firmware-decompile doctor --write-env     # finds them, writes <dir>/re-env.sh (local)
scripts/firmware-decompile targets                # candidates from every snapshot / extract
scripts/firmware-decompile targets audio --add    # chosen ones into <re_dir>/targets.txt
scripts/firmware-decompile run                    # analyze all of targets.txt (asks first)
scripts/firmware-decompile search NAME 'regex'    # function names (or strings)
scripts/firmware-decompile fn NAME function       # one function as C, into decomp/
```

`targets.txt` has one `name|path|extra REA arguments` line per binary.
ELF files (HALs, daemons, ELF firmware) need nothing extra. Raw firmware
needs its CPU and load address:
`fw-dsp|firmware/stock/.../dsp.bin|--target-format raw-binary --architecture arm --entry-point 0x0`.
The address comes from the stock DT (reserved memory) or from the driver
that loads the file.

A run is niced, takes a lock (`build/firmware-decompile.lock`) and runs
one Ghidra per 4 GB of RAM and 4 CPU threads, at most three. Large
binaries may need `GHIDRA_MAXMEM=8G` in `re-env.sh`.

```
<re_dir>/
  targets.txt       what to analyze
  INDEX.md          status per target, functions decompiled so far
  analysis/         REA evidence JSON per target
  snapshots/        Ghidra analysis snapshots (fast follow-up queries)
  decomp/NAME/*.c   decompiled functions
```

## Where the facts go

- `docs/HARDWARE.md`: the hardware map, a source for every row.
- `docs/re/<subsystem>.md`: what reverse engineering taught, in our own
  words ([re/README.md](re/README.md)).
- `config.toml`: partition names, block size, firmware version pattern.
- The firmware files the drivers need: `installer.required_firmware`. The
  installer copies them from the owner's own firmware onto the device;
  our releases never carry them.
