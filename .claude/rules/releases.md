# Releases

- Only CI publishes (images.yml, bootchain.yml). Never upload release assets
  or move channel tags by hand, never publish a `~` version.
- Release channels get only builds of a device-verified export:
  `scripts/pmos-verify "what passed"` after an on-device pass of exactly
  those trees, on the owner's or the coordinator's word. Dev channels get
  every build.
- The signing key never changes casually: installed devices trust only
  `pmos/sysupdate-public-key.asc`. A new key means reinstalling them.
- The update address (`update.base`) is baked into every image. Changing it
  (a repo rename or move) needs an image with the new address published
  and verified on a device first, then the move.
- Vendor firmware is never published. Release notes and Pages records are
  generated (`ci/publish`, `ci/pages`); edit the generators, not the output.
