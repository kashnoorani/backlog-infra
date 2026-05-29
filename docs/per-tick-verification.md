# Per-tick outcome verification (P1 · W2)

**Status: SHIPPED 2026-05-29.** Guard 4 — the **first *vetoing*** tick-guard
consumer (Guards 1/2/3 — circuit-breaker, diff-size, protected-path — only
count/warn; this one reopens work). Driver-only: no D1 migration, no dashboard
change.

## Problem

`tick_once` (`bin/backlog-agent`) treats **`claude -p` exit 0 + claude's
self-report** as success. On exit 0 it runs `_maybe_auto_complete`, clears the
failcount, runs the warn-only Guards 2/3, and records `TICK_OUTCOME=work`. But
**exit 0 is not proof the gate is green**: claude can flip an item to `[x]`,
commit, and push while typecheck/tests are actually broken — and the daemon
records silent "progress." The claude prompt only *asks* for "typecheck + tests
green before declaring done"; it's claude's word, never independently checked.

## Fix

After an exit-0 tick that **claimed completion**, the daemon independently runs
the project's **gate** on the committed HEAD. If the gate fails (or times out),
the item is **reopened** and the failcount **bumped** (feeding the Guard-1
circuit breaker) rather than recording success.

### Trigger (DECISION — confirmed)

Verify **only when the claimed item was flipped to `[x]` this tick** — the
precise "claimed done, prove the gate holds" signal. Detected by
`_completion_claimed`: the item title now appears on an `[x]` line in `## Open`
(fixed-substring match, so a `[x]` line with claude's appended summary still
counts). Additionally requires that a **work commit actually landed**
(`work_base..work_head` non-empty). Partial-progress commits and `[?]` flips do
**not** trigger — those leave no `[x]`.

### Gate source (DECISION — confirmed: config + package.json fallback)

`resolve_gate` populates `GATE_CMD` in precedence order:

1. **`.claude/backlog-gate.json`** — `{"gate": ["npm","run","verify"]}`. An
   **array** is run directly as argv; a **string** is run via `bash -c`.
2. **`package.json` fallback** — a `verify` script (`npm run verify`), else
   `typecheck` && `test` chained via `bash -c`. The npm stock
   `"Error: no test specified"` placeholder is **ignored** so a project that
   never set up tests is not falsely failed.
3. **No gate defined ⇒ FAIL-OPEN** — verification is skipped (the prior
   behaviour), so projects without a gate are never blocked.

backlog-infra's own gate is its canary suite: `.claude/backlog-gate.json` =
`{"gate": ["bash","test/run.sh"]}`.

Parsing uses **node** (already a hard dependency — see `failcount_*`), not jq.
Note: the node resolver prints the argv with a **trailing newline** — `while
read` drops a final unterminated line, so a single-element gate (the common
case) would otherwise never enter the read loop. And it prints **once at the
end** rather than `process.exit()`-ing after `stdout.write` (writing to a pipe is
async; exiting truncates it — the classic node pipe-flush footgun).

### Execution + timeout (DECISION — confirmed: 600 s, timeout = failure)

`run_gate` runs `GATE_CMD` under a **pure-bash wall-clock watchdog**
(`GATE_TIMEOUT_SECS`, default **600**, per-project overridable) — the same
pattern as the claude / status-hook watchdogs, so a hanging gate can never wedge
the tick. A gate that **overruns is killed and counts as a FAILURE** (a gate that
can't finish in budget is not green); a chronically slow/broken gate then
surfaces as `[?]` via the circuit breaker rather than passing silently.

### On failure (DECISION — confirmed: reopen + bump, keep commit, no revert)

- **Reopen** `[x] → [ ]` in `## Open`, targeting the item by title (literal
  `index()` substring match), and **strip the owner stamp** — mirrors the
  exit≠0 unclaim path. (Stripping is load-bearing: otherwise the `<!-- @host -->`
  stamp leaks into the stripped title on the next pick + claim, drifting the
  failcount key so the breaker never accumulates.)
- **`failcount_bump`** — `K` (=`CIRCUIT_BREAKER_THRESHOLD`, 3) consecutive
  verification failures trip the existing Guard-1 circuit breaker, which flips
  the item to `[?]` with the failure note for the user.
- **Do NOT auto-revert.** The work commit stands (flagged in the log + the
  `verify_failed` event). Auto-reverting an already-pushed commit is a
  cross-machine hazard — this mirrors Guards 2/3. Reopening the item + surfacing
  the failing gate is enough.
- If the item's `[x]` can't be found in `## Open` (e.g. claude moved it to a
  `## Done` section instead of the canonical in-place flip), the reopen is a
  no-op but the failcount is still bumped and a loud WARNING is logged — a safe
  degradation that still surfaces via the breaker.

### Ordering + interactions

Verification runs **after** `_maybe_auto_complete` and **before** recording
`TICK_OUTCOME=work`. `work_base..work_head` is snapshotted **once**, before any
reopen commit advances HEAD, so Guards 2/3 and the fleet-freeze auto-arm see only
claude's commit(s), never the reopen markup. `failcount_reset` (the clean-tick
streak clear) is skipped when verification failed (the bump already happened).

**Fleet-freeze:** the auto-arm is gated on `verify_failed != true` — **verify
first**. The daemon never holds the whole fleet on a `bin/` commit that just
failed its own gate (the item is being reopened, so there's no verified infra
change to propagate). For the EXEMPT (backlog-infra) daemon the gate is its
canary suite, so only a passing `bin/` commit arms the freeze.

## Telemetry

- `verify_passed` — `item`, `gate`.
- `verify_failed` — `item`, `exit_code`, `gate`, `fails` (new failcount).

Both via the existing `log_event` channel (`.claude/backlog-agent-events.jsonl`);
no new D1 surface.

## Config

| var | default | meaning |
|-----|---------|---------|
| `GATE_FILE` | `.claude/backlog-gate.json` | per-project gate config |
| `GATE_TIMEOUT_SECS` | `600` | wall-clock cap; overrun = failed verification |
| `GATE_DISABLE` | `0` | `1` hard-disables verification (forces fail-open) |

## Tests

`test/verification.bats` (10): fail-open (no gate), gate pass, gate fail ⇒
reopen + bump, no-auto-revert, breaker composition (3 fails ⇒ `[?]`), trigger
precision (commit without `[x]` ⇒ no verify), timeout ⇒ failure, `GATE_DISABLE`,
package.json placeholder ignored, package.json `verify` used. Suite **155/155**.

## Rollout

Driver-only — propagates with the normal driver sync (gated on canary + skew).
Inert until a project defines a gate (fail-open), so it ships safely fleet-wide
and each project opts in by adding `.claude/backlog-gate.json` (or already having
a `verify` / `typecheck`+`test` script).
