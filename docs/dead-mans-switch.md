# Dead-man's-switch alerting (P1 · W2)

**Status: SHIPPED 2026-05-29.** A notify-channel consumer that promotes
"STALE-too-long / repeated-hook-failure" from a passive **dashboard color** into
an **actual push** (Slack / email / macOS notification).

## Problem

The motivating incident: the cooldown-add bug *knew* it was failing — the status
hook hit `fatal: … did not match any files` **every tick** — and the dashboard
*showed* the project STALE. But nothing escalated to the user for **~8 hours**.
A daemon can be alive-but-broken (failing its git ops) or outright dead, and in
both cases the only signal was a color on a dashboard nobody was looking at.

## Fix — two detectors, two homes

A daemon failure has two shapes, and **a dead daemon cannot alert about itself**,
so the switch is split across two surfaces:

| # | Detector | Signal | Lives in | Why there |
|---|----------|--------|----------|-----------|
| **(b)** | **Repeated hook failure** | N consecutive `status_fail` ticks | **driver** (`bin/backlog-agent`) | the daemon is ALIVE, just failing — it can alert about itself |
| **(a)** | **STALE-too-long** | D1 heartbeat older than 2× `HEARTBEAT_SECONDS` | **CLI monitor** (`bin/backlog-agents monitor`) | a dead daemon can't alert about itself — the watcher must be OUTSIDE it |

Both route through the **one reconciled notify config** (below).

### Reconciled notify config

There were two configs with different shapes. They are now reconciled onto **one
canonical file**, `~/.claude/agent-notify.json`:

```json
{ "slack_webhook_url": "https://hooks.slack.com/...",
  "email": "you@example.com",
  "local_notify": true }
```

All keys optional; an absent file or all-empty keys ⇒ **silent no-op** (alerting
is opt-in, and the switch never depends on it being set up). The driver
(`notify_send`) parses it **jq-free** (grep/sed, like the D1 reads) so an alert
never depends on jq; the CLI monitor's `_notify` reads the **same canonical file**
and falls back to the legacy `~/.config/backlog/notify.json`
(`slack_webhook` / `local_notify`) so an existing setup keeps working. Both the
plan-limit cooldown alert (`notify_cooldown`) and the dead-man's-switch share this
one code path.

### (b) Driver — repeated hook failure

The status hook does the tick's git ops (fetch / rebase / push) + telemetry every
tick. `_run_status_hook` already emits `status_ok` / `status_fail`; it now also
calls **`_hookfail_record`**:

- **failure** → bump a per-host consecutive-fail counter in
  `.claude/backlog-agent-hookfail.json` (`{count, alerted}`); when it reaches
  **`DMS_HOOKFAIL_THRESHOLD`** (default **3**, matching the circuit breaker) and we
  haven't already alerted **for this incident**, fire one `notify_send` and set
  `alerted` (so a persistent failure **throttles** — one alert per incident, not
  per tick);
- **success** → delete the state file, resetting **both** the streak and the
  `alerted` flag, so the **next** incident re-alerts.

Driver-only: no D1 surface, no dashboard change. Per-host ephemeral state,
gitignored like `failcounts` / the event log. A `dms_hookfail_alert` event is
logged for the ledger.

### (a) CLI monitor — STALE-too-long staleness watcher

`backlog-agents monitor` is a per-machine launchd sweeper that already owns
`_notify` + a throttle. A new **Pattern 8** reads the **independent D1 heartbeat**
(written every tick incl. idle/cooldown, decoupled from git — reading the
git-borne status file is exactly what would have lied during the incident) for
each `(project, host)` it knows (enumerated from the synced
`.claude/backlog-status-<host>.json` files — the same source the MACHINES table
uses) and fires when one hasn't heartbeated for **> `DMS_STALE_SECS`** (default
**3600** = 2× the driver's `HEARTBEAT_SECONDS` of 1800).

- **Catches** per-daemon death AND a whole *other* machine's death (its synced
  status file still names it, but its heartbeat goes stale) — as long as at least
  one machine's monitor is alive.
- **Dedup:** a `|`-delimited `project@host` set in `do_monitor` scope (bash-3.2
  safe — no associative arrays) fires once per incident and re-arms when the
  daemon heartbeats again; a monitor restart re-arms all (acceptable).
- **FAIL-OPEN:** a 404 / unreachable / null heartbeat is *skipped*, never treated
  as death (mirrors the reaper's fail-safe — a control-plane outage must not page
  the user with false deaths).
- **infra is EXCLUDED:** the `backlog-infra` daemon is held by policy, so it's
  legitimately not heartbeating and must never trip (keys off `INFRA_PROJECT` /
  `_is_infra_project`).

Each trip is recorded into the monitor's `recent_actions` (so the dashboard's
monitor summary surfaces it via the `flagged` count) and pushed via `_notify_raw`
(bypassing the cosmetic 300s throttle — its own per-incident dedup is the real
throttle; a dead daemon is too important for the cosmetic window).

## Decisions (user, 2026-05-29)

1. **Scope:** ship BOTH halves this session + install the monitor daemon on M1.
2. **Config:** canonical `~/.claude/agent-notify.json` (union of keys), monitor
   falls back to the legacy file.
3. **Detector (a) home:** the monitor loop now; the independent **Cloudflare cron
   worker** (the only thing that catches a *whole-machine* death, when no monitor
   is alive) is the noted **follow-up** below.
4. **Threshold (b):** N = 3 (matches `CIRCUIT_BREAKER_THRESHOLD`).

## Tests

`test/dead-mans-switch.bats` (9, hermetic — curl/mail/osascript PATH-shimmed):
driver fires-once-then-throttles, status_ok-resets-then-re-alerts, no-config
no-op, all-three-channels; monitor trips-and-pushes, live-doesn't-trip,
infra-excluded, fail-open, cross-sweep dedup.

## Follow-up — whole-machine-death backstop (CF cron)

The monitor catches per-daemon and other-machine death **while at least one
machine lives**. If *both* Macs die, no monitor runs. The robust backstop is a
**Cloudflare cron worker** on the dashboard that reads `health_status` heartbeats
server-side and pushes — fully independent of the Macs. Deferred (it's a dashboard
change: bootout the live dashboard daemon, add the CF cron trigger, deploy).
