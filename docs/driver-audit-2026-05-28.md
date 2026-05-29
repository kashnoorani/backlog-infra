# Driver audit — `bin/backlog-agent` (+ `_lib.sh`)

**Date:** 2026-05-28 · **Method:** read-only multi-agent audit (6 concern
lenses → adversarial per-finding verification). 39 agents, ~1.12M tokens.
**Raised 33 → confirmed 15 → refuted 18.** One "confirmed" is reclassified as a
false positive on human review (see §0), so **14 actionable** findings remain.

Every line was verified against the file by a skeptic; severities below are the
**verifier's corrected severity**, not the finder's. Calibrated to the real
runtime: bash 3.2.57, `set -euo pipefail`, BSD userland, multi-machine fleet.

> **Status (2026-05-28): ALL confirmed findings FIXED.**
> - **§1** (findings 1–5): `|| true` guards on the bare set-e abort sites, base-10
>   normalization in the reset-time parser.
> - **§2** (6–7): pure-bash wall-clock watchdogs (no coreutils `timeout` dep) on
>   the `claude` + status-hook calls (+ `spawnSync` timeouts in the hook).
> - **§3(a)** (finding 8 — the headline split-brain fix): claims now carry an
>   owner stamp (`<!-- @host -->`); the reaper parses it and probes the *claiming*
>   host's heartbeat, never the local host's. Unstamped (legacy) claims are
>   unattributable → fail-safe skip in a normal tick (startup reclaim still clears
>   them). Stamp is written on claim, stripped on every unclaim, hidden in the
>   fleet CLI, and ignored by the completion-diff + lint dedup.
> - **§3(b)** (finding 9): `_maybe_auto_complete` push now uses the claim block's
>   rebase+retry CAS instead of a bare `push || true` (no silent dropped completion).
> - **§4(c)** (finding 11): the divergence `reset --hard` now logs the discarded
>   SHA loudly + a reflog recovery command (no longer silent).
> - **§4(d)** (finding 12): the orphaned auto-stash now reports its running count
>   and warns past 5 pending, so it can't leak invisibly.
>
> Shipped with `test/tick.bats` cases (per-owner reclaim, unstamped fail-safe,
> claim-stamp, unclaim-strip, auto-complete-on-origin) — **full suite 87/87 green.**

---

## 0. Human-QA correction — one false positive

**`do_unblock` bare `sed -i ''` (lines 1529, 1537).** The verifier marked this
`is_real:true` but its *reasoning* concluded "cannot fire" — a self-contradiction.
On review its reasoning was *also wrong*: it claimed GNU sed accepts `-i ''` as a
zero-length suffix; in fact GNU sed requires the suffix attached (`-i.bak`), so
`sed -i '' -E 'expr' file` on Linux consumes `''` as an empty script and treats
the real expression as a filename → the unblock silently no-ops. **So the finder
was right that it breaks on Linux — but every fleet host is macOS (MacBook Airs),
so it cannot fire in practice.** Net: real-but-inert consistency nit, demoted out
of the actionable set. (Flagged because it shows the verify pass has a ~1/15 false-
positive rate here — trust but verify.)

---

## 1. Highest value — `set -e` abort family

The bug class the fleet was already burned by (a tolerable non-zero aborts the
whole daemon). All confirmed high-confidence; all fix the same way (`|| true` /
guard the command).

| # | Line | Hazard | Sev |
|---|------|--------|-----|
| 1 | **1126** | `branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"` — bare command-sub assignment in the claim-push-failed recovery `else`. Its siblings at 956 (`\|\| true`) and 1581 (`\|\| pwd`) are guarded; this one isn't. `git rev-parse` returns non-zero on unborn/transiently-locked HEAD → `set -e` kills the daemon on the exact cross-machine race-recovery path it exists to handle. | med |
| 2 | **596–597** | `reclaim_stale_claims` loop: `sed -i ''` + `echo … \| tee -a "$LOG_FILE"` both unguarded; function called bare at 1009. Read-only backlog (concurrent lock) or unwritable/ full log → abort mid-reclaim, some items flipped, some not. *(In the reaper code just shipped — the loop body is pre-existing, the log line is new.)* | med |
| 3 | **476** | `auto_flip_blocked`: `sed -i ''` unguarded (its awk@474 and grep@478 *are* guarded), called bare at 1004. Transiently unwritable backlog → daemon aborts before item selection. | med |
| 4 | **1349–1351** | `do_status`: three `jq -r '… // empty'` reads with no `\|\| true`. `// empty` only applies *after* a successful parse; malformed/truncated status JSON makes jq exit non-zero → `do_status` aborts with a raw jq error. This is the **default subcommand** users + fleet view run constantly. | med |
| 5 | **763** | `printf '%02d:%02d:00' "$hour" "$min"` — `printf '%02d' 08/09` is an invalid-octal error (prints `00`, exits 1). Verifier confirmed it does **not** abort (nested `$()` swallows it under bash 3.2) but **mis-parses** a `HH:08`/`HH:09` cooldown reset to `HH:00` → cooldown expires up to 9 min early. Fix: `min=$((10#$min))`. | low |

---

## 2. Unbounded blocking calls — hang/wedge family

The daemon is single-threaded and holds `TICK_LOCK_DIR` across these. A hang =
no heartbeat = STALE-while-alive = launchd KeepAlive can't help (process is up) =
the reaper fail-safes (DECISION 1) and never reclaims the wedged `[~]`.

| # | Line | Hazard | Sev |
|---|------|--------|-----|
| 6 | **1181** | `claude -p …` invoked with **no wall-clock timeout** — the one unbounded blocking call (every `curl` has `-m`). A stalled stream/overloaded endpoint wedges the tick indefinitely. Fix: wrap in `gtimeout`/watchdog, treat timeout as a non-zero claude_exit (existing unclaim path runs). | med |
| 7 | **845** | `node "$HOOK"` (status hook) has no timeout, and *inside* it `git fetch`/`git push` use `spawnSync` with no `timeout` option. Runs on **every** tick outcome (incl. idle/cooldown), so a degraded network wedges even a heartbeat tick. | med |

---

## 3. Concurrency / non-CAS writes to the shared backlog

| # | Line | Hazard | Sev |
|---|------|--------|-----|
| 8 | **579** | **Reaper checks the wrong owner's liveness.** `reclaim_stale_claims` reads *this* host's `heartbeat_epoch` (via local `hostname`) but the loop flips back **every** `[~]` item regardless of which machine claimed it. If host B's *own* heartbeat is stale (D1 POST failing >90 min while D1 GET still works — a split-brain) B reclaims A's live in-flight claim → two machines work one item. Narrow (3× timing margin: idle HB ≤1800s vs 5400s stale) but real. **Note: pre-existing — the old git-commit-recency design had the same global, non-per-owner property; the switch didn't introduce it.** Fix: stamp the owning host into the `[~]` line and probe *that* host. | med |
| 9 | **882** | `_maybe_auto_complete` flips item→`[x]`, commits, pushes with `\|\| true` and **no CAS rebase/retry** (unlike the claim push at 1112–1142, which retries). Push rejected by a concurrent remote → completion is local-only → next tick's `reset --hard` (988) can discard it → item re-opens on origin → re-claimed and re-worked (duplicate work / wasted tokens). The commit at 881 is also `>/dev/null`-silenced, so a no-op edit that stages nothing still returns 0 "auto-done". *(Two finders reported this same line/issue — merged.)* | med |

---

## 4. Lower-severity correctness / operational

| # | Line | Hazard | Sev |
|---|------|--------|-----|
| 10 | **597** | Startup-reclaim path (`STARTUP_RECLAIM=1`) skips the block that assigns `hb_epoch`, so the log prints `no D1 heartbeat in ~29000000m` (empty→0 in arithmetic). Cosmetic, but misleads anyone reading the log after a restart. *(In the reaper code just shipped; old code had the same pattern with `last_status_ts`.)* Fix: branch the message on startup, or only print the age when `hb_epoch` is set. | low |
| 11 | **988** | Divergence recovery `reset --hard origin/$branch` discards unpushed local commits — incl. real code claude committed-but-couldn't-push — when `pull --rebase` conflicts on the backlog. Verifier downgraded to low: the design *explicitly* accepts this (idempotent-redo comment at 950–955), and the item re-surfaces for retry; the lost artifact is the *diff*, regenerated next tick. Worth a loud `git reflog`/branch-stamp of the discarded SHA before resetting. | low |
| 12 | **643** | `_post_tick_cleanup` auto-stashes any dirty tree every tick, but **nothing ever pops it** (the `$stashed` pop at 972/992 tracks a *different*, status-file stash). Orphaned partial work accumulates as invisible dead stashes. (Verifier corrected one claim: stashes survive `git gc`, so recoverable manually — but it defeats unattended operation.) | low |
| 13 | **1035** | Reclaim commit pushes with `\|\| true`, no CAS. On push failure the reclaim is local-only and a subsequent `reset --hard` discards it → item stays `[~]` (dead-owned) on origin. Verifier downgraded to low: self-heals on the next tick once the network recovers (reclaim re-fires each tick). | low |

---

## 5. What the adversarial pass refuted (18)

The verify stage killed plausible-but-unreachable claims, e.g.: `hostname -s`
host-key divergence (×2 — strip difference doesn't actually change the key for
these hostnames), an `git add "$BACKLOG_FILE"` abort (path always exists post-
write), several TOCTOU/fswatch tick-storm theories (TICK_LOCK serializes them),
status-hook stash-drop losing the heartbeat (per-host file ownership prevents the
conflict), and the `08/09 pm` *abort* theory (confirmed it mis-parses but does not
abort). Full reasoning in the workflow transcript.

---

## 6. Recommended sequencing

1. **§1 set-e guard cluster (1, 2, 3, 4)** — trivial `|| true`, same class as the
   already-fixed empty-array bug, highest unattended-reliability payoff. #2/#3/#10
   sit in/next to the freshly-shipped reaper code.
2. **§2 timeouts (6, 7)** — the wedge-while-alive class; needs a watchdog helper.
3. **§3 (8, 9)** — fold into the existing claim-CAS path; #8 is a reaper-design
   hardening worth noting in `docs/reaper-switch-design.md`.
4. §4 lows — opportunistic.

All findings gate naturally behind the **W0 test harness** — each should land
with a `tick.bats` case (the harness already proved its worth catching the
empty-array regression).
