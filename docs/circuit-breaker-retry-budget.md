# Item-level circuit breaker / retry budget (P1 · W2)

**Status: SHIPPED 2026-05-29.** The *completion* of Guard 1 (the consecutive
circuit breaker shipped earlier). Driver-only; **no D1 / dashboard change**.

## Problem

The motivating incident: the "Daemon broken" item was claimed/unclaimed **6× in
one window** — a silent, token-burning retry storm. Guard 1 already converts a run
of consecutive failures into a `[?]` blocker, but three pieces were missing:

1. **The failure log was not attached.** The auto-block note was generic
   (`auto-blocked after N failed attempts`) — it told the user *that* the daemon
   gave up, never *why*.
2. **The trip was not surfaced.** A trip emitted a `log_event` only; nothing
   *pushed* — the user had to be watching the dashboard to notice.
3. **A FLAPPING item slipped through.** The consecutive counter resets on *any*
   clean tick, so an item that fails → makes partial progress → fails → … never
   strings K failures together and never trips, retrying forever.

## Fix

A small, layered completion of Guard 1 — all in `bin/backlog-agent`, all
fail-open, all per-host-ephemeral state.

### (a) Failure reasons attached to the `[?]` note

The per-item failcount state grew from a bare int into a **record**:

```json
{ "<item title>": { "count": 2, "attempts": 5, "reasons": ["claude exit 1", "verify: exit 1", "ceiling: tokens 2.1M/1M"] } }
```

- `count`    — **consecutive** failures; reset to 0 by any clean tick.
- `attempts` — **cumulative** failures; reset only on completion (`[x]`).
- `reasons`  — the last `FAILREASONS_KEEP` (=3) short failure reasons.

Each of the three existing bump sites now passes a short, ASCII reason:
`claude exit N` (the exit≠0 unclaim), `verify: exit N` (Guard 4 verification
failure), `ceiling: <breach>` (Guard 6 ceiling breach). On a trip those reasons
are rendered into the `[?]` note so the user sees the failure history inline.

**Back-compat:** an older bare-int value (`{ "<title>": 3 }`) is read as
`{ count: 3, attempts: 3, reasons: [] }` and rewritten as a record on the next
bump — so a live rollout over an existing per-host failcounts file degrades
cleanly (the file is gitignored + per-host, so this is the only migration path).

### (b) Surfacing via `notify_send`

When either threshold trips, the daemon fires **one** `notify_send` (mirroring the
dead-man's-switch / budget alert-once pattern) naming the blocked item, the trip
detail, and the recent reasons — so an item that gave up unattended becomes an
actual push, not just a dashboard color. (The notify channel is macOS-local-only
until a Slack webhook / email is filled into `~/.claude/agent-notify.json`.)

### (c) The cumulative "retry budget"

A second threshold on the **same** item: `attempts >= RETRY_BUDGET` (=6, matching
the 6-retry incident). Because `attempts` is reset **only on completion**, a
flapping item whose consecutive streak keeps resetting still climbs the cumulative
counter and eventually trips. Both thresholds auto-block to the same `[?]`; the
note + event record **which** one fired (`kind: consecutive | retry_budget`).

## Thresholds + per-item override

Both thresholds are env-tunable globals (`CIRCUIT_BREAKER_THRESHOLD`=3,
`RETRY_BUDGET`=6) with an **optional** per-item override in a committable
`.claude/backlog-guards.json` (a hard item can legitimately need a higher bar),
mirroring `backlog-ceilings.json`:

```json
{
  "circuit_breaker_threshold": 3,
  "retry_budget": 6,
  "items": {
    "<title substring>": { "circuit_breaker_threshold": 5, "retry_budget": 10 }
  }
}
```

Precedence (each later layer overrides): **env → file top-level → `items` entry
whose KEY is a substring of the item title** (`resolve_guards`, mirroring
`resolve_ceiling`). `RETRY_BUDGET`=0 disables the budget half.

## Decisions (user, 2026-05-29)

1. **Add the retry budget now** (the item title says "/ retry budget"); cap = 6;
   reset on `[x]` only.
2. **Enrich the existing failcount file** (int → record) with back-compat reads.
3. **Env globals + a new `backlog-guards.json`** for the optional per-item override.
4. **Short tag + one-line detail** for each reason; last 3 retained.
5. (Defaults adopted) `notify_send` on every trip; **fail-open** everywhere;
   `log_event circuit_tripped` carries `kind`/`fails`/`attempts`; **no dashboard
   change** (`[?]` + the note + the push are the surfaces).

## State semantics (reset matrix)

| Tick outcome                                  | `count` | `attempts` | `reasons` |
|-----------------------------------------------|---------|------------|-----------|
| Failure (exit≠0 / verify-fail / ceiling)      | +1      | +1         | append    |
| Clean tick, item **completed** (`[x]`)        | drop key (full reset)            |||
| Clean tick, item **incomplete** (still open)  | → 0     | preserved  | preserved |
| Either threshold trips                        | drop key (full reset)            |||

## Composition with the other guards

The three failure sources (exit≠0 unclaim, Guard 4 verification, Guard 6 ceiling)
all feed the **same** counters, so the breaker already composes across failure
kinds. The retry budget composes with all three identically — it only changes
*when* the accumulated failures trip (cumulative vs consecutive).

## Tests

`test/circuit-breaker.bats` (11): consecutive trip + format, note + rendered
reasons, structured events, full reset on success, per-item keying, **retry-budget
trip when consecutive can't**, **flapping survival** (clean-incomplete tick zeroes
consecutive but preserves attempts), **completion clears attempts**, **notify_send
fires on trip**, **per-item override raises the bar**, **malformed guards file
fails open**. Plus the format updates rippled into `test/verification.bats` +
`test/per-item-ceiling.bats` (the failcount value is now a record).
