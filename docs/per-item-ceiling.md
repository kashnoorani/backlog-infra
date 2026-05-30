# Per-item token/turn/spend ceiling (P1 · W2)

**Status: SHIPPED 2026-05-29.** A pause-primitive consumer at `scope=item` — the
**finest-grained** of the four pause scopes (item · project · fleet-via-freeze/pause
· account-via-cooldown). Driver-only + CLI-test-only; **no D1 / dashboard change**.

## Problem

A single hard item can **spiral within ONE tick** — many turns, huge spend —
*below* the per-project budget's radar. The
[per-project budget](per-project-budget.md) caps a project's *rolling* (5h / week)
spend; but one pathological tick can run away (re-reading the whole repo, looping
on a flaky test, thrashing an edit) and burn hundreds of thousands of tokens
*before* the rolling window ever trips. The existing
`CLAUDE_TIMEOUT_SECS` wall-clock watchdog bounds a tick's *wall time*, not its
*turns or tokens*. This adds the missing **per-tick turns/tokens ceiling** —
catching the runaway *task*, not just the runaway *project*.

## Fix — two layers

### 1. Preventive: `--max-budget-usd` (saves the spend tail)

When a per-item **USD** cap is set, the driver passes claude
`--max-budget-usd <amount>` so claude **self-stops** when its predicted next-turn
spend would exceed the budget — the runaway is cut off mid-tick rather than only
caught afterward.

> **Why dollars, not turns?** The bring-up design assumed a `--max-turns` flag, but
> the installed claude CLI (v2.1.157) **has no `--max-turns`**. Its only native
> preventive cap is `--max-budget-usd` (a per-session cumulative spend cap). So the
> preventive layer is denominated in **dollars**; **turns and tokens** are enforced
> **post-hoc** (below). Fallback agents (Layer 3) get no flag — different CLI.

### 2. Post-hoc: turns + tokens ceiling (catches the runaway)

After the tick, the driver reads **this session's actual `num_turns` + headline
tokens** and compares them to the effective ceiling. On a breach:

- **INCOMPLETE item** (still `[~]` after the tick — the runaway that would otherwise
  keep grinding next tick): **reopen** `[~]→[ ]`, strip the `<!-- @host -->` owner
  stamp, append an inline `<!-- ceiling: … -->` note, and **`failcount_bump`** so K
  consecutive breaches trip the Guard-1 circuit breaker → `[?]` (see
  [per-tick-verification.md](per-tick-verification.md) for the breaker). **Keep any
  commit** — like Guards 2/3/4, no auto-revert (reverting an already-pushed commit
  is a cross-machine hazard).
- **COMPLETED item** (`[x]` this tick): **log only, do NOT reopen.** Completion is
  the natural stop; reopening finished work would only **re-spend** to redo it. The
  cost is surfaced via `log_event item_ceiling … reopened=false completed=true`.

This is **Guard 6** in `tick_once`. It is **mutually exclusive** with Guard 4
(verification) by construction: Guard 4 only fires on a completed `[x]` item; the
ceiling only *reopens* an incomplete `[~]` item.

### Token source — claude's newest transcript (no invocation change)

The post-hoc count comes from claude's **newest session transcript** under
`~/.claude/projects/<cwd-with-/-as->/` — the exact source
`backlog-agent-status.mjs` (`findNewestTranscript` + `extractUsage`) already parses
for the history ledger. Each `claude -p` writes a fresh session transcript there,
so the newest one right after claude exits is **this tick's**. This means **no
change to the `claude -p` text invocation** (it is *not* switched to
`--output-format json`, which would change the captured-output shape the plan-limit
regex greps) and **no dependence on the status hook having run yet** (the hook fires
later, at the end of the tick).

Headline tokens = `input + output + cache_creation` (excludes `cache_read`) —
**identical** to the ledger's `tokens`, so the ceiling and the per-project budget
measure the same quantity.

## Configuration — inert / opt-in

Ships **inert**: absent everything ⇒ **uncapped** (today's behaviour). Mirrors the
per-project budget and per-tick verification, so it propagates fleet-wide safely and
each project/item opts in later.

**Global env defaults** (mirror `CLAUDE_TIMEOUT_SECS` / `GATE_TIMEOUT_SECS`):

| var | meaning | default |
|---|---|---|
| `MAX_TURNS_PER_TICK` | post-hoc turn ceiling (≥ trips) | `0` = uncapped |
| `MAX_TOKENS_PER_TICK` | post-hoc token ceiling (> trips) | `0` = uncapped |
| `MAX_BUDGET_USD_PER_TICK` | preventive `--max-budget-usd` | `0` = no flag |
| `CEILING_DISABLE` | hard-disable both layers | `0` |

**Per-project + per-item overrides** — optional `.claude/backlog-ceilings.json`:

```json
{
  "max_turns": 30,
  "max_tokens": 400000,
  "max_budget_usd": 5.0,
  "items": {
    "Refactor the entire auth layer": { "max_turns": 80, "max_tokens": 1200000, "max_budget_usd": 15 }
  }
}
```

**Precedence** (each later layer overrides the earlier): env defaults →
config top-level (project default) → `items` entry whose **key is a substring of the
item title** (first match wins — same literal-substring matching `_completion_claimed`
uses, so a hard item can legitimately raise its own ceiling). This is the documented
**opt-out** for a genuinely expensive item.

## Decisions (resolved with the user, 2026-05-29)

1. **Mechanism = both.** Preventive `--max-budget-usd` + post-hoc turns/tokens check.
   (`--max-turns` would have been the preventive turn cap, but it does not exist in
   this CLI.)
2. **Shape = inert / opt-in.** Absent ⇒ uncapped; env defaults + per-item override.
3. **Token source = newest transcript** (no `claude -p` invocation change).
4. **Failcount = the SAME counter** as exit≠0 / verify-fail — composes with the
   Guard-1 breaker.
5. *(design call)* **A completed item is not reopened** — only logged. Reopening
   finished work would re-spend it, contradicting the budget-saving goal. The
   reopen-with-a-note applies to the **incomplete** runaway, which is the case the
   ceiling actually prevents from continuing.
6. **FAIL-OPEN** on unparseable usage (consistent with every guard).
7. **Surfacing = `log_event item_ceiling`** only — no dashboard change; the reopen +
   failcount + breaker are existing surfaces.
8. **NOT infra-exempt.** Unlike the budget / freeze / pause *fleet holds*, a
   per-item turn/token spiral is a **bug-catch**, not a deliberate policy pause — and
   a spiraling `backlog-infra` item (which self-modifies the shared `bin/`) is the
   *most* dangerous to leave un-caught.

## Tests

`test/per-item-ceiling.bats` (11): token/turn breach reopens+bumps an incomplete
item; a completed hot item is logged-not-reopened; under-cap is a no-op; fail-open on
no-transcript; per-item + project-level config overrides; `CEILING_DISABLE`; and the
preventive `--max-budget-usd` is present iff a USD cap is set (env or per-item).
Default-disabled via `CEILING_DISABLE=1` in `test/helpers.bash`.
