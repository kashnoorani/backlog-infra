# D1 telemetry bus — schema & liveness-decoupling design

**Status: design APPROVED (W1), 2026-05-28.** Captures the D1 schema as code and
the plan to decouple liveness from git commits. Both decisions are now **RESOLVED**
(see §4): **DECISION 1 = fail-safe, do NOT reclaim when D1 is unreachable**;
**DECISION 2 = poll the indexed current-state table (raise to ~30s + ETag),
defer SSE.** The reaper switch remains gated on version-skew + a canary per the
operating rules (the daemon stays DOWN until those land).

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

**[DECISION 1 — RESOLVED: fail-safe, do NOT reclaim.]** When the daemon can't
reach D1, the reaper treats unknown liveness as alive and does **not** reclaim.
A stuck `[~]` is recoverable (startup reclaim, manual unclaim) and visible; a
false reclaim mid-work is the costly incident we're eliminating. The git-log
fallback was rejected because it re-introduces the exact coupling we're removing.
So the `D1 UNREACHABLE` branch above = **return (no reclaim).**

**[DECISION 2 — RESOLVED: poll the indexed table, defer SSE.]** With the
`health_status` design above, a poll hits a **tiny, fully-indexed current-state
table** (tens of rows), far under the 5M-reads/day ceiling. So: **keep polling**,
raise the interval to ~30s and add an ETag/`updated_at` short-circuit; **defer
SSE** to a later item (it's real Worker complexity for a problem the schema
already solves). Revisit SSE only if we ever read history on the hot path.

## 5. Rollout (after decisions, sequenced; daemon stays DOWN until canary)

1. **[CODE LANDED 2026-05-28]** `migrations/0001_telemetry.sql` in
   **backlog-dashboard** — captures `health_status` (`IF NOT EXISTS`, no-op in
   prod), ALTERs in `heartbeat_epoch` + `driver_sha`, creates indexed
   `health_history`. Validated on sqlite for both fresh + already-exists DBs.
   **NOT yet applied to live D1** — run: `npx wrangler d1 migrations apply
   kash-backlogs-d1 --remote` (then deploy the worker).
2. **[CODE LANDED 2026-05-28]** Ingest endpoint writes `heartbeat_epoch` +
   `driver_sha` **defensively** (core upsert always works; new columns via a
   best-effort `UPDATE` so an unmigrated DB still records core state). Status
   hook now sends `heartbeat_epoch` every tick. `health_history` *writes* are
   still deferred to the W2 efficiency-metrics consumer (table created, unused).
3. Switch `reclaim_stale_claims` to the D1 heartbeat per **DECISION 1** (this is
   the correctness fix; gate behind the canary + version-skew per the operating
   rules before the fleet daemons come back up). **← next behavioral step, gated.**
4. Dashboard read-path per **DECISION 2** (poll the indexed table; surface
   `driver_sha`/`heartbeat` in the web UI).
5. Retention/rollup job on `health_history` (prune raw rows past N days; keep
   daily rollups) — cheap insurance against storage/scan growth.

**Deploy order matters:** apply the migration BEFORE deploying the new ingest,
else the telemetry `UPDATE` no-ops (it's caught + logged — core state still
records, so it's safe either way, just no heartbeat column until migrated).

## 6. Status

Design **approved** (both decisions resolved, §4). **Additive groundwork (steps
1–2) CODE-LANDED 2026-05-28** — migration + defensive heartbeat ingest committed,
validated on sqlite; **not yet applied/deployed to live D1** (production action,
awaiting go-ahead). Version-skew visibility shipped last. Remaining gate before
the *reaper switch* (step 3) goes live: a **canary** (W3), with the fleet daemons
DOWN until then (operating rules).
