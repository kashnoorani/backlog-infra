# D1 telemetry bus — schema & liveness-decoupling design

**Status: DRAFT for review (W1).** Captures the D1 schema as code and the plan to
decouple liveness from git commits. The two **[DECISION]** points below gate the
behavioral changes (reaper + dashboard), which are **held** until ruled on — only
the DDL and this design are in scope right now.

## 1. Current state (Path B is ~50% built)

A `backlog-dashboard` investigation found Path B already partly live:

- **D1 binding** `kash_backlogs_d1` → database `kash-backlogs-d1`
  (`backlog-dashboard/wrangler.toml`).
- **Ingest** `POST /api/health-ingest` (`functions/api/health-ingest.js`) —
  bearer-auth, upserts a `health_status` row keyed by `(project, host)`.
- **Read** `GET /api/health` (`functions/api/health.js`) — computes
  fresh/idle/stale pills, returns the fleet snapshot.
- **Push is already wired** into `bin/backlog-agent-status.mjs` (fires after
  every tick) and the dashboard's per-project wrapper.

**The gaps:** (1) the `health_status` schema exists **only in the live Cloudflare
account — there is no DDL in any repo**; (2) there is **no history table**;
(3) the dashboard **polls `/api/health` every 15s** (the read-amplification
risk); (4) **liveness is still git-derived** — `reclaim_stale_claims` reads
`git log --grep=backlog-agent-status` recency, the exact signal that broke in the
2026-05-28 cooldown incident.

## 2. Free-tier budget (must stay on CF free)

Verified 2026-05-28 ([pricing](https://developers.cloudflare.com/d1/platform/pricing/)):
100k rows **written**/day · 5M rows **read**/day · 5 GB storage. D1 bills rows
**scanned**, not returned. At ~1,500 ticks/day fleet-wide, writes (~4.5k/day) and
storage are <5% of the ceiling. **The only blow-up risk is read amplification:**
an unindexed poll over a growing history table on a short refresh loop can scan
100s of millions of rows/day. The schema below is shaped to prevent that.

## 3. Proposed schema (DDL — ready to lift into a migration)

Two tables: a tiny **current-state** table the dashboard reads (one row per
project×host, never scans history), and an **append-only history** table reserved
for analytics and indexed so every access is a range/point lookup.

```sql
-- 0001_telemetry.sql

-- Current state: one row per (project, host). The dashboard's live view reads
-- ONLY this table -> a full scan is at most (projects × hosts) rows (~tens).
CREATE TABLE IF NOT EXISTS health_status (
  project              TEXT NOT NULL,
  host                 TEXT NOT NULL,
  last_tick_at         TEXT,            -- ISO-8601
  last_tick_epoch      INTEGER,         -- unix seconds (for cheap age math)
  last_item            TEXT,
  last_exit_code       INTEGER,
  last_tokens          INTEGER,
  last_commit          TEXT,            -- full SHA (see Open item: full vs short)
  repo_slug            TEXT,            -- owner/repo for commit links
  driver_sha           TEXT,            -- git SHA of backlog-infra/bin (version-skew)
  cooldown_until_epoch INTEGER,
  cooldown_reason      TEXT,
  heartbeat_epoch      INTEGER NOT NULL,-- updated EVERY tick incl. idle/cooldown
  updated_at           TEXT NOT NULL,   -- datetime('now')
  PRIMARY KEY (project, host)
);

-- Append-only ledger for analytics (efficiency metrics, digests). Never read on
-- the dashboard's hot path. Indexed so analytics queries are range scans, not
-- table scans.
CREATE TABLE IF NOT EXISTS health_history (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_epoch    INTEGER NOT NULL,
  ts          TEXT NOT NULL,
  project     TEXT NOT NULL,
  host        TEXT NOT NULL,
  event       TEXT NOT NULL,           -- mirrors the structured event log (W0)
  item        TEXT,
  exit_code   INTEGER,
  tokens      INTEGER,
  num_turns   INTEGER,
  work_commit TEXT,
  outcome     TEXT,                    -- work|idle|cooldown|claim_lost
  duration_s  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_history_ts       ON health_history (ts_epoch);
CREATE INDEX IF NOT EXISTS idx_history_project  ON health_history (project, ts_epoch);
CREATE INDEX IF NOT EXISTS idx_history_host     ON health_history (host, ts_epoch);
```

Notes:
- `heartbeat_epoch` is the **liveness** field — written on *every* tick including
  idle and cooldown ticks, independent of whether any git commit happened. This
  is what decouples liveness from commits (§4).
- `health_history` rows map 1:1 onto the **W0 structured event stream**
  (`.claude/backlog-agent-events.jsonl`) — the ingest can forward those events,
  so analytics is a straight projection of events already emitted.
- New columns vs the live table (`heartbeat_epoch`, `repo_slug`, `driver_sha`,
  full `last_commit`) align with the `## Open` status-hook item and the
  version-skew item — fold those in together.

## 4. Decoupling liveness from commits

`reclaim_stale_claims` today: "no status commit pushed in 90m ⇒ the daemon is
dead ⇒ reclaim its `[~]` items." A failed status *commit* (e.g. the gitignore
bug) makes a live daemon look dead → false reclaim. Fix: consult the **D1
heartbeat** (`heartbeat_epoch`), which is pushed independently of git.

```
reclaim_stale_claims:
  age = now - (D1 heartbeat_epoch for this project×host)
  if D1 reachable and age <= STALE_CLAIM_SECONDS: daemon is alive -> do NOT reclaim
  if D1 reachable and age  > STALE_CLAIM_SECONDS: dead -> reclaim
  if D1 UNREACHABLE: ??? (see DECISION 1)
```

**[DECISION 1] D1-unreachable fail-safe bias.** When the daemon can't reach D1,
should the reaper (a) **fail-safe = do NOT reclaim** (treat unknown as alive —
risks a genuinely-dead daemon's `[~]` items staying stuck until D1 returns), or
(b) fall back to the current git-log heuristic? **Recommended: (a) fail-safe.**
A stuck `[~]` is recoverable (startup reclaim, manual unclaim) and visible; a
false reclaim mid-work is the costly incident we're eliminating. The git-log
fallback re-introduces the exact coupling we're removing.

**[DECISION 2] Dashboard read pattern.** The item proposes SSE/WebSocket push to
kill polling. But with the `health_status` design above, a poll hits a **tiny,
fully-indexed current-state table** (tens of rows), so even a 15s poll is far
under the 5M-reads/day ceiling. **Recommended: keep polling for now** (raise the
interval to ~30s + add an ETag/`updated_at` short-circuit), and **defer SSE** to
a later item — it's real Worker complexity for a problem the schema already
solves. SSE only becomes worth it if we later read history on the hot path.

## 5. Rollout (after decisions, sequenced; daemon stays DOWN until canary)

1. Land `0001_telemetry.sql` in **backlog-dashboard** (`wrangler d1 migrations`)
   so the schema is reproducible; apply to the live DB (idempotent `IF NOT EXISTS`).
2. Extend the ingest endpoint + status hook to write `heartbeat_epoch` (+ the new
   columns) every tick, and to forward W0 events into `health_history`.
3. Switch `reclaim_stale_claims` to the D1 heartbeat per **DECISION 1** (this is
   the correctness fix; gate behind the canary + version-skew per the operating
   rules before the fleet daemons come back up).
4. Dashboard read-path per **DECISION 2**.
5. Retention/rollup job on `health_history` (prune raw rows past N days; keep
   daily rollups) — cheap insurance against storage/scan growth.

## 6. What's blocked on you

Nothing here changes runtime behavior yet. To proceed past the DDL I need rulings
on **DECISION 1** (reaper fail-safe bias) and **DECISION 2** (poll vs SSE). My
recommendations: **(1) fail-safe no-reclaim**, **(2) keep polling an indexed
current-state table, defer SSE.**
