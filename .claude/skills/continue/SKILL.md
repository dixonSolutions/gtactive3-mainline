---
name: continue
description: Continue the work on this exynos-linux device port - takes the /status picture (health, urgent items, blocks, next priorities), picks the top priority and works it through the build loop (change, build, A/B update, test, record), keeping the docs coordinated, then the next one. Use when the user runs /continue, or says "carry on", "keep going", "pick up where we left off" on the port.
---

# Continue the port (/continue)

## 1. Where things stand

Run the `status` skill's gathering and judging (its steps 1 and 2)
yourself; skip its long report. Show the owner only a short version: the
health line, any urgent items and the three next priorities.

If the repo is still the template (`project.template = true`) or its docs
are unfilled, this is not the skill: run `/setup`.

## 2. Pick the work

In this order:

1. **Urgent first** (red CI on main, a regression in a ✔ block, work at
   risk, the owner waiting).
2. **Doc drift that misleads** the next step (a ✔ without evidence on a
   block the next step depends on): verify or downgrade it first.
3. **PLAN.md's next step**, by dependency, unless the handoff records a
   newer decision.

Do not pick work another session already owns (a branch, a worktree or
the handoff says who); do not pick a device test while a coordinator named
in the handoff owns the device, ask it instead. If the priority needs a
decision only the owner can make (a wipe, a publish to a release channel,
a physical action), ask that one question and take the next priority while
waiting. Otherwise decide and start: say in one line what you are doing and
why it is first.

## 3. Work it

- Follow the port's build loop skill (`build-loop`, or the one its
  CLAUDE.md names): change in `src/linux` or the aports,
  module-level tests in the bring-up Linux, `scripts/build-image`, A/B
  update, test on the device per `docs/TESTPLAN.md`, logs in
  `logs/test-runs/<date>-<what>/`.
- `.claude/rules/device-safety.md` holds throughout: every test has its
  way back, only one session drives the device, the owner is asked only
  for physical actions.
- Reference work (registers, clocks, pins, power sequences) comes from the
  starting trees in PLAN.md and the GPL kernel, written as clean mainline
  code with attribution kept (`setup` skill, step 3).
- Commit in small chunks (`.claude/rules/code.md`), each with the docs it
  affects (`.claude/rules/docs.md`): STATUS.md only on evidence, PLAN.md
  when a step lands, gets blocked or proves impossible (with why).

## 4. Loop or stop

When the step is done (verified, or blocked with the reason written down):

- update `docs/AGENT-HANDOFF.md` (dated, what changed, what is in flight,
  the next three steps matching PLAN.md);
- re-judge the priorities (status step 2) and go on with the next one
  while it needs no owner decision;
- stop when the owner asked for one step, when everything left needs
  them, or when a test cannot be run safely; then report in a few lines:
  what was done and verified (with the evidence), what is not, the new
  health line, and what waits for them.
