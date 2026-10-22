# QEMU test harness for the Duranium images

Boots a real SM-T570 Duranium image (a local `mkosi.output` build or a
published release) in `qemu-system-aarch64 -M virt`, headless, and checks
it the way the tablet would be checked, without the tablet.

```sh
tests/virt/run.sh build/wt/duranium/mkosi.output/samsung-gtactive3wifi_phosh_edge/samsung-gtactive3wifi_phosh_edge_<v>.raw
tests/virt/run.sh gh:samsung-gtactive3wifi_phosh_edge-dev          # newest published
tests/virt/run.sh IMAGE --update DIR:VERSION --rollback            # A/B update + fallback
```

Results go to `build/virt/runs/<run>/`: `results.json` (every check with
pass/warn/fail/skip and details), `log.txt`, `serial.log` (edk2,
systemd-boot, kernel, systemd), `shots/*.png` (first boot, greeter,
session, rollback). Exit status 0 = PASS, 1 = a check failed, 77 = not
testable (kernel without virt drivers and `--kernel none`).

## What a run checks

1. edk2 → the image's systemd-boot → its UKI → initrd → first boot:
   systemd-repart creates the second usr slot and the LUKS root
2. f0rmz first-boot setup, driven with the virtual tablet and keyboard
   (user `tester`, password `duranium1`, no disk passphrase)
3. `systemctl is-system-running`, multi-user and graphical targets
4. greeter (Phosh: greetd + phoc + phrog; GNOME: gdm) on virtio-gpu, login,
   the user's phosh / gnome-shell session
5. failed units and `journalctl -p err`, split into QEMU-only
   (`qemu-only.txt`), known harmless (`known-benign.txt`) and unexpected
6. debug layer units (dev images; there is no USB gadget in QEMU)
7. sysupdate source = this project's channel, keyring = only the project
   key; `systemd-sysupdate list` against the live GitHub channel
8. podman: from /usr, else the image's dev-tools sysext/confext (served
   from the image's directory), `podman run alpine`
9. with `--update DIR:VERSION`: a local update server (UKI virtualized,
   SHA256SUMS signed with a throwaway key the guest trusts through
   /etc/systemd/import-pubring.pgp, /etc/sysupdate.d overrides), `updatectl
   update`, reboot, new version booted, boot counting blesses it
10. with `--interrupt`: the update goes through systemd-sysupdate.service
   (the automatic path) and the first usr download breaks off after 64 MiB;
   the image's retry policy must finish the update (RestartSec shortened
   to 30 s; images without a retry drop-in get Restart=on-failure)
11. with `--rollback`: the new version is made unbootable on the host (UKI
   back to `+2-0`, usr partition overwritten), systemd-boot must count it
   down and boot the previous version again

## How the image is booted (and what is not the tablet's path)

- `-machine virt,acpi=off`: edk2 hides the devicetree from the OS when it
  offers ACPI; our kernel has no ACPI, so it would get an empty DT and
  panic ("Unable to initialise architected timer").
- The UKI's `.dtb` section is renamed (`uki-virt.py`): systemd-stub
  installs a plain `.dtb` unconditionally, which would replace QEMU's DT
  with the tablet's. Everything else in the UKI is unchanged.
- The kernel needs `virt.config` (duranium-build
  `contrib/samsung-gtactive3wifi/kernel/virt.config`). For images built
  before it, `build-kernel.sh` builds a virt Image from the aport revision
  that built the image (`APORT_REV`, config must match: e.g. CONFIG_PM
  changes struct device) and `--kernel IMAGE` puts it into the UKI. That
  Image also sets MODULE_ALLOW_BTF_MISMATCH so the image's modules load.
- Extra kernel arguments come from SMBIOS
  (`io.systemd.stub.kernel-cmdline-extra`): serial console on ttyAMA0, a
  root shell on hvc0 (`systemd.debug_shell=hvc0`, also in the initrd), no
  getty on hvc0.
- 4 KiB logical sectors on virtio-blk, like the tablet's UFS.
- TCG (`-cpu cortex-a55`, 4 vCPUs) on the laptop, KVM on an aarch64 host
  that has it. Software rendering (llvmpipe), so timings are not the
  tablet's.

## Interactive use

```sh
tests/virt/harness.py start IMAGE [--kernel ...]  # boots, prints the run dir
tests/virt/harness.py sh RUN 'systemctl --failed'
tests/virt/harness.py shot RUN out.png
tests/virt/harness.py tap RUN 0.5 0.6; tests/virt/harness.py type RUN text; tests/virt/harness.py key RUN ret
tests/virt/harness.py step RUN firstboot ui errors   # single checks
tests/virt/harness.py stop RUN; tests/virt/harness.py resume RUN
```

`shot`/`tap`/`type`/`key` use a second QMP monitor, so they also work while
`check` runs; the hvc0 shell serves one client at a time.

## Laptop rules

One VM at a time (`build/vm.lock`), at most 3 GiB guest RAM, nice 10, a VM
starts only with 4 GiB available (waits up to `VIRT_MEM_WAIT` seconds) and
a watchdog powers it off below 1.5 GiB. The disk is a reflinked sparse copy
in the run directory, deleted at the end unless `--keep-disk`.

Host tools: `setup-host.sh` (Fedora: unpacks the RPMs into
`build/virt/host`, no root; Debian/Ubuntu: apt).
