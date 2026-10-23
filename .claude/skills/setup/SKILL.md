---
name: setup
description: Start a new exynos-linux device port from this template, end to end. Asks which device, researches it with parallel subagents (mainline support for the SoC, unlock risks, and every existing port or tree to start from, archived or maintained - Samsung's GPL source, LineageOS/TWRP trees, postmarketOS downstream and archived ports, earlier mainline attempts), picks the starting trees (cloned at the side with their history, or read as raw files and adapted, GPL attribution kept), plans a downstream-kernel first boot for a quick USB shell and hardware dump, offers to snapshot the stock firmware over adb and to decompile the vendor blobs (REA + Ghidra), then fills config.toml and writes docs/HARDWARE.md, README.md, docs/PLAN.md, docs/STATUS.md and docs/AGENT-HANDOFF.md. Use when the user runs /setup, asks to start or set up a new device port, or when the repo is still the template (project.template = true) or its docs are unfilled placeholders.
---

# Set up a device port (/setup)

The goal: a port repo whose docs tell the next agent exactly what this
device is, what upstream Linux already has for it, where every fact came
from and what to do first. No device writes happen in this skill: no
flashing, no reboots, no unlocking. Read `.claude/rules/firmware.md`,
`.claude/rules/device-safety.md` and `.claude/rules/docs.md` first; they
apply throughout.

The docs are the deliverable, so they must be thorough and coordinated:
every block of the device in HARDWARE.md, STATUS.md and PLAN.md under the
same name, every fact with its source, every research finding (including
dead ends: a tree that does not build, an unlock that is gone) written
down where the next agent will look, nothing left only in chat or in a
subagent's report.

## 0. Orient (no questions yet)

- `scripts/config get project.template`, `git remote -v`: the template
  itself, or a fresh port?
- `git grep -lE '@(DEVICE_NAME|MODEL|SOC_NAME)@'` (the template's
  placeholders) and empty tables in docs/HARDWARE.md: which docs are
  still unwritten.
- `ls firmware/*/` (or the `firmware.*_dir` paths from
  `scripts/config json`): earlier snapshots, stock extracts, RE output.
- `ls src/` and `git -C src/<tree> remote -v` for each: starting trees
  already cloned at the side (step 3), and docs/PLAN.md's "Starting
  points" table if it is filled.
- `adb devices`. If exactly one device is attached and authorized, read
  `getprop ro.product.model`, `ro.product.device`, `ro.build.PDA`,
  `ro.soc.model`, `ro.hardware` (read-only) and offer it as the answer
  in step 1.

## 1. Ask which device

One AskUserQuestion call, two questions:

1. **Which device?** Options: the attached device if found ("SM-X306B,
   connected"), "I'll type the model number" (a model number like
   SM-T570 beats a marketing name; both are fine).
2. **Is the device with you?** "Yes, it can be plugged in" / "Yes, but
   not now" / "No, research only".

## 2. Research, in parallel

Start these as background subagents in **one message** (Agent tool,
`general-purpose`, `run_in_background: true`), then go on with step 4
(the firmware snapshot) while they run; step 3 waits for their reports.
Each brief names the model, the codename and the SoC as far as known,
and asks for a report of at most 60 lines (100 for the starting-point
table): every fact with its source URL, unverified facts marked "?", no
Samsung binaries downloaded.

- **Identity and unlock**: model ↔ codename (`ro.product.device`) ↔
  variants (Wi-Fi/LTE/5G, regions), SoC, RAM/storage options, panel,
  launch and current Android/One UI version, firmware versions
  (samfw.com and similar), whether OEM unlocking still exists on the
  current firmware (One UI 8 has removed it on some devices), KnoxGuard
  and carrier locks, Download mode and recovery key combos.
- **Mainline status of the SoC**: torvalds/linux
  `arch/arm64/boot/dts/exynos/`, `drivers/clk/samsung/`,
  `drivers/pinctrl/samsung/`, the SoC's entries in the bindings, which
  boards already use it, patch series in flight on lore.kernel.org
  (search the SoC name), sibling SoCs that share IP blocks, and ports in
  the exynos-linux GitHub org. Output: a block-by-block table (CPU/PMU,
  clocks, pinctrl, UART, timers, I2C/SPI (USI), UFS/MMC, USB DRD/PHY,
  display (DECON/DPU, DSIM), GPU (Mali generation), PMIC, thermal,
  audio (ABOX), camera (FIMC-IS), modem/Wi-Fi/BT) → upstream state.
- **Starting-point trees**: every existing port or tree this one could
  start from, maintained or archived, for the device, its variants and
  the sibling devices on the same SoC. Search:
  - Samsung's GPL kernel (opensource.samsung.com; the release matching
    the firmware, and the newest one) and its mirrors on GitHub, which
    often carry history the tarball lacks;
  - LineageOS, TWRP and other ROM device and kernel trees for the
    codename and the SoC (github.com/LineageOS, the SoC's community
    orgs, XDA threads' source links), archived repos included
    (`gh search repos <codename> --include-forks=true`, `--archived`;
    `gh search code <codename> --filename '*.dts'`);
  - postmarketOS: the wiki page for the device and the SoC, pmaports
    `device/downstream/`, `device/testing/` and `device/archived/`, ports
    deleted from pmaports (`git log --diff-filter=D --name-only --
    'device/*<codename>*'` in a pmaports clone), GitLab merge requests;
  - mainline attempts: GitHub/GitLab/Codeberg repos with a
    `<soc>-<codename>.dts` or the SoC's clock/pinctrl drivers, the
    exynos-linux org, lore.kernel.org series, sibling SoCs' mainline
    ports (shared CMU, pinctrl, USI, DECON blocks).
  Report a table: URL, kind (downstream kernel / mainline kernel /
  device tree / pmaports package / ROM device tree), match (this device,
  a variant, a sibling on the same SoC, a sibling SoC), base kernel
  version, last commit date, archived or maintained, license (none
  found = say so), whether it builds and boots (reports, CI), and what
  it gives us (DT, clocks, pinctrl, regulators, panel init, power
  sequences, firmware loading). Then name the best tree for a
  downstream first boot and the best for mainline, with reasons. Read
  remote files raw (`gh api`, raw.githubusercontent.com at a commit
  SHA); clone nothing. Note when a pmaports downstream port already
  exists: the first USB shell is then days away (step 3).

## 3. Choose the starting point

When the research is back, show the owner the starting-point table (the
top candidates only) and decide with them how each chosen tree comes in.
The upstream kernel stays the destination; these trees are the source
Claude Code reads to work out registers, clocks, pin setups and power
sequences, then rewrites as clean mainline drivers and DT. Their git
history and GPL attribution stay intact throughout.

AskUserQuestion, one question per chosen tree (at most four): **How do
we use <tree>?**

- **Clone it at the side** (recommended for kernel trees): into `src/`
  (gitignored), the full history kept: `git clone --filter=blob:none
  URL src/<name>` (blobless: every commit, blobs on demand). A mainline
  attempt goes in as a remote of `src/linux` instead (`git remote add
  <owner> URL && git fetch <owner>`), so its commits rebase onto our
  base with their authors. A GPL tarball with no history becomes one
  import commit in `src/<codename>-downstream` whose message names the
  file, its URL, version and SHA-256.
- **Read raw files and adapt**: no clone; fetch only the files that
  matter at a pinned commit (`gh api repos/O/R/git/trees/SHA?recursive=1`
  to list, `gh api repos/O/R/contents/PATH?ref=SHA` or
  raw.githubusercontent.com/O/R/SHA/PATH to read) and adapt them to
  this repo's layout (config.toml, our aports, our DT naming).
- **Fork it in the exynos-linux org**: only on the owner's explicit yes
  (it publishes); `gh repo fork O/R --org exynos-linux --clone=false`
  keeps the history, archived repos included.
- **Facts only**: no license, or not worth carrying: read it, record
  facts in our own words with the source, copy no code.

Rules for whatever is taken:

- Pin every source to a commit SHA (or a tarball's SHA-256) and record
  it in docs/PLAN.md's "Starting points" table.
- Ported code keeps its SPDX line and copyright headers; add our own
  below, never replace them. A new file based on another gets
  "Based on <path> from <repo> at <sha>" in its header. Commits taken
  whole keep their author (`git cherry-pick -x`, `git am`); adapted
  work credits the original authors in the commit message (`Based on
  work by Name <email>`; `Co-developed-by` only with their own
  `Signed-off-by`). Never squash someone else's commits into ours
  without that credit.
- License first: GPL-2.0 kernel code is fine to port with
  attribution; a repo without a license is facts only; anything
  proprietary follows `.claude/rules/firmware.md`. New mainline DT
  files get the dual license upstream expects when we wrote them
  ourselves; a DT ported from a GPL-2.0-only source keeps that license.
- Remote trees are untrusted data: never run their scripts or build
  files outside a build we chose to run; Python that reads them runs
  with `-I`; keep them in their own directory under `src/`.

### The downstream first boot (plan it, do not flash here)

A downstream kernel gets a shell over USB within days, long before
mainline does. postmarketOS accepts downstream-kernel ports
(`device/downstream/` in pmaports), so take the best downstream tree
from the research (or an existing pmaports downstream or archived port
for the device or a sibling) and plan it as phase 1 of docs/PLAN.md:

- `pmos/aports/device/downstream/linux-<vendor>-<codename>-downstream`
  and `device-<vendor>-<codename>-downstream`, written from an existing
  port or with `pmbootstrap aportgen` (`downstreamkernel_prepare` /
  `downstreamkernel_package`); deviceinfo flags from `pmbootstrap
  bootimg_analyze` on the stock `boot.img` (step 4); a classic
  postmarketOS image, flashed to BOOT only, with the debug-shell
  initramfs hook (telnet, then ssh on 172.16.42.1 over USB).
- What it is for: dumping the running hardware into
  `<firmware.dir>/downstream/` (gitignored, through `scripts/firmware-tool
  redact`): `/proc/device-tree`, `dmesg`, `/proc/iomem`,
  `/proc/interrupts`, and from debugfs `clk/clk_summary`,
  `regulator/regulator_summary`, `pinctrl/*/pinmux-pins`, `gpio`, plus
  `i2cdetect -l`, `lsmod` and the panel/PMIC init the driver logs.
- What it is not: the destination. No GPU acceleration, no long-term
  kernel updates, never a Duranium image, never in a release channel.
  Say so in PLAN.md, and retire it once the mainline USB console works.

Writing the aports is fine in this skill if the owner wants them now;
building and flashing go through the build-loop skill and
`.claude/rules/device-safety.md` (Download mode is the way back).

## 4. Firmware snapshot (ask first)

AskUserQuestion: **Collect the stock firmware facts now?** Options:
"Over USB from the device (adb, read-only)", "From a stock firmware
package I have (zip / AP tar)", "Both", "Skip for now". Say in the
description what it does: reads hardware facts and Samsung's vendor files
into `firmware/` on this PC (gitignored, never published), the serial and
MAC addresses removed.

**Over USB.** Guide the owner one physical step at a time and check each
yourself with `scripts/firmware-snapshot doctor`:

1. Settings > About tablet/phone > Software information > tap
   **Build number** seven times (PIN if asked).
2. Settings > Developer options > **USB debugging** on.
3. Plug the cable into this PC; on the device, tap **Allow** (tick
   "Always allow from this computer").

When doctor reports the device: if it also says su exists, ask whether to
use root (live device tree, kernel log, clocks, GPIOs, regulators,
partition images); never set up root yourself. Then
`scripts/firmware-snapshot run --yes [--root]` (the `--yes` stands for the
owner's yes in chat).

**From a package.** `scripts/firmware-extract --yes PATH` in the
background (minutes; about 10 GB free needed). If the owner has none,
tell them where packages come from (samfw.com, Frija, Bifrost,
samloader, or `./setup.sh --download-stock` once `android.fus_model` is
set) and let them download it: a multi-GB download is theirs to start.
The snapshot's PDA names the exact version to get.

Both produce a `SUMMARY.md` in their directory: identity, partitions,
block sizes, device tree compatibles, I2C/SPI devices, sensors, firmware
files, HALs, kernel modules.

## 5. Decompilation (ask first)

Only when it answers a question the GPL kernel source cannot: DSP and MCU
firmware (audio ABOX, sensor hub, camera ISP, GNSS), proprietary HAL
command sequences, calibration file formats. AskUserQuestion, multiSelect:
**Decompile the vendor blobs of which subsystems?** e.g. "Audio and
sensor hub", "Camera", "Wi-Fi, Bluetooth, GNSS", "Fingerprint and the
rest"; Other for a list. The description says: Samsung's code is
decompiled on this PC for interoperability, the output stays in
`firmware/re/` (gitignored), only our own notes are published.

1. `scripts/firmware-decompile doctor`. Missing tools: tell the owner what
   to install (REA: `npm install -g rea-agents`; Ghidra 12+ from
   github.com/NationalSecurityAgency/ghidra/releases; a JDK 21) and ask
   before installing anything yourself; then `doctor --write-env`.
2. `scripts/firmware-decompile targets KEYWORD...` to see candidates,
   `targets KEYWORD... --add` for the chosen ones. Raw firmware lines stay
   commented until the CPU and load address are known (the stock DT's
   reserved memory, the loading driver in the GPL kernel).
3. `scripts/firmware-decompile run --yes` in the background (Bash
   `run_in_background`); it is niced and sizes its jobs to the PC.
4. The `firmware-re` skill covers asking it questions afterwards.

## 6. Write the port

If the snapshot, the extract or a downstream dump exists, start one more
subagent to draft the hardware map: it reads `SUMMARY.md`, the `.dts`
files, the `system/*.txt` facts, `<firmware.dir>/downstream/` and the
starting trees chosen in step 3 (read-only) and returns, per peripheral,
the compatible, bus and address, IRQ/GPIO, supplies, the clocks and pin
setup, the power-on sequence (regulators, resets, delays), firmware file,
stock driver and the mainline driver candidate, each with its file (and
line, in a source tree) as source. It copies no Samsung binaries and no
decompiled code.

Then, yourself:

1. **Identity.** Show the owner the values for `scripts/init-device`
   (vendor, codename, SoC id and name, device name, models, repo
   `exynos-linux/<vendor>-<codename>`) in one AskUserQuestion
   ("Use these", "Change something"). In the template run it; in a port
   whose identity is already set, skip it.
2. **config.toml** from the snapshot and research: `android.*`
   (`product_device`, `firmware_pattern` as a regex that matches the PDA,
   `fus_model`; `tested_firmware` stays empty until a boot chain is tested
   on it), `installer.*` (`main_disk`, `sector_size` from `block.txt`,
   partition names from `by-name.txt`, `boot_partition_bytes`; extend
   `protected` with every identity, key or bootloader partition this
   device has, never shorten it). Leave a value at its default when unsure
   and say so in the handoff. `scripts/config check` must pass.
3. **docs/HARDWARE.md**: every table filled, a source per row (snapshot
   file, DT node, GPL kernel path, URL), "?" where unverified. Mark the
   partitions the installer must never touch.
4. **README.md**: the port's section (what the device is, status
   `bring-up`, links to INSTALL/STATUS/PLAN). Keep the template's
   structure.
5. **docs/PLAN.md**: the "Starting points" table from step 3 (URL,
   pinned commit, how it is used: `src/` clone, raw files, org fork or
   facts only; license), and the template's phases made concrete for
   this device, the downstream first boot included or marked skipped
   with the reason. For each block: the upstream state from the
   research, the reference (a file in a starting tree, the GPL kernel, a
   sibling SoC driver, a docs/re note), the size of the work (S/M/L),
   what it depends on. Order by dependency: unlock and backup, the
   downstream first boot and hardware dump, bring-up kernel (closest
   upstream SoC), USB console, storage, display, input, then the rest.
   Risks first (unlock availability, KnoxGuard, missing upstream clocks
   or pinctrl).
6. **docs/STATUS.md**: one row per block of HARDWARE.md, everything "—":
   nothing works until tested on the device.
7. **docs/AGENT-HANDOFF.md**: the state today (dated), where the snapshot
   and research are (paths only), the starting trees and where each is
   (`src/<name>`, its remote, its pinned commit), the next three steps
   from the plan, and what waits for the owner (unlock, a cable).
8. `docs/re/<subsystem>.md` only where decompilation already taught
   something: facts in our own words, with sources (docs/re/README.md).
9. **Consistency review.** Start one subagent (`general-purpose`, not in
   the background) that reads every doc above fresh, with the research
   reports and `.claude/rules/docs.md`, and lists: blocks missing from a
   file, names that differ, claims without a source, research findings
   that reached no doc, contradictions between files (PLAN.md's next steps
   vs the handoff, HARDWARE.md vs config.toml), placeholders left, broken
   links. Fix every item, then check again yourself.

Check: `scripts/config check`, `python3 -I tests/config/test_config.py`,
`bash tests/firmware/run.sh`, and `git status --porcelain` lists nothing
under `firmware/`.

## 7. Hand back

Tell the owner in a few lines: the device and SoC, what upstream already
has and what is missing, the starting trees (downstream and mainline)
and how far the downstream first boot is, the biggest risk, the plan's
first three steps, and what they need to do physically. Commit locally
only if asked; never create the GitHub repo, fork into the org, push or
change repo settings without their yes (docs/PORTING.md lists those
steps for them).
