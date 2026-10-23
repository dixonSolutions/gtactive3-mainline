# Builds

- Iterate on drivers in the bring-up Linux (rebuild one module, swap it
  live), not by building whole images. Only batch proven fixes into a
  Duranium image.
- Local images: `scripts/build-image`, the same steps as CI. Heavy jobs take
  `build/work/build.lock`: one at a time on a PC. Never delete the ccache
  (`build/work/ccache`): a cold kernel build is many times slower.
- After changing an aport: bump `pkgrel` (the same version may install the
  cached old package) and run `scripts/aport-checksum`.
- Local versions carry `~test<N>` (docs/RELEASES.md) so the next published
  update replaces them.
- If the PC overheats, cap the CPU's turbo rather than turning it off;
  pause containers (`podman pause`), never SIGSTOP make.
