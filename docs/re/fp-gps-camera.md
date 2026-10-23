# Fingerprint, GNSS and cameras: what mainline can reach

Feasibility notes for the SM-T570 (board hw_rev 4, `firmware/stock/dtbo-4.dts`).
Sources: the stock DT, Samsung's GPL kernel for the T570 family
(`build/ref/gtactive3cs`, defconfig `exynos9810-gtactive3ue_defconfig`), the
vendor partition (`firmware/fs/vendor`) and the REA/Ghidra inventory in
`firmware/re-targets/`. So far REA has only binary overviews (procedure and
string counts) for these blobs, so nothing below depends on decompiled code.

## Fingerprint: Egis ET510 (no own driver; possible only via Samsung's TEE stack)

Full evidence and the (A)/(B)/(C) analysis: [fingerprint.md](fingerprint.md).

- **Where it sits:** on SPI1, which is PERIC0 USI00 (`spi_1`), chip select gpp0-3.
  - DRDY IRQ: gpa1-3.
  - Sleep pin: gph1-1.
  - LDO enable: gph1-2.
  - Compatible `etspi,et5xx`, `etspi-chipid = "ET510"`.
  - Sources: `dtbo-4.dts`, fragment@77, around lines 4040-4077.
- **The bus belongs to the secure world.** The node is marked `secure-mode`, and its pinctrl states include `pins_poweron_tz` / `pins_poweroff_tz`.
- **The kernel builds the secure variant.** The GPL Makefile sets `-DENABLE_SENSORS_FPRINT_SECURE` for every non-factory build (`Makefile:944-958`). With that flag:
  - the et5xx driver only handles power and GPIOs;
  - the USI v2 driver skips the SW_CONF write for `CONFIG_SENSORS_FP_USI_NUMBER = 0` (`drivers/soc/samsung/usi_v2.c`, secure-channel check).
- **Confirmed on the device:** an AP read of that SW_CONF register (SYSREG_PERIC0 0x10411004) caused an external abort. TZPC blocks the AP from the channel.
- **Image capture and matching run inside a TEEGRIS trusted app.** `vendor/tee/` holds a TA whose UUID tail decodes to `FINGER` (`00000000-0000-0000-0000-46494e474552`). The HAL is `vendor.samsung.hardware.biometrics.fingerprint@3.0-service`.
  - `libegis_fp_normal_sensor_test.so` is a factory self-test client. Nothing shows it can work while the channel is secure.
- **Verdict:** not reachable from Linux without the TEEGRIS stack.
  - Neither mainline nor libfprint has an ET5xx driver.
  - The AP cannot even clock the SPI controller.
  - Leave the sensor unpowered. If DTS work is wanted later, the only thing worth describing is the LDO enable (gph1-2), so it can be held off.

## GNSS: Broadcom BCM4775 (same chip as the sensor hub)

- GNSS lives in the BCM4775 that also runs the sensor hub. See
  [sensorhub.md](sensorhub.md) for the SPI20 link, the packet/RPC layers and the
  firmware download.
- **AP side:**
  - All GNSS traffic goes as non-sensor RPC packets to `/dev/ttyBCM` and is
    handled by the proprietary `lhd` daemon, together with the vendor GNSS HAL
    (`vendor.samsung.hardware.gnss@2.0-impl.so`, `gps.default.so`).
  - Neither is documented in GPL code.
  - The REA inventory has overviews of `lhd`, `gps.default.so` and the GNSS HAL. Analysis of `gpsd` failed (exit 1 in `firmware/re-targets/INDEX.md`).
- **Verdict:** possible only after the sensor-hub transport works, which is
  phases 1-2 of sensorhub.md.
  - On top of that, the GNSS RPC messages have to be reverse-engineered and exposed as an NMEA/UBX-like stream (for gpsd or ModemManager-free geoclue).
  - That is a separate, large RE project with no GPL reference. Low priority.

## Cameras: S5K3L6 rear and GC5035 front (partly feasible)

- **Rear camera, Samsung S5K3L6:**
  - On I2C_CAM0 (hsi2c_0, 0x10860000) at address 0x2d.
  - DW9808 VCM actuator at 0x0c and a rear EEPROM at 0x58, both on I2C_CAM3 (hsi2c_3).
  - Flash: RT8547. Mainline driver `leds-rt8547` is in drv/misc.
  - Sources: `dtbo-4.dts:878-952`.
- **Front camera, GalaxyCore GC5035:** on I2C_CAM1 (hsi2c_1) at address 0x37 (`dtbo-4.dts:903-920`).
- **The GPL kernel builds these drivers:**
  - CONFIG_CAMERA_CIS_3L6_OBJ, CONFIG_CAMERA_CIS_GC5035_OBJ, CONFIG_CAMERA_ACT_DW9808_OBJ and CONFIG_CAMERA_FLASH_RT8547_OBJ.
  - The sensor drivers come with their full register mode tables (`drivers/media/platform/exynos/fimc-is2/sensor/module_framework/cis/fimc-is-cis-3l6*.{c,h}`, `fimc-is-cis-gc5035*.{c,h}`).
  - Writing V4L2 sub-device drivers for both sensors and the DW9808 is therefore feasible from GPL sources.
  - Mainline has neither sensor driver. The DW9808 is close to the existing dw9714/dw9807 VCM drivers.
- **Receiver path:** MIPI CSIS v4 plus the FIMC-IS "3AA/ISP" chain. The GPL tree has CSIS and FLITE/DMA code (`fimc-is-device-csi_v4.c`, `fimc-is-device-flite.c`, hw/ blocks).
- **Image processing is proprietary DDK code.** It runs on the AP inside the kernel: `vendor/firmware/fimc_is_lib.bin`, about 3.7 MB, loaded and executed by `fimc-is-binary.c`/`fimc-is-interface-wrap*.c`, plus `fimc_is_rta.bin`.
  - Mainline cannot load executable vendor blobs into the kernel.
  - The ISP itself therefore stays out of reach. The `setfile_*.bin` tuning files only matter to that DDK.
- **Verdict:**
  - Realistic target: raw Bayer capture.
    - A new Exynos9810 CSIS v4 + CSIS-DMA (or FLITE) V4L2 driver written from the GPL register code.
    - The two sensor drivers.
    - libcamera's software ISP for debayer and AE/AWB.
  - Large (months), but no step depends on proprietary blobs.
  - Clocks/power: the CAM CMU and the camera LDOs. LDO28/32/34/39/44/45 are described read-only in the board DTS; they need a write-capable S2MPS18 driver (power track).
  - Hardware ISP features (3A, NR, HDR) stay unavailable.

## Summary

| block | verdict | blocker |
|---|---|---|
| fingerprint ET510 | own driver: no; via Samsung's TEEGRIS stack: maybe (6-8 weeks, go/no-go test first) | SPI1 owned by TEEGRIS (TZPC abort confirmed), matching in TA; see fingerprint.md "Path via Samsung's TEE stack" |
| GNSS (BCM4775) | later, large | needs sensor-hub transport first, then GNSS RPC RE (no GPL reference) |
| cameras | raw capture feasible, large | CSIS/DMA driver + 2 sensor drivers + soft ISP; vendor ISP DDK unusable |
