# Fingerprint sensor (Egis ET510 on SPI1): verdict for mainline

Short answer: **not reachable from Linux on retail firmware.** The SPI channel
is owned by the secure world (TEEGRIS) from boot. Image capture, matching and
template storage all run inside a Samsung-signed trusted app. fprintd/libfprint
unlock cannot be built on this hardware without that TEE stack. The rest of
this note gives the evidence and what would be needed.

Update 2026-10-23: an open driver stays impossible. Running Samsung's own TEE
stack, as custom ROMs do, is a real but large route. It has never been done on
a mainline kernel. See
[Path via Samsung's TEE stack](#path-via-samsungs-tee-stack-as-custom-roms-do)
for the details, the cost and a go/no-go test.

Sources:
- Stock DT overlay `firmware/stock/dtbo-4.dts` (board hw_rev 4).
- Samsung GPL kernel `build/ref/gtactive3cs` (defconfig `exynos9810-gtactive3ue_defconfig`).
- Vendor partition `firmware/fs/vendor`.

No decompiled code is used or reproduced here.

## Hardware as described by the stock DT

`dtbo-4.dts` fragment@77, lines 4040-4077, targets `spi_1`. That is the PERIC0 USI00 SPI controller (USI SW_CONF at SYSREG_PERIC0 + 0x1004, alias `usi0 = "/usi@10411004"` in `stock-0.dts:3401`).

| item | value |
|---|---|
| compatible | `etspi,et5xx`, `etspi-chipid = "ET510"` |
| chip select | gpp0-3 (`controller-data/cs-gpio`) |
| DRDY (finger/frame interrupt) | gpa1-3 |
| sleep/reset pin | gph1-1 |
| sensor LDO enable | gph1-2 |
| SPI clock | 13 MHz (`spi-max-frequency = 0xc65d40`) |
| DMA | pdma0 channels 0/1 |

Two properties mark the bus as secure:
- `secure-mode;` on the controller (`dtbo-4.dts:4045`).
- The pinctrl states `pins_poweron_tz` / `pins_poweroff_tz` (`dtbo-4.dts:4057`). They only switch the IRQ pin and leave the SPI pins alone (`dtbo-4.dts:4061-4062`, versus the non-TZ poweron state at `:4059`, which muxes SPI clk/cs/miso/mosi). The normal world is not meant to own the SPI pins.

## (A) Is the bus accessible from the non-secure world? No.

1. **The retail kernel is always built in secure mode.** `Makefile:943-958` exports `-DENABLE_SENSORS_FPRINT_SECURE` whenever `CONFIG_SENSORS_FINGERPRINT=y` (defconfig:4210) and the build is not `SEC_FACTORY_BUILD`. The flag is injected into three places:
   - `drivers/fingerprint` (`drivers/fingerprint/Makefile:7`)
   - `drivers/spi` (`drivers/spi/Makefile:6`)
   - `drivers/soc/samsung` (`drivers/soc/samsung/Makefile:5`)
2. **The SPI and USI drivers leave the FP channel alone.**
   - SPI: `spi-s3c64xx.c:1222-1228` returns early from `setup()` for `port_id == CONFIG_SENSORS_FP_SPI_NUMBER` (=1, defconfig:2430), with the log "spi configuration for secure channel is skipped(FP)".
   - SPI: `spi-s3c64xx.c:2008-2012` skips USI init and controller hwinit for `secure-mode` controllers.
   - USI: `usi_v2.c:92-97` skips the SW_CONF write for `CONFIG_SENSORS_FP_USI_NUMBER` (=0, defconfig:4648).
3. **Every data-path routine in the Egis driver compiles to a stub.** In `et5xx-spi_data_transfer.c` all of the following start with `#ifdef ENABLE_SENSORS_FPRINT_SECURE return 0;`: register read (`:262-265`), burst write (`:20-25`), NVM write (`:664-668`) and frame read `etspi_io_get_frame` (`:918-921`). In the retail kernel the normal-world driver does only these jobs:
   - LDO and sleep GPIOs (`et5xx-spi.c:219-238`, `:992-1004`).
   - The DRDY interrupt and poll.
   - Enabling the SPI clocks (`fp-spi-pclk`/`fp-spi-sclk`, `et5xx-spi.c:265-310`) for the secure side, through the `FP_SET_SPI_CLOCK` ioctl (`:704-760`).
   - CPU boost for the TEE (`tz_boost_enable`, `:830-846`).
   - The Kinibi SMC hooks (`MC_FC_FP_PM_RESUME`, `MC_FC_FP_CS_SET`, `:58-70`, `:228-231`) are compiled out because this board uses TEEGRIS (`CONFIG_TZDEV=y`, defconfig:1433).
4. **The hardware enforces the lock independently of any Android software.** Under our mainline kernel no tzdev driver and no trusted app runs. Even so, a plain AP read of SYSREG_PERIC0 + 0x1004 (USI00 SW_CONF) caused an external abort on the device; this is recorded in `fp-gps-camera.md`. So the TZPC/sysreg protection for USI00 is set by the secure boot firmware before Linux starts. The bootloader confirms it: the EYI1 `sboot.bin` contains the strings "TEEGRIS - Fingerprint protection failed." and "TEEGRIS - protection error in Fingerprint %x". We have no SMC to release it.
   - The only FP-related SMCs in the GPL tree (the `MC_FC_FP_*` calls) are Kinibi power hooks. None of them hands the channel back.
5. **The trusted app owns the SPI.**
   - `vendor/tee/00000000-0000-0000-0000-46494e474552` (UUID tail = ASCII "FINGER") is a signed TEEGRIS TA. Its header starts `SEC3` and is followed by an arm64 ELF.
   - Its strings include Egis's copyright, the ET510/ET516/ET520 sensor tables, "Failed to initialize SPI", "Failed to initialize SPIDMA" and a secure-SPI mode query. The secure world opens the SPI and the PDMA itself.
6. **The factory self-test also delegates to the TA.** `libegis_fp_normal_sensor_test.so` ("NS" stands for normal scan) talks to `/dev/esfp0`, but its symbols only cover these operations:
   - power, reset and clock set;
   - interrupt enable/wait;
   - EEPROM enable and CPU speedup.

   It has no register or frame I/O. It hands the measurement to a callback, which is the TA path through `libbauthtzcommon.so`/`libteecl.so`. No normal-world image path exists on retail firmware.

The GPL source does contain a complete normal-world implementation: the `!ENABLE_SENSORS_FPRINT_SECURE` branches. The ioctls cover register R/W, burst, NVM, VDM and `FP_GET_ONE_IMG`, and the SPI opcodes are in `et5xx.h:81-94`, e.g. 0x20/0x24 register read/write and 0x50 image read. That branch is built only for `SEC_FACTORY_BUILD` kernels. It presumably runs together with factory boot firmware that leaves USI00 non-secure. That is unverified, because we have no factory BL to inspect. It would not help anyway: flashing a Samsung combination/factory bootloader replaces the boot chain Duranium depends on and risks rollback-fuse and lock problems. That breaks the "never strand / never reinstall" rules.

## (B) Driver from Linux: not applicable

If the bus were reachable, the work would be medium-sized and fully based on GPL code:
- **Protocol:** the opcodes and register/frame sequence come from the GPL factory branch above.
- **Kernel side:** a small mainline SPI driver, or spidev plus GPIO/IRQ, with the ET510 LDO, sleep and DRDY handling.
- **libfprint side:** a new SPI image driver. libfprint's Egis drivers (`egis0570`, `egisetp`) are USB-only and use a different command set.
- **Matching:** host-side in libfprint. ET510 is a small capacitive area sensor, so it would need libfprint's small-sensor matcher path, not NBIS minutiae.

None of this can run while every AP access to the channel aborts. I did not start a `drv/fp` branch.

## (C) What it would take with the secure world

To use the sensor, Linux would have to run Samsung's stack unchanged. This list was corrected on 2026-10-23; the full analysis is in the next section.
1. A TEEGRIS client driver (`tzdev`, 14.5 kLOC in `drivers/misc/tzdev`, of which about 7.2 kLOC are needed; out of tree, never upstreamed). It has to be ported to Linux 7.x with its IWI interrupts, SMC transport and shared memory. Boost is off on this board (`CONFIG_TZDEV_BOOST` not set).
   - The kernel, not the daemon, uploads `startup.tzar` (`CONFIG_TZDEV_DEPLOY_TZAR=y`).
   - A second small GPL driver is also needed: the secure-RPMB relay (`drivers/scsi/scsi_srpmb.c`). The TEE's storage reaches the RPMB through it.
2. The Bionic userspace: `libteecl.so`, `tzdaemon` and `tzts_daemon`. The daemons serve TA storage (`/data/vendor/tee`, `/mnt/vendor/efs/tee`). `fsdev` (`CONFIG_TZ_NWFS`) is not built on this board.
3. The signed FINGER TA, the Gatekeeper TA (enrolment needs a hardware auth token from it) and the fingerprint HAL. We do not need the private HAL-to-TA protocol: `libbauthserver.so` exports a plain C API (`ss_fingerprint_*`), and LineageOS's open-source HAL calls exactly that. Templates are bound to the device keys inside the TEE.
4. A host-side service that only ever sees enroll progress and match/no-match, never images. The best fit is a daemon offering fprintd's D-Bus API, not a libfprint driver.

Items 1-3 are proprietary and Android-specific. libhybris shims are not needed: the blobs run as Bionic processes in a small Android container, and the host talks binder to them. Custom ROMs and Halium ports do this on Samsung's own kernels. Nobody has done it on a mainline kernel. It can never be upstreamed.

## Recommendation

- Treat the fingerprint sensor as unsupported for now. Use PIN/password unlock in Phosh/GNOME. The only route to a working sensor is the TEE path below, and its stage-0 test decides whether to pursue it.
- Do not add a DT node for USI00/SPI1. Probing it would touch secure registers and abort.
- Optional and low value: the sensor LDO (gph1-2) could be held low with a `gpio-hog` so the sensor stays unpowered. Our kernel never touches it today. The stock driver drives it low at probe (`et5xx-spi.c:1003`), and the bootloader most likely leaves it off. Check its state read-only first:
  - Run `cat /sys/kernel/debug/gpio | grep -A3 gph1` on the device.
  - Expected: line 2 is an input or output-low.
  - If it reads high, a one-line `gpio-hog` with `output-low` on `&gph1 2` in the board DTS is enough. It is safe: a plain GPIO, nothing secure.

## Path via Samsung's TEE stack, as custom ROMs do

Research of 2026-10-23. Nothing was run on the tablet. Sources:
- the GPL kernel (`build/ref/gtactive3cs`);
- the stock vendor partition (`firmware/fs/vendor`, T570XXSFEYI1, Android 13, VNDK 33);
- the stock DT;
- the stock `/cache` and EFS snapshots in `firmware/device-snapshot/` (`sda28.img` holds stock kernel logs, `sda1.img` is EFS);
- the public trees linked at the end.

Only GPL code, file names, exported symbol names and strings are used. Nothing is decompiled.

### Summary

- **Why it does not work today.**
  - The boot firmware locks the sensor's SPI bus to the secure world before Linux starts (section A). A normal-world driver gets a bus abort. No amount of driver work changes that.
  - The only code allowed to talk to the sensor is Samsung's signed FINGER trusted app inside TEEGRIS. Our kernel has no TEEGRIS client, so nothing asks that app to run.
- **Can it work?** In principle yes, the same way custom ROMs do it.
  - Run Samsung's own TEE client stack. Linux then asks the trusted app "enroll" or "does this finger match", and gets back only the answer.
  - LineageOS and Ubuntu Touch do this on TEEGRIS Samsungs, with Knox tripped. They always use Samsung's own kernel.
  - Nobody has done it on a mainline kernel.
- **Is there a refusal point?** Nothing found in TEEGRIS checks which kernel runs. The one unverified step is tzdev's version handshake. Stage 0 below (a few days) settles it.
- **Cost.**
  - About 6-8 weeks of work.
  - A permanent out-of-tree kernel driver.
  - Samsung blobs that public images cannot ship.
  - Some device risk.
- **Recommendation:** run the stage-0 go/no-go test before committing to the rest (see the end of this section).

### What the custom ROMs actually run

The original claim was that S9/S9+/Note9 ROMs use tzdev + tzdaemon + libteecl + the FINGER TA. **For those three phones that is wrong.**
- LineageOS's universal9810 kernel (starlte/star2lte/crownlte, lineage-17.1) is built with `CONFIG_TRUSTONIC_TEE=y` and has no `TZDEV`.
- So those phones run Trustonic Kinibi (MobiCore), not TEEGRIS. Their fingerprint works through a different TEE, and none of that stack applies here.
- The blob list of LineageOS 17.1 for the 9810 has no TEE entries at all; those parts come from the stock vendor partition.

The Tab Active3 is the odd one out: same SoC, but TEEGRIS v4 (`defconfig:1433-1457`: `CONFIG_TZDEV=y`, `CONFIG_TEEGRIS_VERSION=4`; `:5146` `CONFIG_TRUSTONIC_TEE` not set). The stock `/cache` logs show it running: `SW> securefp: Trustlet Fingerprint::Returning 0`, `TEEGRIS H/W Gatekeeper TA version : 4.200`.

The TEEGRIS references are the Exynos 9820 and later:
- **LineageOS exynos9820-common (S10/Note10, lineage-23.2).**
  - Kernel: `CONFIG_TZDEV=y`, `TZDEV_DEPLOY_TZAR=y`, `UFS_SRPMB=y`. Samsung's hypervisor is off (`CONFIG_UH` not set), and there is no FIVE/PROCA.
  - Blob list: `tzdaemon`, `libteecl`, `tzts_daemon` and the `vendor/tee/*` TAs.
  - Fingerprint HAL: LineageOS's own open-source `android.hardware.biometrics.fingerprint-service.samsung`. Its `LegacyHAL.cpp` `dlopen()`s Samsung's `libbauthserver.so` and calls the exported `ss_fingerprint_open/enroll/authenticate/...` functions. Our `libbauthserver.so` exports the same set.
  - Gatekeeper and keymaster are AOSP/LineageOS wrappers around Samsung's TEE-backed modules.
- **Firmware matching.**
  - LineageOS kernel commit "misc: tzdev: Support fallback tzar" ships two `startup.tzar` files: the international Note10 runs an older TEE than the other 9820 models.
  - ExtremeXT's 9820 kernel build picks an "old" or "new" tzdev per model.
  - So tzdev and `startup.tzar` must match the TEEGRIS inside the bootloader.
- **Exynos 990 (S20, ExtremeXT `x1s`) and Exynos 9611 (M31) trees** use the same LineageOS HAL. The Exynos 990 tzdev identifies clients the same way ours does: SHA-256 of the client executable. The S10's older tzdev hashes the executable's path instead.
- **Ubuntu Touch on the Galaxy S10 (beyond1lte, Halium 10)** lists the fingerprint reader as "Working". Halium means Samsung's kernel, an LXC Android container with the vendor partition, and host services that talk to the HAL.
- **Droidian (`droidian-fpd`) and Sailfish (`sailfish-fpd-community`)** run a host daemon over the Android biometrics HAL. UBports biometryd MR !48 (opened June 2026) moves to libgbinder: AIDL on `/dev/binder`, else HIDL on `/dev/hwbinder`, no libhybris.
- All of these run on Samsung's vendor kernel, with Knox tripped and the bootloader unlocked. Fingerprint keeps working there. What breaks is Samsung Pass, Pay, Secure Folder and attestation.

### What the TEE needs from the normal world on this tablet

| piece | GPL source | role | port? |
|---|---|---|---|
| tzdev core + lib | `drivers/misc/tzdev/core`, `lib` (about 7.2 of 14.5 kLOC) | SMC transport, shared memory, IW sockets, `/dev/tzdev`, `/dev/tziwsock`, `/dev/tziwshmem` (the nodes `libteecl` opens) | yes |
| startup.tzar deploy | `core/deploy_tzar.c:35` (`.incbin`), uploaded at init over the "userboot" IW socket | TEEGRIS userland (root TA, system TAs). 4 MB, byte-identical (sha256 9495cb51...) to the copy inside the stock EYI1 kernel image | yes; load it with `request_firmware` instead of `.incbin` |
| secure-RPMB relay | `drivers/scsi/scsi_srpmb.c` (495 lines), registered with `SMC_SRPMB_WSM` (`:348`), stock DT `ufs-srpmb` IRQ | The secure world reads and writes RPMB through the normal-world UFS stack. The stock logs in the `/cache` snapshot show 197 READ_DATA, 32 WRITE_DATA and 32 GET_WRITE_COUNTER jobs | yes |
| esfp driver | `drivers/fingerprint/et5xx-spi.c`, secure branch only | LDO/sleep GPIOs, DRDY IRQ, USI00 clocks on request (`FP_SET_SPI_CLOCK`), the `/sys/class/fingerprint/fingerprint/{name,type_check,adm,...}` files the HAL reads | yes, as a small platform driver (no SPI controller node) |
| tzirs | `extensions/irs.c` | integrity/OEM-flag channel; `icdrv` uses it to blow tamper fuses (`set_tamper_fuse`, `OEMFLAG_FIDO` ...) | no |
| icdrv, tzic, PROCA, FIVE, uH/RKP | `drivers/security/samsung`, `security/` | Knox integrity | no (LineageOS 9820 runs without them) |
| teec, ion_fd2phys, tui, scma, fsdev, boost, hotplug | `drivers/misc/tzdev` | in-kernel clients, ION, trusted UI | no |

#### Port details

- **SMC:** fast SMC32 calls in the Trusted-OS range, function ID `0xB2000000 + n` (`tzdev_internal.h:43-56`).
  - The calls: CONNECT=1, SCHEDULE=3, SHMEM_LIST_REG=6, SYSCONF=9, CHECK_VERSION=13.
  - This is plain SMCCC, so mainline `arm_smccc_smc()` can issue it. Our kernel already makes EL3 SMCs (FMP for UFS).
- **IWI interrupts:** two GIC SPIs from the stock node `teegris { compatible = "samsung,teegris"; interrupts = <0 453 4>, <0 454 4>; }` (`stock-0.dts:7555-7558`).
  - These are hwirq 485/486, the same values as `CONFIG_TZDEV_IWI_EVENT/PANIC`.
  - tzdev finds the node by its compatible (`tzdev.c:275`) and registers its own platform device. It needs no other DT.
- **Memory:**
  - Reserve `teegris_rmem` (0xed310000, 8 KiB) and `seclog_mem` (0xc0000000, 512 KiB) as `no-map` before the first load. Both lie inside our current memory map.
  - No GPL C code uses `teegris_rmem`, so the boot firmware or the secure world does.
  - PFNs are passed as 32-bit values (`TZDEV_SK_PFNS_64BIT` off). That is fine for our DRAM.
- **Kernel API changes since 4.9:**
  - `get_user_pages` becomes `pin_user_pages(_remote)`, and `mmap_sem` becomes `mmap_lock`.
  - `crypto/sha.h` becomes `crypto/sha2.h`, and the shash `desc->flags` field is gone.
  - `irq_to_desc()` is no longer exported: build the driver in, or use `irq_get_irq_data()`.
  - The driver already has a `sysdep.h` compatibility layer. Samsung's 5.10 trees (Exynos 990/9611, MTK) carry the same code and are a guide.
- **Threads:** per-CPU workers use smpboot (`SK_MULTICORE=y`) and make SMCs from whichever CPUs are online. Our 4 little cores are enough.
- **Panic:** stock has `CONFIG_TZDEV_SWD_PANIC_IS_CRITICAL=y`, which panics Linux when the secure world panics (`tzdev.c:354`). Turn it off.
- **Once per boot:** tzdev never disconnects from the secure world. Load it once per boot; retrying means rebooting.
- **Boost:** off on this board. `FP_CPU_SPEEDUP` can be a no-op or a frequency-QoS request.
- **Clocks and DMA:**
  - The TA needs the USI00 gates and divider in CMU_PERIC0, which are present in our `clk-exynos9810.c`.
  - It probably also uses PDMA0: the TA contains "Failed to initialize SPIDMA", and the stock DT gives `spi_1` pdma0 channels 0/1.
  - The clock framework must not gate these as unused, and the mainline pl330 driver must not claim those channels.

#### Does TEEGRIS accept a non-Samsung kernel?

- **Boot:** the bootloader starts TEEGRIS before any kernel runs.
  - The EYI1 `sboot.bin` contains `TEEGRIS_EXYNOS9810_CSMC`, "TEEGRIS - Fingerprint protection failed." and "CSMC: bl_secure_info.warranty_bit (%x)". So the bootloader both sets up the fingerprint bus lock and tells the secure world the warranty bit, all before Linux.
  - TEEGRIS cannot inspect the normal-world kernel; all it knows comes from tzdev.
- **Version check (the real unknown):**
  - tzdev sends `LINUX_VERSION_CODE` and driver version 3.0.0 (`tzdev_internal.h:115`). An `-EINVAL` reply means "kernel or TZDev not compatible" (`tzdev.c:129-145`).
  - No example of a different kernel major version on TEEGRIS exists, because Samsung keeps one kernel version per device.
  - Our port can send the stock value (4.9.191 = 0x0409BF).
- **Client identity:**
  - tzdev itself hashes the calling process's executable (SHA-256) and sends that with pid/uid/gid (`cred.c:117-124`). This is not a trust boundary, because our kernel computes it.
  - If the FINGER TA pins the HAL's hash, running Samsung's unmodified HAL binary satisfies it.
  - The S20 tree ships LineageOS's own HAL binary on content-hash TEEGRIS, which suggests FINGER does not pin the hash at all. Unverified: the tree does not say whether fingerprint works.
  - Run the HAL as uid 1000 (system), as stock does.
- **TA load:** the TAs are signed `SEC3` images. TEEGRIS checks them against Samsung's keys and anti-rollback counters. This has nothing to do with the kernel; it only passes with TAs from the firmware matching the bootloader.
- **Key derivation:**
  - Templates and Gatekeeper records are encrypted inside the TEE with device-unique keys. The kernel plays no part.
  - The bootloader reports the same verified-boot state (unlocked/orange) whether stock Android or Duranium boots.
- **Knox:**
  - The warranty bit is already 0x1 since the unlock. Knox flags such as `OEMFLAG_FIDO` gate Samsung Pass/FIDO, not the FINGER TA.
  - Do not port `icdrv`/`tzic`, so our kernel never blows another tamper fuse.
- **PROCA:**
  - The secure-world process authenticator reads normal-world kernel memory. The stock logs show "KASLR Magic code is found" and "GAF is loaded".
  - It will fail on mainline. FINGER does not depend on it: LineageOS 9820 ships no PROCA, and fingerprint works there.
- **Conclusion:** if anything refuses, it is the kernel handshake (CHECK_VERSION, CONNECT, tzar deploy). Neither TA loading nor key derivation is expected to refuse.

### Userspace: running the Bionic blobs

What has to run. All of it is Bionic code from the vendor partition (Android 13, VNDK 33):
- **`tzdaemon` and `tzts_daemon`** (`vendor/etc/init/teegris.rc`):
  - They link only `libteecl`, `libuuid`, `liblog`, `libc` and `libdl`.
  - They set Android properties (`vendor.tzdaemon=Ready`, `vendor.secureos.*`), so they need a property service.
  - They store data under `/data/vendor/tee` and `/mnt/vendor/efs/tee`. EFS already holds Gatekeeper and vault-keeper objects in `/efs/tee/srt`.
- **Gatekeeper:** `android.hardware.gatekeeper@1.0-service` with `gatekeeper.exynos9810.so` (via `libteecl`), talking to the GATEKE TA.
- **Fingerprint HAL:**
  - The chain: `vendor.samsung.hardware.biometrics.fingerprint@3.0-service` (HIDL; @3.0 extends AOSP @2.1 `IBiometricsFingerprint`), then `fingerprint.default.so`, `libbauthserver.so`, `libbauthtzcommon.so`, `libteecl.so`, and finally the FINGER TA.
  - `libbauthserver` opens `/dev/esfp0` and reads `/sys/class/fingerprint/fingerprint/*`.
  - It reads the properties `ro.hardware.chipname`, `ro.product.vendor.name`, `ro.soc.model` and `ro.build.type`.
  - Templates live in `/data/vendor/biometrics/fp/User_<n>`.
- **Hardware auth token (HAT):**
  - Enrolment needs a HAT. `libbauthserver` has the error string "enroll hat is 0", and it hands the HAT HMAC key to the TA.
  - Droidian's fpd shows the working recipe: enroll a fixed internal password in the vendor Gatekeeper, verify it against the `preEnroll()` challenge, and pass the resulting HAT to `enroll()`.

| option | verdict |
|---|---|
| libhybris | No. In practice it needs glibc, and postmarketOS uses musl. The daemons would still need properties and separate processes, so it gains nothing. |
| Waydroid as shipped | No. Its container boots its own generic vendor image and the full Android framework: wrong vendor, and heavy. |
| Halium-style LXC container (recommended) | Reuse what the waydroid sysext already brings (LXC, binderfs) for a second, small container.<br>- System: an Android 13 image, either Waydroid's LineageOS 20 image or a Halium GSI system image. It provides init, the property service, hwservicemanager, the linker and the VNDK 33 apex, matching our vendor.<br>- Vendor: the Samsung subset.<br>- Services: a minimal init.rc that starts only `tz_service`, `tzts_service`, gatekeeper and `fps_hal`.<br>- Pass in `/dev/tzdev`, `/dev/tziwsock`, `/dev/tziwshmem` and `/dev/esfp0`, and bind-mount EFS.<br>- No zygote or framework. |
| Bionic sandbox + NDK bridge | Possible fallback. A small NDK program `dlopen()`s `libbauthserver.so` (the same `ss_fingerprint_*` calls as LineageOS's `LegacyHAL.cpp`) plus the gatekeeper module, and serves a UNIX socket. Lighter, but more custom glue, and tzdaemon still needs a property service. |

Host side:
- **A small daemon offering fprintd's D-Bus API** (`net.reactivated.Fprint`, Manager and Device) on top of libgbinder.
  - It talks to `android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint` and `android.hardware.gatekeeper@1.0::IGatekeeper` on the container's hwbinder.
  - The fingerprint calls it needs: `setNotify`, `setActiveGroup`, `preEnroll`, `enroll`, `authenticate`, `enumerate`, `remove` and `cancel`.
  - With it, gnome-control-center enrolment, GNOME Shell unlock and `pam_fprintd` (sudo, polkit) work unchanged.
- **Why not a libfprint driver:** libfprint has no out-of-tree driver interface (only the libfprint-tod fork has one), and matching happens in the TEE anyway.
- **Phosh:** its lock screen has no fingerprint unlock; there is only a 2024 feature request (phosh#1070). It needs a Phosh patch. So GNOME comes first; a Phosh tablet only gets the feature once Phosh does.

### Firmware rules

- **One firmware version for everything.** These must all come from the firmware that matches the tablet's bootloader (T570XXSFEYI1):
  - TEEGRIS itself, inside `sboot.bin` of `BL_T570XXSFEYI1`;
  - `startup.tzar`;
  - the `vendor/tee/*` TAs;
  - `tzdaemon`, `libteecl` and the HALs.
- **We already have a matching set.** `firmware/fs/vendor` is EYI1, and the GPL `startup.tzar` equals the one in the stock EYI1 kernel.
- **Mixed versions fail** at tzar deploy or TA load; that is what the fallback-tzar and old/new tzdev cases above show.
- **Bootloader changes:**
  - If the bootloader is ever updated, re-extract the whole set together.
  - The bootloader cannot be downgraded (rollback fuses), and anti-rollback will probably refuse TAs from older firmware.
- **Templates:**
  - The TA encrypts them with device-unique keys. They are stored in `/data/vendor/biometrics`, with metadata in `/efs/biometrics/meta`.
  - They only work on this tablet and are lost with the data. Android-era enrolments are already gone, since userdata was wiped.
- **Distribution:**
  - The vendor blobs are Samsung-proprietary, and public images cannot carry them. `setup.sh` would extract them from the user's own firmware package, like the other firmware.
  - `startup.tzar` ships in Samsung's GPL tarball but is still a blob, so load it from `/lib/firmware`.
- **EFS:**
  - `tzdaemon` writes `/mnt/vendor/efs/tee`, and EFS is on the never-wipe list. A backup exists (`firmware/device-snapshot/sda1.img`, 2026-10-21).
  - Take a fresh read-only `dd` before the first run, and run the first tests against a copy of the `tee/` directory.

### Effort and risk

| stage | work | estimate |
|---|---|---|
| 0: go/no-go | Build tzdev core as a module, loaded after boot and never from the initrd. Add the DT node and memory reservations, and the srpmb relay. Pass criteria: CHECK_VERSION and CONNECT succeed, IWIs arrive, "Startup tzar deployment done" appears, and SW> logs come through iwlog. Then `tzdaemon` in a minimal Bionic chroot reaches Ready. | 3-5 days, plus 2-3 coordinator device sessions |
| 1: sensor | esfp driver; the container; Gatekeeper HAT enrolment; enroll and authenticate from a test client | about 2 weeks |
| 2: desktop | fprintd-API daemon over libgbinder; GNOME integration; Phosh lock-screen patch | about 2 weeks, plus 1 for Phosh |
| 3: packaging | sysext behind a feature flag, blob extraction in `setup.sh`, tests | about 1 week |

Total: about 6-8 weeks. After that, the out-of-tree driver must be rebased for every kernel release. It can never go upstream, because its userspace ABI is Samsung's proprietary `libteecl`.

Risks:
- **Freezes:** a secure-world hang or an IWI storm can freeze the tablet with USB gone, and only a force reset helps.
  - Load tzdev only as a module after boot, and only with the coordinator's go.
  - Keep panic-on-secure-world-panic off.
- **Irreversible writes:** writes to EFS and the RPMB (TA storage, the RPMB write counter) are normal TEE behaviour but cannot be undone. Back up first.
- **Shared hardware:** clock or DMA conflicts on USI00/PDMA0 with mainline drivers.
- **Security:** matching stays in the TEE, but root on Linux can fake a "match" result, as with any fprintd setup. This is a convenience feature, not extra security.
- **Resources:** the container and its daemons have to run all the time to serve the lock screen.

### Recommendation

This is not a firm "no".

1. Run stage 0 once the coordinator has a free device slot, after the current priorities (big cores, suspend, cameras). It is cheap, and it decides the question.
2. If TEEGRIS rejects the handshake even with the stock version code, close the topic for good. The decisive reason would be: the secure world refuses our kernel.
3. If stage 0 passes, the rest is known engineering. Do the GNOME image first.

### Sources

- LineageOS S9/S9+/Note9 kernel (Kinibi): https://github.com/LineageOS/android_kernel_samsung_universal9810/blob/lineage-17.1/arch/arm64/configs/exynos9810-starlte_defconfig
- LineageOS 9810 device tree (stock vendor, no TEE blobs listed): https://github.com/LineageOS/android_device_samsung_universal9810-common/blob/lineage-17.1/proprietary-files.txt
- LineageOS S10 kernel config (TEEGRIS): https://github.com/LineageOS/android_kernel_samsung_exynos9820/blob/lineage-23.2/arch/arm64/configs/exynos9820-beyond1lte_defconfig
- LineageOS fallback tzar commit: https://github.com/LineageOS/android_kernel_samsung_exynos9820/commit/e2fb793a2ea210f59c45e587edef85a5940f0208
- LineageOS 9820 blobs and HAL packages: https://github.com/LineageOS/android_device_samsung_exynos9820-common/blob/lineage-23.2/proprietary-files.txt and https://github.com/LineageOS/android_device_samsung_exynos9820-common/blob/lineage-23.2/common.mk
- LineageOS Samsung fingerprint HAL (`ss_fingerprint_*`): https://github.com/LineageOS/android_hardware_samsung/blob/lineage-23.2/aidl/fingerprint/LegacyHAL.cpp
- ExtremeXT 9820 kernel, old/new tzdev per model: https://github.com/ExtremeXT/android_kernel_samsung_exynos9820/blob/main/build.sh
- ExtremeXT Exynos 990 tzdev (SHA-256 client hash): https://github.com/ExtremeXT/android_kernel_samsung_exynos990/blob/main/drivers/misc/tzdev/core/cred.c
- Ubuntu Touch on Galaxy S10, fingerprint "Working" (Halium 10): https://devices.ubuntu-touch.io/device/beyond1lte/release/xenial
- Droidian fpd (Gatekeeper HAT enrolment): https://github.com/droidian/droidian-fpd/blob/droidian/android/hybris/biometry_fp_hidl_for_hybris.cpp
- UBports biometryd over libgbinder (MR !48): https://gitlab.com/ubports/development/core/biometryd/-/merge_requests/48
- Sailfish fpd community: https://github.com/sailfishos-open/sailfish-fpd-community
- Phosh fingerprint feature request: https://gitlab.gnome.org/World/Phosh/phosh/-/issues/1070
- TEEGRIS kernel loaded by S-Boot (S10 notes): https://notes.generalzero.org/Reverse%20Engineering/Firmware/Samsung%20S10%20TEEGRIS.html
- Waydroid images are lineage-20 (Android 13): https://docs.waydro.id/development/compile-waydroid-lineage-os-based-images
