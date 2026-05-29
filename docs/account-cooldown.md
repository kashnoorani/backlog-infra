# Account-level shared cooldown (P1 · W2)

**Status: SHIPPED 2026-05-29.** A pause-primitive consumer at `scope=fleet` that
rides the D1 telemetry bus.

## Problem

The Anthropic plan limit is **per-account** — shared across every machine and
project. But the driver arms cooldown **per-project, per-machine**:
`start_cooldown` (`bin/backlog-agent`) writes a local
`.claude/agent-cooldown.json` and `cooldown_active` reads its integer
`until_epoch`. So when one daemon hits the cap, the **other 11 daemon×project
combos** (6 projects × 2 machines) each have to independently fail a `claude -p`
call, detect the limit signature, and arm their own local cooldown — a fleet-wide
burst of wasted failing calls every time the cap is hit, and a staggered recovery.

## Fix

A **single account-level cooldown signal on D1** that every `tick_once` consults
**FIRST** (alongside the local `cooldown_active` check), so the **whole fleet
stands down at once** the moment ANY daemon detects the plan limit, and **resumes
together** at the reset time.

### Carrier — dedicated `/api/cooldown` + `account_cooldown` table

A **dedicated** single-row table (`migrations/0004_account_cooldown.sql`) and
endpoint (`functions/api/cooldown.js`), NOT folded into `fleet_control`. The
cooldown is genuinely different from the freeze/pause/stop control rows:

- it carries an **`until_epoch`** (reset moment) the control rows don't;
- it **auto-expires** by time (no manual clear — the row lapses, never deleted);
- it **falls through to the Layer-3 fallback agent** (a non-Claude provider isn't
  capped), whereas the control modes are deliberate holds on *all* work.

`until_epoch` IS the signal: a future value ⇒ active; NULL/past ⇒ no cooldown.

### Write side — publish on arm

When `start_cooldown` arms locally (plan-limit detected), it ALSO calls
`_d1_publish_cooldown <until_epoch>` — a jq-free, bearer-auth, **backgrounded
best-effort** POST (like `notify_cooldown`, so a slow/unreachable D1 never stalls
the tick). The endpoint keeps the **LATER** `until_epoch` (`MAX`) across concurrent
writers, so a daemon that couldn't parse the reset (and fell back to the shorter
`now + COOLDOWN_SECONDS` window) can't truncate a correctly-parsed longer cooldown.

### Read side — consult first, fail open

`_d1_account_cooldown_epoch` (jq-free, mirrors `_d1_heartbeat_epoch`) echoes the
account `until_epoch` if a cooldown is active, else nothing. `tick_once`'s Layer 2
treats the cooldown as the **union** of the local and account signals:

```
acct_cd_epoch="$(_d1_account_cooldown_epoch)"
if cooldown_active || [[ -n "$acct_cd_epoch" ]]; then …  # Layer 2/3, as before
```

- **FAIL-OPEN:** D1 unreachable / non-200 / no row / expired ⇒ empty ⇒ the local
  per-project cooldown still governs. A control-plane outage is **never** a fleet
  stall and never a regression to the existing per-project behaviour.
- The effective reset = the **later** of the local and account `until_epoch`, so
  the daemon loop sleeps until the fleet actually resumes (`COOLDOWN_WAIT_SECONDS`).
- The driver re-checks `now < until_epoch` with its **own clock**, so the signal
  is robust to edge clock-skew even though the endpoint also computes `active`.
- **Layer-3 fallback:** if an opt-in fallback agent is available, the tick falls
  through to work on it (the Anthropic per-account limit doesn't cap a different
  provider) — for both the local and account cooldown.

### CLI surface

`backlog-agents`:
- **Banner:** a `cooldown: ACCOUNT-WIDE  by <host>  resumes in <t>` line (shown
  only while active, like the `control:` line).
- `cooldown [--status]` — human-readable state (default; exits 0).
- `cooldown --check` — exit 0 iff an account cooldown is active.
- `cooldown --clear` — manually lapse the D1 signal (e.g. a bad reset-time parse);
  POSTs `until_epoch=null` + `clear:true`. The fleet resumes on each daemon's next
  tick.

## Precedence / interaction with the local cooldown

The account signal is the **fleet-wide superset** of the local per-project
cooldown. It is checked at the same Layer-2 slot, OR'd with the local check.
Because the read fail-opens, the local cooldown remains the intact fallback when
D1 is unreachable — never a regression.

## Decisions (resolved with the user, 2026-05-29)

| Decision | Resolution |
|---|---|
| **Carrier** | Dedicated `/api/cooldown` endpoint + `account_cooldown` table (cleaner separation; cooldown ≠ control mode). |
| **Write contention / tie-break** | Keep the **latest** `until_epoch` (`MAX`) — a fallback (unparsed) write can't shorten a good one. |
| **CLI** | Banner line + manual `cooldown --status` / `--check` / `--clear`. |
| **Precedence** | Checked FIRST, OR'd with local; fail-open keeps local as the fallback. |
| **Layer-3 fallback** | Honored for the account cooldown too (different provider isn't capped). |

## Tests

`test/account-cooldown.bats` (13): driver gate (hold / fallback fall-through /
auto-expiry / fail-open / local-still-holds / combined-label / disable-flag),
driver publish (publishes on plan-limit / no publish when disabled), CLI
(`--check` / `--status` / default-clear / `--clear`). Hermetic — curl PATH-shimmed,
no network.

## Rollout

1. backlog-dashboard: apply `migrations/0004_account_cooldown.sql` to remote D1 +
   deploy Pages (the new endpoint). Outward-facing — `launchctl bootout` the live
   dashboard daemon before editing its repo, then re-bootstrap.
2. backlog-infra: push the driver; `daemon-sync` propagates to the 6 non-infra
   daemons (gated on canary + skew); M3 pulls + `canary`. The infra daemon stays
   held.
3. The signal is inert until both the endpoint is live AND a driver carrying the
   read/publish is running — until then `_d1_account_cooldown_epoch` 404s →
   fail-open → existing per-project behaviour, exactly as before.
