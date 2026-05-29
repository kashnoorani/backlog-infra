# Reaper switch — D1 heartbeat liveness for `reclaim_stale_claims`

**Status: DRAFT.** Implementation spec for **step 3** of
`docs/d1-telemetry-schema.md`: switch `reclaim_stale_claims` in
`bin/backlog-agent` off the git-commit-recency signal and onto the **D1
`heartbeat_epoch`** that `bin/backlog-agent-status.mjs` already pushes to
`https://kash-backlogs.pages.dev/api/health-ingest` on every tick.

This document is the spec only. Landing it is still **gated behind the canary
(W3) + version-skew checks** per the operating rules in
`docs/d1-telemetry-schema.md §5` — the fleet daemons stay DOWN until that gate
clears. DECISION 1 is **RESOLVED**: when D1 is unreachable the reaper
**fails safe and does NOT reclaim**.

---

## 0. Why

`reclaim_stale_claims` today (`bin/backlog-agent:417`) decides "is the daemon
that holds these `[~]` claims still alive?" by reading the timestamp of the most
recent `backlog-agent-status` commit on `origin/$branch`:

```sh
last_status_ts="$(git -C "$PWD" log "origin/$branch" --format="%ct" \
                  --grep="backlog-agent-status" -1 2>/dev/null || echo "")"
```

That couples liveness to git pushes. The 2026-05-28 cooldown incident showed the
failure mode: the status *commit* silently stopped (a `.gitignore` change skipped
the commit path) while the daemon kept ticking. A live daemon looked dead, and
its in-flight `[~]` item was reclaimed mid-work — the exact incident we are
eliminating.

`heartbeat_epoch` in `health_status` is written on **every** tick (work, idle,
cooldown — see `backlog-agent-status.mjs:511`), independent of whether any git
commit happened. Reading it is the liveness signal that is immune to the
commit-path breaking.

---

## 1. READ contract — fetching per-(project, host) `heartbeat_epoch`

### Decision: add a dedicated `GET /api/heartbeat` endpoint

`GET /api/health` (`backlog-dashboard/functions/api/health.js`) does
`SELECT * FROM health_status` (a full scan of the current-state table) and
returns the entire fleet keyed by **project only** — it drops `host` into the
value and overwrites on collision (`projects[row.project] = …`). For the reaper
we need a **single, indexed, point read** of one `(project, host)` row, returning
`heartbeat_epoch` directly. Reusing `/api/health` would (a) scan + serialize the
whole fleet on every reaper call, and (b) lose per-host resolution. Both are
avoidable.

Add a new Pages Function `backlog-dashboard/functions/api/heartbeat.js`. It is a
**point read on the primary key** `(project, host)` — D1 bills rows *scanned*,
and a PK lookup scans exactly one row, so this is the cheapest possible read and
trivially free-tier safe (`docs/d1-telemetry-schema.md §2`).

> NOTE — this endpoint lives in the `backlog-dashboard` repo, NOT here.
> Per the task's hard rule this spec only *describes* it; creating
> `functions/api/heartbeat.js` is a separate backlog item in that repo and is a
> prerequisite for the bash switch in §2.

**Request**

```
GET /api/heartbeat?project=<name>&host=<host>
```

No auth required (read-only liveness, same posture as `GET /api/health`, which is
already public + CORS `*`). Reuse health.js's CORS/`Cache-Control: no-store`
headers.

**Worker shape (reference implementation, for the dashboard repo):**

```js
export async function onRequest(context) {
  const { request, env } = context;
  const HEADERS = { "Content-Type": "application/json", "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*" };
  const url = new URL(request.url);
  const project = url.searchParams.get("project");
  const host = url.searchParams.get("host");
  if (!project) {
    return new Response(JSON.stringify({ error: "missing project" }),
      { status: 400, headers: HEADERS });
  }
  let row;
  try {
    // Point lookup on PK (project, host). `host IS ?2` is null-safe — mirrors
    // the ingest's null-host handling in health-ingest.js.
    row = await env.kash_backlogs_d1
      .prepare("SELECT heartbeat_epoch, last_tick_at FROM health_status WHERE project = ?1 AND host IS ?2")
      .bind(project, host || null)
      .first();
  } catch (e) {
    console.error("heartbeat D1 read failed:", e.message);
    return new Response(JSON.stringify({ error: "storage error" }),
      { status: 500, headers: HEADERS });
  }
  if (!row) {
    return new Response(JSON.stringify({ found: false }),
      { status: 404, headers: HEADERS });
  }
  return new Response(JSON.stringify({
    found: true,
    project, host: host || null,
    heartbeat_epoch: row.heartbeat_epoch ?? null,
    last_tick_at: row.last_tick_at ?? null,
  }), { headers: HEADERS });
}
```

**Response (200):**

```json
{ "found": true, "project": "backlog-infra", "host": "Kashs-MacBook-Pro",
  "heartbeat_epoch": 1748400000, "last_tick_at": "2026-05-28T12:00:00.000Z" }
```

**Response shapes the reaper must handle:**

| Condition                         | Status | Body                              | Reaper interpretation         |
|-----------------------------------|--------|-----------------------------------|-------------------------------|
| Row found, heartbeat present      | 200    | `{"found":true,"heartbeat_epoch":N,…}` | use `N` for age math     |
| Row found, heartbeat NULL (unmigrated/never-set) | 200 | `{"found":true,"heartbeat_epoch":null}` | empty → fail safe (no reclaim) |
| No such (project, host) row       | 404    | `{"found":false}`                 | empty → fail safe (no reclaim) |
| D1 / Worker error                 | 5xx    | `{"error":"storage error"}`       | unreachable → fail safe       |
| Network/DNS/timeout               | curl≠0 | (no body)                         | unreachable → fail safe       |

All non-`{found:true, heartbeat_epoch:<int>}` cases collapse to the **same
fail-safe branch**: do not reclaim. (DECISION 1.)

### Key match between push and read — the `project` / `host` subtlety

The reaper must query with the **same** `(project, host)` keys the status hook
*writes*, or it reads someone else's row (or none). From
`backlog-agent-status.mjs`:

- **project** = `package.json` `.name` if present, else `basename(REPO_ROOT)`
  (`backlog-agent-status.mjs:482-485`). `reclaim_stale_claims` runs in the same
  CWD, so it must derive `project` **identically**: try `package.json` name
  first, fall back to `basename "$PWD"`. A naive `basename "$(pwd)"` (as
  `notify_cooldown` uses) is **wrong** whenever the package name differs from the
  directory name.
- **host** = `hostname().replace(/\.local$/, "")`
  (`backlog-agent-status.mjs:312`). The bash side must strip the same `.local`
  suffix. `hostname -s` is close but not identical (it strips the whole domain,
  not just `.local`); to match exactly, use `hostname` then `sed 's/\.local$//'`.

These two derivations are spelled out as helpers in §2 so the push side and read
side cannot drift.

---

## 2. Bash integration in `reclaim_stale_claims`

Replace the git-log block (`bin/backlog-agent:427-434`) with a D1 heartbeat read.
Style matches the existing file: jq-free `grep -oE` parsing (as in
`cooldown_active`), curl with a short `-m` timeout (as in `notify_cooldown`), and
fail-safe `return` on any uncertainty.

### 2a. New helpers (place near `cooldown_active`)

```sh
# Derive the (project, host) keys EXACTLY as backlog-agent-status.mjs writes
# them, so the heartbeat read hits the same health_status row the push updates.
#   project: package.json .name if present, else basename of CWD
#   host:    hostname with a trailing ".local" stripped (matches the mjs)
_health_project() {
  local name=""
  if [[ -f "$PWD/package.json" ]]; then
    # jq-free: first "name": "<value>" in package.json.
    name="$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$PWD/package.json" 2>/dev/null \
            | head -n1 | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
  fi
  [[ -z "$name" ]] && name="$(basename "$PWD")"
  printf '%s' "$name"
}

_health_host() {
  hostname 2>/dev/null | sed -E 's/\.local$//' || echo "?"
}

# URL-encode the few characters that legitimately appear in a project/host:
# space and the few punctuation chars. Project names are git-repo-safe in
# practice (no `&`, `?`, `#`), so a minimal encoder is enough; spaces are the
# realistic case. Keeps us curl-clean without pulling in a dependency.
_urlencode() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Fetch heartbeat_epoch for THIS (project, host) from the D1 telemetry bus.
# Echoes the integer epoch on success; echoes NOTHING on any failure
# (unreachable, non-200, found:false, null heartbeat, malformed body).
# Bearer auth is optional for the read endpoint, but we send it when the
# health key is present so the endpoint can be locked down later w/o a client
# change. Short -m timeout so a slow/unreachable dashboard never stalls a tick.
_d1_heartbeat_epoch() {
  command -v curl >/dev/null 2>&1 || return 0
  local key_file="$HOME/.config/backlog/health-key"
  local auth=() key
  if [[ -f "$key_file" ]]; then
    key="$(tr -d '[:space:]' < "$key_file" 2>/dev/null || true)"
    [[ -n "$key" ]] && auth=(-H "Authorization: Bearer $key")
  fi
  local project host url body http_code
  project="$(_urlencode "$(_health_project)")"
  host="$(_urlencode "$(_health_host)")"
  url="https://kash-backlogs.pages.dev/api/heartbeat?project=${project}&host=${host}"

  # -s silent, -m 5 hard cap, -w to capture the HTTP status separately so we can
  # require a 200 before trusting the body. On curl failure $? != 0 -> empty.
  body="$(curl -s -m 5 "${auth[@]}" -w $'\n%{http_code}' "$url" 2>/dev/null)" || return 0
  http_code="$(printf '%s' "$body" | tail -n1)"
  body="$(printf '%s' "$body" | sed '$d')"   # strip the trailing status line
  [[ "$http_code" == "200" ]] || return 0
  # Require found:true before reading the epoch (404 returns found:false).
  printf '%s' "$body" | grep -q '"found"[[:space:]]*:[[:space:]]*true' || return 0
  # jq-free integer extract, same idiom as cooldown_active.
  local epoch
  epoch="$(printf '%s' "$body" \
           | grep -oE '"heartbeat_epoch"[[:space:]]*:[[:space:]]*[0-9]+' \
           | grep -oE '[0-9]+$' | head -n1 || true)"
  [[ -n "$epoch" ]] && printf '%s' "$epoch"
  return 0
}
```

Notes:
- `grep -oE '"heartbeat_epoch"…[0-9]+'` matches the integer form only; a `null`
  heartbeat (`"heartbeat_epoch":null`) yields no match → empty → fail safe.
- `curl … || return 0` makes every transport failure (DNS, connect, the `-m 5`
  timeout) collapse to "empty epoch" — which the caller treats as unreachable →
  no reclaim.

### 2b. Rewritten `reclaim_stale_claims`

```sh
reclaim_stale_claims() {
  RECLAIMED_COUNT=0
  local stale_secs=5400 now hb_epoch age line line_num item_title

  now="$(date +%s)"
  [[ -z "$(git -C "$PWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" ]] && return

  # On daemon startup (first tick) any [~] items belong to a dead incarnation —
  # reclaim immediately, no liveness probe. (Unchanged from the git-log version.)
  if [[ "${STARTUP_RECLAIM:-0}" != "1" ]]; then
    # Liveness now comes from the D1 heartbeat, NOT git-commit recency.
    hb_epoch="$(_d1_heartbeat_epoch)"

    # DECISION 1 — fail safe. Empty heartbeat == D1 unreachable / no row / null /
    # malformed. Treat unknown liveness as ALIVE and do NOT reclaim. A stuck [~]
    # is recoverable (startup reclaim, manual unclaim) and visible; a false
    # reclaim mid-work is the costly incident we are eliminating.
    [[ -z "$hb_epoch" ]] && return

    age=$(( now - hb_epoch ))
    # Heartbeat fresh enough -> the owning daemon is alive -> do NOT reclaim.
    (( age <= stale_secs )) && return
    # else: heartbeat is older than the stale threshold -> daemon is dead ->
    # fall through and reclaim its [~] items.
  fi
  STARTUP_RECLAIM=0

  while IFS= read -r line; do
    line_num="$(echo "$line" | cut -d: -f1)"
    item_title="$(echo "$line" | cut -d: -f2- | sed -E 's/^(- )?\[~\] //')"
    sed -i '' "${line_num}s/\[~\]/[ ]/" "$BACKLOG_FILE"
    echo "  [reclaim] stale [~] item '${item_title}' (no D1 heartbeat in $(( (now - hb_epoch) / 60 ))m)" | tee -a "$LOG_FILE"
    RECLAIMED_COUNT=$((RECLAIMED_COUNT + 1))
  done < <(grep -nE '^(- )?\[~\] ' "$BACKLOG_FILE" 2>/dev/null || true)
}
```

Behavioural diff vs. today:
- **Liveness source**: `git log --grep` recency → `_d1_heartbeat_epoch`.
- **Unreachable**: today there was no D1 to be unreachable; the old code's
  "`[[ -z "$last_status_ts" ]] && return`" already fails safe when git gives
  nothing, and the new empty-heartbeat guard preserves that fail-safe posture for
  the D1 case (DECISION 1).
- **Threshold**: `stale_secs=5400` (90 min) is **unchanged** — same window,
  different clock source. (The schema doc's pseudocode names it
  `STALE_CLAIM_SECONDS`; keep the existing local `stale_secs` to minimise the
  diff. If a named constant is desired, introduce `STALE_CLAIM_SECONDS=5400` at
  the top of the file and reference it here — optional, out of scope for the
  switch.)
- **Log line**: "no status commit in Nm" → "no D1 heartbeat in Nm" so the
  reason text matches the new signal.
- `STARTUP_RECLAIM` path is untouched — startup still reclaims unconditionally
  without a network probe (correct: a freshly started daemon's predecessor is by
  definition gone, and we must not block startup on the dashboard being up).

---

## 3. Removal of the old git-log path

The git fallback is **REJECTED** (`docs/d1-telemetry-schema.md §4`,
DECISION 1) — it re-introduces the exact commit↔liveness coupling this change
removes. Concretely, **delete** from `bin/backlog-agent`:

```sh
# DELETE — lines 428-431 (the entire git-log liveness probe + its fallback):
    last_status_ts="$(git -C "$PWD" log "origin/$branch" --format="%ct" --grep="backlog-agent-status" -1 2>/dev/null || echo "")"
    if [[ -z "$last_status_ts" ]]; then
      last_status_ts="$(git -C "$PWD" log "origin/$branch" --format="%ct" -1 2>/dev/null || echo "")"
    fi
    [[ -z "$last_status_ts" ]] && return
    (( now - last_status_ts <= stale_secs )) && return
```

- The `branch` local is no longer needed for liveness — drop it from the
  function's `local` declaration (the only remaining git call is the
  `rev-parse --abbrev-ref` guard, which can stay as a plain "are we in a repo?"
  check and discard its output).
- Update the function's doc comment (`bin/backlog-agent:410-416`): it currently
  describes "checks whether any daemon has pushed a status commit recently … If
  the most recent status commit is older than STALE_CLAIM_MINUTES." Rewrite to:
  "consults the D1 telemetry heartbeat (`heartbeat_epoch`) for this
  (project, host); if older than the stale threshold the daemon is dead and its
  `[~]` items are reclaimed. If D1 is unreachable, fails safe and does NOT
  reclaim (DECISION 1)."
- No other call site reads `last_status_ts`; nothing else in the file
  greps for `backlog-agent-status` commits for liveness (the
  `backlog-agents` fleet CLI is a separate concern and out of scope).

No git-log liveness code remains after this change.

---

## 4. Hermetic test plan

Extend `test/tick.bats` (and `test/helpers.bash`) to mock `curl` via the existing
PATH-shim mechanism (`$SHIM` is already prepended to `PATH` in `_setup_repo`).
The driver is exercised black-box via `run_tick`, exactly as the current stale-
claim test (`tick.bats:60`).

### 4a. A `curl` shim helper (add to `helpers.bash`)

Mirror `make_claude`: write an executable `$SHIM/curl` whose canned response is
chosen by a mode. The reaper's `_d1_heartbeat_epoch` calls
`curl -s -m 5 … -w '\n%{http_code}' <url>`, so the shim must emit the JSON body
followed by a newline and the HTTP status code on the last line.

```sh
# Generate the `curl` PATH stub for heartbeat-read tests. Modes:
#   live        -> 200, found:true, heartbeat_epoch = NOW   (daemon alive)
#   dead        -> 200, found:true, heartbeat_epoch = NOW-7200 (>90m, dead)
#   unreachable -> exit 7 (curl "couldn't connect"), no body
#   notfound    -> 404, found:false
make_curl() {
  local mode="$1"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
mode="$mode"
now="\$(date +%s)"
EOF
  cat >> "$SHIM/curl" <<'EOF'
# The real reaper appends -w $'\n%{http_code}'; emulate body + status line.
emit() { printf '%s\n%s' "$1" "$2"; }   # $1=body, $2=http_code
case "$mode" in
  live)        emit "{\"found\":true,\"heartbeat_epoch\":$now}" 200 ;;
  dead)        emit "{\"found\":true,\"heartbeat_epoch\":$((now-7200))}" 200 ;;
  notfound)    emit "{\"found\":false}" 404 ;;
  unreachable) exit 7 ;;   # curl: (7) Failed to connect
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}
```

Because `$SHIM` is first on `PATH`, the reaper's `command -v curl` resolves to
this stub and `notify_cooldown`'s real curl calls (if any fire) hit it too —
harmless, they ignore the output. To probe the *non-startup* path the tests must
**not** set `STARTUP_RECLAIM=1` (startup reclaim short-circuits before any curl).
They must also provide the health-key file so the bearer branch is exercised:
`mkdir -p "$HOME/.config/backlog" && echo testkey > "$HOME/.config/backlog/health-key"`
(the `_setup_repo` fixture should point `HOME` at a scratch dir for this, as
`_setup_status_repo` already does).

### 4b. Test cases

```
# Live heartbeat -> daemon alive -> [~] NOT reclaimed.
@test "live D1 heartbeat does not reclaim a [~] claim" {
  make_curl live
  write_backlog_open "- [~] in-flight on a live daemon"
  git -C "$WORK" commit -qam "claim"; git -C "$WORK" push -q origin main
  run_tick                       # NOT STARTUP_RECLAIM
  [ "$status" -eq 0 ]
  open_has_marker '~'            # still claimed
  [[ "$output" != *"reclaim"* ]]
}

# Dead heartbeat (>90m old) -> reclaim flips [~] -> [ ] and logs it.
@test "stale D1 heartbeat reclaims a [~] claim" {
  make_curl dead
  write_backlog_open "- [~] orphaned by a daemon that stopped beating"
  git -C "$WORK" commit -qam "claim"; git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker ' '
  ! open_has_marker '~'
  [[ "$output" == *"reclaim"* ]]
  [[ "$output" == *"no D1 heartbeat"* ]]
}

# D1 unreachable (curl exit 7) -> FAIL SAFE -> [~] NOT reclaimed (DECISION 1).
@test "unreachable D1 does not reclaim (fail-safe)" {
  make_curl unreachable
  write_backlog_open "- [~] in-flight, dashboard is down"
  git -C "$WORK" commit -qam "claim"; git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker '~'            # preserved — we must not reclaim mid-work
  [[ "$output" != *"reclaim"* ]]
}

# 404 / found:false (no row for this project,host) -> also fail safe.
@test "missing D1 row does not reclaim (fail-safe)" {
  make_curl notfound
  write_backlog_open "- [~] no telemetry row yet"
  git -C "$WORK" commit -qam "claim"; git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker '~'
  [[ "$output" != *"reclaim"* ]]
}

# Startup reclaim still works WITHOUT any network (no curl dependency on boot).
@test "startup reclaim flips [~] regardless of heartbeat" {
  make_curl unreachable          # even with D1 down...
  write_backlog_open "- [~] orphaned by a dead incarnation"
  git -C "$WORK" commit -qam "claim"; git -C "$WORK" push -q origin main
  run_tick STARTUP_RECLAIM=1     # ...startup path reclaims unconditionally
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim"* ]]
}
```

### 4c. Coverage matrix

| Scenario        | curl mode     | STARTUP_RECLAIM | Expected            |
|-----------------|---------------|-----------------|---------------------|
| Live daemon     | `live`        | unset           | no reclaim          |
| Dead daemon     | `dead`        | unset           | reclaim             |
| D1 unreachable  | `unreachable` | unset           | no reclaim (safe)   |
| No row (404)    | `notfound`    | unset           | no reclaim (safe)   |
| Startup         | `unreachable` | `1`             | reclaim (no probe)  |

The three negative cases (`live`, `unreachable`, `notfound`) all assert
`open_has_marker '~'` survives, directly encoding DECISION 1: the only path that
reclaims a non-startup claim is a *confirmed-stale* heartbeat.

### 4d. Hermeticity guarantees

- No network: the `curl` shim is pure-local; the existing `claude`/`ssh` shims
  already block all external calls.
- No real config: `HOME` is redirected to a scratch dir (the fixture must do this
  for the reaper tests so `$HOME/.config/backlog/health-key` is controlled, the
  same pattern `_setup_status_repo` uses).
- Deterministic age: the shim computes `heartbeat_epoch` relative to `date +%s`
  at call time, so `live`/`dead` straddle the 5400s threshold by construction
  (`dead` = now−7200 is unambiguously > 90m; `live` = now is unambiguously ≤ 90m).

---

## 5. Sequencing & gate (recap)

1. Land `GET /api/heartbeat` in **backlog-dashboard** + deploy. (Prereq;
   separate repo, separate backlog item.)
2. Land the §2 bash switch + §3 removal + §4 tests in **backlog-infra**.
3. **Do not** bring the fleet daemons up until the **canary (W3)** and
   **version-skew** checks pass (`docs/d1-telemetry-schema.md §5`). The switch is
   a behavioural change to the reaper; it ships dark until the gate clears.

Open sub-decision deferred to implementation: whether to introduce a named
`STALE_CLAIM_SECONDS=5400` constant (cosmetic) — not required for correctness.
