# Exynos 9810 A-Box (audio subsystem): how it works and what Linux needs

Our own description of the A-Box as used on the SM-T570 (Galaxy Tab Active3),
written from:

- Samsung's GPL A-Box driver: `sound/soc/samsung/abox/` and
  `include/sound/samsung/abox_ipc.h` in the T570-family kernel
  (`build/ref/gtactive3cs`) and the Galaxy S9 kernel (`src/samsung-9810-ref`);
- the stock device tree (`firmware/stock/stock-0.dts` abox, abox_gic,
  sysmmu_aud; `dtbo-4.dts` sound, rt5665, rt5510);
- the downstream CMUCAL/PMU tables (`drivers/soc/samsung/cal-if/exynos9810/`);
- static analysis of the vendor firmware `calliope_sram.bin`,
  `calliope_dram.bin`, `calliope_iva.bin` (T570XXSFEYI1) in
  `firmware/re-targets/` (Ghidra/REA). No decompiled code is reproduced here,
  only register names, offsets, bit fields and sequences.

Status markers: **[GPL]** taken from Samsung's GPL source, **[DT]** from the
stock DT, **[FW]** observed in the firmware, **[HW]** read on the device,
**[?]** inferred, not verified.

## 1. Blocks and addresses

| block | address | notes |
|---|---|---|
| CMU_AUD | 0x17c0_0000, 0x8000 | PLL_AUD, AUD dividers and gates **[GPL]** |
| SYSREG_AUD | 0x17c1_0000 | MISC_CON 0x32c, L2_CACHE_CON 0x328 **[GPL]** |
| A-Box SFR | 0x17c5_0000, 0x10000 | routing, SPUS/SPUM, UAIF, RDMA/WDMA, CPU debug **[DT][GPL]** |
| RDMA0-7 | 0x17c5_1000 + 0x100·n | read (playback) DMA **[DT]** |
| WDMA0-4 | 0x17c5_2000 + 0x100·n | write (capture) DMA **[DT]** |
| UAIF0-3 | 0x17c5_0500 + 0x10·n | I2S/TDM ports, pins on pinctrl@17c60000 gpb0/gpb1/gpb2 **[DT]** |
| DSIF | 0x17c5_0550 | PDM/DSD out (unused here) |
| pinctrl_aud | 0x17c6_0000 | aud-i2sN-bus: function 2, pull-down **[DT]** |
| A-Box GIC (GIC-400) | GICD 0x17cf_1000, GICC 0x17cf_2000 | the DSP's interrupt controller; AP side gets SPI 76 **[DT]** |
| A-Box SRAM | 0x17d0_0000, 0x31000 | DSP code/data + IPC mailboxes **[DT]** |
| SYSMMU_AUD | 0x17e0_0000, 0x9000 | the A-Box AXI master (DSP + DMAs) goes through it; SPI 79 **[DT]** |
| PMU | 0x1406_0000 | AUD power domain, Calliope CPU power/reset, pad retention **[GPL]** |

The AUD power domain status is at PMU 0x4004 (on = low nibble 0xf). S-Boot
leaves it on (0x0010000f read on the device by the earlier audio session
**[HW]**). Touching any AUD register with the domain off is an SError.

## 2. Clocks (CMU_AUD)

**[GPL]** offsets from cmucal-sfr.c, tree from cmucal-node.c:

```
OSCCLK 26 MHz ─ PLL_AUD (PLL_1031X, fractional) ─┬─ DIV_CLK_AUD_AUDIF ─┬─ DIV_UAIF0..3 ─ MUX_UAIF0..3 ─ gates BCLK_UAIFn, RSTNSYNC_UAIFn
                                                 │                     └─ DIV_DSIF ─ DIV_DMIC
                                                 ├─ DIV_CLK_AUD_BUS ── DIV_CLK_AUD_BUSP (APB, SFR access)
                                                 └─ DIV_CLK_AUD_PLL
CMU_TOP clkcmu_aud_cpu (800 MHz) ─ MUX_CLKCMU_AUD_CPU_USER ─ MUX_CLK_AUD_CPU ─ HCHGEN ─ DIV_CPU_ACLK, DIV_CPU_ATCLK, DIV_CPU_PCLKDBG
```

| register | offset | fields |
|---|---|---|
| PLL_LOCKTIME_PLL_AUD | 0x0000 | lock time [19:0]; fractional PLL: P × 500 |
| PLL_CON0_PLL_AUD | 0x0120 | ENABLE 31, STABLE 29, M [25:16], P [13:8], S [2:0], MUX_SEL 4 (0 = FIN), MUX_BUSY 7 |
| PLL_CON3_PLL_AUD | 0x018c | K [15:0] (signed) |
| MUX_CLK_AUD_UAIFn | 0x1004 + 4n | SELECT 0: DIV_CLK_AUD_UAIFn, 1: external CLKIO |
| DIV_CLK_AUD_AUDIF | 0x1800 | ratio [8:0], BUSY 16 |
| DIV_CLK_AUD_BUS / BUSP | 0x1804 / 0x1808 | |
| DIV_CLK_AUD_CPU_ACLK / ATCLK | 0x180c / 0x1810 | |
| DIV_CLK_AUD_UAIFn | 0x1824 + 4n | ratio [8:0] |
| GAT ABOX BCLK_UAIFn | 0x201c + 4n | CG_VAL 21, MANUAL 20, HWACG 28 |
| GAT RSTNSYNC_CLK_AUD_UAIFn | 0x2090 + 4n | same |

Rates: PLL_AUD 1179.648 MHz for the 48 kHz family (M 45, P 1, S 0,
K 24319) and 1083.8016 MHz for 44.1 kHz (M 42, K −20665). AUDIF is set to
24.576 MHz (AUDIF_RATE_HZ, PLL_AUD / 48). The CMUCAL boot LUT for BLK_AUD
puts PLL_AUD at 1.2 GHz with ATCLK /2, ACLK /2, BUS /2, BUSP /3. A UAIF bit
clock is AUDIF / (DIV_UAIFn + 1); the driver asks for rate × channels × width
(1.536 MHz for 48 kHz S16 stereo, ratio 16).

## 3. A-Box SFR map (the parts Linux uses)

**[GPL]** abox.h; defaults from abox_reg_defaults_9810.

| reg | offset | content |
|---|---|---|
| IP_INDEX | 0x0000 | 0x41424f58 "ABOX" |
| VERSION | 0x0004 | |
| SYSPOWER_CTRL / STATUS | 0x0010 / 0x0014 | bit 0: "DRAM on" request (keep the AXI path to DRAM up) |
| SYSTEM_CONFIG0 | 0x0020 | default 0x4444 |
| REMAP_MASK / REMAP_ADDR | 0x0024 / 0x0028 | 0xfff00000 / 0x17d00000: the DSP's address 0 is SRAM |
| DYN_CLOCK_OFF | 0x0030 | default 0x7fffffff |
| QCHANNEL_DISABLE | 0x0038 | bit n = enum qchannel: 0 CCLK_CA7, 1 ACLK, 2-5 BCLK_UAIF0-3, 6 BCLK_DSIF, 7 CCLK_ATB, 8 CCLK_ASB; 1 = keep the clock running |
| ROUTE_CTRL0 | 0x0040 | UAIFn speaker source, 4 bits at 4n: 1 SIFS0 (mixer), 2 SIFS1, 3 SIFS2, 0xc SIFMS; DSIF [23:20] |
| ROUTE_CTRL1 | 0x0044 | NSRCn source, 4 bits at 4n: 8 + m = UAIFm; SPUSM [19:16] |
| ROUTE_CTRL2 | 0x0048 | RSRC sources |
| SPUS_CTRL0 | 0x0200 | per RDMA n, nibble n: bit 0 ASRC on, bits 2:1 OUT (0 SIFS1, 1 SIFS0/mixer, 2 SIFS2), bit 3 IN (0 RDMA, 1 SIFSM) |
| SPUS_CTRL1 | 0x0204 | MIXP_FORMAT [4:0], SIFS_OUT1_SEL [18:16], SIFS_OUT2_SEL [21:19] (= SPUS OUT n), SIFM_IN_SEL [24:22] |
| SPUS_CTRL2 / CTRL3 | 0x0208 / 0x020c | MIXP flush bit 0 / SIFS1 flush 0, SIFS2 flush 1, SIFM flush 2 |
| SPUS_SBANK_RDMAn | 0x0220 + 4n | SPUS sample bank of RDMA n **[FW][?]**: start [13:7] (128 byte units), size [29:20] (16 byte units) |
| SPUS_SBANK_ASRCn | 0x0240 + 4n | |
| SPUS_CTRL_SIFS_CNT0/1 | 0x0280 / 0x0284 | SIFS0 [15:0], SIFS1 [31:16], SIFS2 [15:0]: only needed when a SIFS feeds an NSRC (loopback) |
| SPUM_CTRL0 | 0x0300 | per NSRC n: bit 4n+4 ASRC, bit 4n+7 OUT (0 WDMA) |
| SPUM_CTRL1 | 0x0304 | RECP_SRC_FORMAT [12:8], RECP_SRC_VALID [1:0] |
| SPUM_CTRL3 | 0x030c | SIFM0-3 flush bits 0-3 |
| UAIFn_CTRL0 | 0x0500 + 0x10n | START_FIFO_DIFF_MIC [31:28], _SPK [27:24], DATA_MODE 4, IRQ_MODE 3, MODE 2 (1 = A-Box drives BCLK/WS), MIC_ENABLE 1, SPK_ENABLE 0 |
| UAIFn_CTRL1 | 0x0504 + 0x10n | FORMAT [28:24], BCLK_POLARITY 23, WS_MODE 22 (0 I2S, 1 DSP_A), WS_POLAR 21, SLOT_MAX [20:18], SBIT_MAX [17:12], VALID_STR [11:6], VALID_END [5:0] |
| UAIFn_STATUS | 0x050c + 0x10n | ERROR_OF_MIC 1, ERROR_OF_SPK 0 |
| CPU_R0..R14, PC, L2C_STATUS | 0x2c00.., 0x2c3c, 0x2c40 | DSP register snapshot (debug) |

"Format" everywhere (DMA, UAIF, MIXP) is `(channels − 1) | (w << 3)` with
w = 1, 2, 3 for 16, 24, 32 bit. I2S NB_NF is BCLK_POLARITY 1, WS_POLAR 0.
For stereo VALID_STR/END are 0, otherwise width − 1; SLOT_MAX = channels − 1;
SBIT_MAX = width − 1. On capture start the GPL driver sets DATA_MODE 1,
IRQ_MODE 0.

### RDMA/WDMA

The GPL driver only names CTRL0 enable, the status register and the
BUF_*/VOL registers; the firmware's accessors (calliope_sram.bin
0x209c-0x2330, RDMA base literal 0x17c51000; calliope_dram.bin WDMA accessors
around 0x80002b6a, base 0x17c52000) give the full CTRL0 layout **[FW]**:

| reg | offset | content |
|---|---|---|
| CTRL0 | 0x00 | ENABLE 0, BUF_TYPE 4, BUF_UPDATE 5, FORMAT [12:8], EXPAND 13 (RDMA: 16 bit mono to stereo), FUNC [18:16] (0 normal, 1 pending/pause), BURST_LEN [22:19] |
| CTRL1 | 0x04 | |
| BUF_STR | 0x08 | buffer start [31:4] (device address, 16 byte aligned) |
| BUF_END | 0x0c | buffer end [31:4] |
| BUF_OFFSET | 0x10 | period size in bytes [15:4] |
| STR_POINT | 0x14 | start pointer [31:4] |
| VOL_FACTOR | 0x18 | [23:0], 0x800000 = 0 dB |
| VOL_CHANGE | 0x1c | [23:0] ramp step |
| SBANK_LIMIT | 0x20 | [13:7] |
| STATUS | 0x30 | PROGRESS 31, RBUF_OFFSET [28:16] (× 16 = byte offset of the current period), RBUF_CNT [12:0] (bytes into it) |

The firmware's "set buffer" sequence for DMA n (calliope_dram.bin 0x8000048e)
is: VOL_FACTOR (skipped for RDMA6/7), VOL_CHANGE, FUNC = 0, BUF_STR, BUF_END,
STR_POINT, BUF_OFFSET, BURST_LEN (8; 2 for RDMA2, 4 for RDMA7), FORMAT if it
changed, BUF_UPDATE = 1, BUF_TYPE, EXPAND (for 16 bit mono), then it unmasks
the DMA's two interrupts in the A-Box GIC (ids 38 + n and 46 + n for RDMA n;
54 + n and 59 + n for WDMA n) **[FW]**. The GPL driver's pointer callback
reads STATUS and walks back to a period boundary; position = offset + count.

Stopping: clear ENABLE and wait for PROGRESS to drop (GPL timeout 40 ms); if
it does not, toggle ENABLE once more (abox_dma_barrier).

## 4. Interrupts

The A-Box GIC is a GIC-400 shared by the DSP (CPU interface 0) and the AP.
The AP reaches it through GICC 0x17cf2000 and an interrupt line on the main
GIC (SPI 76) **[DT][GPL]**:

- AP to DSP: write `GICD_SGIR = (1 << 16) | id` (target CPU interface 0),
  id = the IPC_ID of the message (below). The GPL driver programs GICC_PMR
  0xff, GICD_CTLR 3, all priorities 0x10 and GICC_CTLR 3 before boot.
- DSP to AP: an SGI with id < 16 arrives on SPI 76; the AP reads GICC_IAR,
  writes EOI and DIR, and dispatches on the id (0x8/0x9 WDMA0/1 buffer full,
  0xb-0xe RDMA0-3 buffer empty, otherwise the IPC message in the RX mailbox).
- The DMA, UAIF and SPUS hardware interrupts (ids ≥ 32) are SPIs of the
  A-Box GIC and are enabled and handled by the firmware **[FW]**. Without
  firmware nobody enables them; routing them to the AP's interface through
  GICD_ITARGETSR is possible in principle but untested **[?]**, so the
  firmware-less driver uses an hrtimer per period and the DMA STATUS register
  for the position.

## 5. Booting the Calliope DSP (Samsung's way)

**[GPL]** abox.c (`samsung_abox_probe`, `abox_enable`, `abox_download_firmware`,
`abox_cpu_power`, `abox_cpu_enable`):

Memory, all through SYSMMU_AUD (an IOMMU domain owned by the A-Box device):

| DSP address (IOVA) | size | backing |
|---|---|---|
| 0x0000_0000 | 0x31000 | A-Box SRAM 0x17d00000 (REMAP, not the SYSMMU) |
| 0x1000_0000 | 4 KiB | identity map of 0x10000000 (chip ID) |
| 0x8000_0000 | 18 MiB | DRAM firmware, `dma_alloc_coherent` |
| 0x9000_0000 | 512 KiB | IVA firmware (`calliope_iva.bin`) |
| 0x9100_0000 + 1 MiB·n | | RDMA n buffer (mapped at hw_params) |
| 0x9200_0000 + 1 MiB·n | | WDMA n buffer |
| 0x9300_0000 / 0x9400_0000 | | compress offload / virtual DMA buffers |
| 0xa000_0000 / 0xa100_0000 | 6 MiB / | VSS firmware (phys 0xfee00000) and parameters, shared with the modem |
| 0xd000_0000 | | debug dump buffer |

Boot sequence (runtime resume):

1. enable the AP's A-Box GIC interrupt (SPI 76); ask for the top CPU gear;
2. SYSREG_AUD MISC_CON (0x32c) = 1;
3. enable the "cpu" clock and set "audif" to 24.576 MHz;
4. restore the cached SFRs (regmap cache sync);
5. initialise the A-Box GIC (section 4);
6. pinctrl "default" for the UAIF pins;
7. copy `calliope_sram.bin` to SRAM offset 0 and zero the rest of SRAM;
   copy `calliope_dram.bin` to the DRAM area (IOVA 0x80000000, zero the
   rest of 18 MiB); copy `calliope_iva.bin` to the IVA area; copy the
   "extra" binaries listed in the DT (ext_bin@N: area 1 = DRAM area,
   offset: AP_AUDIO_SLSI.bin at 0x7e0000, APBargeIn_AUDIO_SLSI.bin at
   0x7dc000, APDV_AUDIO_SLSI.bin at 0x4d0000 on this device);
8. optional boot arguments string into SRAM at `samsung,abox-bootargs-offset`
   (not set in the stock DT; the firmware parses "vss=true/false" **[FW]**);
9. SYSPOWER_CTRL = 1 (DRAM on);
10. PMU ABOX_CPU_CONFIGURATION 0x415c bit 0 = 1 (local power up);
11. PMU ABOX_CPU_OPTION 0x4164 bit 28 = 1 (release the CPU), then poll
    PMU ABOX_CPU_STATUS 0x4160 bit 0 for up to 1 s;
12. release pad retention: PMU PAD_RETENTION_ABOX_OPTION 0x4170 bit 28 = 1,
    PMU GPIO_MODE_ABOX_SYS_PWR_REG 0x1424 bit 0 = 1;
13. the DSP boots from its address 0 (SRAM), prints "Now it's ready to get IPC
    message" **[FW]** and sends IPC_SYSTEM/ABOX_BOOT_DONE with param3 = the
    four-character firmware version; the AP then sends ABOX_RESUME (cpu pm),
    replays saved state (gear, component controls) and starts sending PCM
    messages.

Suspend: IPC_SYSTEM/ABOX_SUSPEND, wait for the CPU to reach WFI (PMU
ABOX_CPU_STANDBY 0x3804 bit 28), CPU_OPTION bit 28 = 0, CONFIGURATION bit 0
= 0, pad retention on (0x1424 bit 0).

## 6. AP <-> DSP IPC

**[GPL]** abox_ipc.h, abox.c `__abox_process_ipc`, `abox_irq_handler`;
offsets from the stock DT (ipc_tx_offset etc.).

Mailboxes in A-Box SRAM:

| | offset | |
|---|---|---|
| AP to DSP message | 0x30000 | one ABOX_IPC_MSG (0x2fc bytes) |
| AP to DSP ack word | 0x302fc | AP writes 1, DSP clears it when it has taken the message |
| DSP to AP message | 0x30300 | |
| DSP to AP ack word | 0x305fc | AP writes 0 after copying the message out |

Send: copy the message, write 1 to the TX ack word, raise SGI `ipcid`, poll
the ack word for up to 10 ms (retry; after 10 timeouts the GPL driver
declares the DSP dead). Messages are queued and sent from an ordered work
queue, one at a time, 10-100 µs apart.

Message layout (little endian, 32-bit fields):

```
+0x00 ipcid    1 SYSTEM, 2 PCMPLAYBACK, 3 PCMCAPTURE, 4 OFFLOAD, 5 ERAP,
               0xa ABOX_CONFIG, 0xf ASB_TEST (and SGI-only ids 8,9,0xb-0xe)
+0x04 task_id  (PCM: the DMA id)
+0x08 union, up to 0x2f4 bytes:
  PCMTASK:  msgtype, channel_id, param
            msgtype 11 PLTDAI_OPEN, 12 CLOSE, 14 HW_PARAMS {rate, bit_depth,
            channels}, 15 HW_FREE, 16 PREPARE, 17 TRIGGER {1 start, 0 stop},
            18 POINTER (DSP to AP: a period has elapsed), 20 SET_BUFFER
            {DSP address, period bytes, period count}, 22 ACK, 50 REGISTER
  SYSTEM:   msgtype, param1, param2, param3, bundle[740]
            1 SUSPEND, 2 RESUME, 3 BOOT_DONE (param3 = version), 4 CHANGE_GEAR,
            7 REQUEST_SYSCLK, 0x10 REPORT_LOG, 0x20 REPORT_DUMP,
            0x40.. SRAM claim (IVA sharing), 0x50 SET_MODE, 0x60 SET_TYPE,
            0xa0 START_VSS, 0xc0.. components, 0xfa REPORT_FAULT
  ABOX_CONFIG: msgtype, param1 (width), param2 (channels)
            1 SET_MIXER_SAMPLE_RATE .. 9 SET_INMUX4_SAMPLE_RATE,
            0x10 SET_MIXER_FORMAT .. 0x18 SET_INMUX4_FORMAT
  ERAP:     realtime/loopback, USB offload
  OFFLOAD:  compressed playback
```

Playback with firmware (abox_rdma.c): map the ALSA buffer at IOVA
0x91000000 + 1 MiB·id; SET_BUFFER (IOVA, period bytes, periods); HW_PARAMS;
PREPARE; TRIGGER 1 at start; the DSP programs the RDMA (section 3) and sends
PCMPLAYBACK/POINTER per period; TRIGGER 0; HW_FREE. The routing, SPUS/SPUM,
ASRC and UAIF registers stay with the AP (regmap writes), the IPC only covers
the DMA and the DSP's own mixing.

## 7. Minimum for PCM playback without firmware

This is what `sound/soc/samsung/exynos9810-abox.c` (branch drv/audio) does:

1. AUD domain on (PMU 0x4004 = 0xf), do not touch anything otherwise;
2. CMU_AUD: PLL_AUD 1179.648 MHz (mux to FIN, disable, lock time P × 500,
   K, PMS, enable, wait STABLE, mux back), AUDIF divider 47 (24.576 MHz);
3. pad retention release (PMU 0x4170 bit 28, 0x1424 bit 0), SYSREG_AUD
   MISC_CON = 1;
4. per stream: QCHANNEL_DISABLE ACLK and BCLK_UAIFn, SYSPOWER_CTRL = 1;
5. route: SPUS_CTRL0 nibble n = IN RDMA, ASRC off, OUT SIFS1 (UAIF0) or
   SIFS2 (UAIF1); SPUS_CTRL1 SIFS_OUT1_SEL = 0 / SIFS_OUT2_SEL = 1;
   SBANK; ROUTE_CTRL0 UAIF0 = 2 (SIFS1), UAIF1 = 3 (SIFS2); flush SIFS;
6. UAIF: BCLK divider = 24.576 MHz / (rate × 2 × width), MUX 0, gates on;
   CTRL0 MODE 1; CTRL1 I2S, NB_NF, SBIT_MAX, SLOT_MAX, FORMAT;
7. RDMA: the set-buffer sequence of section 3 with the physical (bus)
   address of a 32-bit DMA buffer, which assumes SYSMMU_AUD is in bypass
   **[?, to be checked on the device: peek 0x17e00000]**;
8. start: RDMA ENABLE, wait PROGRESS, UAIF SPK_ENABLE; period timing from
   an hrtimer, position from RDMA STATUS.

Capture is the mirror: ROUTE_CTRL1 NSRCn = 8 + n (UAIFn), SPUM_CTRL0 ASRC off
and OUT WDMA, flush SIFMn, WDMA n + 1, UAIF MIC_ENABLE.

If the bypass assumption fails (SYSMMU enabled by the bootloader, or DMA
faults), the fallbacks are, in order: program SYSMMU_AUD with an identity
or IOVA page table from Linux (mainline exynos-iommu, if its v5+ code fits
this SysMMU: PT_BASE at 0x0c, CTRL 0x0, CFG 0x4, VERSION 0x34), or boot the
firmware as in sections 5 and 6.

## 8. Codecs

- RT5665 (i2c 0x1b on HSI2C_7, USI01_I2C in PERIC0): headset codec on
  UAIF0 (AIF1), I2S, codec is the clock consumer; Samsung's machine driver
  locks the codec PLL1 to BCLK1 (rate × width × 2) and runs SYSCLK at
  rate × 512 **[GPL]** (gtactive3-rt5665-rt5510.c). Differential IN1 (headset
  mic, MICBIAS1), IN3 (main mic, MICBIAS2), IN4 (sub mic, MICBIAS3); stock
  realtek,jd-src = 2 (JD1 + JD2) is a Samsung extension **[DT]**.
  Device ID register 0xff reads 0x6451 (mainline rt5665.c checks it).
- RT5510 (i2c 0x34 on HSI2C_18, USI07 in PERIC1, hw_rev 4): the
  Richtek-branded MT6660, mono class-D speaker amplifier on UAIF1, I2S, clock
  consumer. Same chip ID check as MT6660 (DEVID & 0xff0 = 0x0e0/0x1e0);
  Samsung's init table differs only in the word-length register (TDM_CFG3
  0x15) and an E2+ PWM phase shift tweak (RESV23 0xbd) **[GPL]**.
- Stock UAIF2 carries RT5665 AIF2 (voice), UAIF3 Bluetooth **[DT]**.
- RT5510 registers that matter for "is the speaker on" (read over I2C during
  a stream on the device **[HW]**, meanings as in Richtek's RT5512B datasheet,
  same family): 0x03 SYSTEM_CTRL bit 0 power down, 1 mute, 2 class-D on
  (0x04 while playing); 0x10 SERIAL_CFG1 AUD_BIT [7:6], auto-detected
  BCK_MODE [5:3] (0 = 32fs, 2 = 64fs) and SR_MODE [2:0] (3 = 48 kHz);
  0x15 AUD_WL [9:4]; 0x29 VOL_CTRL, attenuation in 0.5 dB steps,
  0x00 = +12 dB, 0x18 = 0 dB, 0xff = -115.5 dB; multi-byte registers
  read back as 0xff/0xa5 patterns while the chip is powered down.
  Samsung's mixer paths never write the amplifier volume, and spkamp.bin is
  not RT5510 data but A-Box DSP code for the TI SmartPA (TAS2562 boards).
- RT5665 supplies: stock realtek,regulator_1v8 = S2MPS18 LDO33 (on at
  boot) and realtek,regulator_3v3 = LDO36 (off at boot, LCTRL 0x3c **[HW]**),
  which the stock codec driver switches on; LDO36 is the microphone bias
  supply.

## 9. Firmware facts

- calliope_sram.bin 35048 bytes, ARM/Thumb-2 (Cortex-A7), runs at DSP
  address 0 (SRAM); vectors at 0; holds the boot code, the IPC dispatcher
  (ABOXSYSTEM, PCMOUT, PCMIN, ABOXCONFIG handlers), the RDMA register
  accessors and the A-Box GIC driver (GICD/GICC literals) **[FW]**.
- calliope_dram.bin 2239404 bytes, runs at 0x80000000 (IOVA): middleware,
  DMA set-up, WDMA accessors, effects; refers to SYSREG_AUD and CMU_AUD
  addresses **[FW]**.
- calliope_iva.bin 57728 bytes, Thumb, loaded at IOVA 0x90000000 **[FW]**.
- Version string printed at boot as four characters (`ABox fiwmare
  version: %c%c%c-%c`) **[FW]**.
