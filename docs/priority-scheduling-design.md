# Priority-weighted fleet scheduling — design (DRAFT · W3)

> **Status: DRAFT.** Backlog item *(P2 · W3) Priority-weighted fleet
> scheduling*. This sketches two implementations (a lightweight per-project
> weight and an elegant single fleet scheduler) and how priority interacts
> with the existing escalating-idle-sleep + cooldown and underpins
> `infra = highest priority` for fleet-freeze. Open DECISIONS at the end gate
> implementation; do not build until they are resolved.

---

## 1. The problem

Today all daemons are **peers with no notion of value**. Each project's
LaunchAgent runs its own independent `tick_once` loop (architecture.md §8) on
the same cadence constants (`HEARTBEAT_SECONDS=1800`, `FAST_SECONDS=300`, the
`ESCALATING_IDLE_SLEEP` schedule — all in `bin/backlog-agent`). The only shared
constraint is the **Anthropic plan limit, which is per-account** — shared across
every machine and project (this is exactly the framing of the W2
account-cooldown item).

Two consequences:

1. **No prioritisation.** A high-value project (e.g. one shipping a release this
   week) ticks at the same rate as a parked, low-value one. When `claude -p`
   capacity is plentiful this is harmless; when it is scarce it is wasteful —
   low-value projects consume account budget that high-value work needed.
2. **First-come contention for the shared budget.** When several daemons wake
   near-simultaneously (an `fswatch` storm, a heartbeat alignment, or recovery
   after a cooldown reset), they race for the same account budget on a
   first-to-call-`claude` basis. Whoever's loop happens to fire first wins; this
   is arbitrary, not value-ordered. Hitting the plan limit then arms cooldown
   (architecture.md §10) — so the *arbitrary* winners got their work in and the
   losers stand down, regardless of which work mattered more.

The goal: **a per-project priority so high-value work gets more frequent ticks
and wins contention for the shared account budget.** And specifically, priority
must be expressible strongly enough that `backlog-infra` can be declared
*highest priority* — the load-bearing requirement for the W3 fleet-freeze item
(infra changes are fleet-affecting, so infra's own work must outrank everyone).

This design deliberately sketches **two tiers**: a lightweight version that
needs no cross-machine coordination and can ship immediately, and an elegant
version that requires the D1 bus (W1) and replaces independent loops with a
single allocator. They are **the same priority model at two levels of
ambition** — the lightweight one is a strict subset, so it is also the
migration's first step.

---

## 2. How priority is declared

Both tiers read the **same priority source**, so the declaration mechanism is
settled independently of which scheduler consumes it.

### Source of truth: extend `~/.claude/backlog-budgets.json`

`backlog-budgets.json` is already the per-user, fleet-wide config the status
hook and dashboard read (architecture.md §6, §12). Today it carries account-wide
targets:

```jsonc
{
  "label": "personal agent-effort budget",
  "budgets": {
    "rolling_5h_tokens": 3000000,
    "rolling_week_tokens": 30000000
  }
}
```

Add an optional **`projects`** map keyed by project name (the same key the
dashboard already uses), each with a `priority` and an optional per-project
budget (which the W2 per-project-enforcement item also wants — they share this
block, build the field once):

```jsonc
{
  "label": "personal agent-effort budget",
  "budgets": { "rolling_5h_tokens": 3000000, "rolling_week_tokens": 30000000 },
  "default_priority": 50,
  "projects": {
    "backlog-infra":    { "priority": 100 },   // highest — see §6
    "backlog-dashboard":{ "priority": 70 },
    "sacred-geography": { "priority": 60, "rolling_5h_tokens": 800000 },
    "some-parked-repo": { "priority": 10 }
  }
}
```

- **`priority`** — an integer weight, higher = more valuable. A 0–100 scale is
  suggested (mnemonic, leaves headroom). Absent → `default_priority` (absent →
  `50`). This is a *relative* weight, not an absolute rate; the scheduler
  normalises (see §4, §5).
- **`backlog-infra` is pinned at the top of the scale by convention**, which is
  what §6 / fleet-freeze leans on. (Whether infra should be a hard `Infinity`
  rather than just the largest finite value is **DECISION 4**.)

Rationale for choosing the budgets file over a new file or an in-repo field:

- **Already fleet-wide and per-user.** Priority is inherently a *cross-project
  ranking decision the user makes* — it does not belong inside any one repo's
  `docs/Backlog.md` (which is per-repo and agent-mutable; letting an agent edit
  its own priority is a trust hole, cf. the prompt-injection threat model). The
  budgets file is human-owned and already the place fleet-wide knobs live.
- **One file the dashboard + scheduler + budget-enforcement all read.** No new
  config surface, no new `doctor` check beyond extending the existing
  budgets-file validity check.
- **Backward compatible.** Missing `projects` / `priority` → everyone is
  `default_priority` → behaviour is identical to today (uniform). Shipping the
  field is a no-op until someone sets a weight.

### Alternative considered: per-repo declaration

A `priority:` line in each repo's backlog header or a `.claude/priority` file
was considered and **rejected as the source of truth**: it puts a cross-project
ranking inside per-project, agent-writable state, and it forces the fleet
scheduler (§5) to read N repos to learn the ranking. (A per-repo file could
still serve as a *self-nomination* an agent surfaces to the user — but the user
ratifies it into `backlog-budgets.json`; the agent never sets its own priority.
This stays out of scope here — DECISION 5.)

---

## 3. Interaction with the existing tick cadence

Priority must compose cleanly with the two existing time controls in
`do_run` / `tick_once` (architecture.md §4, §8) rather than fight them:

- **Escalating idle backoff** (`ESCALATING_IDLE_SLEEP="30 60 120 300 600 1800"`,
  selected by `_pick_idle_sleep` on the `idle` outcome): an *idle* daemon
  already backs off, so a low-priority project that has nothing to do is already
  cheap. Priority must **not** override the idle escalation's job of quieting a
  project with an empty `## Open` — an idle project is idle regardless of
  weight. Priority modulates the cadence of a daemon that *has work*, and the
  *aggressiveness* of how fast it climbs the idle ladder, not whether it climbs.
- **Cooldown** (`COOLDOWN_WAIT_SECONDS`, the `cooldown` outcome): when the
  account plan limit is hit, *everyone* should stand down — that is the W2
  account-cooldown item's whole point. Priority must **never** let a
  high-priority daemon keep calling `claude` through an armed account cooldown
  (that just re-hits the limit and burns the signal). **Cooldown strictly
  dominates priority.** Priority decides *who goes first when capacity returns*,
  not *who may ignore the limit*.

So the precedence at top-of-tick is, highest-to-lowest:

```
fleet-freeze (W3)  >  account cooldown (W2)  >  priority scheduling  >  idle backoff
```

(fleet-freeze on top because a stale-infra freeze must halt even high-priority
project work — except infra itself, §6.)

---

## 4. Lightweight version — per-project tick weight

**No cross-machine coordination. Ships without the D1 bus.** Each daemon stays
an independent loop; priority just **scales its own sleep interval** so
high-priority projects tick more often and therefore *naturally win more of the
first-come races* (more frequent attempts → more frequent wins) without any
explicit arbitration.

### Mechanism

Add a derived multiplier to `do_run`'s sleep computation. Read this project's
priority from `backlog-budgets.json` once at daemon start (re-read on each tick
is cheap and lets the user retune without a restart — prefer per-tick read,
it's a tiny JSON file):

```
weight   = priority / default_priority      # 1.0 at default, >1 high, <1 low
factor   = clamp(default_priority / priority, FLOOR, CEIL)   # inverse: <1 speeds up
```

Apply `factor` as a multiplier on the **work-cadence and idle-ladder sleeps**,
not on cooldown (per §3):

- `work` outcome: `sleep_sec = round(base_sec * factor)` where `base_sec` is the
  current `FAST_SECONDS` / `HEARTBEAT_SECONDS`. A priority-100 project with
  default 50 → `factor 0.5` → heartbeats every 900s instead of 1800s; a
  priority-10 project → `factor 5.0` (clamped at `CEIL`) → backs off hard.
- `idle` outcome: scale the value `_pick_idle_sleep` returns by `factor` so a
  high-priority project climbs the idle ladder more slowly (re-checks for new
  work sooner) and a low-priority one climbs faster.
- `cooldown` outcome: **unchanged** — `COOLDOWN_WAIT_SECONDS` is honoured
  verbatim.

Clamp `factor` to a sane band (suggest `FLOOR=0.25`, `CEIL=6.0`) so no project
can busy-spin (`claude` calls cost money + hit the very plan limit we respect)
and none is starved to never-ticks. The floor in particular keeps a
high-priority project from polling `claude` so fast it single-handedly trips the
account cooldown — the floor is the lightweight version's only contention
safety, and it is crude (see Limitations).

### Where it touches code

- `bin/backlog-agent`: a `_project_priority()` helper (reads
  `backlog-budgets.json` via `jq`, falls back to `default_priority` then `50`),
  a `_priority_factor()` that returns the clamped multiplier, and three
  multiply-and-round sites in the `case "$TICK_OUTCOME"` block of `do_run`
  (lines ~1160–1180) — `work`, `idle`, and the heartbeat-loop twin at ~1212.
  Cooldown branch untouched.
- `backlog-agents doctor`: extend the existing budgets-file validity check to
  warn on a non-integer / out-of-range `priority`.
- `backlog-agents` dashboard: show a `PRIO` column so the ranking is visible.

### What it buys / what it does not

- **Buys:** immediate, dependency-free prioritisation of *tick frequency*. High
  value → more attempts → statistically more wins of the first-come race. Zero
  new infrastructure; pure-local; fully backward compatible.
- **Does not buy:** true contention arbitration. It is *probabilistic* — two
  daemons can still collide on the same tick and the lower-priority one can
  still win that particular race. It cannot *reserve* account budget for
  high-priority work; under heavy contention the floor is the only guard and it
  is per-project-blind (a daemon can't see how much budget peers are using).
  That is precisely what the elegant version fixes.

---

## 5. Elegant version — single fleet scheduler allocating the shared budget

**Requires the D1 telemetry bus (W1).** Replace "7 independent loops racing
first-come" with **one logical scheduler that allocates the shared account token
budget by priority** and hands out *permission to tick*. The per-project daemons
remain the executors (they still run `claude -p` locally — we are not
centralising the work, only the *admission decision*), but before a daemon spends
on `claude`, it must hold a **tick lease** granted in priority order.

This is the natural endpoint because the contention being arbitrated — the
Anthropic plan limit — is *already* a single shared, cross-machine resource, and
W1 already builds the cross-machine substrate (D1) to coordinate it. The
account-cooldown item (W2) puts the *stop* signal on D1; this item puts the *go,
and in what order* signal on the same bus.

### Model: weighted fair share of the account budget

The account has a rolling token budget (the `rolling_5h_tokens` ceiling already
in `backlog-budgets.json` is the natural unit — self-imposed, sits below
Anthropic's hard cap, so the scheduler throttles *before* the real cooldown
fires). Allocate it by priority weight:

```
share_p = priority_p / Σ(priority over projects with open work)
budget_p = share_p * (account_5h_budget − account_5h_spent_so_far)
```

A project may tick (be granted a lease) while its **rolling spend is under its
weighted share**. Only projects with open `## Open` items count toward the
denominator, so a parked project's weight doesn't dilute active ones — idle
projects neither consume nor reserve budget (this is how priority composes with
idle backoff at the fleet level: idle = out of the denominator).

### Two viable implementations of the allocator

**(a) D1 lease table — decentralised, no new daemon (preferred).** Daemons stay
independent loops. At top-of-tick, after the cooldown check, a daemon performs a
**compare-and-swap acquire of a tick lease** in D1, conditioned on the weighted
share above (the same CAS discipline the git claim already uses, now on D1
instead of a git push). D1 already aggregates per-project rolling spend (W1
telemetry bus / `health_history`), so each daemon can compute its own
`budget_p` and `spent_p` from a single query and self-admit:

```
acquire lease IF (spent_p < budget_p)
            AND (no higher-priority project is currently waiting on budget)
```

The "no higher-priority project waiting" clause is the contention winner: a
short-lived **wait registry** row (priority + timestamp, TTL'd like the 90-min
claim reaper) lets a low-priority daemon *yield* when a higher-priority one wants
budget. This is strictly stronger than the lightweight version's probabilistic
floor: it is *deterministic priority ordering* under contention, with no central
process to keep alive (consistent with the system's "origin/D1 IS the
coordination medium, no lock service" philosophy — §5 of architecture.md).

**(b) A single scheduler daemon — centralised, simplest to reason about.** One
fleet-scheduler process (a sibling of the `daemon-sync` watchdog) computes the
allocation and pings each project's daemon when it's that project's turn,
replacing per-project `fswatch`/heartbeat triggering with scheduler-driven
triggering. **Rejected as the primary path:** it introduces a single point of
failure (scheduler dies → fleet stalls) and a control-plane the rest of the
system pointedly avoids. Keep (b) only as a fallback if the D1-lease CAS proves
too racy in practice.

### Interaction with cadence + cooldown (elegant tier)

- The lease *replaces* the lightweight `factor`-scaled work-cadence: cadence is
  now an emergent property of budget availability, not a fixed multiplier. The
  idle ladder still governs how often a daemon *checks for work* (and whether it
  even tries to acquire a lease).
- Account cooldown still strictly dominates: an armed cooldown (W2) means the
  account budget is **exhausted**, so `budget_p − spent_p ≤ 0` for everyone and
  no leases are granted — the scheduler degrades into "everyone heartbeats" with
  zero special-casing. The two mechanisms compose by construction.

### Where it touches code / depends

- **Depends on W1 D1 bus** for cross-machine rolling-spend aggregation +
  the lease/wait tables. Build *after* W1 lands and *after* the W2
  account-cooldown signal (it reuses the same D1 health/spend data).
- `bin/backlog-agent`: a `_acquire_tick_lease()` step inserted in `tick_once`
  between the cooldown short-circuit and item selection; release on tick end.
- D1 schema (in backlog-dashboard, per the W1 doc): `tick_lease`
  (project, host, granted_epoch, ttl) + `tick_wait` (project, priority,
  since_epoch) tables, indexed per the W1 free-tier read-amplification rules.

---

## 6. How this underpins `infra = highest priority` for fleet-freeze

The W3 fleet-freeze item lists `priority-scheduling` as a dependency and states
two things this design must deliver: **(d) backlog-infra ticks highest
priority**, and the **critical gotcha** that backlog-infra's own daemon must be
*exempt* from the freeze (else the daemon that must land + verify the infra fix
freezes itself → permanent deadlock).

This design supplies both:

1. **Highest priority** is a one-line declaration in `backlog-budgets.json`:
   `"backlog-infra": { "priority": 100 }` (the top of the scale). In the
   lightweight tier this gives infra the fastest cadence; in the elegant tier it
   gives infra the largest weighted budget share and it wins every lease
   contention. Either way, when a fleet-affecting infra change is in flight,
   infra's own work outranks all project work for capacity — which is what makes
   "land the fix fast" achievable.

2. **The freeze exemption is a priority *ceiling* check, not a separate flag.**
   Fleet-freeze sets a D1 freeze key that every daemon consults at top-of-tick
   (above cooldown, §3). The exemption rule is simply: **a daemon ignores the
   freeze iff its own priority is the fleet maximum** (i.e. it *is*
   backlog-infra). Because priority already lives in the shared budgets file and
   infra is pinned at the top, the freeze logic reads "am I the highest-priority
   project? then I am the one expected to fix infra → do not freeze me." No
   bespoke "is this repo backlog-infra" string match is needed — the exemption
   falls out of the priority ranking, which is more robust (renaming the repo or
   relocating infra responsibility just moves the top priority, and the
   exemption follows).

   (Whether the exemption should be "strictly the unique max" vs. "any project
   above a freeze-exempt threshold" is **DECISION 4** — a unique infinite-priority
   infra avoids ambiguity but precludes ever having two fleet-affecting repos.)

So: priority is the *common currency* fleet-freeze, the account-cooldown ordering,
and per-project budget enforcement all spend. Building it once (the budgets-file
field + the precedence rules in §3) is the W3 keystone those siblings stand on.

---

## 7. Recommended build order

1. **Ship the declaration (§2)** — extend `backlog-budgets.json` with
   `projects[].priority` + `default_priority`, extend the `doctor`
   budgets-validity check, add the dashboard `PRIO` column. Inert until a weight
   is set; unblocks everything.
2. **Ship the lightweight scheduler (§4)** — `factor`-scaled cadence in
   `do_run`. Pure-local, no D1, immediate value, and it is the migration's first
   step (same priority field).
3. **When W1 (D1 bus) + W2 (account cooldown) land**, build the elegant lease
   allocator (§5a) on the same D1 substrate, and switch the freeze exemption
   (§6) to the priority-max rule. The lightweight `factor` cadence becomes the
   fallback when D1 is unreachable (consistent with the W1 reaper fail-safe
   decision: degrade to local behaviour, don't do something unsafe).

---

## Open DECISIONS

- **[DECISION 1] Priority scale + semantics.** Confirm the 0–100 integer scale
  with `default_priority = 50`, and that it is a *relative weight* (normalised by
  the active-project sum), not an absolute tick rate. Alternative: a small
  ordinal set (`high | normal | low | parked`) that maps to fixed multipliers —
  simpler for the user to set, less expressive for the budget allocator.

- **[DECISION 2] Lightweight `factor` band.** Confirm `FLOOR=0.25` /
  `CEIL=6.0` (or pick others). The floor is the only contention safety in the
  lightweight tier — too low and a high-priority daemon can busy-poll `claude`
  fast enough to trip the very account cooldown we respect; too high and high
  priority barely matters. Needs a sanity pass against observed tick rates.

- **[DECISION 3] Account-budget unit for the elegant allocator.** Use the
  existing self-imposed `rolling_5h_tokens` ceiling as the allocable pool
  (throttles before Anthropic's hard cap — preferred), or track against the real
  plan limit? The former keeps the scheduler decoupled from the brittle
  plan-limit regex; the latter is the *actual* scarce resource. Recommend the
  former.

- **[DECISION 4] Infra-exemption rule for fleet-freeze.** Is backlog-infra a
  *unique infinite* priority (clean exemption: "the one project above the freeze
  ceiling"), or just the largest *finite* weight with a "strictly-the-max"
  exemption test? Infinite is unambiguous but precludes a second fleet-affecting
  repo; finite-max is flexible but needs a tie-break rule. Affects §6 directly.

- **[DECISION 5] May an agent self-nominate a priority?** The threat model says
  agents must not edit their own controller. Should a per-repo *suggestion*
  (surfaced to the user, ratified into `backlog-budgets.json` by hand) be in
  scope at all, or is priority strictly human-set fleet-wide? Recommend
  strictly human-set for now; defer self-nomination.

- **[DECISION 6] Re-read cadence of the priority config.** Per-tick re-read of
  `backlog-budgets.json` (retune without restarting daemons — recommended, it's
  a tiny file) vs. read-once-at-daemon-start (cheaper, but a priority change
  needs a `backlog-agents sync` to take effect). Recommend per-tick read.
