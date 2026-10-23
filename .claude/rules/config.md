# config.toml is the single source

- Every device-specific value lives in `config.toml`, documented in
  `docs/CONFIG.md`. Scripts read it through `scripts/config` only (`get`,
  `shell` -> CFG_* variables, `json`, `channels`, `matrix`); never parse
  the TOML anywhere else and never hard-code a value it holds (device id,
  models, URLs, partition names, UIs, channels).
- Derived values (device.id, kernel.package, update.base, update.pages,
  bootchain.tag, installer.name, update.channel_file) are computed in
  `scripts/config` and nowhere else.
- New key: add it to config.toml with a comment, validate it in
  `scripts/config check()` if it has a format, document it in
  docs/CONFIG.md, cover it in tests/config/test_config.py.
- `config.toml` is public (published as device.json). Never a secret in it:
  the signing key is the SYSUPDATE_SIGNING_KEY repository secret.
- Device logic that a value cannot express goes into the device's own
  files (device package, `scripts/installer/device.sh` hooks,
  `bootchain/build.sh`), not into the shared plumbing.
