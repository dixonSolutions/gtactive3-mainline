# Fingerprint sensor (Egis ET510 on SPI1): verdict for mainline

Short answer: **not reachable from Linux on retail firmware.** The SPI channel
is owned by the secure world (TEEGRIS) from boot. Image capture, matching and
template storage all run inside a Samsung-signed trusted app. fprintd/libfprint
unlock cannot be built on this hardware without that TEE stack. The rest of
this note gives the evidence and what would be needed.

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
4. **The hardware enforces the lock independently of any Android software.** Under our mainline kernel no tzdev driver and no trusted app runs. Even so, a plain AP read of SYSREG_PERIC0 + 0x1004 (USI00 SW_CONF) caused an external abort on the device; this is recorded in `fp-gps-camera.md`. So the TZPC/sysreg protection for USI00 is set by the secure boot firmware before Linux starts. We have no SMC to release it.
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

To use the sensor, Linux would have to run Samsung's stack unchanged:
1. A TEEGRIS client driver (`tzdev`, about 14.5 kLOC of C in `drivers/misc/tzdev`, out of tree, never upstreamed). It has to be ported to Linux 7.x together with its IWI interrupts, shared-memory and boost interfaces.
2. The userspace TEE client (`libteecl.so`, Bionic) and the TEEGRIS daemon. The daemon loads `startup.tzar` and serves the TA filesystem (`fsdev`).
3. The signed FINGER TA, and Samsung's private command protocol between the HAL (`libbauthserver.so`/`libbauthtzcommon.so`) and the TA. Templates are bound to the device keys inside the TEE.
4. A libfprint driver speaking that protocol. It would only see match/no-match, never images.

Items 1-3 are proprietary and Android-specific. The protocol is undocumented, and running Bionic blobs under glibc/musl would need libhybris-style shims. This is not reproducible or maintainable in this project, and it cannot be upstreamed.

## Recommendation

- Treat the fingerprint sensor as unsupported. Use PIN/password unlock in Phosh/GNOME.
- Do not add a DT node for USI00/SPI1. Probing it would touch secure registers and abort.
- Optional and low value: the sensor LDO (gph1-2) could be held low with a `gpio-hog` so the sensor stays unpowered. Our kernel never touches it today. The stock driver drives it low at probe (`et5xx-spi.c:1003`), and the bootloader most likely leaves it off. Check its state read-only first:
  - Run `cat /sys/kernel/debug/gpio | grep -A3 gph1` on the device.
  - Expected: line 2 is an input or output-low.
  - If it reads high, a one-line `gpio-hog` with `output-low` on `&gph1 2` in the board DTS is enough. It is safe: a plain GPIO, nothing secure.
