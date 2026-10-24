# BCM4775 GNSS + sensor hub: how accel and light reach the AP, and what mainline needs

Our own description of the sensor path of the SM-T570 (Galaxy Tab Active3,
board hw_rev 4 = `dtbo-4`, HARDWARE.md:84), written from:

- Samsung's GPL driver `drivers/sensorhub/brcm/` in the T570-family kernel
  (`build/ref/gtactive3cs`, defconfig `exynos9810-gtactive3ue_defconfig`),
  cross-checked against the Galaxy S9 copy in `src/samsung-9810-ref`
  (same bbdpl code, different patch blob);
- the stock device tree (`firmware/stock/stock-0.dts`, `dtbo-0..5.dts`);
- vendor config (`firmware/fs/vendor/etc/sensor/lhd.conf`,
  `vendor/etc/init/init.gps.rc`, `vendor/ueventd.rc`);
- `strings -n 6` of the vendor binaries `vendor/bin/hw/lhd`,
  `vendor/lib64/sensors.sensorhub.so` and of the hub firmware image
  `firmware/re-targets/bcm_sensorhub_a1.blob.bin`;
- the REA/Ghidra inventory in `firmware/re-targets/` (only binary overviews
  exist so far: procedure and string counts, no protocol findings;
  `analysis/gnss-lhd.json`, `analysis/fw-bcm-sensorhub.json`).

No Samsung/Broadcom code and no decompiled code is reproduced; only message
layouts, constants and sequences, described in our own words.

Path shorthands: `GPL/` = `build/ref/gtactive3cs/drivers/sensorhub/brcm/`,
`BBD/` = `GPL/bbdpl/`, `DT4` = `firmware/stock/dtbo-4.dts`,
`DT3` = `firmware/stock/dtbo-3.dts`, `DT0` = `firmware/stock/stock-0.dts`.

Status markers: **[GPL]** from the GPL source, **[DT]** stock device tree,
**[CFG]** vendor config, **[STR]** strings in a vendor binary, **[FW]** hub
firmware image, **[VER]** checked by us with a script, **[?]** inferred, not
verified.

---

## 0. Short answer

- On our board (rev 4/5) accelerometer (TDK ICM-42605M), light/proximity
  (ams TMD3725), magnetometer (AKM AK09916) are wired to the **Broadcom
  BCM4775 B0** GNSS chip's own sensor-hub MCU, not to the AP. The AP sees one
  SPI device (`spi_20`, compatible `ssp,BCM4773`) plus handshake GPIOs.
  Nothing on any AP I2C/SPI bus, and nothing on the Exynos CHUB, reaches the
  sensors. (Early boards rev 0-3 had them directly on AP buses; see 1.3.)
- The hub runs a RAM patch (`bcm_sensorhub_a1`, ~400 KB, embedded in the stock
  kernel) that must be downloaded after every power-up. **The download and
  the chip power/reset sequencing are done by the proprietary userspace
  daemon `lhd`.** The kernel only exposes the patch file and a raw byte pipe.
- Everything *after* the hub firmware runs is documented by GPL code: the SPI
  link ("SSI"), the packet layer (framing, escaping, CRC-8, flags), the RPC
  wrapper for sensor data, and Samsung's SSP sensor protocol (enable, rate,
  data records). We verified the CRC and framing on two sample frames that
  ship in the GPL code.
- (2026-10-22) The ROM handshake, patch download and host packet-layer
  behaviour are now known from lhd (6.3); a lhd-free kernel driver is in
  `src/linux` branch `drv/shub` (drivers/iio/common/bcm4775_shub).
- (2026-10-23) Rebased onto cand/1024 as `drv/shub2` (worktree
  build/wt/shub2): LDO37 joins the switchable-LDO whitelist of drv/hwgaps,
  DT binding `iio/brcm,bcm4775.yaml`, SPI20 + hub node (touch = spi0.0,
  hub = spi1.0 via aliases), mount matrix diag(-1,-1,1) (hub = Android
  frame, iio-sensor-proxy wants the gravity vector: y < 0 = upright).
  Still untested on the device. The hwdb ACCEL_MOUNT_MATRIX cannot be used
  (systemd's 60-sensor.rules only matches usb/i2c/platform parents).
- (2026-10-24) On the device (r23, cand/1032): download and hub start
  work, but SENSOR_SCANNING stays 0 until S2MPS18 LDO35 VDD_SENSOR_1P8,
  LDO42 vdd_proxy_led_3p3 (3.3 V) and LDO43 (3.3 V) are on: the stock DT
  keeps them always-on (DT4:3752-3759, 3819-3828, 3830-3837), S-Boot
  leaves them off. With them on: sensors 0x50d730e07f69f, accel range 8,
  20 Hz accel through IIO, iio-sensor-proxy and Phosh auto-rotate
  (logs/test-runs/2026-10-24-shub). Fix: src/linux drv/shub3. The hub's
  "CPUART: NOT COMPLETE(WR)" messages appear either way (not the cause).
- Previously missing for a lhd-free mainline: (a) exact power/NSTDBY timing (small),
  (b) the ROM bootloader handshake and patch download protocol (the real
  unknown), (c) the host TX side of the packet layer (sequence numbers, acks,
  "sync" handshake: inferable from the RX side, but details need a capture),
  (d) the RPC wrapping of host->hub sensor commands (inferable, needs capture).
- **Verdict: feasible, medium-high effort, one high-risk item (patch
  download).** The cheapest way to retire that risk is to capture a full SPI
  trace of a stock boot: the stock kernel already contains a hex dumper for
  every SPI frame, enabled by a control string (section 9). With that trace
  the download can be replayed/reimplemented without reverse engineering lhd.

---

## 1. Hardware

### 1.1 Chips (rev 4/5 = our tablet)

| function | chip | where | evidence |
|---|---|---|---|
| GNSS + sensor-hub MCU | Broadcom BCM4775 B0 ("4775.B0 FlagtailPatch ver. 545126"), AsicVersion 0x004775B0 | AP `spi_20`, CS0 | DT4:4756-4799; patch header `<AsicVersion=0x004775B0>` (BBD/q_os/bbd_patch_file_tab_active_3.h:4); **[FW]** version string |
| accel + gyro | TDK ICM-42605M | hub's SPI master | defconfig `CONFIG_SENSORS_SSP_ICM42605M=y` (5262); **[FW]** "SSP_ACC ... Icm426xx", "MCU_SPI_Sensor_Read", "csPin" |
| ambient light + proximity | ams TMD3725 | hub's I2C master **[?]** | defconfig `CONFIG_SENSORS_SSP_TMD3725=y` (5284); **[FW]** "SSP_l TMD3725 probe fail", "Light_Ambient_TMD3725_Register_RW", "patch_i2cm.c" |
| magnetometer | AKM AK09916 | hub's I2C master **[?]** | DT4:4791 `ssp-mag-type=1` (AKM); **[FW]** "GeoMagnetic_AK09916_Register_RW" |
| pressure | LPS22H claimed by defconfig (5276) | ? | **[FW]** no LPS22 driver strings, only "PD: BaroDisabled": probably not fitted **[?]** |

"on the hub's I2C/SPI" is inferred from the firmware strings and from the
fact that the AP pins formerly used by these sensors are re-purposed for the
hub on rev 4 (1.3). No schematic was available.

### 1.2 AP side of the link (DT4)

SPI controller: `spi_20` = USI_CHUB00 at 0x13AC0000, GIC SPI 104
(DT0:5877-5891, `interrupts = <0 0x68 0>`), USI put into SPI mode by
DT4:3199-3205 (`usi_00_chub`). It is a CHUB-domain USI driven directly by
the AP; pins are in pinctrl@13A80000 (CHUB pinctrl, bank gph0).

| DT property | pin | dir (AP) | function | evidence |
|---|---|---|---|---|
| SPI SCLK/MOSI, CS | gph0-0, gph0-1, gph0-3 (func 2) | out | SPI, CS also as `cs-gpio` gph0-3 | DT4:4661-4668, 4795-4797 |
| SPI MISO | gph0-2 (func 2, pull-down) | in | SPI | DT4:4670-4677 |
| SPI mode | 25 MHz max (`0x17d7840`), CPOL=1 CPHA=1 (mode 3) | | | DT4:4770-4772 |
| `ssp-host-req` | gpa2-1, EINT, pull-down | in, IRQ | chip -> AP "I have data"; level-high IRQ, wake source | DT4:4736-4743, 4778; BBD/bcm_gps_spi.c:1183, 1265 |
| `ssp-mcu-req` | gpp2-1, output | out | AP -> chip "wake up, I want to talk" | DT4:4697-4706, 4779; bcm_gps_spi.c:1190-1199, 509 |
| `ssp-mcu-resp` | gpp2-0, input | in | chip -> AP "awake" (ack of mcu-req) | DT4:4686-4695, 4780; bcm_gps_spi.c:1200-1209, 510 |
| `ssp-gps-pwr-en` | gpg0-4, output, pull-down | out | chip NSTDBY (out-of-standby / reset). Kernel only exports it to sysfs `/sys/class/sec/gps/GPS_PWR_EN`; lhd drives it | DT4:4708-4719, 4777; bcm_gps_spi.c:1211-1224; lhd.conf `GpioNStdbyPath` |
| `ssp-batch-wake-irq` | gpa2-0 | out (!) | despite the name, driven as an output "AP SLEEP" (AP suspend notification, pulsed low at suspend) | DT4:4726-4734, 4781; GPL/ssp_dev.c:389-398, 1094-1096, 1122 |
| `ssp-shub-int` | gpa4-0, EINT, pull-down | in, IRQ | hub -> AP falling-edge pulse used only to timestamp gyro samples (camera VDIS) | DT4:4745-4752, 4782; ssp_dev.c:339-349, 858-860 |
| `ssp-vdd-mcu-1p8` | regulator `vdd_mcu_1p8` = S2MPS18 LDO37, 1.8 V, not always-on | | hub/MCU supply, switched by lhd through `/sys/class/sec/sensorhub/mcu_power` | DT4:3771-3778, 4792; ssp_dev.c:364-372; GPL/ssp_sysfs.c:557-590, 1297-1299; lhd.conf `GpioNPowerPath` |
| (related) `vdd_proxy_led_3p3` | S2MPS18 LDO42, always-on | | name suggests TMD3725 IR LED supply **[?]** | DT4:3819-3827 |

Other node properties (passed to the hub during init, 6.6):
`ssp-acc-position=5`, `ssp-mag-position=0`, `ssp-glass-type=0`,
`ssp-mag-array` (27-byte soft-iron matrix, overridden by DT4 fragment@97),
`ssp-thermi-up/-sub` (thermistor ADC tables) (DT4:4783-4791).

Not used on this board: `bcm_gps_hostwake.c` (`CONFIG_BCM_GPS_HOSTWAKE_DRIVER`
unset, BBD/Makefile:6), the TTY/I2C transport variants (defconfig 5330-5333).

### 1.3 Board history: rev 0-3 had the sensors on the AP

DT3 (and dtbo-0..2) for hw_rev 0-3 ("EUR OPEN BRINGUP/00/01/02") describe a
completely different sensor wiring on the *same* AP pins:

- `spi_20` carries `tdk,icm42605m` directly (DT3:4818-4844), IRQ on gpa2-0,
  second INT on gpa2-1 (DT3:4688-4705);
- `hsi2c_12` (USI_4, pins gpp2-0/gpp2-1) carries `ak09916c-i2c@0c` and
  `taos,tmd3725@39` with IRQ gpa4-0 (DT3:4674-4680, 4765-4816);
- GNSS was a separate BCM4753 (`samsung,exynos54xx-bcm4753`, DT3:2234-2238).

On rev 4/5 those pins became the hub's SPI, mcu-req/resp, host-req,
batch-wake and shub-int (table above), and `hsi2c_12` disappears. So on our
tablet **the sensors are not reachable from the AP**; mainline drivers
(`inv_icm42600` exists in src/linux `drivers/iio/imu/inv_icm42600/`) would only
help a rev 0-3 prototype board.

### 1.4 Exynos CHUB is not used as a sensor hub

- Stock DT has no contexthub/nanohub node; the only CHUB-domain nodes are the
  four USI selector registers at 0x13A13000-0x13A1300C, all disabled in the
  base DT (DT0:4521-4551). The overlay enables `usi_00_chub` and
  `usi_01_chub` in SPI mode only (DT4:3199-3215) so that the AP can drive
  SPI20 (sensor hub) and SPI21 (touchscreen) directly.
- The defconfig has no CHUB/CONTEXTHUB/NANOHUB option (grep of
  `exynos9810-gtactive3ue_defconfig` finds none), and
  `firmware/extracted/INDEX.md` lists no CHUB firmware.
- So the CHUB Cortex-M core stays off; only its clock domain/USIs/pinctrl
  are borrowed. The cpu/touch work (branch drv/cpu, not yet in `integ`)
  already models this for SPI21 (`arch/arm64/boot/dts/exynos/exynos9810.dtsi`
  `cmu_chub` and `usi_chub01`, and `drivers/clk/samsung/clk-exynos9810.c`
  with the USI_CHUB00 gates), so SPI20 is a small DT addition on top.

---

## 2. End-to-end data path (stock)

```
ICM42605M --(hub SPI)--> BCM4775 hub MCU (patch firmware, SSP engine)
   hub builds SSP record -> wraps in RPC 0x21 -> packet layer (ESC/SOP..CRC..ESC/EOP)
   -> SSI frame on SPI20, raises HOST_REQ
AP kernel:
   HOST_REQ IRQ -> bcm_gps_spi rx/tx work: MCU_REQ/MCU_RESP handshake, SSI read
   -> bbd_parse_asic_data() (packet layer RX, CRC check)            [kernel]
      |- packet contains RPC 0x21 (sensor response) -> bbd_sensor_write()
      |     -> ssp_bbd.c callback_bbd_on_packet() -> SSP reassembly
      |     -> ssp_data.c parse_dataframe() -> ssp_iio.c -> /dev/iio:deviceN
      |        -> sensors.sensorhub.so (HAL) -> Android
      '- anything else (GNSS RPCs, acks, ROM/boot traffic) -> raw escaped bytes
            -> /dev/ttyBCM read buffer -> lhd
AP -> hub (enable accel, set rate):
   HAL writes /sys/class/sensors/ssp_sensor/enable, poll_delay
   -> ssp_sysfs.c -> ssp_i2c.c send_instruction() -> ssp_bbd.c bbd_do_transfer()
   -> bbd_send_packet(): [u16 len][SSP bytes] queued on /dev/bbd_sensor
   -> lhd reads it, wraps into RPC (0x20 [?]) + packet layer, writes /dev/ttyBCM
   -> bcm_gps_spi TX work -> SSI write frame on SPI20 -> hub
```

Who does what:

| layer | RX (hub -> AP) | TX (AP -> hub) |
|---|---|---|
| SSI/SPI link + GPIO handshake | kernel (bcm_gps_spi.c) | kernel |
| packet layer (framing, CRC, seq, flags) | kernel for sensor packets (bbd_rpc_lh.c); lhd for everything else | **lhd only** |
| reliable channel, acks, TL sync | **lhd** (kernel parses flags but never sends acks, bbd_rpc_lh.c:488-547) | **lhd** |
| RPC (id/len TLV) | kernel extracts RPC 0x21 only | **lhd** |
| SSP protocol | kernel (ssp_*.c) | kernel builds the SSP bytes; lhd only carries them |
| power, NSTDBY, ROM handshake, patch download, crash recovery | **lhd** | **lhd** |

### 2.1 /dev nodes and control strings

| node | created by | direction | content |
|---|---|---|---|
| `/dev/ttyBCM` (misc, dynamic minor) | BBD/bcm_gps_spi.c:1276-1281 | lhd read: chip bytes the kernel did not consume (escaped packet-layer stream); lhd write: complete packet-layer frames to send | 32 KB rings each way (bcm_gps_spi.h `BCM_SPI_READ/WRITE_BUF_SIZE` = 8 pages) |
| `/dev/bbd_sensor` (major 239, minor 1) | BBD/bbd.c:1104-1152, 1041-1049 | read-only for lhd: SSP packets from the kernel, each prefixed by a little-endian u16 length (bbd.c:335-349) | lhd turns them into RPC frames |
| `/dev/bbd_control` (239/2) | bbd.c:1050-1058 | lhd writes status strings; kernel pushes requests to lhd | see below |
| `/dev/bbd_patch` (239/3) | bbd.c:1059-1067, 764-781 | read-only file = the embedded patch text (bbd.c:131-137) | lhd reads it (`LhePatch=/dev/bbd_patch`, lhd.conf) |
| `/dev/bbd_shmd` (239/0) | not registered (bbd.c:1117-1119) | internal kernel ring for SSP | |
| `/sys/bbd/bbd` (write) | bbd.c:789-793, 855 | same parser as `/dev/bbd_control` | debug switches |

Control strings (BBD/bbd.h:49-71, handled in bbd.c:448-522, ssp_bbd.c:310-340):
lhd -> kernel: `ESW:READY` (hub firmware is up: kernel starts SSP init),
`ESW:NOTREADY`, `ESW:CRASHED`, `SSI:PassThru=1/0` (patch download begin/end,
holds a wakelock), `GPSD:CORE_ON/OFF`, `LHD:STOP <reason>`, debug switches
`SSP:DEBUG=1`, `SSI:DEBUG=1`, `PZC:DEBUG=1`, `RNG:DEBUG=1`.
kernel -> lhd: `BBD:RESET_REQ` (SSP timed out, please reset the hub,
bbd.c:411-432), `GPSD:SENSOR_ON/OFF`.

---

## 3. SSI: the SPI link layer (GPL, BBD/bcm_gps_spi.c, bcm_gps_spi.h)

### 3.1 Control byte (first MOSI byte of every transfer)

| bit | meaning (bcm_gps_spi.h:25-41) |
|---|---|
| 7 | 1 = debug/register-access mode, 0 = stream mode |
| 6 | 1 = full duplex, 0 = half duplex |
| 5 | 1 = read, 0 = write (full duplex always uses "write") |
| 4 | 1 = 2-byte length fields, 0 = 1-byte |
| 3 | 1 = flow control (write-acknowledge count) enabled |

Stock settings: full duplex, 2-byte lengths, flow control with 3 retries
(bcm_gps_spi.c:59-62), giving **TX control byte 0x58 and RX control byte
0x50** (computed in bcm_spi_open, bcm_gps_spi.c:252-288). These are global
and not changeable by lhd, so the ROM bootloader must accept this mode too.
Frame size limit 8 KB (bcm_gps_spi.h:119-130). All transfers are plain
8-bit `spi_sync` (the bits_per_word argument is ignored, bcm_gps_spi.c:631-657).

### 3.2 Wake handshake (every work-item)

1. Drive MCU_REQ high, poll MCU_RESP for up to ~100 ms (1 ms steps, then
   1 ms sleeps); every 20 polls pulse MCU_REQ low/high again
   (bcm477x_hello, bcm_gps_spi.c:501-541).
2. On timeout: log, request a hub reset (`bbd_mcu_reset`) and stop
   (bcm_gps_spi.c:901-907).
3. After the transfer loop: drop MCU_REQ ("bye", bcm_gps_spi.c:547-550) and
   re-enable the HOST_REQ IRQ.

### 3.3 Work loop (bcm_rxtx_work_func, bcm_gps_spi.c:889-1030)

The HOST_REQ level-high IRQ (bcm_gps_spi.c:1038-1064) disables itself and
queues the work; a write() to `/dev/ttyBCM` queues the same work. Loop while
HOST_REQ is high or TX data is pending: if HOST_REQ, do one RX frame; if TX
bytes are queued, send up to one frame.

### 3.4 RX frame (bcm_ssi_rx, bcm_gps_spi.c:790-858)

Two SPI transactions:

1. 3 bytes MOSI `[0x50][00 00]` -> MISO `[status][len lo][len hi]`.
2. `len + 3` bytes MOSI `[0x50][00 00][zeros]` -> MISO
   `[status][len lo][len hi][len bytes of chip stream]`. The length is
   re-read and the smaller value used. If `len` was 0 the host reads 254
   bytes anyway. The payload goes to the packet-layer parser.

### 3.5 TX frame (bcm_ssi_tx, bcm_gps_spi.c:660-782)

MOSI `[0x58][M lo][M hi][M payload bytes][2-byte FC field, sent as 0]`.
Simultaneously MISO returns `[status][N lo][N hi][chip stream bytes...]`
and, at offset `3 + M`, a 2-byte "bytes accepted" count. If the chip
accepted fewer than M bytes, the remainder is moved to the front and resent
(max 3 attempts). Chip bytes received during a write are fed to the same
parser (full duplex piggy-back).

### 3.6 Status byte ("PZC", bcm_gps_spi.c:169-206, bcm_gps_spi.h:43-63)

bits 2:0 = count, bits 4:3 = block-size index {32, 256, 2048, 16384},
bit 6 = protocol error. Free space in the chip's RX ring = count x size; the
host waits 1 ms if it wants to send more than that.

### 3.7 Register/debug mode (BBD/bcm_gps_regs.c)

Control byte 0x80/0xA0 gives access to the SSI block's own command registers
and, through them, 32-bit AHB reads/writes into chip memory
(RegRead/RegWrite bcm_gps_regs.c:158-259, bcm_reg32Iwrite/Iread 275-419;
used for HSI_CTRL/RNGDMA debug dumps in bcm_spi_open). An unused helper
`bcm477x_rpc_get_version` (bcm_gps_regs.c:48-141) documents how to talk to
a chip that may still be in ROM: a 32-byte burst of 0x80 as "autobaud", then
a half-duplex stream write (control 0x00, no length field) carrying one
packet-layer frame "get version", then polling reads. This helper is the
only kernel-side hint about the ROM phase.

---

## 4. Packet layer (GPL RX side, BBD/bbd_rpc_lh.c)

Broadcom calls it TransportLayer. Same format in both directions
(the host TX side lives in lhd, but the GPL "get version" example frame in
bcm_gps_regs.c:71 uses it, and its CRC checks out, **[VER]**).

### 4.1 Byte stuffing

| byte | meaning |
|---|---|
| 0xB0 0x00 | start of packet (ESC SOP) |
| 0xB0 0x01 | end of packet (ESC EOP) |
| 0xB0 0x03 | literal 0xB0 |
| 0xB0 0x04 | literal 0x11 (XON) |
| 0xB0 0x05 | literal 0x13 (XOFF) |
| raw 0x11 / 0x13 | dropped by the receiver (UART soft flow control legacy) |

(bbd_rpc_lh.c:98-109, parser 575-674.) Bytes outside packets count as garbage.

### 4.2 Unstuffed packet

```
[seq u8][size u8][flags u8][flag-detail bytes...][payload: size bytes][crc u8]
```

- Flag details: one byte per set flag bit, in increasing bit order.
- If flag bit 7 (EXTENDED) is set, its detail byte is OR-ed in as flag bits
  15:8 and parsing continues; if bit 6 (SIZE_EXTENDED) is set, its detail is
  the size MSB (bbd_rpc_lh.c:415-471).
- A packet is valid only when all flags were understood and the remaining
  length equals `size` (bbd_rpc_lh.c:474).

| flag bit | name | detail byte |
|---|---|---|
| 0 | ACK | sequence number being acknowledged |
| 1 | RELIABLE | reliable sequence number of this packet |
| 2 | RELIABLE_ACK | acked reliable seq |
| 3 | RELIABLE_NACK | last good reliable seq |
| 4 | MSG_LOST | number of packets the peer lost |
| 5 | GARBAGE | garbage bytes the peer saw (capped 255) |
| 6 | SIZE_EXTENDED | size bits 15:8 |
| 7 | EXTENDED | flag bits 15:8 |
| 8 | INTERNAL | packet is for the transport layer itself (sync, version, ...) |
| 9 | IGNORE_SEQID | do not count sequence gaps |

(bbd_rpc_lh.c:113-132.) Receiver behaviour: sequence gaps are counted;
an ACK is owed for payload packets but delayed until 200 are outstanding;
reliable packets are deduplicated by (reliable seq, CRC, length) and answered
with ACK+RELIABLE_ACK, or RELIABLE_NACK on an out-of-order reliable seq
(bbd_rpc_lh.c:474-547). Customisation constants: max packet 2048 B, reliable
retry 1000 ms, 10 retries, 150 reliable packets in flight
(bbd_rpc_lh.c:60-84).

### 4.3 CRC

CRC-8, polynomial 0x4D, MSB-first, initial value 0, computed over the
unstuffed bytes from `size` up to the last payload byte (i.e. excluding the
sequence number and the CRC itself); the result is sent with its two nibbles
swapped (bbd_rpc_lh.c:232-272, 371-391). **[VER]**: our script reproduces the
CRC of all three sample frames in the GPL code: the sensor packet in
bbd_rpc_lh.c:682-684 (CRC 0xB2), and the get-version request/response in
bcm_gps_regs.c:71 and :76 (0xB1, 0x43).

### 4.4 Worked examples (from the GPL samples, decoded by us)

Get-version request (host -> chip, bcm_gps_regs.c:71), after the SSI byte:
`B0 00 | 00 02 80 03 00 00 | 00 01 | B1 | B0 01` =
seq 0, size 2, flags 0x80 + detail 0x03 -> flags 0x0380 (EXTENDED, INTERNAL,
IGNORE_SEQID), details 00 00, payload `00 01`, CRC 0xB1.

Version response (comment at bcm_gps_regs.c:76): seq 0, size 8, flags
0x0180 (INTERNAL), payload `01 01 00 00 FF 00 00 FF`, CRC 0x43.

Sensor packet (bbd_rpc_lh.c:682-684, from an old 4773 firmware): seq 0x85,
size 0x26, flags 0, payload = one RPC (id 0x21, len 0x24) containing a 34-byte
SSP stream, CRC 0xB2.

### 4.5 RPC layer inside the payload

Payload = sequence of TLVs `[id][len][data]`; id and len are 1 byte, or 2
bytes big-endian when the first byte has bit 7 set (the bit is masked off)
(bbd_rpc_lh.c:299-369). The RPC id list is a frozen enum (bbd_rpc_lh.c:137-172);
only the last two matter to us:

| id | name | dir | data |
|---|---|---|---|
| 0x20 (32) | sensor request | AP -> hub | **[?]** by symmetry: `[u16 LE length][SSP bytes]`, built by lhd |
| 0x21 (33) | sensor response | hub -> AP | `[u16 LE length][SSP bytes]`, the kernel checks length == RPC len - 2 (bbd_rpc_lh.c:278-294) |

A packet that contains at least one 0x21 RPC is consumed by the kernel and
not forwarded to lhd; all other packets (and INTERNAL ones) are copied raw
(still stuffed) into `/dev/ttyBCM` (bbd_rpc_lh.c:548-561).

---

## 5. SSP: Samsung Sensor Protocol over the RPC (GPL ssp_*.c)

### 5.1 AP -> hub message header (9 bytes, little-endian, packed)

| off | size | field |
|---|---|---|
| 0 | 1 | cmd (instruction code, 5.4) |
| 1 | 2 | length of the data phase (0 = header-only command) |
| 3 | 2 | options: bits 1:0 type (0 = AP2HUB_READ, 1 = AP2HUB_WRITE, 2 = HUB2AP_WRITE), bit 2 = RETURN (want a 1-byte result after a write), bits 4:3 gyro DPS / index |
| 5 | 4 | data (immediate u32 argument for header-only commands) |

(GPL/ssp.h:596-625; sent by ssp_bbd.c:117-118 `bbd_send_packet(msg, 9)`.)

### 5.2 Hub -> AP header (4 bytes)

`[options u16][length u16]`, then data (ssp_bbd.c:695-823, 446-602).

### 5.3 Transactions

- **Command without data** (`length = 0`, e.g. AP state changes): send the
  9-byte header; no reply expected (ssp_bbd.c:113, ssp_i2c.c:182-209).
- **Write** (`AP2HUB_WRITE`, length L): send header; the hub answers with a
  4-byte header whose type is WRITE and whose options equal ours; then the AP
  sends the L data bytes. If RETURN was set, the hub later sends a READ|RETURN
  header + 1 result byte. Matching is by exact options value, so the kernel
  serializes all transactions (ssp_bbd.c:761-783, comm_mutex in 92).
- **Read** (`AP2HUB_READ`, length L): send header; hub answers with a READ
  header followed by L bytes (ssp_bbd.c:746-754, 796-808).
- **Unsolicited data** (`HUB2AP_WRITE`): header with type 2 and a length,
  followed by a data frame parsed by `parse_dataframe` (ssp_bbd.c:755-760,
  809-813). After every third such frame the AP sends instruction 0xA7 with
  its current boottime in ns (s64) so the hub can stamp samples in AP time
  (ssp_bbd.c:673-691, 758-759).
- Timeout: 400 ms (1000 ms if >5 s since resume) per transaction; on timeout
  the kernel schedules a hub reset (ssp_i2c.c:34-46, ssp_bbd.c:147-205).

### 5.4 Instruction codes we need (GPL/ssp.h)

| code | name | dir/type | payload |
|---|---|---|---|
| 0x0F | WHOAMI | READ, 1 byte | answer must be 0x55 (ssp.h:82, 224; ssp_i2c.c:499-532) |
| 0xF1 | SENSOR_FORMATION | WRITE, 3 bytes | accel position, gyro position (= accel), mag position (ssp_i2c.c:534-570) |
| 0xEC | GLASS_TYPE | WRITE | DT `ssp-glass-type` (ssp.h:217) |
| 0xF4 | SENSOR_SCANNING | READ, 8 bytes | u64 bitmap of sensors the hub found, bit n = sensor id n (ssp_i2c.c:848-877) |
| 0xF0 | FIRMWARE_REV | READ, 4 bytes | u32 (ssp_i2c.c:879-902) |
| 0xE1 | GET_ACCEL_RANGE | READ | accel full-scale (ssp.h:214) |
| 0xA1 | SENSOR ADD (enable) | WRITE, 10 bytes | `[sensor id][s32 period ms][s32 max batch latency ms][s8 batch flags]` (ssp_sysfs.c:147-157, ssp_i2c.c:236-301) |
| 0xA4 | CHANGE_DELAY | WRITE, 10 bytes | same layout as ADD (ssp_sysfs.c:179-182, 221-224) |
| 0xA2 | SENSOR REMOVE | WRITE, 5 bytes | `[sensor id][s32 period]` (ssp_sysfs.c:285-286) |
| 0xA7 | CURRENT_TIMESTAMP | WRITE, 8 bytes | AP boottime ns |
| 0xD1..0xD5 | AP status wakeup/sleep/resume/suspend/reset | header-only | (ssp.h:200-205) |
| 0x49 / 0x50 | set/get light coefficients | WRITE / READ | optional (ssp.h:273-274) |

ADD/CHANGE/REMOVE are only sent for sensors present in the scanning bitmap
(ssp_i2c.c:223-228). Batch latency 0 means "bypass", i.e. report every
sample (ssp_i2c.c:312-319).

### 5.5 Sensor ids (GPL/sensor_list.h:22-80)

`ACCELEROMETER = 0`, `GYROSCOPE = 1`, `GEOMAGNETIC_UNCALIB = 2`,
`GEOMAGNETIC_RAW = 3`, `GEOMAGNETIC = 4`, `PRESSURE = 5`, `PROXIMITY = 7`,
**`LIGHT = 9`**, `PROXIMITY_RAW = 10`, `LIGHT_IR = 24`, `LIGHT_CCT = 31`,
`ACCEL_UNCALIB = 33`, `UNCAL_LIGHT = 40`, `AUTO_ROTATION = 48`
(the hub can even compute the screen orientation itself).

### 5.6 Data frames (hub -> AP, GPL/ssp_data.c:751-907)

A HUB2AP data frame is a sequence of records, each starting with an
instruction byte:

| byte | record | layout after the byte |
|---|---|---|
| 0x37 | sensor sample ("bypass data") | `[sensor id u8][sample][u64 timestamp ns, AP boottime]` (ssp_data.c:775-812, 94-174) |
| 0x0A | sensor init done | none (completes `mcu_init_done`, ssp_data.c:770-773) |
| 0xA8 | timestamp offset | `[u64 hub time]` (ssp_data.c:735-745) |
| 0x05 | meta (flush complete) | `[what u8 = 1][sensor id]` |
| 0x03 | debug text | (print_mcu_debug) |
| 0x04 | big data | `[u32 len][u32 addr]` |
| 0x06, 0x08, 0x09, 0x0B, 0x0C, 0x97 | time sync, gyro/mag cal, bigdata, scontext, prox cal | not needed |

Unknown instruction bytes abort the frame (ssp_data.c:890-906).

Sample sizes:

| sensor | bytes | layout |
|---|---|---|
| accelerometer (0) | 6 | s16 x, s16 y, s16 z, already rotated by the hub per SENSOR_FORMATION (ssp_data.c:176-181, sensor_list.h:98) |
| light (9) | 21 | s32 lux, s32 cct, u16 r, u16 g, u16 b, u16 w (clear), u16 atime, u16 again, u8 brightness (ssp.h:480-491, ssp_data.c:231-236, sensor_list.h:108) |
| light_cct (31) | 25 | as light + u32 raw lux |

So one accel record on the wire is 1 + 1 + 6 + 8 = 16 bytes, one light record
1 + 1 + 21 + 8 = 31 bytes. Lux is reported ready-computed by the hub
(`CONFIG_SENSORS_SSP_LIGHT_REPORT_LUX=y`, defconfig 5294). Accel scale: read it
with 0xE1; Samsung HALs usually treat SSP accel as 4096 LSB/g **[?]**.

### 5.7 Delivery to Android (stock)

Every sensor is a separate IIO device named after the sensor
(`accelerometer_sensor`, `light_sensor`, ...) with one opaque channel holding
the raw record plus timestamp (GPL/ssp_iio.c:185-189, 644-700). The HAL
(`sensors.sensorhub.so`) reads `/dev/iio:deviceN` and enables sensors through
`/sys/class/sensors/ssp_sensor/enable` (u64 bitmask) and per-device
`poll_delay` (**[STR]** HAL strings; GPL/ssp_sysfs.c:342, 466, 1007-1009).
This ABI is Android-specific; a mainline driver should expose standard
`in_accel_{x,y,z}_raw` + `scale` + mount matrix and `in_illuminance_input`
so iio-sensor-proxy works unchanged.

### 5.8 Kernel SSP bring-up after `ESW:READY` (ssp_bbd.c:264-287, 379-430; ssp_dev.c:221-300)

1. wait for record 0x0A "sensor init done" (or 1 s);
2. WHOAMI must return 0x55;
3. SENSOR_FORMATION (positions from DT), GLASS_TYPE;
4. SENSOR_SCANNING -> bitmap of present sensors (must be non-zero);
5. magnetometer matrix, thermistor table, proximity calibration, FIRMWARE_REV,
   GET_ACCEL_RANGE, hall state;
6. re-add previously enabled sensors and resend the last AP state.

---

## 6. Hub boot (all done by lhd)

### 6.1 The patch file

Text file, embedded in the kernel and served as `/dev/bbd_patch`
(bbd.c:131-137, 764-781). Header lines `<Key=Value>` then `<Blob=...>` with
the binary image as hex text:

| key | stock-kernel patch (`firmware/extracted/kernel-builtin/bbd/bcm_sensorhub_a1.patch`) | GPL tree copy (`BBD/q_os/bbd_patch_file_tab_active_3.h`) |
|---|---|---|
| FormatVersion | 0x00010003 | 0x00010003 |
| Crc | 29 | 162 |
| BlobLength | 404243 | 393724 |
| AsicVersion | 0x004775B0 | 0x004775B0 |
| Name / Type | bcm_sensorhub_a1 / Application | same |
| PatchAddress | 0x00800161 | 0x00800141 |

The two builds differ (both carry "FlagtailPatch ver. 545126"): **use the
stock-kernel one**, it matches the shipped lhd and is the one already staged
by firmware/extracted/INDEX.md. The blob starts with a 7-byte header
(`F1 94 03 00 00 80 00`, identical in both builds; bytes 3-6 read as LE
0x00800000 = load address), followed by a Cortex-M image at 0x00800000 whose
reset vector equals PatchAddress (**[VER]**; also how REA built
`bcm-sensorhub.elf`, see `bcm-sensorhub.spec.json`). The header Crc is not
the packet-layer CRC-8 nor a simple sum/xor (**[VER]**, our check); lhd
validates it ("FD:CheckPatch failed", **[STR]**), the chip probably does not
need it **[?]**.

### 6.2 Sequence (from lhd.conf and lhd strings; order **[?]**)

lhd configuration (lhd.conf): `LheName=bbd`, `LheBbdPacket=/dev/ttyBCM`,
`LheBbdControl=/dev/bbd_control`, `LheBbdSensor=/dev/bbd_sensor`,
`LhePatch=/dev/bbd_patch`, `GpioNPowerPath=/sys/class/sec/sensorhub/mcu_power`,
`GpioNStdbyPath=/sys/class/sec/gps/GPS_PWR_EN/value`, `LheAutoBaudDelayMS=10`,
`LheClockMHz=100`, `LheMaxMcuResetTries=3` (also 4 earlier in the file),
`LhePinMux=P17=M1` (GNSS external LNA).

1. Power: write `1` to `mcu_power` (kernel enables LDO37 and sleeps 20 ms,
   ssp_sysfs.c:568-583); lhd then waits "Power enable delay: %dms" **[STR]**.
2. NSTDBY: drive GPS_PWR_EN; strings "GpioNStdbyInitHigh", "enforce NSTDBY
   init high", "ClearNstdbyPin() delay: 120us" suggest: start high, reset =
   low pulse of ~120 us, then high **[?]**. The kernel leaves it low at probe
   (bcm_gps_spi.c:1216), i.e. the chip is held in standby until lhd runs.
3. `SSI:PassThru=1` to bbd_control (download begins, wakelock).
4. ROM handshake, firmware-downloader state machine **[STR]**:
   FD_WAIT4AUTOBAUD ("Sending Autobaud") -> FD_SENT_AUTOBAUD -> (wait
   `LheAutoBaudDelayMS`) -> FD_GOT_SYNC / FD_GOT_SYNC_CONFIRM ("Got Remote
   Sync") -> FD_WAIT4VERSION_INIT / FD_GOT_VERSION_INIT ("ROM Version
   mismatch... Trying ASIC reset", FD_ROMRESET) -> FD_GOT_VERSION_CONFIRM ->
   FD_REQUEST_DOWNLOAD -> FD_WAIT4DOWNLOAD_START ("Initialize Patch") ->
   "Downloading Patch" -> "Starting Patch Verification" -> "Patch loaded and
   verified" -> FD_WAIT4DOWNLOAD_COMPLETE ("Starting Service APP 0x%X", i.e.
   jump to PatchAddress) -> FD_WAIT4APP -> FD_DONE. The autobaud/version
   steps very likely use the INTERNAL packet-layer frames shown in 4.4 and
   the 0x80 burst of bcm_gps_regs.c:65-66 **[?]**.
5. "LH:MCU Transport Synchronized" (packet-layer sync with the application,
   INTERNAL packets **[?]**), then `SSI:PassThru=0` and `ESW:READY` to
   bbd_control; the kernel starts SSP (5.8).
6. Recovery: on `BBD:RESET_REQ` from the kernel, a hub crash ("MCU SW PANIC",
   `ESW:CRASHED`) or lhd's own timeouts, repeat from 1 (max 3 tries).

~~What is unknown~~ (2026-10-22): resolved by reading lhd's firmware
downloader and transport layer in Ghidra (lhd keeps its C++ class and
method names in RTTI/log strings). Raw decompiler output stays in the
gitignored `firmware/re-targets/decomp/`; 6.3 describes the result in our
own words. Marker **[LHD]** = from the lhd binary.

### 6.3 Host side of the download and the packet layer (**[LHD]**)

Power (BrcmGpsHalGpio::Normal, sysfs variant): `mcu_power`=1 (LDO37), then
NSTDBY (GPS_PWR_EN)=1, then `gpioDelayMs` (not set in lhd.conf). If NSTDBY
read back high first, it is pulled low for 20 ms. Off = NSTDBY 0, then
power 0. Before the downloader runs, lhd writes one 16-byte 0x80 burst
(LheAutoBaudDelayMS=10 before it).

Firmware downloader state machine (FD_* log strings), with its timers:

| step | host sends | waits for |
|---|---|---|
| autobaud | 36 bytes 0x80, raw (not a packet) | 100 ms |
| sync | INTERNAL packet "sequence request" (below), every 100 ms, up to 6 | "sequence response"; on timeout repeat autobaud (5 tries) |
| version | reliable RPC 0x00 (no data) | RPC 0x03 `[u32 asic][u32 rom][u32 patch level]` (or 0x3b ext), 250 ms, 5 tries |
| check | if asic not a 4775B0 variant: RPC 0x1a `[u8 1]` (reset) and restart | |
| download | the patch blob as RPCs (below) in reliable packets, while the reliable window has >= 2 KB free | every reliable packet acknowledged |
| start | `Type` starting with 'A' (Application): RPC 0x2e `[u32 PatchAddress]` "start scratch app", plain packet; otherwise RPC 0x37 `[u32 addr][4 x u32 0]` "service start" | 40 ms (100 ms for service) |
| app sync | autobaud + sync again | sequence response from the application |
| confirm | reliable RPC 0x00 | RPC 0x03 from the application -> done, then `ESW:READY` |

Patch blob = stream of records `[type u8][len u16 LE][body]`, len <= 950;
lhd's "PatchEngine" turns each into an RPC:

| type | body | RPC |
|---|---|---|
| 0xf1 write | `[u32 addr][data]` | 0x05 `[u32 addr][u16 n][n bytes]` |
| 0xf0 masked write | `[u32 addr][u32 mask][u32 value]` | 0x06, same 12 bytes |
| 0xf5 masked verify | 12 bytes | 0x07 memory read of 4 bytes |
| 0xf2 crc | `[u32][u32][u8]` | 0x31 crc-8 of a range |
| 0xf3 checksum | 12 bytes | 0x30 32-bit checksum of a range |
| 0xf4 service | `[u32 entry][0..4 x u32]` | 0x37 |

The stock patch (`bcm_sensorhub_a1`, AsicVersion 0x004775B0) is 441 write
records only, 401156 bytes contiguous at 0x00800000-0x00861f04
(**[VER]** `tools/shub/patchparse.py`), entry 0x00800161, Type
Application. Records are packed into packets of up to 1024 payload bytes
(one 916-byte write per packet in practice).

Stream encoding: all multi-byte values little-endian. RPC record header:
id and length are 1 byte, or 2 bytes big-endian with bit 15 set when
>= 0x80. Other RPC ids seen in lhd: 0x01 get state, 0x02 sleep cycles,
0x1b reset transport layer, 0x2f flow control, 0x34 pin mux (lhd sends
`[7][2]` for 4775B0 after start, GNSS LNA), 0x36 interrupt, 0x3a version
ext request; hub -> host 0x17/0x18 exception (+ text), 0x19 and 0x402
log text `[u16 n][text]`; 0x20/0x21 sensor (5.x). Sensor requests go as
plain (not reliable) packets, at most 1000 SSP bytes per RPC.

Packet layer, host side (TransportLayer::BuildAndSendPacket and
PacketReceived):

- Every packet: next packet sequence number (wraps at 256), CRC as in 4.3.
  Details in flag-bit order: ACK = last sequence number received, RELIABLE
  = reliable sequence number, RELIABLE_ACK/NACK = last reliable sequence
  number received, MSG_LOST/GARBAGE = counts since the last report (capped
  255), SIZE_EXT = size high byte, EXTENDED = flag bits 15:8, INTERNAL and
  IGNORE_SEQID = one 0 byte each. ACK is added to any outgoing packet when
  payload packets were received since the last ACK.
- Plain payload packets are acknowledged lazily: a bare ACK packet only
  after 200 unacknowledged ones.
- A received reliable packet is answered at once with ACK|RELIABLE_ACK
  (new in-order one, or a duplicate: same reliable seq, CRC and size), or
  ACK|RELIABLE_NACK (out of order, not delivered).
- Own reliable packets wait in a queue; RELIABLE_ACK n drops all up to n,
  RELIABLE_NACK n drops up to n and resends the rest; retransmit after
  500 ms, give up after 10 tries (communication error). Reliable buffer
  10 KB.
- INTERNAL packets, first payload byte = type: 0 sequence request `[0][n]`
  (sent with INTERNAL|IGNORE_SEQID; n counts the attempts from 1); 1
  sequence response `[1][n][last seq received][last ACK detail][last
  reliable seq received][next seq][next reliable seq][last reliable seq
  acked]`; on it the requester sets next seq = byte 2 + 1, next reliable
  seq = byte 4 + 1, last seq received = byte 5, last reliable received =
  byte 6 - 1; 2/3 statistics request/response (11 x u32); 4/5 settings
  request/response (u16: max packet 1024, 1024, retry 500 ms, 10 tries,
  150 in flight).

SSI framing is not changed during the download: the same 0x58/0x50 frames
as for sensor traffic (3.x); `SSI:PassThru` only takes a wake lock.

---

## 7. Proprietary vs GPL

| piece | where | status |
|---|---|---|
| SSI SPI transport, GPIO handshake, IRQ | BBD/bcm_gps_spi.c | GPL, complete |
| SSI register/AHB debug access | BBD/bcm_gps_regs.c, bcm_gps_mem.c | GPL |
| packet layer RX (framing, CRC, flags, reliable dedup) | BBD/bbd_rpc_lh.c | GPL |
| packet layer TX (seq numbering, acks, reliable retransmit, sync) | lhd | proprietary; format fully implied by the RX side, behaviour not |
| RPC TLV format, sensor response id 0x21 | BBD/bbd_rpc_lh.c | GPL |
| sensor request RPC id/wrapping (0x20) | lhd | proprietary, inferred |
| SSP protocol (commands, ids, records) | GPL/ssp_*.c | GPL, complete |
| hub application firmware | patch blob (binary, redistributable status unclear) | proprietary binary; we only load it |
| ROM bootloader, autobaud/sync/version/download protocol | chip ROM + lhd | proprietary, undocumented |
| power/NSTDBY sequencing and timing | lhd (+ GPL sysfs knobs) | proprietary timing, trivial mechanism |
| GNSS (gpsd, RPC ids 0x00-0x1F) | gpsd/lhd | proprietary, out of scope |

---

## 8. What a lhd-free mainline needs (minimum for accel + light)

1. **DT**: `usi_chub00` + `spi_20` (mode 3, <= 25 MHz, CS gph0-3), the five
   GPIOs, LDO37 as supply, HOST_REQ as interrupt.
2. **SSI transport** (port of bcm_gps_spi.c, ~400 lines): MCU_REQ/RESP
   handshake, HOST_REQ IRQ, 0x50 read / 0x58 write frames, FC retry.
3. **Packet layer** (~400 lines): stuffing, CRC-8/0x4D nibble-swapped,
   seq counter, ACK/RELIABLE_ACK generation, INTERNAL packets, the sync
   handshake; reliable retransmit can probably be skipped for sensor traffic
   **[?]**.
4. **Firmware loader**: power + NSTDBY sequence, autobaud, ROM sync/version,
   patch download, start, transport sync. Patch via `request_firmware()`
   (`samsung/gtactive3wifi/bbd/bcm_sensorhub_a1.patch` as already staged).
   **This is the part that needs a capture or lhd RE.**
5. **SSP client** (~500 lines): request RPC wrapping, header/write/read
   transactions with options matching, WHOAMI, FORMATION, SCANNING, ADD/REMOVE
   for ids 0 and 9, data-frame parser for records 0x37/0x0A/0xA8/0x05,
   periodic 0xA7 timestamp.
6. **IIO front-ends**: accel (`IIO_ACCEL`, raw + scale, `mount-matrix`
   derived from `ssp-acc-position=5` or left to the hub's FORMATION) and
   light (`IIO_LIGHT`, `in_illuminance_input` from the s32 lux), both with
   buffered/trigger support and runtime enable mapped to ADD/REMOVE.
   iio-sensor-proxy then gives auto-rotate and auto-brightness for free.

Not needed: GNSS, gyro/mag/prox, batching, big-data, scontext, VDIS shub-int,
the "AP SLEEP" pulse (nice to have for suspend).

Architecture options:

- **A. All in kernel** (recommended end state): one SPI driver
  `bcm4775-shub` (transport + packet layer + loader + SSP) with two IIO child
  devices. Clean, no daemon, works with stock userspace (iio-sensor-proxy).
- **B. Userspace prototype first**: spidev + libgpiod (GPIO edge events on
  HOST_REQ) + sysfs regulator control, in Python or C, implementing exactly
  the same layers. Best for the RE iterations of the loader (no kernel
  rebuild per experiment); then port to A. Delivery to iio-sensor-proxy from
  userspace is awkward (uinput works for accel only), so B is not the end state.
- **C. Stopgap with stock lhd**: port bbd/bcm_gps_spi to mainline and run the
  bionic `lhd` binary in an Android-linker environment. Avoids the loader RE,
  but drags proprietary bionic userspace into postmarketOS; only worth it as a
  tracing tool (the ported kernel side logs every SPI frame).

## 9. Risks and effort

| item | risk | effort (focused) |
|---|---|---|
| DT for SPI20 + GPIOs + LDO37 | low (SPI21 already works on the same CMU_CHUB) | 0.5 day |
| SSI transport | low (GPL reference, exact) | 2-3 days |
| packet layer RX/TX | low-medium (format verified; TX behaviour and sync handshake inferred) | 3-5 days |
| power/NSTDBY sequence | low-medium (timing from capture or trial; LDO + 1 GPIO) | 1 day with capture |
| ROM handshake + patch download | **high** without a capture (3-6 weeks of lhd RE, may still miss checks); **medium** with a capture (replay, then generalise: 1-2 weeks) | see left |
| SSP client + IIO accel/light | low (GPL reference, exact layouts) | 1-1.5 weeks |
| suspend/resume, crash recovery | medium | 3-5 days |

Total: roughly 4-6 weeks with a stock SPI capture, 7-12 weeks without.
Other risks: the hub firmware may refuse sensor RPCs until GNSS-side
initialisation done by lhd (e.g. a config RPC, `LhePinMux`) has happened
**[?]**; firmware licence for redistribution in pmaports is unclear (the blob
is in Samsung's GPL tarball, but as data); a wrong NSTDBY/LDO sequence is
unlikely to damage anything but can leave the chip in ROM.

## 10. Capturing the stock protocol (to be run by the user, not by an agent)

The stock kernel already contains the tools:

- `SSI:DEBUG=1` written to `/dev/bbd_control` or `/sys/bbd/bbd` turns on
  `pk_log`, which prints every SPI transfer (both MOSI and MISO, 32 bytes per
  line, with a ms timestamp) to the kernel log (bbd.c:495-498,
  bcm_gps_spi.c:552-593, 649-651). `SSP:DEBUG=1` additionally dumps SSP
  packets both ways (ssp_bbd.c:29-43). `BBD:DEBUG=1` is compiled out
  (bbd.c:480-483).
- The flag is set after lhd has already started, so the first boot is missed.
  Two ways to see the download: (a) after enabling the flag, force a hub
  reset (e.g. `echo 0 > mcu_power` / restart lhd, or wait for a crash
  recovery), or (b) build the GPL kernel with `ssi_dbg = true` as default
  (bcm_gps_spi.c:54) and boot stock Android with it. Root is needed to write
  the node and read dmesg; the patch download is ~400 KB, so use a large log
  buffer or stream `dmesg -w` to storage.
- Also record the GPIO/regulator timing: `/sys/kernel/debug/gpio` and
  regulator `enable` state before/after lhd restart, and lhd's own log
  (lhd.conf `Lhe477xDebugFlags`, logcat tag gpsd/lhd).

## 11. Phased plan

1. **Phase 0, capture (user, stock Android)**: SSI+SSP debug trace of a full
   hub bring-up and of enabling accel/light in a sensor test app; save
   dmesg + lhd logcat. Decode offline with a small parser (packet layer +
   RPC + SSP, all from this document).
2. **Phase 1, link up**: DT for `spi_20`; userspace prototype (spidev +
   libgpiod) or kernel skeleton that powers LDO37, releases NSTDBY, does the
   MCU_REQ/RESP handshake and reads frames on HOST_REQ. Goal: see the ROM
   talk (any bytes / a version response to the INTERNAL get-version frame
   of 4.4). Readout of chip/ROM version = done.
3. **Phase 2, patch download**: replay/implement the ROM sync, version and
   download sequence from the capture with the stock-kernel patch; detect
   the application start and the transport sync. Goal: hub sends HUB2AP
   frames with record 0x0A (sensor init done).
4. **Phase 3, SSP**: WHOAMI 0x55, FORMATION, SCANNING (expect bits 0 and 9),
   ADD accel (id 0, e.g. 100 ms, latency 0) and light (id 9, 200 ms); decode
   0x37 records. Goal: live x/y/z and lux on the console.
5. **Phase 4, mainline driver**: fold everything into `bcm4775-shub` (SPI
   driver, firmware via request_firmware, IIO accel + light with buffers and
   runtime PM, recovery on WHOAMI/timeout failure), DT binding, then
   iio-sensor-proxy test for auto-rotation and auto-brightness.
6. **Phase 5 (optional)**: proximity, magnetometer, gyro; suspend
   notification (AP SLEEP pin, 0xD2/0xD3); GNSS stays out of scope.

## 12. Evidence index (beyond inline citations)

- lhd strings (`strings -n 6 firmware/fs/vendor/bin/hw/lhd`): "FD:FD_..."
  states, "Sending Autobaud", "Patch loaded and verified", "Starting Service
  APP 0x%X", "LH:MCU Transport Synchronized", "LH: TransportLayer Stats: Host
  - TxPackets ... TxReliablePacket ... TxPacketRetry", "ClearNstdbyPin()
  delay: 120us", "Power enable delay: %dms", "GpioNStdbyInitHigh",
  "BbdSensor::%s(%d,%d,%d,%d) incomplete cmd", source path
  ".../lhe2_dev/transport/rpc_engine.cpp".
- hub firmware strings (`bcm_sensorhub_a1.blob.bin`): "MCU_BCM477X_transport_layer.c",
  "patch_transport_layer.cpp", "SensorHubTask", "SSP_ACC ... ICM42605",
  "SSP_l TMD3725 ...", "GeoMagnetic_AK09916_Register_RW", "patch_i2cm.c",
  "MCU_SPI_Sensor_Read/Write", "4775.B0 FlagtailPatch ver. 545126".
- HAL strings (`sensors.sensorhub.so`): "/dev/iio:device%d",
  "/sys/bus/iio/devices/iio:device%d/poll_delay",
  "/sys/class/sensors/ssp_sensor/enable", "accelerometer_sensor", "light_sensor".
- Device nodes and permissions: `firmware/fs/vendor/ueventd.rc:213-229`;
  lhd service: `firmware/fs/vendor/etc/init/init.gps.rc` (service lhd);
  `mcu_power` ownership: `vendor/etc/init/init.exynos9810.rc:190`.
- REA: `firmware/re-targets/INDEX.md` lists `fw-bcm-sensorhub` (1310
  procedures, 1026 strings) and `gnss-lhd` (1230 procedures, 1005 strings);
  no deeper analysis exists yet. Next useful REA queries: the lhd functions
  referencing the "FD:" strings (firmware downloader) and "ClearNstdbyPin",
  and the hub firmware's transport-layer INTERNAL packet handler.
