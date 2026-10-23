---
name: status
description: Report where this exynos-linux device port stands, as one easy-to-scan page - overall port health, anything urgent, a block-by-block table (verified, works unverified, buggy, in progress, not started, not possible - with how and why), recent work locally and on GitHub (uncommitted, unpushed, branches, CI, PRs, releases), what is left and the next priorities. Read-only. Use when the user runs /status, asks where the port is, what works, what was done recently or what to do next; /continue uses it to pick the work.
---

# Port status (/status)

Read-only: no builds, no device access beyond reading what is already
logged, no edits, no commits. A port older than the template may keep
these files elsewhere (PLAN.md or HARDWARE.md at the top level, a
coordination doc): its CLAUDE.md says where. The report is built from evidence, and the
docs are checked against it: a doc that disagrees with git, CI or the test
logs is itself a finding.

## 1. Gather (in parallel where you can)

- **The docs**: `docs/AGENT-HANDOFF.md` (newest state, its date),
  `docs/STATUS.md`, `docs/PLAN.md` (starting points, risks, phases, next
  three steps), `docs/HARDWARE.md`, `docs/TESTPLAN.md`, `config.toml`
  (`scripts/config get device.status`, `project.repo`, the channels).
- **Evidence**: `ls -t logs/test-runs/ | head`, and for each block a
  STATUS.md row claims, the run it cites (does it exist, how old is it,
  did it pass).
- **Local work**: `git status --short`, `git log --oneline -15`,
  unpushed commits (`git log @{u}..` per branch), `git worktree list`,
  `git branch -vv --sort=-committerdate | head`, and in `src/linux` the
  integration branch, topic branches and their last commits. Uncommitted
  work in another worktree belongs to someone; report it, never touch it.
- **GitHub** (`gh`, repo from `project.repo`; skip with a note if gh is
  not logged in): `gh run list -L 10` (failures on main first), `gh pr
  list`, `gh issue list -L 20` (labels bug/urgent first), `gh release
  list -L 5`, and the published channel versions if the Pages site is up.
- **In flight**: running builds (`pgrep -af 'build-image|pmbootstrap|make'`),
  other Claude sessions named in the handoff (a coordinator owns the
  device: say so), anything the handoff says waits for the owner.

## 2. Judge

Classify each block of STATUS.md / HARDWARE.md, strictly:

| Mark | Meaning | Needs |
|---|---|---|
| ✔ verified | Duranium ✔ in STATUS.md with a test run you found | the run's date and path |
| ◐ works, unverified | works at bring-up only, or a ✔ without evidence, or evidence older than a kernel change that touched it | what is missing to verify |
| ✘ buggy | a known failure (STATUS.md, an issue, a failing test, the handoff) | the symptom and the issue/log |
| … in progress | a branch, PR or open PLAN step on it | where |
| — not started | nothing yet | the PLAN step |
| ⊘ not possible (now) | blocked by hardware, TrustZone, missing docs/firmware, or upstream | why, and what would unblock it |

Then the **port health**, one line: `healthy` (main green, docs current,
progress in the last week), `at risk` (stale handoff >7 days, red CI on
main, verified blocks regressed, unpushed work piling up), or `blocked`
(a risk from PLAN.md hit: unlock gone, device unavailable, a hard
dependency stuck). Say which facts decided it.

**Urgent** is anything that loses work or users: red CI on main or a
failed publish, a regression in a ✔ block, a device left in a bad state,
uncommitted or unpushed work at risk, a security or signing problem, a
release channel serving a broken build, the owner waiting on us.

**Doc drift**: STATUS.md claims without evidence, a handoff older than
the last commits, PLAN.md next steps already done or contradicting the
handoff, blocks missing from a file (`.claude/rules/docs.md`).

## 3. Report

One page in chat, scannable, in this order:

1. **Health**: `<device> (<model>, <soc>) · <device.status> · health:
   <healthy|at risk|blocked>` and one sentence why.
2. **Urgent** (omit when none): one line each, with the fix.
3. **Blocks**: one table, every block, sorted ✘, …, ◐, —, ⊘, ✔:

   | Block | State | Evidence / where | How | Why / blocker | Next |
   |---|---|---|---|---|---|

   "How" is the driver or approach (mainline driver, DT only, our
   driver, firmware from stock); "Why" says why it is not done or not
   possible. Keep cells short; link files as `path:line`.
4. **Recent work**: local (uncommitted, unpushed, branches, worktrees,
   running builds) and on GitHub (last commits on main, CI, open PRs,
   last release per channel), dated.
5. **What is left**: PLAN.md phases with done / in progress / open, and
   the count of blocks per mark.
6. **Next priorities**: the top three, urgent first, then PLAN.md's
   order by dependency, each with why now and what it unblocks. Say where
   this disagrees with the handoff's next steps.
7. **Doc drift** (omit when none): what to fix in which file.

End with one line offering `/continue` on priority 1. Offer to publish
the page as an artifact only if the owner wants to share it.
