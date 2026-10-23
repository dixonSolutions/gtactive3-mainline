# Exynos 9810 suspend, wake-up and power-off on the SM-T570

Our own description of how the SM-T570 (Galaxy Tab Active3) sleeps, wakes
up and powers off, and of what the mainline port does with it. Written from:

- Samsung's GPL kernel for the T570 family (`build/ref/gtactive3cs`, Linux
  4.9): `drivers/soc/samsung/exynos-pm.c`, `exynos-powermode.c`,
  `exynos-reboot.c`, `acpm/acpm.c`, `cal-if/` (PMUCAL tables
  `exynos9810/flexpmu_cal_*_exynos9810.h`), `drivers/firmware/psci.c`,
  `pinctrl-exynos.c`, `drivers/rtc/rtc-s3c.c`, the driver suspend paths named
  below;
- the stock device tree (`firmware/stock/stock-0.dts`, board overlay
  `dtbo-4.dts`);
- a look at the plaintext part of the stock EL3 monitor (in `sboot.bin`).

Nothing here is copied code: register names, offsets, values and sequences
only. Markers: **[GPL]** Samsung's source, **[DT]** stock DT, **[FW]** stock
firmware, **[HW]** measured on the device, **[?]** inferred, unverified.

## 1. What stock does for system sleep

Samsung's "suspend to RAM" is **not** PSCI SYSTEM_SUSPEND. The last CPU
makes a PSCI **CPU_SUSPEND** call with a "system" power state, after telling
the PMU firmware (flexpmu on the APM, the Cortex-M3 that also runs ACPM)
through the CPU_INFORM registers what it wants **[GPL]**.

Sequence (exynos-pm.c `exynos_pm_enter`, exynos-powermode.c
`exynos_prepare_sys_powerdown`, pmucal_system.c), with the secondary CPUs
already offline (PM_SLEEP_SMP):

1. syscore suspend:
   - PMU `EINT_WAKEUP_MASK` 0x060c = the alive-EINT wake mask from pinctrl
     (bit = EINT number, 0 = may wake; `irq_set_wake` clears the bit).
   - PMU `WAKEUP_MASK` 0x0610 = 0xd00f7e7e, `WAKEUP_MASK2` 0x0614 =
     0xffff00ff, `WAKEUP_MASK3` 0x0618 = 0xffff00ff, `WAKEUP_MASK4` 0x0644 =
     0 (DT exynos-powermode/wakeup-masks, column SYS_SLEEP = mode 8) **[DT]**.
   - CPU_INFORM of the calling CPU (PMU 0x0860 + 4 · cpu) = 4 (SLEEP;
     C2 = 1, CPD = 2, SICD = 3, SLEEP_USBL2 = 5) **[GPL]**.
   - save a few CMU registers (CPUCL1 EMA, G3D/AUD PLL lock times,
     SHORTSTOP, CPUCL1 CTRL_EXT_EVENT), then the "enter" sequence:
     pmu-intr-gen (0x14070000) `GRP2_INTR_BID_ENABLE` 0x0200 bit 4 = 1,
     clear the pending `GRP1_INTR_BID` bit 4 (0x010c if 0x0108 bit 4),
     PMU `EVENT_INTERRUPT_ENABLE_GRP2` 0x7f08 bit 4 = 1 (bit 4 = CPU0, the
     same per-CPU hint scheme as C2, see STATUS.md "CPU idle").
2. `arm_cpuidle_suspend(0x85)`: Samsung's psci.c maps index 0x85
   (PSCI_SYSTEM_SLEEP) to `power_state = 0x03000000` (original format:
   StateID 0, type 0, AffinityLevel 3) and calls CPU_SUSPEND 0xc4000001
   with `cpu_resume` as the entry point **[GPL]**. The APM firmware then runs
   its own SoC/MIF sequencers (`soc_sequencer_sleep_down` in the ACPM
   framework build of the same table: GPIO_MODE 0x3700, PAD_RETENTION_*,
   EXT_REGULATOR 0x3600 = PWREN, OSCCLK_SLEEP 0x2d60) **[GPL]**.
3. On wake-up the CPU comes back through `cpu_resume`; syscore resume runs
   the "exit" sequence: GRP2 bit 4 = 0, GRP2 pending clear, 0x7f08 bit 4 =
   0, every `BUS_COMPONENT_DRCG_EN` back to 0xffffffff (dynamic root clock
   gating of the bus components; conditional on the block being powered),
   then **releases the pad retention**: PMU `PAD_RETENTION_*_CONFIGURATION`
   bit 0 = 1 for TOP 0x3060, SPI 0x3080, BOOTLDO_0 0x30a0, BOOTLDO_1 0x30c0,
   PCIE 0x3120, UART 0x31a0. Without that release every pad stays frozen.
   An aborted entry (`early_wakeup`) instead clears GRP2/GRP1 bit 4,
   0x7f08 bit 4 and GRP4 bit 0.
4. Wake reason: PMU `WAKEUP_STAT` 0x0600 (bit 0 EINT, bit 1 RTC alarm,
   bit 2 RTC tick), extra stat 0x0640, alive EINT pending registers at
   GPIO_ALIVE (0x14050000) + 0xa00 + 4 · (n / 8) **[GPL]**.

There is **no AP to APM "go to sleep" IPC**: the APM learns it from
CPU_INFORM, the pmu-intr-gen request and the last core's PSCI call. ACPM
traffic on the way down comes only from drivers: the TMU (type 0x04
AP_SUSPEND on its channel, 0x10 on resume), devfreq (MIF/INT release at
suspend_late) and exynos-pm-dvs (lower LDO voltages through the PMIC)
**[GPL]**. `exynos_pm_enter` logs the APM's MIF-down counter (APM SRAM
0x0204f97c) to tell whether the memory interface really went down
(debug only).

A second variant, **SLEEP_USBL2** (mode 0xc, CPU_INFORM 5, WAKEUP_MASK
0xd00d7e7e), keeps the USB link in L2. Stock uses it only while DWC3 is in
**host** mode; as a gadget, DWC3 is shut down for sleep like everything
else **[GPL]**.

`WAKEUP_MASK` bits (1 = masked): bit 0 EINT, 1 RTC alarm, 2 RTC tick, 5 + n
PCIe channel n WAKE#, others unnamed **[GPL][?]**. The SLEEP value leaves
bits 0, 7, 8, 15, 20-27, 29 unmasked: the **SoC RTC alarm is masked in
stock sleep**, the alarms come from the S2MPS18 RTC through its IRQ line on
an alive EINT.

### PSCI / EL3

The stock DT has a PSCI 0.1 node (`"arm,psci"`, explicit cpu_suspend /
cpu_off / cpu_on IDs), so Linux never asks PSCI_VERSION or PSCI_FEATURES and
never calls SYSTEM_SUSPEND, SYSTEM_OFF or SYSTEM_RESET **[GPL][DT]**. The
EL3 monitor (sboot.bin + 0x1fd000, built Sep 2021) is encrypted apart from
its entry code, so the implemented functions cannot be read statically
**[FW]**. S-Boot itself uses the standard 0.2 IDs CPU_ON 0xc4000003 and
CPU_OFF 0x84000002 **[FW]**.

Test to run later (bring-up console or a tiny module; read-only, cannot
hang the tablet):

| call | x0 | x1 | meaning of the answer |
|---|---|---|---|
| PSCI_VERSION | 0x84000000 | | 0x00000002 = 0.2, 0x0001000x = 1.x, 0xffffffff = not supported (0.1) |
| PSCI_FEATURES | 0x8400000a | 0xc400000e | 0 = SYSTEM_SUSPEND implemented, -1 = not (or no FEATURES, i.e. < 1.0) |
| PSCI_FEATURES | 0x8400000a | 0xc4000001 | bit 1 = extended power_state format (expected 0) |
| PSCI_FEATURES | 0x8400000a | 0x84000008 | SYSTEM_OFF (expected 0 if 0.2+) |

Do **not** call SYSTEM_SUSPEND (0xc400000e) or SYSTEM_OFF/RESET before the
answers are known; SYSTEM_SUSPEND needs the secondaries offline and does not
return on success. Even if it exists, it would only do what CPU_SUSPEND
0x03000000 does with the flexpmu hints above.

## 2. Wake-up sources on the SM-T570

Alive EINT number = 8 · bank + pin (gpa0 = bank 0 ... gpa3 = 3, gpa4 = 4).
Only EINTs 0-31 fit the 32-bit `EINT_WAKEUP_MASK`.

| source | pin | EINT | stock | mainline (drv/suspend) |
|---|---|---|---|---|
| Power key | gpa2-4 | 20 | gpio-keys wakeup | gpio-keys `wakeup-source` |
| Home key | gpa3-5 | 29 | wakeup | `wakeup-source` |
| Active key | gpa0-5 | 5 | wakeup | `wakeup-source` (pin never changes on hw_rev 4) |
| Hall (cover) | gpa0-2 | 2 | always armed | `wakeup-source`, wakes on open only (EV_ACT_DEASSERTED) |
| S2MPS18 IRQ (RTC alarm, PMIC events) | gpa0-1 | 1 | armed | not used (PMIC read-only, no IRQ in DT) |
| MAX77705 (charger plug, USB-C, fuel gauge) | gpa1-6 | 14 | armed | max77705 MFD arms it (device_init_wakeup) |
| SM5504 pogo MUIC | gpa1-4 | 12 | armed | driver does not probe yet |
| Wi-Fi host wake (BCM4375 OOB) | gpa0-7 | 7 | armed | not used (brcmfmac PCIe has no OOB) |
| BT host wake | gpa2-3 | 19 | armed while BT is on | hci_bcm arms it while BT is up (CONFIG_PM) |
| Touch (Himax) | gpa1-0 | 8 | armed, but the IRQ is disabled in sleep | IRQ disabled in sleep |
| Pen (Wacom) irq / pdct | gpa3-3 / gpa3-7 | 27 / 31 | irq armed | not armed |
| Sensor hub | gpa4-0 | 32 | cannot wake (beyond the mask) | no driver |
| SoC RTC alarm | SPI 31 | | masked | **rtc-s3c, wake source for rtcwake** |

CMGP pins (gpm*) never wake in stock: they share the alive wake irq_chip,
and a `set_wake` on them would alias onto the alive bits. Mainline has the
same property (exynos7 wake chip: bit = 2 · eint_offset + pin, which for
gpm banks even exceeds 64 bits). Nothing on this board uses gpm IRQs.

### SoC RTC

`rtc@141e0000`, S3C6410-style RTC in the ALIVE block, alarm SPI 31, tick
SPI 32, register clock = CMU_APM `APBIF_RTC` gate (HWACG; which of the two
APM RTC gates belongs to 0x141e0000 is **[?]**), counter clock = the
S2MPS18's always-on 32.768 kHz output (XrtcXTI). Stock does not build the
driver (rtc0 is the S2MPS18 RTC); whether its counter runs and keeps time is
**unknown** until read on the device. The mainline kernel therefore uses it
only for alarms (`rtcwake`), not as the system clock (no RTC_HCTOSYS /
RTC_SYSTOHC until it has been seen to keep time).

## 3. Sleep states in the mainline port

The firmware speaks PSCI 0.1, so the kernel registers **no platform
suspend ops**: `/sys/power/mem_sleep` offers only `s2idle`, and "mem" means
suspend to idle. In s2idle:

- tasks are frozen, every device runs its suspend callbacks (noirq
  included), non-wake interrupts are disabled;
- the CPUs stay online and idle in the deepest *enabled* cpuidle state:
  without an `enter_s2idle` hook the idle loop falls back to
  `cpuidle_find_deepest_state()` through the normal enter path (tick
  stopped, timekeeping running). With C2 gated off (default,
  `exynos9810_c2=`) that is **WFI**; with C2 enabled s2idle would use C2.
  drv/deepsleep adds the hook (C2 then entered with the tick frozen) and
  stops exynos-pmu from dropping the C2 hints during s2idle (its noirq
  `sys_insuspend` flag used to suppress them for any suspend);
- when the last CPU enters, timekeeping and the clockevents are suspended:
  only a wake-armed interrupt (GIC SPI, alive EINT chained through the
  per-pin GIC lines) ends the sleep;
- the SoC itself stays powered (no PMU sleep, no pad retention): the PMU
  wake masks of section 1 play no role.

Battery effect: the device-side savings (backlight off, touch IRQ off, Wi-Fi
in D3 with its firmware asleep, UFS powered down, USB PHY off, GPU cores
off, CPUs at the 1053 MHz suspend OPP in WFI) without the SoC-level savings
(MIF/DRAM self-refresh, power domains off, PWREN low). The display pipeline
stays up (see below), which is the main remaining consumer.

### What each driver does (CONFIG_PM=y, drv/suspend)

| driver | runtime PM | system sleep |
|---|---|---|
| DPU (exynos9810_dpu) | none | pipe off like a screen blank (backlight 0 over DCS, scanout on the boot framebuffer, vblank off); DECON and DSI keep running (no code to restart them) |
| backlight / panel (dsim-bl) | none | follows the DPU (set_power) |
| panfrost | autosuspend 50 ms: cores + L2 off, reset on resume; the G3D domain stays on (keep-on) | forced runtime suspend |
| exynos-pd (G3D) | registers with CONFIG_PM, always on | – |
| UFS | none (no RPM_AUTOSUSPEND cap, LUs keep runtime PM forbidden) | **spm level 5** like stock: device power-down, link off, PHY isolated; resume = host reset + link startup (the probe path); FMP security SMCs redone |
| DWC3 + glue | forbidden by default (keep it so: never `power/control=auto`) | gadget soft-disconnect, core exit, PHY off, glue clocks off; on resume full core init and **re-enumeration** on the host |
| i2c-exynos5 / exynos-usi | none | noirq suspend; resume re-inits USI and HSI2C |
| spi-s3c64xx (touch, SPI21) | autosuspend 200 ms: gates its clocks, re-inits on resume | forced runtime suspend |
| samsung_tty (BT UART) | – | port suspend/resume, USI reset pulse on resume |
| hci_bcm (BT) | **new with CONFIG_PM**: host-wake IRQ on gpa2-3, UART LPM (sleep mode 1, BT_WAKE / HOST_WAKE active high, matching stock), autosuspend 5 s | host-wake armed as a wake source |
| brcmfmac PCIe | – | D3_INFORM handshake with the firmware, PCI D3hot; resume: hot resume or full re-probe |
| pcie-exynos9810 | – | none (link stays up, device in D3hot) |
| himax touch | – | IRQ disabled |
| wacom | – | power off/on |
| max77705 MFD | – | IRQ armed for wake |
| s3c2410 watchdog | – | stopped and restarted, or kept counting with `run_in_suspend=1` |
| rtc-s3c | – | alarm IRQ armed |
| cpufreq-dt | – | LITTLE cluster parked at the 1053 MHz `opp-suspend` |
| pinctrl | – | register save/restore; "No retention data configured" warning on the alive controller is harmless in s2idle |

## 4. Deep sleep (drv/deepsleep, off by default)

Kernel branch `drv/deepsleep` (from cand/1027) implements section 1 as
platform suspend ops, **only registered with `exynos9810_pm.deep=1`**
(command line, or written to `/sys/module/exynos9810_pm/parameters/deep`
at runtime). Then `/sys/power/mem_sleep` shows `s2idle [deep]`; the
device package keeps systemd on `SuspendState=freeze`, so only an explicit
`echo mem > /sys/power/state` uses it. Test plan with exact commands,
expected messages and recovery: `build/scratch/deepsleep/test-plan.txt`
(helper `deepsleep-test.sh` next to it). Nothing has run on the device yet.

### Flow (drivers/soc/samsung/exynos9810-pm.c, called from exynos-pmu)

1. `.begin`: optional RTC timer (`test_wake_sec`) on the SoC RTC as a
   dead man's switch.
2. devices suspend; the DPU blanks with `EXYNOS9810_PANEL_FORCE` (panel
   rails off, lanes in ULPS, DECON stopped) whatever `power_off_level`
   is; pinctrl (late) saves the banks and writes `EINT_WAKEUP_MASK`.
3. `.prepare_late` (after noirq suspend): every local power domain that is
   still on (DPU, AUD, G3D, DCF/DCPOST/DCRD, ISP, ... - Samsung's runtime
   PM has them all off at this point) is powered off like exynos-pd: CMU
   and SYSREG save, D-TZPC save SMC (0x82000410, 0), CONFIGURATION = 0,
   for G3D the oscillator switch. `domains_off=0` skips this.
4. CPUs 1-3 offline (generic; the CPU-off hints are the exynos-pmu
   hotplug ones), syscore (GIC distributor and CPU interface through the
   `cpu_pm` syscore, timekeeping).
5. `.enter`: save the always-on CMU/SYSREG list, program the DT wake-up
   masks (RTC alarm bit 1 cleared unless `rtc_alarm_wake=0`), CPU_INFORM
   = 4, GRP2 enable + EVENT_INTERRUPT_ENABLE_GRP2 bit 4, GRP1 pending
   clear, `cpu_suspend(0x03000000)` with `cpu_resume` as entry. Early
   return = firmware refused or saw a pending interrupt: early wake-up
   sequence, -EBUSY. `dry_run`/`test_abort` exercise this path.
6. Wake-up: exit sequence, CMU/SYSREG restore, masks back, wake-up reason
   (WAKEUP_STAT, EINT pending, APM SRAM sleep/MIF-down counters) to dmesg
   and `.../14060000.system-controller/sleep/result`.
7. `.wake` (before noirq resume): domains on again, D-TZPC restore SMC,
   CMU/SYSREG restore. Pinctrl (early resume) restores the banks and,
   once the last controller is done, sets PAD_RETENTION_*_CONFIGURATION
   bit 0 for TOP/SPI/BOOTLDO_0/1/PCIE/UART; `.finish` releases any group
   still retained.

Register lists: Samsung's `save_sleep` and the local `*_save` tables
(user muxes, dividers, PLL_AUD/G3D, clock-out, controller options,
Q-channels, DRCG), plus what Linux needs and stock does not save: the
gate registers of TOP/PERIS/PERIC/FSYS/CMGP/CHUB/DPU/AUD (user space and
`manual_gates` force gates on), the PERIC0/1 dividers and CMU_TOP PERIC
dividers (Linux uses fixed USI clocks), the CMU_TOP SD clock. Blocks of a
domain that is off are skipped (PMU STATUS checked at save and restore).

### Per block: what is lost, what restores it

| block | in SLEEP | restored by |
|---|---|---|
| ALIVE: PMU, GPIO_ALIVE/EINT, RTC, mailbox, CMU_APM/CMGP | kept (APM moves APM/CMGP bus muxes to OSC) | PM driver restores CMU_APM/CMGP muxes |
| CPU context, GIC-400 | lost | `cpu_suspend`/`cpu_resume`; `cpu_pm` syscore saves/restores the GIC distributor and CPU interface |
| arch timer | counter may restart (unknown) | timekeeping resume resets `cycle_last`; arch timer `cpu_pm` notifier; logged as "counter reset" |
| CMUs (TOP reset by the APM; leaf CMUs) | lost; TOP re-initialised by the warm-boot firmware (assumed, as stock never saves TOP) | PM driver save lists |
| local domains (DPU, AUD, G3D, ...) | must be off at entry (stock) | PM driver power off/on with D-TZPC SMCs |
| pads (TOP etc.) | retained until released | pinctrl after restoring the banks (shared count) |
| DECON/DPP/IDMA/DMA, DPU sysreg | lost | DPU driver: probe-time snapshot written back when DECON has no window enabled, D-PHY isolation bypass (PMU 0x70c/0x710) |
| DSIM links, M4S4 D-PHYs | lost | dsim-bl `restore` hook (drv/deepsleep is rebased on drv/panelpm): link and D-PHY configuration from a probe snapshot in Samsung's `_dsim_enable()` order, left as level 3 leaves it; panelpm's level 3 wake-up then locks the PLLs, brings the lanes to LP-11, resets and initialises the panel. The D-PHYs are mapped without claiming them (the CSIS receivers own the same ranges) |
| panel, touch (TDDI) | rails off by the forced blank | panel init sequence; touch follows the panel notifier |
| UFS host + PHY | lost | spm level 5 (already): host reset, PHY init, link startup, FMP SMCs |
| DWC3 + USB DRD PHY | lost | `dwc3_core_init` on resume (phy_init/power_on incl. PMU 0x72c), gadget re-enumerates |
| PCIe RC + PHY, BCM4375 | lost; chip powered (WLAN_REG_ON retained) | **not yet**: the driver refuses deep sleep (-EBUSY) while bound; unload pcie_exynos9810 after brcmfmac and reload after |
| HSI2C/USI/SPI/UART | lost | existing resume paths (USI SW_CONF, HSI2C init, s3c64xx hwinit, UART port restart); clocks from the PERIC divider restore |
| A-Box | lost (AUD domain) | A-Box suspend/resume (new): pad retention release, GPIO mode, MISC_CON, stream registers; codec regcache |
| G3D (panfrost) | lost | runtime PM resume does a full GPU reset/MMU init; PM driver handles G3D clocks + D-TZPC |
| TMU | lost (PERIS) | TMU driver (new): saved CONTROL/thresholds written back, enable last |
| watchdog | lost (PERIS), restarts with reset values | s3c2410_wdt noirq resume re-arms it (new) |
| CSIS (camera) | lost (ISP domains) | new streams program everything; deep sleep refused while streaming |
| SD (dw_mmc) | lost | runtime resume re-init; HS400_DQS_EN bit not restored (SD does not use HS400) |
| S2MPS18/MAX77705/codecs | on battery; PWREN-controlled LDOs go off | unknown which boot-on LDOs are PWREN-controlled (check LCTRL bits 7:6) |

### Unknown until run on the device

- Whether the EL3 monitor and the APM accept the system state from Linux
  (PSCI 0.1 firmware; `debugfs exynos9810-pm/psci` asks VERSION/FEATURES on
  read), and whether the CPU_INFORM/GRP2 hints suffice (APM sleep counter
  and MIF-down counter in the log tell).
- Whether CMU_TOP comes back as S-Boot set it (stock assumes so).
- Whether the SoC RTC alarm is a working PMU wake-up source (WAKEUP_MASK
  bit 1; stock masks it and wakes through the S2MPS18 RTC on EINT 1). The
  SoC RTC comes up cleared at every boot (invalid date, every read
  -EINVAL until `hwclock -w`); drv/deepsleep starts it at 2000-01-01 in
  that case so that rtcwake works right after boot.
- Spurious wake-ups from the unmasked WAKEUP_MASK bits 7, 8, 15, 20-27, 29.
- Whether the arch counter survives, the watchdog reset defaults after
  wake-up, and which external supplies drop with PWREN.
- The DSIM/DECON restart and the A-Box restore have only been reasoned
  out from Samsung's sequences: `pm_test=platform` with mem_sleep deep
  cycles the local domains without a SoC sleep and tests them first.

### Suspend-to-idle improvements, in order of value

1. **C2 in s2idle**: per-core C2 works and is on by default from device
   r41, so s2idle already picks C2 through the fallback path, but
   without the flexpmu hints (exynos-pmu dropped them during any
   suspend). drv/deepsleep keeps the hints in s2idle and lets s2idle
   enter C2 with the tick frozen; needs one s2idle test
   (`cpuidle/state1/s2idle_usage` must count).
2. **Panel/DECON off on blank** (`exynos9810_dsim_bl.power_off_level=3`,
   drv/blank): the largest screen-off consumer; no SoC sleep needed.
3. **MIF floor**: `exynos9810_pm.s2idle_mif_khz=421000` asks the APM for
   the lowest MIF level during s2idle (MIF runs at 1794 MHz otherwise).
   Implemented, off by default: MIF DVFS has never been driven from
   Linux. Try one s2idle cycle with the parameter written at runtime
   (`/sys/module/exynos9810_pm/parameters/s2idle_mif_khz`) before putting
   it on the command line.
4. **Big-cluster rails** (vdd_cpucl1 BUCK2, vdd_cpucl1_m): not worth it
   now. The PMIC is read-only except whitelisted LDOs, the APM sets the
   CPUCL1 voltage itself and powers CPUCL1 up in its SLEEP exit
   sequence; switching the rail off behind it risks a hang. The cluster
   is already power-gated (NONCPU off), only leakage at 681 mV remains.
5. INT floor: no measured need; same unknowns as MIF.

## 5. Power-off and reboot

- **Power-off** (stock `exynos_power_off`): ACPM STOP request (protocol 22,
  "enter WFI", on the ACPM channel of the `acpm` node, 4), then PMU
  `PS_HOLD_CONTROL` 0x330c bit 8 = 0: the PMIC cuts the SoC supplies
  **[GPL]**. The ACPM STOP keeps the APM from talking to the PMIC while
  power drops; stock sends it for reboots too, where mainline works without
  it. Mainline: the common `exynos-syscon-restart.dtsi` already gives the
  PMU a `syscon-poweroff` node, but it writes the Exynos5 reset value
  0x5200 to the whole register, and the driver was not built. drv/suspend
  overrides it to clear only bit 8 (mask 0x100, value 0) like stock and
  enables POWER_RESET_SYSCON_POWEROFF. PSCI 0.1 has no SYSTEM_OFF, so it is
  the only power-off handler. Before this, `poweroff` ended with no
  handler: the kernel halted with the power on and a panic/watchdog later
  rebooted the tablet.
- **With a charger attached** the PMIC powers the SoC up again for
  charging; S-Boot then boots BOOT with `androidboot.mode=charger` on the
  command line (stock Android shows its LPM charging screen) **[GPL]**. In
  our chain that is uniLoader -> U-Boot; to stay "off" U-Boot must notice
  the charger boot (the command line S-Boot passes) and show a charging
  screen or power off again instead of starting Duranium.
- **Reboot**: syscon-reboot from the same include, PMU `SWRESET` 0x0400
  bit 0 (priority above the watchdog restart handler); the boot reason for
  S-Boot is in PMU INFORM3 0x080c (syscon-reboot-mode).

## 6. Watchdog across boot and sleep

- `s3c2410_wdt` (cluster 0, 9810 variant): reset routing is PMU
  `AUTOMATIC_WDT_RESET_DISABLE` 0x0408 bit 24 = 0 and `MASK_WDT_RESET_REQUEST`
  0x040c bit 24 = 0 (bit 23 for cluster 1); reset status `RST_STAT` 0x0404
  bit 24 **[HW]**.
- drv/suspend keeps a watchdog that the bootloader left **armed** (WTCON
  enable and reset-enable bits set) instead of stopping it at probe; with
  `CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED` the core pings it until systemd
  opens /dev/watchdog. The driver re-programs its own timeout (15 s
  default) at probe and stops the watchdog in `.shutdown`, so a power-off
  is not turned into a reboot.
- What a bootloader must leave for the handover: PMU 0x0408 bit 24 = 0,
  0x040c bit 24 = 0, WDT (0x10050000) WTDAT = WTCNT = count, WTCON =
  prescaler << 8 | ENABLE (bit 5) | DIV128 (bits 4:3 = 3) | RSTEN (bit 0),
  INTEN (bit 2) off. With the 26 MHz source the longest timeout is
  65535 · 256 · 128 / 26 MHz = 82.6 s (prescaler 255).
- System sleep: the driver stops the watchdog (default) or, with
  `s3c2410_wdt.run_in_suspend=1` (writable at runtime), reloads it and
  lets it run, so a sleep that does not end within one timeout resets the
  SoC (WDT reset -> uniLoader boots the bring-up fallback).
