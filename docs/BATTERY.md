# Battery: how stock Android gets a day, and our roadmap to match it

SM-T570 (Galaxy Tab Active3 Wi-Fi), Exynos 9810, 5050 mAh (health: charge_full
3917 of 4370 mAh design, 80 cycles). Written 2026-10-23 from the Samsung GPL
kernel + stock DT + stock `firmware/fs`, a read-only audit of the running
Phosh image (kernel r14 / cand/1023), and the CPU/PM reverse-engineering in
`docs/STATUS.md` and `docs/re/`. "Stock" = Android 13, the tablet's shipped OS.

## TL;DR

Stock reaches a day because **everything powers off the moment it is idle**,
not because it runs slow. Three layers do the work:

1. **CPU idle**: per-core **C2** power-down, then cluster power-down (**CPD**,
   big cluster only), then **SICD** (system idle clock-down: PLLs gated, DRAM
   self-refresh) while the screen is off but the SoC is "awake".
2. **System suspend (SLEEP)**: userspace autosleep gated by wakelocks drops
   the SoC to tens of mW; the ACPM firmware powers the MIF/DRAM down.
3. **Bus/GPU/display scale and gate off**: MIF/INT/DISP devfreq via ACPM, GPU
   runtime-PM power gating, and a real panel + DSIM + DECON power-off on blank.

Responsiveness comes from short, event-driven **boosts** (touch/app-launch
raise the floor for 0.1-1 s), not from a high base clock.

We have **none** of layers 1-3 working yet, and we have a software regression
that makes it far worse than it should be: the little cluster sits at 1950 MHz
most of the time. Measured now: **~600 mA idle with the screen on** (2.3 W),
vs the project's own earlier figure of 214 mA and Android's day-plus.

## Measured today (read-only, on the running Phosh image, not charging)

| Condition | Current | Notes |
|---|---|---|
| Screen on, apps busy | 716-1150 mA (avg ~0.9 A, 3.5 W) | test apps + agent SSH load |
| Screen on, quiet | 555-610 mA (2.3 W), UPower 3.9 W | 4 %/11 min capacity drop |
| Earlier project figure (26102208) | 214 mA screen on / 184 mA blank | docs/STATUS.md |
| Stock Android | not instrumented here | `power_profile.xml` is AOSP placeholder |

Root causes of the ~600 mA (vs 214) regression, in order of size:

1. **Little cluster pinned at 1950 MHz.** `sched_util_clamp_min_rt_default =
   1024`: every RT/RR thread wakeup (DRM vblank `card0-crtc0`, touch/SPI IRQ
   threads, `panfrost-job`, PipeWire data loops, `brcmf_pcie` IRQ) clamps the
   little cluster to the top OPP. `time_in_state`: 42 % at 1950 MHz, 49 % at
   455 MHz, 208/299 MHz never used, while CPU is <3 % busy.
2. **schedutil is twitchy and the ACPM path busy-waits.** rate_limit 150 µs;
   80-156 freq transitions/s; `sugov:0` burns ~6.5 % of a core because ACPM
   DVFS replies are polled with a `udelay(20)` loop. Each transition also
   fires function-call IPIs (145/s idle, ~1090/s busy).
3. **Screen never blanks** (user dconf `idle-delay = 0`), and even on blank we
   only turn the backlight off; the panel, DSIM and DECON keep scanning out.
4. **Big-cluster rails stay on** with the cores offline (`vdd_cpucl1` 681 mV,
   `vdd_cpucl1_m` 1300 mV).
5. **No cpuidle at all**: `cpuidle current_driver: none`, cores only WFI.

## How stock does it (evidence)

Paths: **K** = `build/ref/gtactive3cs` (Samsung 4.9 T570 kernel; the S9 tree
`src/samsung-9810-ref` is identical for all of this), **D** = stock DT
(`firmware/stock` / K dts), **V/S** = `firmware/fs/{vendor,system}`.

### CPU idle (C2 / CPD / SICD)

- The only DT cpuidle state is **C2** (PSCI `0x10000`): A55 entry 70 µs / exit
  160 µs / min-residency 2000 µs, M3 235/220/3500 µs (D cpus + idle-states).
  Governor `menu`, NO_HZ_IDLE + HIGH_RES_TIMERS, HZ=250, MCT driver on.
- **CPD and SICD are not cpuidle states** — they are escalations chosen inside
  the C2 entry path (`exynos_cpu_pm_enter`, K exynos-powermode.c:521): if all
  online cores in a cluster are in C2 with >=10 ms to their next event, the
  cluster powers down (CPD, big cluster only — powering the boot/A55 cluster
  down "gains nothing"); if additionally every unmasked idle-IP is idle, the
  AP enters **SICD**, where the APM gates the TOP/CPUCL1/FSYS0 PLLs and puts
  DRAM in self-refresh (`soc_sequencer_sicd_down`, `mif_sequencer_sicd_down`).
- Per-core C2 needs the **ACPM/APM handshake**: before power-down the kernel
  writes CPU_INFORM(cpu)=1 (PMU 0x14060000+0x860+4n), sets the core's bit in
  pmu-intr-gen GRP2_INTR_BID_ENABLE (0x14070200) and in PMU 0x7f08, and clears
  its GRP1 pending bit; the APM firmware then powers the core off, arms its
  GRP1 wake-enable, and powers it back on when a GRP1 wake event (from the
  GIC via pmu-intr-gen) arrives. docs/STATUS.md already records this.
- **SICD is impossible while the display is on** (`pd-dpu` is in the SICD
  idle-IP list), so a real panel-off is a prerequisite for screen-off SICD.

### System suspend

- `PM_AUTOSLEEP` is off; Android's userspace `system_suspend` writes
  `/sys/power/state` when no wakelock is held. DECON holds a wakeup source
  while the screen is on and releases it on blank (`_decon_disable`).
- `exynos-pm` syscore suspend enters SLEEP (PSCI `0x03000000`, CPU_INFORM 4,
  SLEEP_USBL2 when USB is attached); the APM sleep sequencers power MIF/DRAM
  down. Wakeup masks: EINT + RTC. (docs/re/suspend.md.)

### Scheduler, cpufreq, boosts

- EAS fork **EHMP/EMS**: ontime up-migrate to the M3 at load 79, back at 128;
  40 s boot boost; `input_booster` raises the floor on touch (M3>=1066, A55>=
  832 MHz for 130 ms, 500 ms tail). The **Hyper HAL** applies timed
  min-frequency / min-GPU / min-MIF / uclamp locks on app-launch (0.7 s),
  wake (1 s), interaction (0.5 s). cpufreq is schedutil + Samsung freqvar with
  **5 ms up/down rate limits** and an 80 % (A55) tipping point.
- Stock A55 range is **455-1950 MHz** (never 208), M3 650-1794 MHz.
- cpusets confine background/system-background to cpu0-1 / 0-2; Freecess
  freezes hidden apps.

### Bus / GPU / display

- MIF/INT/DISP/INTCAM devfreq, governor `interactive` = **max of PM-QoS
  minimum votes** (CPU-freq->MIF table, GPU-level->MIF, DECON BTS), no polling.
  MIF default 208 MHz (boot QoS 1794 for 40 s), INT down to 107, DISP 200-640.
- GPU (Mali-G72) DVFS 260-572 MHz, **runtime-PM autosuspend after 50 ms** so
  `pd-embedded_g3d` gates off whenever nothing renders.
- On screen-off the panel runs DISPLAY_OFF + SLEEP_IN (40 ms), DECON/DPP stop,
  BTS votes release, DSIM D-PHY off, and the panel rails go low
  (RST/BUCK_EN/LDO_EN), then `pd-dpu` powers off.

### Wi-Fi / BT

- bcmdhd PM2 always; on suspend: DTIM skip up to ~925 ms, ARP/ND offload,
  packet filters, firmware roam off; PCIe runtime-PM after 100 ms + L1SS;
  OOB host-wake GPIO. BT_WAKE drops 1 s after last TX; IRQ-driven host wake.

## Roadmap (prioritised; mA at ~3.7 V; "ship this week" = no device-driver work)

| # | Item | Layer | Expected saving | Difficulty | This week? |
|---|---|---|---|---|---|
| 1 | `sched_util_clamp_min_rt_default = 0` sysctl | device pkg | 40-120 mA | trivial | **yes** |
| 2 | Screen blank timeout (UI dconf 60-300 s) + ask user | device pkg | ~30 mA (backlight) | trivial | **yes** (user ok) |
| 3 | Wi-Fi powersave (`wifi.powersave=3`), ship `iw` | device pkg | 5-20 mA | trivial | **yes** |
| 4 | Drop phone daemons (chatty/calls/vvm/mmsd/wwan) | device pkg | <5 mA, ~450 MB RAM | trivial | **yes** |
| 5 | schedutil rate_limit ~2 ms + ACPM IRQ/sleep not udelay poll | kernel | 15-40 mA, fewer IPIs | medium | partial |
| 6 | Real panel/DSIM/DECON power-off on DPMS-off | kernel (DRM) | 100-200 mA when blank | medium | no |
| 7 | **cpuidle C2** per-core (drv/c2fix, this session) | kernel | 15-40 mA + enables SICD | hard | test now |
| 8 | MIF/INT devfreq via ACPM (QoS-voted) | kernel | large (DRAM/bus) | hard | no |
| 9 | GPU devfreq already gates (keep); verify in Phosh | — | — | — | — |
| 10 | System suspend (SLEEP) once wake path proven | kernel | dominant, screen-off | hard | no |
| 11 | Big-cluster rails off / cores powered down | kernel/DT | 0-100 mA | low-med | no |
| 12 | Display vblank IRQ off when idle (`disable_vblank`) | kernel | 2-5 mA | medium | no |

Items 1-4 alone should take quiet screen-on drain from ~600 mA toward ~400 mA
with no new driver work. Items 6, 8 and 10 are where the day-plus actually
comes from (panel off + SICD + suspend). Item 7 (C2) is the first CPU-idle
win and the prerequisite for SICD.

Exact drop-in files for items 1-4 are in the CPU/battery agent's hand-off to
the lead (device package, UI-neutral). C2 (item 7) is on kernel branch
`drv/c2fix`; see docs/STATUS.md "CPU DVFS and idle".
