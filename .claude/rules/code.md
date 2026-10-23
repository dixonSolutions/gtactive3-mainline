# Code and commits

- Match the surrounding code: POSIX sh / bash with `set -eu` and tabs, Python
  3 standard library only (`python3 -I`), comments that say why, at the
  existing density. No new dependencies for the plumbing.
- Commit in small, self-contained chunks with a subject like
  `area: what changed` and a body that says why. End messages with the
  Co-Authored-By line your tooling asks for.
- Never commit: `src/`, `build/`, `firmware/`, keys, Samsung files, the
  owner's serial number or data, local Wi-Fi profiles or SSH keys.
- Plumbing changes (ci/, scripts/, workflows, installer, pmos/duranium/)
  that are not device-specific belong upstream in exynos-linux/
  device-template too: keep them free of device values so they merge back.
- Run the offline tests before pushing: `scripts/config check`,
  `python3 -I tests/config/test_config.py`, `bash tests/installer/run.sh`,
  shellcheck on what you touched.
