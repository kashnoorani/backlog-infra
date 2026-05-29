# Per-project budget enforcement (P1 · W2)

**Status: SHIPPED 2026-05-29.** A pause-primitive consumer at `scope=project`.
Unlike account-cooldown / fleet-freeze (D1-backed, fleet-wide), this signal is
**LOCAL + per-project** — no D1 round-trip.

## Problem

`~/.claude/backlog-budgets.json` only ever **colored the dashboard** (a bullet
graph of rolling-5h / rolling-week agent token usage against a target). It had no
teeth: a single runaway project could burn the shared account budget all day and
nothing would stop it. We want **self-imposed *spend* control at per-project
granularity** — a voluntary cap, distinct from the account-level **plan-limit
cooldown** (Anthropic's hard cap, already shipped; see
[account-cooldown.md](account-cooldown.md)).

## Fix

When a project's own rolling token spend exceeds a per-project cap, its daemon
**pauses to heartbeat-only** (and alerts ONCE), then **resumes on its own** as the
rolling window drains back under the cap — self-clearing, computed fresh each tick.

### Spend source — the project's own ledger

Each tick the status hook appends a row to `.claude/backlog-history.jsonl` with a
`tokens` headline (0 on idle / cache-only ticks, the real count on work ticks).
The cap is a **plain sum of `tokens` over the window** — the exact quantity the
dashboard's burn-rate bar already shows. The ledger is **git-tracked**, so after a
pull it contains rows from *every* host: the window sum is the project's
**total** spend across the fleet, not just this machine's (decision #2). If a
project blows its cap, **both** machines' daemons for it pause.

### Caps — an optional `projects` map (opt-in)

`backlog-budgets.json` gains an optional map; absent entry ⇒ **uncapped** (today's
behaviour):

```json
{
  "budgets": { "rolling_5h_tokens": 3000000, "rolling_week_tokens": 30000000 },
  "projects": {
    "_comment": "Optional per-project rolling token caps; absent ⇒ uncapped.",
    "some-project": { "rolling_5h_tokens": 1000000, "rolling_week_tokens": 10000000 }
  }
}
```

The top-level `budgets` stays the **account-level dashboard target**, untouched.
The map is keyed by the project's `_health_project` identity (package.json `.name`
or the directory basename — the same identity `freeze_exempt` uses). Either window
cap is independently optional. `doctor` validates the map: a malformed entry is a
**WARN, not a fail** (enforcement is fail-open, so a bad value just leaves that
window uncapped).

### Read side — `_budget_over_cap`, fail open

`_budget_over_cap` (`bin/backlog-agent`) does one `node` pass: read the caps,
window-sum the ledger, echo a one-line reason (e.g. `5h 3.1M/3.0M, week 31M/30M`)
if **5h sum > cap_5h OR week sum > cap_week**, else nothing. The whole feature is
**FAIL-OPEN** — any missing/unreadable input echoes empty = no enforcement:

- `BUDGET_DISABLE=1`, no `node`, no budgets file, no `projects` entry for this
  project, no cap set, or an unreadable ledger ⇒ no pause.

A telemetry hiccup must never wedge a project — consistent with every other guard.
On **under-cap**, the helper clears the alert-once state file (mirrors
`cooldown_active`'s expired-file cleanup), so a later breach re-alerts.

### The hold — same shape as cooldown, NOT a 5th mechanism

A top-of-tick short-circuit placed right after the cooldown block and before the
fleet-control block. It reuses the existing heartbeat-only path
(`_run_status_hook "" 0 loop "$pre_head" 0; TICK_OUTCOME=budget; return 0`) — the
claim is retained, the daemon stays alive (not STALE), no work is claimed.

- **infra EXEMPT** (`! freeze_exempt`): backlog-infra is operated interactively
  and must keep ticking (mirrors freeze/pause).
- **Layer-3 fallback honored** (decision #3): a budget cap is on *Anthropic*
  spend, so if an opt-in fallback agent is available the tick falls through to
  work on it (structurally mirrors the cooldown block, not the freeze/pause one).
  The `use_fallback` guard avoids re-handling if cooldown already chose it.

### Alert — once per breach, then throttle

`_budget_alert_once` mirrors `_hookfail_record`: a per-host
`.claude/backlog-agent-budget.json` `{alerted, reason}` fires ONE `notify_send` on
the rising edge of a breach, throttles while it persists, and is cleared on resume
(by `_budget_over_cap` going under cap) so the next breach alerts again. The alert
also fires on the fallback path (the project *did* blow its self-imposed cap — the
user should know), with wording accurate for both paths. `log_event budget_alert`
records the fire; `log_event budget_paused` / `tick_done outcome=budget` record the
hold. No new D1 surface.

### CLI surface

`backlog-agents`:
- **Banner:** a `budget: OVER CAP  <project>  (<reason>)` line, shown only while a
  local project is over cap. Read from each local project's
  `.claude/backlog-agent-budget.json` (per-host, like the driver-sha loop) — so it
  reflects this machine's daemons. No new D1 surface.
- **`doctor`:** validates the optional `projects` map (positive-integer caps; WARN
  on a malformed entry).

## Decisions (resolved with the user, 2026-05-29)

| Decision | Resolution |
|---|---|
| **Which window enforces** | **Both** rolling-5h AND rolling-week (pause if either is over cap). |
| **Cap scope** | **Project total across all hosts** (plain sum of the git-shared ledger). |
| **Layer-3 fallback** | **Honored** — a budget cap is on Anthropic spend; a non-Claude fallback may still drive the tick. |
| **Schema** | Optional `projects` map; **absent ⇒ uncapped** (opt-in enforcement). |
| **Fail-open vs closed** | **Fail-OPEN** on any missing/unreadable input (consistent with every guard). |
| **Infra exemption** | **Exempt** (operated interactively; mirrors freeze/pause). |
| **Surfacing** | Banner line + `log_event budget_paused` / `budget_alert`; `doctor` validation. |

## Tests

`test/per-project-budget.bats` (10): over-5h-cap → heartbeat-only; over-week-cap
(5h under); cross-host sum (project-total); under-cap proceeds; infra-exempt;
fail-open (no budgets file / no project entry); disable-flag; fallback honored;
alert-once → throttle → re-alert-after-resume. Hermetic — no network (the D1 reads
default off via `FREEZE_DISABLE` / `ACCOUNT_COOLDOWN_DISABLE`); `BUDGET_DISABLE`
gates enforcement per test.

## Rollout

Driver + CLI only — **no D1 migration / dashboard change**. The feature ships
**inert/opt-in**: until a project gets a real `projects` entry, `_budget_over_cap`
returns empty (no entry ⇒ uncapped) and behaviour is exactly as before. Push the
driver; `daemon-sync` propagates to the 6 non-infra daemons (gated on canary +
skew); M3 pulls + `canary` + `sync`. The infra daemon stays held. Opt a project in
by adding its cap to `~/.claude/backlog-budgets.json` (a dotfiles-symlinked file).
