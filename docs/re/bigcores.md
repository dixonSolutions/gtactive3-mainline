# Exynos 9810 big cluster (4x Mongoose M3): power-up path

Our notes from live register reads on the SM-T570 and from Samsung's GPL
kernel (cal-if/exynos9810 flexpmu tables). Status: cluster 1 can be powered;
a late-onlined M3 enters the kernel; all eight at boot not yet confirmed.

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

## 2026-10-23: when does a powered M3 run?

| | QCH / MEMORY_CLUSTER1 options at CPU_ON | ACPM up | result |
|---|---|---|---|
| late online, 2026-10-22 kernel (no exynos-pmu option code yet) | S-Boot values 0xc7.. / 1 | yes | powered, never fetches, CRP 3 |
| late online, RECOVERY 2026-10-23, after the exynos-pmu probe | stock 0x8d.. / 2 | yes | enters the kernel, CRP **0**, dies at its first LSE atomic |
| CPU_ON in `smp_init()` (no maxcpus) | S-Boot values | no | powered, never fetches, CRP 3 |

- Nobody on the AP side writes CRP_PM_CC1_0 back: S-Boot sets [1:0] = 3,
  the APM's cluster1_off table does the same (then waits for bit 16 = 0),
  its cluster1_on table (HCHGEN = 0, NONCPU config 0xf, BISR/OTP, ETC
  resets) has no SCI write, and no APM code has an SCI address except the
  BTS-like setup of 0x090/0x0b4/0x0bc/0x108/0x140/0x1ac/0x1b4/0x1d4/0x1dc and
  0x808-0x83c. The port reads 0 once the core runs: the cluster (or the EL3
  warm boot on the core) connects itself. Writing [1:0] = 0 from the AP while
  the core could not run hung the SoC beyond the watchdog: never write it.
- So the precondition is stock `lpm_init`'s PMU subset, which stock applies
  at time_init (clk-exynos9810 -> cal_if_init) and mainline's exynos-pmu only
  at postcore: CPU_QCH_CLUSTER1_NONCPU top byte 0x8d and
  MEMORY_CLUSTER1_*_OPTION = 2 (the APM never touches either; they shape the
  PMU's own power-up of the cluster). exynos9810-cpucl1 LPM_PMU (0x02)
  applies them before the first big-core CPU_ON (test plan:
  build/scratch/bigcores/test-plan2.txt).
- APM flexPMU GRP1 handler (core wake): bit -> cpu (bits 0-3 = cpu 4-7),
  reads CPU_INFORM(cpu) (PMU 0x860 + 4 cpu); refuses with bit 16 set
  ("HotPLG_e") or INFORM[15:0] outside 1..3 ("invldnIR", "GRP1_err"), else
  powers cluster and core and clears the core's GRP1 enable and pending.
  (The working late online had INFORM = 0 written by exynos-pmu just before
  CPU_ON, so EL3's CPU_ON probably sets it; the APM log tag "cpu_infm"
  shows the value it saw.)
- S-Boot powers all cores into a secure-SRAM pen early, then powers cluster
  1 off when secure SRAM 0x02020000 != 0xdab and 0x1000903c[3:0] != 0. Its
  wait on CRP_PM_CC1_0 bit 16 tests the address register, not the value, so
  it never waits.
- Watchdog: stock `lpm_init` also sets RESET_LPI_TIMEOUT (0x420: bit 0,
  duration 0x20 in [31:16]) and WDTRESET_LPI (0x418 bit 0). Without the
  timeout a reset waits for LPI acks of every bus port; a wedged SCI port
  then blocks the watchdog reset (the 0x15 test). PMU RST_STAT watchdog bits
  survive a software reset.

## Still open

- Confirm LPM_PMU on the device (kexec test, then a cold boot), and which of
  QCH / memory option it is.
- Big-core C2, cluster power-down, CPUCL1 DVFS under cpufreq-dt.

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

## All eight CPUs at boot (2026-10-23, measured)

RECOVERY bring-up (4 CPUs, exynos-pmu probed: CPU_QCH_CLUSTER1_NONCPU top
byte 0x8d, MEMORY_CLUSTER1_*_OPTION = 2), then kexec into a test kernel with
no maxcpus and exynos9810_cpucl1.enable=0x11 (GRP1 wake + watchdog): all
four M3 cores boot in smp_init ("CPU4..7: Booted secondary processor
0x00000001nn [0x531f0020]", MPIDR 0x800001nn, suspend hash ok), online 0-7.
policy4 (CPUs 4-7) schedutil 598-1794 MHz reaches 1794 MHz under load;
capacity 1024 (M3) vs 318 (A55); energy model registered. Dependent-chain
benchmark: A55 486 Miter/s at 1950 MHz, M3 444 at 1794 MHz (same IPC on this
latency-bound loop), all eight 3547 Miter/s (four A55s: ~1931). The cold
boot that failed (CRP_PM_CC1_0 stayed 3) had S-Boot's values (QCH 0xc7,
MEMORY options 1): the PMU low-power settings must be in place before the
M3s' CPU_ON, see drv/bigcores-b LPM_PMU.
