---
name: test-new-remote-and-drivers
description: Long-horizon, mostly autonomous on-device test campaign for the SM-T570 Duranium port - new kernel/drivers (suspend, cameras, PM, ...), the Phosh and GNOME images, the GitHub update remote (A/B sysupdate, boot counting, ~test overrides) and the setup.sh installer suite. Tests, logs, diagnoses, rebuilds and re-tests until everything passes, asking the user only for physical actions (with a loud notification). Use when the user runs /test-new-remote-and-drivers or asks to test the new remote, releases, drivers or images on the tablet.
---

# /test-new-remote-and-drivers

You are a long-horizon test agent for `~/Projects/gtactive3-mainline`. Goal:
every item in `docs/TESTPLAN.md` passes on the real tablet, with evidence,
and the release gate (`scripts/pmos-verify`) is passed for the verified
export. Keep going: test → log → diagnose → fix → rebuild → re-test. Pivot
when something is blocked; never stop at the first failure.

## 0. Before anything

1. Read `docs/AGENT-HANDOFF.md`, `docs/COORDINATION.md`, `docs/STATUS.md`,
   `docs/TESTPLAN.md` (the test cases, with commands and expected results),
   `docs/RELEASES.md`, `docs/INSTALL.md`. Memory rules apply (never strand
   the tablet, never full-reinstall the user's Duranium, verify the GUI
   yourself, no Plasma, both Phosh and GNOME).
2. Device ownership: for the whole campaign you need the device. Ask the
   coordinator session ("PostmarketOS duranium bootloader unlock") for the
   device, or if the user started you as the lead, update the "Coordinator"
   line in docs/COORDINATION.md. Hold `build/device.lock` for every
   disruptive action (reboot, flash, update, module swap, register pokes).
3. Start a run log: `R=logs/test-runs/$(date +%Y%m%d-%H%M)`; `mkdir -p $R`.
   Every test writes `$R/<id>.log` (commands + output) and a line to
   `$R/results.tsv` (`id<TAB>PASS|FAIL|BLOCKED|SKIP<TAB>evidence path<TAB>note`).
   Screenshots go to `$R/shots/`. Look at every screenshot you take (Read the
   PNG) before you call a GUI test passed.

## 1. Asking the user for help (only for physical things)

Only ask for what software cannot do: pressing keys, touching the screen,
plugging/unplugging cables, typing the disk passphrase, looking or
listening (speaker, camera image on screen, LEDs, vibration).

- Batch requests: collect everything that needs hands for the next ~15 min
  into ONE request with numbered steps. At most one interruption per ~20 min
  unless blocked.
- Always both:
  1. `scripts/notify-user --wait 900 "<short title>" "<numbered steps>"`
     (critical desktop notification, chime at full volume, the request
     spoken, volume restored; prints `done` when the user clicks Done,
     `timeout` after the wait). Use `--info` for "FYI, done" messages.
  2. The `PushNotification` tool with the same one-line request (reaches the
     user's phone).
  Also write the request plainly in your reply.
- Say exactly what they'll see and how long it takes ("Hold Power for 1 s;
  the screen turns on within 3 s"). Never ask them to judge something you
  can measure (dmesg, sysfs, screenshots, audio loopback, frame captures).
- While waiting, do laptop-side work (builds, log analysis); detect the
  result yourself (evdev events, sysfs, console) instead of relying on
  "done".

## 2. Unattended reboots: passphrase and login

The user stores test secrets in ClaudeKeys (list them with the claudekeys
tool; e.g. DISK_ENCRYPT_AND_USER_PASSWD for the disk). Pass one only as
`GTA3_PASSWORD=<its ClaudeKeys placeholder>` on a command line of its own
(the ClaudeKeys guard refuses commands that also echo/cat/tee):
- `scripts/tab-unlock` answers the initrd's disk passphrase prompt over the
  console (waits for it, reports accepted/rejected).
- `scripts/tab-login [USER]` logs in at GDM or phrog (virtual keyboard).
- `scripts/tab-checkpw` checks a secret against the LUKS root and the
  account without using it (tells a wrong secret from a broken login).
If no working secret exists for a step, batch it into the next request to
the user instead of guessing.

## 2b. Know the tablet's state

`./setup.sh status` (installer suite) reports: nothing on USB / Android
(adb) / Download mode (04e8:685d) / bring-up Linux (console TCP 23,
`cat /proc/version` contains borysthebear) / Duranium (console 23 and
ssh 22 with `build/secrets/duranium-dev-ed25519`, `/usr/lib/os-release`
IMAGE_VERSION + VARIANT_ID). `scripts/tab`, `tab-get`, `tab-put`,
`tab-shot` work in the bring-up and in dev Duranium images.
`scripts/devd.sh` must run exactly once (the coordinator's); it flashes
`build/images/boot-mainline.img` whenever the tablet is in Download mode -
keep that = `boot-good.img` unless a test needs otherwise.

Recovery playbook (try in order, tell the user before any reboot):
- Hung Duranium with console: `scripts/tab "poke 0x8ff1ff04c 4"` then
  `scripts/tab "write /proc/sysrq-trigger b"` → fallback Linux next boot.
- New version does not boot: boot counting returns to the previous entry
  after two failed tries (the user may need to type the passphrase each
  time); check `bootctl list` afterwards and mark the result.
- No USB at all: ask the user for Power + Volume Down 10 s (force restart),
  then Volume Up + Volume Down while plugging USB = Download mode; devd
  flashes boot-mainline.img.
- pstore after a crash: `/sys/fs/pstore/console-ramoops-0`; U-Boot log:
  `scripts/tab ulog`.

## 3. The campaign (order matters: cheap and safe first)

A. **Laptop-side gates** (no tablet): `tests/installer/run.sh`,
   `tests/virt/run.sh` on the newest local Phosh and GNOME images and on the
   newest `-dev` release (Phosh must reach phosh/phoc running with a
   screenshot that shows the lock screen or home screen), CI status
   (`gh run list -w images.yml -L 5`), releases.json on GitHub Pages lists
   the current versions with valid signatures. Fix anything red first.
B. **Images**: build what the TESTPLAN lists as "under test" (kernel
   candidate + device package; see the gtactive3-build-loop skill for the
   fast loop and caching). Phosh is the one under test, GNOME stays the
   default/fallback boot entry.
C. **Deliver** to the tablet only with `scripts/duranium-update` (A/B,
   boot counting) or `./setup.sh update --test` (same, `~test` version that
   the next remote update replaces). Never install-to-userdata on the
   user's tablet. Version scheme: CI publishes `YYMMDDNN`; a local test
   build must be BUILT as `<newest published + 1>~test<N>`
   (`build/wt/duranium/mkosi.version`), never a plain number (it would
   block CI updates) and never renamed after the build. Published release
   files: `zstd -d` the usr/verity `.raw.zst` next to the `.efi`, then
   `OUT=<dir> UI=<ui> EXTENSIONS="" scripts/duranium-update <ver>`.
   Before the first CI image on a tablet: `scripts/firmware-to-tablet`.
D. **Boot + baseline**: `scripts/duranium-check $R/shots/boot.png`, failed
   units, journal errors, Phosh running, screenshot looked at.
E. **Drivers**, one block at a time, in the TESTPLAN order (each case says
   whether it needs the user): PM/runtime PM sanity → suspend (RTC wake
   first, power-key wake second; never enable suspend-on-power-key until
   the wake path is proven) → cameras (staged power-up in the bring-up,
   then libcamera/Snapshot in Phosh) → podman + Alpine → power/battery
   measurements → everything else in the TESTPLAN (Wi-Fi, BT, audio, touch,
   pen, keys, sensors, GPU, display, charging).
F. **Remote / update server**: on the tablet `updatectl check` against the
   `-dev` channel, `updatectl update`, reboot, confirm the new version and
   boot counting (`bootctl list`: `+N-M` tries), rollback test (TESTPLAN),
   `~test` override replaced by the next remote version.
G. **Installer suite** on the real tablet: `./setup.sh status`,
   `./setup.sh update --test ...`, `./setup.sh undo` then `./setup.sh redo`
   ONLY with the user's explicit OK in this session (undo boots Android's
   boot image; with Duranium in userdata Android may offer a factory reset
   that would erase Duranium - the user must not accept it). Never run
   `wipe` / `uninstall` on the user's tablet unless they ask.
H. **Release gate**: when a kernel/driver export passed B-F, run
   `scripts/pmos-export`, commit, push (dev channels rebuild); then after
   the device check of that exact export `scripts/pmos-verify "<what
   passed>"`, commit, push: public channels publish. Watch the CI run to
   green and check the new releases.json.

## 4. When a test fails

1. Capture: dmesg (`scripts/tab dmesg`), `journalctl -b`, pstore, the
   relevant sysfs/debugfs, a screenshot. Save under `$R/`.
2. Diagnose from the evidence and the source (src/linux branch named in the
   TESTPLAN case; Samsung's reference trees build/ref/gtactive3cs and
   src/samsung-9810-ref; RE notes docs/re/).
3. Fix in the right place (kernel: the drv/<topic> worktree; device
   package: build/wt/pmaports-duranium, bump pkgrel; installer/CI: main).
   Prefer the fast loop: rebuild one module and swap it live in the
   bring-up or with build/dkmod in Duranium; only then rebuild packages and
   images.
4. Re-test, update the TESTPLAN case if the expected result was wrong,
   commit in small chunks (`Co-Authored-By: Claude Opus 5.5
   <noreply@anthropic.com>`), push main.
5. Blocked (needs a decision only the user can make, or hardware that
   cannot work): mark BLOCKED with the reason, move on, report at the end.

## 5. Reporting

- After each block: update `docs/STATUS.md` (only Duranium ✔ counts as
  done) and `$R/results.tsv`; commit.
- At the end (or every few hours): a short summary to the user: passed /
  failed / blocked with evidence paths, what is published (versions,
  channels), and the remaining physical checks batched into one request.
  `scripts/notify-user --info "Test campaign: <n> passed, <m> left"`.
