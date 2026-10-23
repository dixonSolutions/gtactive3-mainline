# Exynos 9810 big cluster (4x Mongoose M3): power-up path

Our notes from live register reads on the SM-T570 and from Samsung's GPL
kernel (cal-if/exynos9810 flexpmu tables). Status: cluster 1 can be powered,
the cores do not reach the kernel yet.

## Who does what

- **Boot firmware** powers all 8 cores early, then powers cluster 1 **off**
  before Linux runs: clears CLUSTER1_CPUn_ETC_OPTION bit 17
  (PMU 0x14063c08 + 0x10 n), sets CRP_PM_CC1_0 (0x1a0001a4) |= 3 and waits for
  bit 16, then clears CLUSTER1_NONCPU_CONFIGURATION[3:0] (0x14062040).
  It skips this when the word at secure SRAM 0x02020000 is 0xdab.
- **PSCI CPU_ON (EL3)** for a big core only writes
  CLUSTER1_CPUn_CONFIGURATION[3:0] = 0xf (0x14062000 + 8 n); it does not
  power the cluster.
- **APM firmware** (Cortex-M in APM SRAM, AP 0x02039000 = APM 0; AP-readable
  from 0x0203c000; peripherals at APM 0xa0000000 + (phys - 0x10000000)) runs
  the flexPMU sequences. A core power-up request reaches it as a **GRP1**
  event of the PMU interrupt generator (0x14070000: GRP1 enable 0x100,
  pending 0x108, clear 0x10c; bits 0-3 = M3 cores, 4-7 = A55). Its GRP1 loop
  powers the cluster (cluster1_on: CPUCL1_HCHGEN_CLKMUX, NONCPU1 config
  0xf, BISR/OTP, ETC resets), then the core, then clears the core's GRP1
  enable bit.
- **GRP2** (0x14070200, pending 0x208, PMU 0x7f08) is the AP-side C2 wake
  group; with bits 0-3 pending, unmasking it hung the SoC.

## Measured (bring-up, 2026-10-22)

| | before | GRP1 bits 0-3 enabled + cpu4 online |
|---|---|---|
| GRP1 enable 0x14070100 | 0x0 | 0xe (APM cleared bit 0 itself) |
| NONCPU1 cfg / status 0x14062040/44 | 0x000f0000 / 0x00880000 (off) | 0x000f000f / 0x0010000f (on) |
| CPU4 cfg / status 0x14062000/04 | 0 / 0x00880000 | 0xf / 0x00100f0f (on, same as an onlined A55) |
| CRP_PM_CC1_0 0x1a0001a4 | 3 | 3 |

The kernel still reports `CPU4: failed to come online` with an untouched
secondary boot trace: the M3 never reached `secondary_entry`. No hang.

## Still open

- CRP_PM_CC1_0 stays 3 (cluster 1 disconnected from the coherent
  interconnect); nothing in the APM sequences clears it.
- Where the powered M3 is stuck: CPU4 external debug at 0x1e410000
  (stock coresight cl1_cpu0): MIDR 0xd00, EDPRSR 0x314, EDPCSR 0xa0/0xac
  (Samsung reads the M3 PCSR without unlocking).
- Cluster 1 must come up before `smp_init()` in the final kernel: a big core
  onlined later lacks the A55-only features the boot CPU enabled (LSE, PAN,
  ...).
- Stock also runs pmucal `lpm_init` (MEMORY_CLUSTER1_*_OPTION = 2,
  CPU_QCH_CLUSTER1_NONCPU top byte 0x8D, CPUCL1 HCHGEN/EXT_EVENT/SHORTSTOP);
  the A55 cluster works with the same option values left at 1, so this is
  probably not the blocker (drv/c2fix programs them anyway).

## DVFS tables (APM fvmap, kHz)

MIF 2093000 2002000 1794000 1539000 1352000 1014000 845000 676000 546000 421000;
INT 534000 400000 336000 267000 178000 107000;
CPUCL0 (A55) 2002000 .. 208000 (cpufreq uses up to 1950000);
CPUCL1 (M3) 2886000 2860000 2704000 2652000 2496000 2314000 2106000 2002000
1924000 1794000 1690000 1586000 1469000 1261000 1170000 1066000 962000
858000 741000 650000 598000 (boot level 1066000);
G3D 598000 .. 260000.
Running MIF (Duranium, 2026-10-23): PLL_CON0_PLL_MIF 0x1B800120 = 0xa19e0310
= 3588 MHz PLL -> MIF 1794 MHz. No kernel consumer of dvfs_mif/dvfs_int.
