# Lifecycle & backlog-hygiene maintenance — design

**Status: DRAFT (W4).** Design only; nothing below is wired up. The two
features here are *meta-maintenance* — they keep the fleet itself lean and the
backlogs themselves healthy, rather than doing any project work. Both are
strictly **advisory**: they surface candidates and propose cleanups, and a
human (or an explicit confirmation) does the destructive part. Neither ever
auto-archives a repo or auto-edits a backlog item.

Covers two `## Open` W4 items from [`Backlog.md`](./Backlog.md):

1. **Dead-project / archive-candidate detector** (P3 · W4) — auto-flag
   projects whose backlog has been effectively dead for weeks and are just
   burning heartbeat cycles + dashboard space; ties into `dev-projects archive`.
2. **Weekly backlog-hygiene self-audit tick** (P3 · W4) — a scheduled sweep of
   every backlog for stale items, duplicates, things parked in `## Thinking`
   forever, and mis-marked states, proposing cleanups so the queue doesn't rot.

Read alongside [`architecture.md`](./architecture.md) §2 (the data model), §6
(status & effort accounting — where the signals come from), and §7 (fleet &
lifecycle tooling — where these land as subcommands).

---

## Contents

1. [Design principles shared by both](#1-design-principles-shared-by-both)
2. [Feature 1 — dead-project / archive-candidate detector](#2-feature-1--dead-project--archive-candidate-detector)
3. [Feature 2 — backlog-hygiene self-audit](#3-feature-2--backlog-hygiene-self-audit)
4. [How each runs — placement decision](#4-how-each-runs--placement-decision)
5. [Safety model](#5-safety-model)
6. [Open decisions](#6-open-decisions)

---

## 1. Design principles shared by both

- **Propose, never delete.** Output is a *report* of candidates with reasons.
  The actual archive (`dev-projects archive`) or backlog edit stays a separate,
  human-confirmed step. See [§5](#5-safety-model).
- **Read from artefacts already on disk.** Both features derive their signals
  from data the system already produces — `docs/Backlog.md` marker counts, the
  per-host `backlog-status-<host>.json`, and the append-only
  `backlog-history.jsonl` ledger (architecture.md §6). No new per-tick state and
  no token spend to *gather* signals.
- **Fleet-level, read-only-by-default tools.** Like `backlog-agents doctor` and
  `canary`, both live above the per-project daemon and observe the whole fleet
  via `discover_active_repos` / the `~/dev/projects/active/*` scan. The detector
  is token-free (pure file reads). The hygiene audit is the only one that may
  optionally spend tokens (an agent pass), and only when explicitly run with a
  reasoning flag — its default mode is deterministic and token-free.
- **Idempotent + re-runnable.** Running either twice produces the same report
  and changes nothing. They never write to the queue or the manifest on their
  own.

---

## 2. Feature 1 — dead-project / archive-candidate detector

### The problem

A project that has shipped everything still runs its launchd daemon. Each
heartbeat (default 1800s, architecture.md §12) wakes `claude -p`'s skip path,
pushes a status commit, and takes a row in `backlog-agents`. A dozen finished
projects = a dozen daemons heartbeating forever and a dozen `0 open · idle`
rows drowning the dashboard. Nothing is *wrong*, but the active fleet stops
reflecting what's actually active. The fix is to notice "this backlog has been
empty for weeks" and nudge it toward `archived/`.

### The signal

A project is an **archive candidate** when *both* hold:

1. **`## Open` is empty.** Zero `- [ ]` / `- [!]` items in the `## Open` section
   (the only section the daemon picks from — architecture.md §2). `## Thinking`
   items do **not** count as live work (the daemon never picks them), and
   `## Blocked` `- [?]` items do **not** rescue a project from candidacy on
   their own — a project blocked-and-abandoned is exactly what we want to catch
   (it surfaces with a distinct reason; see below). `## In progress` `- [~]`
   items *do* keep a project live (work is mid-flight).

2. **Last completion is old.** The age of the most recent *work* tick exceeds a
   threshold (proposed default **21 days**, tunable). "Last completion" is
   derived, in priority order:
   - newest entry in `backlog-history.jsonl` with `exit_code == 0` and a
     non-null `work_commit` (a real item moved to `## Done`), else
   - `last_work_commit` / `last_tick_at` from `backlog-status-<host>.json`
     across all hosts (take the newest), else
   - if no history at all, fall back to the mtime of `docs/Backlog.md` (a never-
     worked scaffold counts as old once it ages out).

Both conditions are read straight from artefacts already described in
architecture.md §6 — no new instrumentation.

### Candidate reasons (the report classifies, doesn't just list)

| Reason tag | Condition | Suggested action |
|---|---|---|
| `done` | Open empty, no `[~]`, last completion > threshold, has history of completed work | strong archive candidate — work finished, queue drained |
| `never-started` | Open empty, no history, scaffold older than threshold | likely an abandoned `dev-projects new`; archive or populate |
| `stalled-blocked` | Open empty, only `[?]` blocked items, > threshold since last activity | needs a *decision*, not an archive — surface to user to unblock |
| `borderline` | Open empty + recent completion (< threshold) | not yet a candidate; shown only under `--all` for visibility |

`stalled-blocked` is deliberately **not** auto-flagged for archival — a blocked
project is waiting on the human, not dead. It is reported under a different
heading so the user unblocks rather than archives.

### How it surfaces

Three layers, increasingly pushy:

1. **On-demand report** — `dev-projects archive-candidates` (or
   `backlog-agents archive-candidates`; see [§4](#4-how-each-runs--placement-decision)).
   A read-only table:

   ```
   PROJECT            OPEN  LAST DONE   REASON          SUGGESTED
   old-landing-page   0     38d ago     done            dev-projects archive old-landing-page
   throwaway-spike    0     never       never-started   dev-projects archive throwaway-spike
   paused-thing       0     45d ago     stalled-blocked  (blocked — unblock, don't archive)
   ```

   The `SUGGESTED` column prints the exact `dev-projects archive <name>` command
   for `done` / `never-started` rows — copy-pasteable, never auto-run. `--json`
   for machine consumption; `--all` to include `borderline`.

2. **Dashboard annotation** — `backlog-agents` (default view, architecture.md
   §7) tags a candidate row with a dim `archive?` marker in the freshness
   column, so the signal shows up without a separate command. Purely cosmetic.

3. **Digest / notification (opt-in)** — when run on a schedule (see §4), if the
   candidate set is non-empty it emits one summary line through the existing
   `_notify` helper in `backlog-agents` (Slack webhook / local osascript, config
   at `~/.config/backlog/notify.json`). Throttled like the monitor's notifies.
   No notification when the set is empty (no noise on a healthy fleet).

### What it does *not* do

It never calls `dev-projects archive`, never boots out a daemon, never touches
the manifest. The whole feature is detection + suggestion. Archival remains the
existing manual `dev-projects archive <name>` path (bin/dev-projects
`cmd_archive` — moves to `archived/`, drops from manifest, boots the daemon),
which already has its own confirmations and leaves the launchd plist in place
for the user to remove.

---

## 3. Feature 2 — backlog-hygiene self-audit

### The problem

Backlogs rot in ways the daemon can't see because it only ever reads the *first*
pickable item:

- **Stale `## Open` items** that have sat untouched for months (the daemon keeps
  skipping past them because something earlier always wins, or they silently
  never match).
- **Duplicates / near-duplicates** — the same idea appended twice across
  sessions.
- **`## Thinking` graveyard** — ideas parked "to promote later" that have been
  there forever and will never be promoted.
- **Mis-marked states** — a `- [~]` (in progress) with no matching live claim
  (orphaned by a crash the reaper didn't catch), a `- [?]` blocked item that
  already has a `[user]` answer in its body but was never flipped to `- [!]`, a
  `- [x]` done item still sitting in `## Open` instead of `## Done`, or items
  with malformed markers.
- **Section-order / structural drift** — missing canonical sections, items under
  the wrong heading.

### The two-pass design

The audit runs in two passes, cheap-first:

**Pass A — deterministic linter (token-free, always runs).** Pure parsing of
`docs/Backlog.md`, reusing the same section/marker logic the status hook already
implements (architecture.md §2; the parser in `backlog-agent-status.mjs` that
counts markers by section). It flags everything detectable by rule:

| Check | Rule |
|---|---|
| stale-open | `- [ ]` in `## Open` whose introducing commit (git blame on the line) is older than N days (default 60) |
| thinking-rot | `- [ ]` in `## Thinking` older than M days (default 90) |
| orphan-inprogress | `- [~]` present but no live claim (no recent status commit / no `tick.inflight`) — cross-checks the reaper's liveness window |
| answered-not-flipped | `- [?]` whose body contains a `[user]` line but marker is still `[?]` (should be `[!]`) — same condition `auto_flip_blocked` keys on |
| misplaced-done | `- [x]` outside `## Done` / `## Archive` |
| malformed-marker | a list item whose bracket isn't one of the six known markers |
| dup-exact | two items with byte-identical text |
| missing-section | a canonical section header absent |

**Pass B — semantic review (token-spending, opt-in `--deep`).** For the fuzzy
cases Pass A can't do by rule — *near*-duplicates (same intent, different
wording), items that read as already-done, `## Thinking` items that are actually
ready to promote — a single `claude -p` (or the configured fallback agent) reads
the backlog and returns a structured proposal. This is the only token cost in
either feature, and it's gated behind an explicit flag. Like the worker, it
operates from the markdown contract, so it is agent-agnostic.

### Output — a proposal artefact, not an edit

Both passes emit a **proposal**, never a mutation. Two forms:

1. **Human-readable report** (default) grouped by check, each finding citing the
   item text + line number + reason + suggested fix. Per-project, or fleet-wide
   when run across all repos.

2. **A `cleanup:` proposal block appended to the backlog under a fenced,
   clearly-marked `## Hygiene (proposed — review & apply)` section** (opt-in
   `--write-proposal`). It writes *suggestions as text the user reviews*, not
   applied edits — e.g. "consider flipping item 7 `[?]`→`[!]` (has a `[user]`
   answer)", "items 3 and 11 look like duplicates". The user applies by hand or
   approves. This block is itself never picked by the daemon (it contains no
   pickable `## Open` items) and is removed by the user once actioned.

   Note: appending this block edits `docs/Backlog.md`, which trips `fswatch` and
   wakes the daemon. That's benign (the proposal section has no `## Open` items
   to claim) but the audit must commit the proposal as a distinct `hygiene:`
   commit so it's auditable and easy to revert, and must respect the same
   scoped-`git add` discipline the rest of the system uses (architecture.md §6 /
   the global git rules — explicit paths only, never `-A`).

The safe default is **report-only**; `--write-proposal` is the pushier mode and
still stops short of applying any state change to a real item.

---

## 4. How each runs — placement decision

Both are **fleet maintenance**, so they belong with the other observe/maintain
tooling (architecture.md §7), not inside `tick_once` (which is per-project work
execution and must stay token-frugal and single-purpose).

### Subcommand placement

- **Dead-project detector → `dev-projects archive-candidates`.** It reasons
  about *repos and the manifest* (the `dev-projects` domain), and its suggested
  action is a `dev-projects archive` command. It naturally sits beside
  `dev-projects status` / `list`. (Alternative: `backlog-agents
  archive-candidates`, since the freshness signal lives in `.claude/` status
  files that `backlog-agents` already reads. See open decisions.)

- **Hygiene audit → `backlog-agents audit` (Pass A) / `audit --deep` (Pass B).**
  It reasons about *backlog contents and marker health*, which is the
  `backlog-agents` domain (the same place `doctor` lives). `doctor` checks
  *config/daemon* hygiene; `audit` checks *backlog-content* hygiene — a clean
  parallel.

Both follow the `doctor` / `canary` precedent: read-only by default, exit
non-zero only in an explicit gate mode if the user wants to use them in CI, and
no mutation without an explicit flag.

### Scheduling — a watchdog tick, not a daemon tick

Neither should run on the hot per-item path. Two viable schedule hosts:

1. **Reuse `dev-projects watch-daemons`'s loop.** It already wakes on an
   interval (default 1800s) and runs `cmd_install_daemons` + `cmd_health_check`
   (bin/dev-projects). Add a *low-frequency* gate inside it: run
   `archive-candidates` and `audit` at most **once a day** (track a
   `last-audit` timestamp under `~/.claude/`), regardless of the 30-min wake
   cadence. This piggybacks on infra that already exists and runs fleet-wide.

2. **A dedicated launchd plist** (mirroring `install-watchdog`) running a
   `weekly-hygiene` entrypoint on a `StartCalendarInterval` (e.g. Monday 09:00).
   Cleaner separation, one more plist to manage. The backlog item calls it the
   "**weekly** backlog-hygiene self-audit tick," which favors this option's
   explicit weekly cadence.

**Recommendation:** start with option 1 (daily, piggybacked, report-only,
notify-on-findings) because it ships with zero new launchd surface and reuses
the existing watchdog liveness; promote to a dedicated weekly plist (option 2)
only if the daily cadence proves too chatty or the deep pass needs its own
schedule. Either way the *scheduled* run is report/notify-only — the
`--write-proposal` and any apply step stay manual.

### Cost shape

- Detector: pure file reads, token-free, safe at any cadence.
- Audit Pass A: pure parse + `git blame`, token-free.
- Audit Pass B (`--deep`): one `claude -p` per project; only on explicit
  invocation, never on the scheduled path by default. If ever scheduled, it must
  consult the cooldown (`agent-cooldown.json`) and skip while a plan-limit
  cooldown is armed, exactly like `tick_once` (architecture.md §11), so hygiene
  never competes with real work for a scarce token budget.

---

## 5. Safety model

The load-bearing invariant for both: **detection and proposal are decoupled
from action.**

- **No auto-archive.** The detector emits candidates + the exact command; it
  never runs `dev-projects archive`, never boots a daemon, never edits the
  manifest. A project wrongly flagged costs the user one ignored report line,
  not a moved repo.
- **No auto-edit of real items.** The audit never flips a marker, deletes a
  duplicate, or promotes a `## Thinking` item. The strongest thing it does is
  append a clearly-fenced *proposal* section (opt-in) that the user reviews and
  removes. Real-item state changes stay with the user or the existing daemon
  paths (`auto_flip_blocked`, the reaper) that already own them.
- **Conservative thresholds + escape hatches.** Age thresholds are tunable and
  default high (21d archive, 60d stale-open, 90d thinking-rot). An opt-out marker
  (e.g. an HTML comment `<!-- keep-active -->` near the top of a backlog, or a
  `keep` tag in the manifest) exempts a project the user wants kept active
  despite an empty queue — read but never written by the detector.
- **`stalled-blocked` ≠ archive.** Blocked-but-empty projects are surfaced for
  *unblocking*, never proposed for archival, so a project waiting on the human is
  never mistaken for dead.
- **Auditable, revertable mutations.** The one place either feature can write
  (the opt-in proposal block) goes in its own `hygiene:` commit with scoped
  `git add` (explicit paths only — never `-A`/`.`, per the global git rules and
  architecture.md §6), so it's a trivial single-commit revert and never sweeps a
  parallel edit.
- **Respect the daemon's locks.** Anything that edits a backlog must not race a
  live tick. The scheduled audit runs from the watchdog context (not inside
  `tick_once`) and, before writing a proposal, checks there's no in-flight tick
  (`backlog-agent-tick.inflight` / a recent claim) for that project — deferring
  to the next cycle if one is active, rather than committing into a contended
  tree.

---

## 6. Open decisions

- **Detector home: `dev-projects archive-candidates` vs `backlog-agents
  archive-candidates`.** The action is a `dev-projects` command (argues for
  `dev-projects`), but the freshness signal lives in `.claude/` status files
  that `backlog-agents` already parses (argues for `backlog-agents`). Leaning
  `dev-projects` for action-locality; needs a call.
- **Archive-candidate age threshold.** 21 days proposed. Too low → churns
  briefly-quiet projects; too high → dead repos linger. Wants a real value once
  there's fleet data on typical idle gaps.
- **Schedule host: piggyback on `watch-daemons` (daily) vs dedicated weekly
  launchd plist.** The item name says "weekly," favoring the dedicated plist;
  the cheap-to-ship path is the piggyback. Recommendation is piggyback-first,
  but the user may prefer the explicit weekly plist from the start.
- **Should Pass B (semantic `--deep`) ever run on the scheduled path?** Default
  proposal is no (manual-only, to keep the schedule token-free). Revisit if the
  deterministic Pass A misses too much (near-dup / already-done detection is its
  main gap).
- **Proposal delivery: report-only vs the opt-in in-backlog `## Hygiene`
  block.** Writing into the backlog is the most visible but also the only path
  that mutates the file. Confirm whether the user wants that opt-in at all, or
  prefers proposals to live only in the CLI report / notification.
- **Opt-out mechanism for "keep active despite empty queue."** HTML comment in
  the backlog vs a manifest tag vs a `~/.claude/` allowlist. Needs a pick before
  the detector can honor exemptions.
- **Should the detector and audit share one `lifecycle`/`maintenance`
  entrypoint, or stay two subcommands?** They run on the same schedule and share
  the fleet-scan; one combined command is fewer moving parts, two keeps domains
  clean (repos vs backlog content).
