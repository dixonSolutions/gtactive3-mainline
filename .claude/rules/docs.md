# Documentation (thorough and coordinated)

The docs are how the next agent, the owner and `/status` know where the
port stands. Work is not done until they say so, consistently.

- **One fact, one home; everything else links.** Each file has a job:

  | File | Holds |
  |---|---|
  | `config.toml` | the port's public values (never copied into prose) |
  | `docs/HARDWARE.md` | what the device is: parts, buses, addresses, partitions, each with a source |
  | `docs/STATUS.md` | what is verified on the device, strictly (legend in the file) |
  | `docs/PLAN.md` | starting points, risks, phases, per-block work, the next three steps |
  | `docs/AGENT-HANDOFF.md` | the state today, dated, newest on top; what waits for the owner |
  | `docs/TESTPLAN.md`, `logs/test-runs/<date>-<what>/` | how each block is tested; the evidence |
  | `docs/re/<subsystem>.md` | facts learnt from decompiling, in our own words, with sources |

- **Same names everywhere.** A block is called the same in HARDWARE.md,
  STATUS.md, PLAN.md and the handoff, and has a row in each.
- **Every claim has its source.** A fact: file, DT node, source path:line,
  URL or commit. A ✔ in STATUS.md: the test run (log directory or commit)
  and the date. "?" where unverified; never upgrade a row on belief.
- **Update in the same change.** A commit that changes what works, what is
  next or how something is done updates the docs it affects in that same
  commit: STATUS.md when a test result changes (better or worse, bugs
  included), PLAN.md when a step lands, gets blocked or turns out
  impossible (say why), HARDWARE.md when a fact is learnt.
- **Before you stop**, update `docs/AGENT-HANDOFF.md`: date and time, who,
  what changed, what is in flight (branches, worktrees, uncommitted work,
  running builds), the next three steps (the same as PLAN.md's), and what
  waits for the owner. A session that ends without this leaves the port
  harder to continue.
- **Consistency check** after editing docs: every HARDWARE.md block has a
  STATUS.md and a PLAN.md row; PLAN.md's next steps match the handoff;
  links and paths resolve; no `@TOKEN@` left in a port; dates are
  absolute (2026-10-24, not "yesterday").
