# Cameras: S5K3L6 (rear) and GC5035 (front)

State 2026-10-23: drivers in kernel cand/1023 (r14). On the tablet (Phosh
26102219~test2) both sensors probe (chip IDs right, LDOs on and off through
ACPM), SysMMU ISPPRE reads 0x00000004 (bypass), both cameras stream at
30 fps. The first build stored pixels in 12-bit containers (see "Results");
drv/cam e8606290d switches to 16-bit words, not yet re-tested. This file is
the design summary and the staged on-device test plan for the test skill.

## Results 2026-10-23 (Phosh 26102219~test2, cand/1023 = drv/cam 1f359392e)

- Probe: CSIS 05010000 twice; `s5k3l6 5-002d`, `gc5035 6-0037`; video0 =
  16230000.csis (rear), video1 = 16250000.csis (front).
- Streaming: rear 2064x1548 at 33.33 ms per frame, front 2576x1932 at 30 fps.
- DMA layout with DMA_FMT PACK12 set: 12-bit little endian containers, two
  pixels in three bytes (p0 = b0 | (b1 & 0xf) << 8, p1 = b1 >> 4 | b2 << 4,
  10-bit values), lines padded to 16 bytes (3104 bytes at 2064 pixels, 3872
  at 2576): the buffers sized for MIPI RAW10 were overrun (caught by
  v4l2-grab's 2x guard). Colour bars (test pattern 2) decode to perfect
  GRBG bars with that layout (`bayer2png.py --format le12 --stride 3104`).
- Black level: lens in a dark room, mean 64.0 rear / 64.2 front (10-bit):
  `blackLevel: 4096` confirmed.
- Captures: logs/test-runs/20261023-chunk2/{bars,rear,front}.raw (truncated
  at the old sizeimage).
- e8606290d (16-bit words) live-swapped onto r14: Snapshot shows both
  cameras. Findings and fixes (drv/cam):
  - both previews upside down: DT rotation rear 90 -> 270, front 270 -> 90
    (4ad6ec3fd, needs a kernel package);
  - front went black after a mode switch, "0 DMA starts, 146 DMA errors":
    a 2576-pixel line at 16 bits (5152 bytes) did not fit the 5 KiB half of
    the shared DMA SRAM bank; each receiver now gets a whole 10 KiB bank
    (2f77c736a), and the error log line shows the DMA status and
    DMA_ERR_CODE;
  - bad focus: the rear DW9808 voice coil (stock `fimc-is-actuator-dw9808`
    @0c on I2C_CAM3) is now described and driven by dw9807-vcm with its
    supplies (ce0b68d26, 4ad6ec3fd). libcamera 0.7.2's simple pipeline
    has no lens controls: the position is the V4L2 control
    `focus_absolute` (0-1023, 0 = infinity end) on the lens subdev;
  - rear module EEPROM @58 exposed through at24/nvmem (AF infinity/macro
    DAC codes at 0x3314/0x3320, AWB at 0x3340/0x3364 per the stock DT).

## Design

Raw Bayer straight from the MIPI receiver to memory, image processing in
libcamera's software ISP. The Exynos camera ISP (3AA/ISP/MCSC) is driven by
proprietary firmware that runs inside the vendor kernel and is not ported.

```
S5K3L6 (I2C_CAM0 0x2d) --4 lanes, 1196 Mbps--> CSIS0 + VC DMA0 --> /dev/videoX ("16230000.csis")
GC5035 (I2C_CAM1 0x37) --2 lanes,  897 Mbps--> CSIS2 + VC DMA2 --> /dev/videoY ("16250000.csis")
                                                  \--> libcamera simple pipeline + SoftISP (GPU debayer
                                                       with EGL, else CPU) --> PipeWire --> Snapshot
```

| piece | where | notes |
|---|---|---|
| CSIS v5.1 + VC DMA | `drivers/media/platform/samsung/exynos9810-csis/` | one media device + video node per receiver; RAW10 LSB-aligned in 16-bit words (V4L2 `BA10`/`RG10`, DMA_FMT PACK12 clear), lines padded to 16 bytes; DMA addresses 32-bit, SysMMU ISPPRE left in bypass; ISPPRE bus clocked through ACPM DVFS cam/intcam (690 MHz streaming, 590/630 MHz floor) |
| S5K3L6 | `drivers/media/i2c/s5k3l6.c` | Samsung setfile B (stock DT `setfile = "setB"`): 4128x3096 and binned 2064x1548, both 30 fps, GRBG (flips change the order); gain code/32 (1x-16x); test pattern 0-4 |
| GC5035 | `drivers/media/i2c/gc5035.c` | setfile A: 2576x1932 (897 Mbps) and 1288x966 (448 Mbps), 30 fps, RGGB; total gain in 1/256 (analogue step + digital); OTP defect table on rev WC1XB |
| camera LDOs | `drivers/mfd/sec-acpm.c`, `drivers/regulator/s2mps11.c` | the S2MPS18 bus stays read-only except LDO28/32/34/39/44/45 control (0x65/0x69/0x6b/0x70/0x75/0x76) |
| DT | `exynos9810.dtsi`, `exynos9810-gtactive3wifi.dts` | pins, resets, MCLK (CIS_CLK0/1 from CMU_TOP, 26 MHz) from the stock DT |
| bindings | `samsung,exynos9810-csis.yaml`, `samsung,s5k3l6.yaml`, `galaxycore,gc5035.yaml`, sysreg | dt_binding_check clean |
| libcamera | `patches/libcamera/` | `exynos9810-csis` in the simple pipeline (SoftISP), sensor helpers + properties for `s5k3l6` and `gc5035`; for upstream libcamera. Until it is in postmarketOS: `options exynos9810_csis mc_driver_name=qcom-camss` (modprobe.d) makes the stock libcamera 0.7.2 accept the receiver |

Power: the sensors use runtime PM (on for streaming, off 1 s after). With
CONFIG_PM=n they stay powered from probe (both sensors in software standby,
MCLK running), with CONFIG_PM=y they power down. The CSIS has runtime PM
calls but no power domain in the DT: ISPPRE (PMU 0x14064048) stays on from
the bootloader either way. A real `pd_isppre` needs the DTZPC restore SMC
the stock power domain does (`need_smc = 0x16210204`) after every power-on.

The combo D-PHYs are shared with the display: M4S4_TOP (0x16160000, PMU
isolation 0x70c) is DSIM0 + CSIS0, M4S4_MOD (0x16170000, 0x710) is DSIM1 +
CSIS2. The camera driver only toggles the receive-side reset (SYSREG_ISPPRE
0x16210500 bit 0 / bit 1) and never the isolation, or the panel goes dark.

## Packages and image needs (for the lead / PLATFORM agent)

- Kernel: `drv/cam` merged; Duranium fragment `camera.config` (wired into
  gen-kernel-config.sh); CMA raised to 256 MiB in gtactive3wifi.config for
  the contiguous capture buffers; bring-up fragment
  `configs/gtactive3-camera.config`.
- Already in the Phosh and GNOME images through postmarketOS: `libcamera`
  0.7.2 (pmaports temp/, built with the EGL SoftISP), `libcamera-ipa`,
  `pipewire-spa-libcamera`, `wireplumber`, `snapshot`.
- Device package (PLATFORM agent):
  - `/usr/lib/modprobe.d/gtactive3wifi-camera.conf`:
    `options exynos9810_csis mc_driver_name=qcom-camss`
    (until libcamera carries patches/libcamera/0001).
  - `/usr/share/libcamera/ipa/simple/s5k3l6.yaml` and `gc5035.yaml`
    (SoftISP tuning, below), until libcamera has the sensor helpers.
  - only if stage D shows a second, unusable "16230000.csis" V4L2 camera in
    Snapshot: a WirePlumber rule disabling the raw V4L2 devices,
    `/usr/share/wireplumber/wireplumber.conf.d/50-gtactive3wifi-camera.conf`:
    ```
    monitor.v4l2.rules = [
      {
        matches = [ { api.v4l2.cap.driver = "exynos9810-csis" } ]
        actions = { update-props = { device.disabled = true } }
      }
    ]
    ```
  - only if stage C shows `/dev/udmabuf` without an ACL for the user: a udev
    rule `KERNEL=="udmabuf", TAG+="uaccess"` (libcamera allocates the SoftISP
    output buffers there).
- Dev images: `libcamera-tools` (cam) and `v4l-utils` (v4l2-ctl, media-ctl)
  make stage C easier; the static `tools/v4l2-grab` works without them.

SoftISP tuning file (both sensors, same content; black level 64 at 10 bits,
measured). The Ccm below is a generic sensor-to-sRGB matrix (rows sum to 1),
not calibrated for these modules; it brings the colour saturation up and
enables the Saturation control, but costs time on the CPU debayer: drop it
if the SoftISP runs on the CPU (log `falling back to CPU debayer`).

```yaml
# SPDX-License-Identifier: CC0-1.0
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
      blackLevel: 4096
  - Awb:
  - Ccm:
      ccms:
        - ct: 2800
          ccm: [ 1.60, -0.40, -0.20,
                -0.40,  1.70, -0.30,
                -0.10, -0.80,  1.90 ]
        - ct: 6500
          ccm: [ 1.70, -0.50, -0.20,
                -0.30,  1.60, -0.30,
                 0.00, -0.50,  1.50 ]
  - Adjust:
  - Agc:
...
```

## Staged on-device test

Every stage keeps the usual way back: the bring-up init arms "any reset ->
Download mode" and devd reflashes (loop protection falls back to
boot-good.img); in Duranium the new UKI is boot-counted and the previous
version stays the fallback. Nothing here writes the disk. Run stages in
order; stop at the first failure and use the table under each stage.

Tools on the laptop: `tools/v4l2-grab` (static aarch64, build line in the
file header), `tools/bayer2png.py` (raw frame -> PNG, needs numpy + PIL).

### Stage A: bring-up kernel with the camera drivers

Build: `KSRC=build/wt/cam EXTRA_CONFIGS=configs/gtactive3-camera.config
scripts/build.sh`, boot it the usual bring-up way. All later commands are
console commands (`scripts/tab "..."`).

A1. Before loading anything (read-only):

| check | command | expected | if not |
|---|---|---|---|
| ISPPRE domain on | `peek 0x14064048` (PMU ISPPRE status/config) | same as on Duranium 26102209 (domain on) | domain off: nothing below works; stop |
| SysMMU ISPPRE in bypass | `peek 0x16310000` | bit 0 = 0 (CTRL, not enabled) | enabled: the VC DMA would be translated; do not stream (A4), report |
| SysMMU version | `peek 0x16310034` | non-zero (for the record) | |
| CSIS0 / CSIS2 version | `peek 0x16230000`, `peek 0x16250000` | 0x05010000 | other: wrong block or clock gated |
| PHY isolation | `peek 0x1406070c`, `peek 0x14060710` | bit 0 = 1 (released; the display uses them) | 0: the display PHY is isolated too; stop |
| MCLK CIS_CLK0/1 | `peek 0x1a241018`, `peek 0x1a241814`, `peek 0x1a242018`, `peek 0x1a24201c` | mux OSCCLK, divider 0, gate on (as read on 26102209) | |

A2. Load the receiver (no sensor power yet). The bring-up fragment builds
the media core, v4l2-async and v4l2-fwnode in; the rest are modules:
`insmod /lib/modules/videobuf2-common.ko`, `videobuf2-v4l2.ko`,
`videobuf2-memops.ko`, `videobuf2-dma-contig.ko`, `v4l2-cci.ko` (in that
order), then `insmod /lib/modules/exynos9810-csis.ko`.
Expected dmesg: `exynos9810-csis 16230000.csis: CSIS version 05010000` and
the same for 16250000.csis; no `/dev/video*` yet (it waits for its sensor).

A3. Sensor power and chip ID: `insmod /lib/modules/s5k3l6.ko`, then
`dmesg`.

| result | meaning |
|---|---|
| no error, `/sys/class/video4linux/v4l-subdev*` and `video*` appear, `cat /sys/class/video4linux/video*/name` = `16230000.csis` | regulators on, MCLK, reset, CCI and chip ID 0x30c6 all fine; the media graph is complete |
| `chip id mismatch: 30c6!=...` | I2C works but another device/variant answers: report the value |
| `failed to read chip id: -6` / `-110` (ENXIO/ETIMEDOUT, NACK) | sensor not powered or in reset: check `cat /sys/class/regulator/*/name` + `state` for VDD_CAM_IO_1P8, VDD_RCAM_A2P8, VDD_RCAM_CORE_1P05, VDD_RCAM_AF_2P8 (all `enabled` during probe); reset gpg2-6 high; I2C_CAM0 pins gpc0-0/1 in function 2 |
| `failed to get supply regulators` / probe deferral | s2mps11 did not register LDO28-45 writable: check that the drv/cam s2mps11/sec-acpm are the ones loaded |
| regulator enable `-EPERM` | the PMIC write filter refused: register list in sec-acpm.c |
| `MCLK clock frequency ... is not supported` | CMU_TOP CIS_CLK0 is not at 26 MHz (mux/divider changed since 26102209) |

Then the same with `insmod /lib/modules/gc5035.ko` (chip ID 0x5035, supplies
VDD_CAM_IO_1P8, VDD_FCAM_CORE_1P2, VDD_FCAM_A2P8, reset gpg2-5,
`16250000.csis`).

Regulator values while a sensor is on (stock voltages, approved by the
coordinator): LDO44 1.8 V, LDO32 2.8 V, LDO34 1.05 V, LDO45 2.8 V (rear),
LDO39 1.2 V, LDO28 2.8 V (front). With CONFIG_PM=n the sensors stay
powered after probe; with PM=y `state` goes back to `disabled` 1 s later.

A4. One raw frame from the rear sensor's colour bars (no optics, known
image). Find the nodes: `cat /sys/class/video4linux/*/name` (the
`v4l-subdevN` named `s5k3l6 N-002d`, the `videoN` named `16230000.csis`).
Upload the tool once: `scripts/tab-put build/.../v4l2-grab /run/v4l2-grab`.

```
run /run/v4l2-grab ctrl /dev/v4l-subdevS 0x009f0903 2      # test pattern: colour bars
run /run/v4l2-grab grab /dev/videoV /dev/v4l-subdevS 2064x1548 /run/bars.raw 1 4
```

Expected output:

```
sensor 2064x1548 code 300a                     (MEDIA_BUS_FMT_SGRBG10_1X10)
video 2064x1548 BA10, 4128 bytes/line, 6390144 bytes
4 buffers of 12783616 bytes                     (2x sizeimage, page aligned)
frame 0: seq 0, 6390144 bytes, written up to 63901xx, +0 us
frame 1: seq 1, ..., +33333 us                  (30 fps)
...
wrote 1 frame(s) of 6390144 bytes to /run/bars.raw
```

Pull and look: `scripts/tab-get /run/bars.raw /tmp/bars.raw 6390144`,
`python3 tools/bayer2png.py /tmp/bars.raw 2064 1548 /tmp/bars.png --order GRBG`,
then view bars.png (8 vertical colour bars) and bars.raw.png.

| result | meaning |
|---|---|
| bars straight and coloured | receiver, PHY, DMA layout, stride and Bayer order right |
| `written up to` > sizeimage, `DMA OVERRUN` | the DMA stores another layout. The tool's buffers are 2x and it keeps an overrun frame whole: `bytes / height` is the real stride; try `bayer2png.py --format le12` (the PACK12 layout). Stop before libcamera |
| bars slanted / sheared | stride wrong: retry bayer2png with `--stride` = written bytes / height |
| bars right but very dark (max ~63) or posterized | the 16-bit words are MSB-aligned instead of LSB-aligned: values >> 6; report, the driver would then need a 16-bit format |
| colours swapped (R/B) | Bayer order: try `--order` RGGB/BGGR/GBRG, then fix the driver's mbus code table |
| `no frame within 2000 ms after 0 frames`; dmesg `stream: 0 frame starts, ...` | nothing arrives at the receiver: sensor not streaming (check 0x0100 readback in a debug build), lanes/settle, PHY reset not released (`peek 0x16210500` bit 0 must be 1 while streaming) |
| `N frame starts, 0 DMA starts` | the receiver sees frames but the VC DMA never starts: DMA_DATA_CTRL/OTF path, VC DMA disabled; `peek 0x162b0000` (DMA_CTRL, 0x3 expected), `0x162b0030` (ACT_CTRL) |
| DMA starts but no frames | frame end never comes: DMA error interrupts (counter in the same line), `peek 0x162b0418` (DMA_ERR_CODE) |
| receiver errors with `last 000xxxxx`: bits 16-19 (SOT_HS) or 1 (CRC) | D-PHY settle/skew: the settle value (59 at 1196 Mbps) or the bias block |
| frame interval 66 ms or irregular | ISPPRE bus too slow: the ACPM cam/intcam request failed (`camera DVFS request failed` in dmesg) |
| SError / hang while streaming | the DMA wrote through a translating or blocking SysMMU, or the address is above 4 GiB: check A1 SysMMU, note the reset reason; the watchdog/Download fallback brings the console back |

A5. Real image: `run /run/v4l2-grab ctrl /dev/v4l-subdevS 0x009f0903 0`
(pattern off), point the camera at a lit scene, grab again
(`/run/rear.raw`), convert, look. Black level: grab with the lens covered,
bayer2png prints per-channel min/mean: mean near 64 confirms the tuning
file's `blackLevel: 4096` (measured: 64.0 / 64.2). Full resolution:
`4128x3096` (bytes/line 8256, 25.6 MB per frame) needs the 256 MB CMA;
v4l2-grab's 2x guard buffers (4 x 51 MB) may not fit, so test it with
libcamera.

A6. Front sensor: same with the GC5035 subdev/`16250000.csis` node,
`2576x1932` (bytes/line 5152) and `1288x966`; `--order RGGB`. The GC5035
driver has no test pattern: use a scene.

A7. `rmmod exynos9810_csis gc5035 s5k3l6`: regulators back to `disabled`
(PM=y) and no oops.

### Stage B: Duranium kernel (Phosh image), drivers by hand

Kernel package from drv/cam merged into the candidate + camera.config.
Before the A/B update, keep udev from loading the drivers at the first
boot: `printf 'blacklist exynos9810_csis\nblacklist s5k3l6\nblacklist gc5035\n'
> /etc/modprobe.d/camera-test.conf` on the tablet (root shell, port 2323);
delete the file once B passes.

B1. After booting: `lsmod | grep -E 'csis|s5k3l6|gc5035'` empty; then
`modprobe s5k3l6; modprobe gc5035; modprobe exynos9810_csis
mc_driver_name=qcom-camss` and the A3 checks (`dmesg`, `ls /dev/video*
/dev/v4l-subdev* /dev/media*`).
B2. Raw frames with v4l2-grab (or `v4l2-ctl -d /dev/videoV
--set-fmt-video=width=2064,height=1548,pixelformat=BA10 --stream-mmap
--stream-count=5 --stream-to=/tmp/f.raw` after `media-ctl -d /dev/mediaM
-V '"s5k3l6 N-002d":0 [fmt:SGRBG10_1X10/2064x1548]'`), as A4-A6.
B3. dma-buf permissions for the desktop user: `getfacl /dev/udmabuf
/dev/video* /dev/media* /dev/v4l-subdev*` must list the logged-in user
(uaccess). If udmabuf lacks it, see the udev rule above.

### Stage C: libcamera

C1. `cam -l` (libcamera-tools in a dev image), roughly:

```
Available cameras:
1: 's5k3l6' (/base/soc/i2c@10860000/camera@2d)
2: 'gc5035' (/base/soc/i2c@10870000/camera@37)
```

| result | meaning |
|---|---|
| no cameras, `LIBCAMERA_LOG_LEVELS=SimplePipeline:0 cam -l` says nothing about the media devices | the receiver's media driver name is not one the simple pipeline knows: mc_driver_name not applied (`cat /sys/module/exynos9810_csis/parameters/mc_driver_name`) or a libcamera without the patch |
| `Mandatory V4L2 control ... not available` | sensor driver controls: report |
| `Failed to create camera sensor helper` warning | expected with the stock 0.7.2 (no helper for these sensors): AGC uses raw gain codes, fine |

C2. `cam -c 1 --capture=10 --file=/tmp/frame-#.ppm --stream
pixelformat=RGB888,width=1280,height=960` (SoftISP output), pull a ppm
back, look at it; then `-c 2`. The SoftISP debayers on the GPU when EGL
works (otherwise the log says `EGL not available, falling back to CPU
debayer`).
C3. Frame rate: `cam -c 1 --capture=90` prints per-frame timestamps; 30 fps
expected from the sensor, SoftISP may drop to ~15-30 on the A55s at 2064x1548.

### Stage D: PipeWire and Snapshot (Phosh)

D1. `wpctl status` (as the user): two libcamera Video sources (names from
the sensors) under Video Sources. A raw V4L2 node next to them means the
WirePlumber rule above is needed.
D2. Open Snapshot (ask the user to tap it, or `gtk-launch org.gnome.Snapshot`
in the user session), switch cameras, take a photo; screenshot through
the Phosh/Mutter screenshot D-Bus API and pull it back; the photo lands
in ~/Pictures/Camera.
D3. Rotation: the preview must be upright in portrait for both cameras.
The DT `rotation` (rear 90, front 270) is a first guess from Android
convention; fix it in the DT if the image is turned.

### Expected register values (reference)

| what | address | value |
|---|---|---|
| CSIS version | 0x16230000 / 0x16250000 | 0x05010000 |
| CSIS0 CMN_CTRL streaming | 0x16230004 | CSI_EN (bit 0) = 1, LANE_NUMBER (9:8) = 3, INTERLEAVE (11:10) = 2 |
| CSIS2 CMN_CTRL streaming | 0x16250004 | bit 0 = 1, LANE_NUMBER = 1 |
| ISP_CONFIG_CH0 | +0x40 | 0x10ac (dual pixel, data type 0x2b RAW10, VC 0) |
| ISP_RESOL_CH0 | +0x44 | height << 16 \| width |
| PHY_CMN_CTRL | +0x704 | ENABLE_CLK (bit 0) + ENABLE_DAT (4:1) = 0x1f rear, 0x07 front |
| VC DMA0 CTRL / FMT | 0x162b0000 / 0x162b0004 | 0x3 / 0x0 (RAW10 in 16-bit words, 2D, legacy) |
| VC DMA0 RESOL | 0x162b0040 | width |
| D-PHY slave reset | 0x16210500 | bit 0 (CSIS0) / bit 1 (CSIS2) = 1 while streaming |
| D-PHY settle (rear) | 0x161628b0 + 0x400 * lane | 59 (1196 Mbps); front 0x161728b0: 44 (897 Mbps) |
| S5K3L6 chip ID | I2C 0x2d, reg 0x0000 (16-bit) | 0x30c6 |
| GC5035 chip ID | I2C 0x37, reg 0xf0, 0xf1 | 0x50, 0x35 |
| PMIC LDO ctrl when on | S2MPS18 0x65/0x69/0x6b/0x70/0x75/0x76 | 0xe8/0xe8/0xdc/0xe8/0xec/0xe8 (bits 7:6 = 11, then vsel) |
