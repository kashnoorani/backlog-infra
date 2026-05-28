# Cross-machine locking & coordination

The daemon (`backlog-agent run`) can run on multiple machines against the
same git repo. This doc explains how coordination works, why the
obvious "just make the lock cross-machine" instinct is wrong, and how
every failure mode is handled.

## The two locks (they do different jobs)

The system uses **two separate coordination mechanisms** — conflating them
is the root cause of the "why can't the lock work cross-machine" confusion.

```
┌─────────────────────────────────────────────────────────────┐
│                      ONE MACHINE                             │
│                                                              │
│  ┌──────────────────┐     ┌──────────────────────────────┐  │
│  │  PROCESS LOCK     │     │  WORK-ITEM CLAIM              │  │
│  │  (local only)     │     │  (cross-machine via git)      │  │
│  │                   │     │                              │  │
│  │  Mechanism:       │     │  Mechanism:                  │  │
│  │   mkdir + PID     │     │   git commit + push          │  │
│  │                   │     │                              │  │
│  │  Location:        │     │  Location:                   │  │
│  │   .claude/        │     │   origin (GitHub)            │  │
│  │   backlog-agent   │     │                              │  │
│  │   .lock/          │     │  Guards:                     │  │
│  │                   │     │   Two daemons (anywhere)     │  │
│  │  Guards:          │     │   claiming the same [ ]      │  │
│  │   Two daemon      │     │   item simultaneously        │  │
│  │   processes on    │     │                              │  │
│  │   the SAME        │     │  Stale recovery:             │  │
│  │   checkout        │     │   TTL reaper (90 min         │  │
│  │                   │     │   with no status commits)    │  │
│  │  Stale recovery:  │     │                              │  │
│  │   kill -0 check   │     │                              │  │
│  │   (same-machine   │     │                              │  │
│  │    PID lookup)    │     │                              │  │
│  └──────────────────┘     └──────────────────────────────┘  │
│         │                            │                       │
│         │ local fs                   │ git push              │
│         ▼                            ▼                       │
│  ~/project/.claude/              origin/main                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                                                              │
┌─────────────────────────────────────────────────────────────┤
│                      ANOTHER MACHINE                         │
│                                                              │
│  (same two locks, different local checkout)                  │
│                                                              │
│  ┌──────────────────┐     ┌──────────────────────────────┐  │
│  │  PROCESS LOCK     │     │  WORK-ITEM CLAIM              │  │
│  │  (local only)     │◄────│  (cross-machine via git)      │  │
│  │                   │     │                              │  │
│  │  Guards against:  │     │  push rejected →             │  │
│  │  two daemons on   │     │  reset to origin →           │  │
│  │  THIS checkout    │     │  skip item → retry next tick │  │
│  └──────────────────┘     └──────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Process lock (`acquire_lock`, line ~206)

- **Purpose**: prevent TWO daemon processes on the SAME machine from both
  running `tick()` concurrently on the same checkout.
- **How**: `mkdir .claude/backlog-agent.lock` — only one process succeeds.
  The winner writes its PID.
- **Why local-only is correct**: nothing about process exclusion (file
  system contention, O_SYNC safety, PID lifecycle) translates across
  machines. A PID on box A is meaningless on box B.
- **Stale recovery**: `kill -0 $lock_pid` checks if the recorded PID is
  still alive on THIS host. If not, the lockdir is removed and
  orphaned `[~]` items are reclaimed (same-machine crash recovery).

### Work-item claim (line ~549)

- **Purpose**: prevent two daemons ANYWHERE from claiming the same `- [ ]`
  item from `docs/Backlog.md`.
- **How**: flip `[ ]` → `[~]` in the file, commit with message `"claim: <title>"`,
  push to origin. If push is **rejected** (another machine pushed first),
  discard the local commit (`reset --hard origin/<branch>`) and skip the
  item on this tick.
- **Cross-machine by construction**: origin (GitHub) is the single shared
  medium. The push is the compare-and-swap — first to push wins.

### Per-tick lock (`tick_once`) — a finer-grained sibling of the process lock

The process lock guards two *daemons* on one checkout, but a single daemon
drives `tick_once` from **two contexts** — the fswatch subshell and the poll
loop (see `do_run`). The process lock is held for the daemon's whole lifetime
and does not serialize those two drivers. A `mkdir`-based per-tick lock
(`.claude/backlog-agent.tick.lock`) at the top of `tick_once` lets only one
tick run at a time; a concurrent trigger skips. Released on tick return (a
`RETURN` trap), and cleared across restarts in `release_lock` and
`acquire_lock`'s stale-reclaim path.

**Why it's needed:** a tick's own backlog write (a `claim:`/`reclaim:` commit)
trips fswatch, which would otherwise start a *second* concurrent tick. In
steady state that second tick finds the item already `[~]` and idles — but
while recovering a long-stale item it turns into a runaway: `reclaim_stale_claims`
re-fires every tick until a fresh status commit lands, so each concurrent tick
re-opens and re-claims the same item and spawns its own `claude`.

## Full tick lifecycle

```
  tick start
    │
    ├─ 1. cooldown check ──── if plan-limit active, heartbeat only, return
    │
    ├─ 2. git fetch + merge ── sync from origin (hardened pull pathway)
    │      │                    ┌ if HEAD diverged: reset --hard to recover
    │      │                    └ if fast-forward ok: merge --ff-only
    │      ▼
    ├─ 3. auto_flip_blocked ── [?] items with [user] answers → [!]
    │
    ├─ 4. reclaim_stale_claims ── if no status commit in 90 min:
    │      │                       all [~] → [ ] (dead daemon recovery)
    │      ▼
    ├─ 5. select next item ──── first [ ] or [!] from ## Open
    │      │
    │      ▼
    ├─ 5b. push reclaim ─────── if any [~]→[ ] this tick: commit + push
    │      │                     "reclaim: N" BEFORE the claim, so the claim's
    │      │                     [ ]→[~] stays a real diff even when the
    │      │                     reclaimed item is the one being claimed
    │      │
    │      ├─ no item ──▶ heartbeat ──▶ return
    │      │
    │      ▼
    ├─ 6. claim item ────────── [ ] / [!] → [~]
    │      │                    commit "claim: <title>"
    │      │                    push to origin
    │      │
    │      ├─ push rejected ──▶ reset --hard origin/<branch> ──▶ skip, retry next tick
    │      │                    (other machine claimed first)
    │      │
    │      ▼ push accepted
    │
    ├─ 7. claude -p ─────────── work the item (commit + push by claude)
    │      │
    │      ├─ claude exits 0 ──▶ success
    │      │
    │      └─ claude exits ≠0 ──▶ if plan-limit: start cooldown
    │                              unclaim: [~] → [ ], commit+push
    │
    ├─ 8. status hook ───────── stash → pull --rebase → stash pop
    │      (backlog-status.mjs)  write backlog-status.json +
    │                            backlog-status-<hostname>.json
    │                            commit + push
    │
    └─ 9. post-tick cleanup ─── log rotation, auto-compact
```

## Cross-machine race: visual walkthrough

Two machines (A and B) pick up the same item simultaneously:

```
    Machine A                          origin (GitHub)               Machine B
    ────────                          ────────────────               ────────
                                                                        │
    ┌─ tick start                                                       │
    │                                                                    │
    ├─ pull (HEAD = abc) ◄─────────────── abc ◄───────────── pull (HEAD = abc)
    │                                                                    │
    ├─ select item "Fix login"                                          ├─ select item "Fix login"
    │                                                                    │
    ├─ awk: [ ]→[~] locally                                            ├─ awk: [ ]→[~] locally
    │                                                                    │
    ├─ commit "claim: Fix login"                                       ├─ commit "claim: Fix login"
    │    (commit = def)                                                  │    (commit = xyz)
    │                                                                    │
    ├─ push origin main ──────────────▶                             ◄─── ├─ push origin main
    │          │                         │                          │      │
    │          │                         ▼                          │      │
    │          │              origin accepts push (def)             │      │
    │          │              origin is now abc→def                 │      │
    │          │                                                    │      │
    │          │              origin REJECTS push (xyz)             │      │
    │          │              (xyz is not a descendant of def)      │      │
    │          │                         │                          │      │
    │          │                         ▼                          │      │
    │          ▼                                                    ├─ push FAILED
    ├─ claimed=true                                                    │
    │                                                                    ├─ reset --hard origin/main
    ├─ claude works "Fix login"                                        ├─ "skipped — retry next tick"
    │                                                                    │
    ├─ commits + pushes result                                         ├─ next tick pulls ──▶ sees "Fix login" is
    │                                                                    │   [~] (claimed by A) ──▶ skips it
    └─ done                                                             │
```

Both machines see the same item, but only one wins the push race. The
loser detects the rejected push and resets, so its local state matches
origin for the next tick. No item is worked twice.

## Status files: per-host + shared

After each tick, the status hook writes TWO files:

```
.claude/
├── backlog-status.json              ← shared (last-writer-wins for fleet dashboard)
├── backlog-status-<hostname>.json    ← per-host (canonical per-machine record)
└── backlog-history.jsonl            ← append-only log of all ticks
```

The **shared file** preserves the `last_host` from the previous real-work
tick across idle ticks (the fleet dashboard's "LAST BY" column). This
means it's last-writer-wins if two machines tick simultaneously — but
that's cosmetic (the "LAST BY" column might briefly show the wrong
host).

The **per-host file** always writes the local hostname regardless of
idle preservation. The fleet dashboard and per-machine views read this
file for attribution.

## Failure modes & recovery

### 1. Daemon crashes mid-claim (after push, before claude)

```
  State: item is [~] on origin. mkdir-lock on crashed machine exists.
  
  On SAME machine restart:
    → acquire_lock detects stale PID → kills lockdir
    → flips all [~] → [ ] (same-machine crash recovery, line ~228)
    → item becomes available
  
  On OTHER machine:
    → reclaim_stale_claims (90-min TTL): after 90 min with no status
      commits from the crashed machine, flips [~] → [ ] locally,
      commits+pushes "reclaim:" commit
    → item becomes available
```

### 2. Daemon crashes during claude (after claim push)

```
  State: item is [~] on origin. Some work might be committed locally
         but not pushed. mkdir-lock exists on crashed machine.
  
  Same as scenario 1 — recovered by same-machine stale-lock or
  cross-machine TTL reaper.
```

### 3. Claude push fails (network/auth issues)

```
  State: work is committed locally, not on origin. Next tick's pull
         finds HEAD diverged from origin.
  
  Recovery: hardened pull pathway detects divergence via
    merge-base --is-ancestor → reset --hard origin/<branch>
    Discards the local-only work commit. Claude will redo the work
    on the next tick if the item is still [ ] (it won't be — it's
    [~] on origin, so another machine or the stale reaper handles it).
```

### 4. Working tree dirty blocks pull --rebase in status hook

```
  State: claude exited abnormally, leaving unstaged changes. Status
         hook's `git pull --rebase` fails with "unstaged changes."
  
  Recovery: status hook now git stash's dirty files before pull,
    pops the stash after (even on pull failure). If stash pop
    conflicts, changes stay in the stash (no data loss).
```

### 5. Claim push fails (race condition)

```
  State: two machines claimed same item. One push succeeded, one failed.
  
  Recovery: losing machine does reset --hard origin/<branch> (line ~573),
    discards its local claim commit. Next tick pulls the winner's claim
    and skips the now-[~] item.
```

## The four improvements (May 2026)

### 1. Stale-claim TTL reaper (`reclaim_stale_claims`)

Before selecting the next item, the daemon checks if any daemon
anywhere has pushed a status commit in the last 90 minutes. If not,
all `[~]` items are considered abandoned and flipped back to `[ ]`.

**Liveness signal**: `git log origin/<branch> --grep="backlog-agent-status" --format="%ct" -1`
A daemon pushes a status commit every ≤30 min; 90 min of silence
means no daemon is running.

When any items are reclaimed, a standalone `"reclaim: N stale claim(s)"`
commit is pushed *before* the claim below, so other machines see the
freed items. This must happen even when a new item is then claimed: if
the reclaimed item is also the one selected, reclaim (`[~]`→`[ ]`) and
claim (`[ ]`→`[~]`) cancel to a zero net diff, so bundling them into a
single claim commit would commit nothing — the claim is silently skipped
and the tick aborts as "claim push failed". Pushing the reclaim first
keeps the claim's `[ ]`→`[~]` a real diff so the CAS push still works.

### 2. Hardened pull pathway

Replaced `git pull --ff-only || true` (silent failure) with:

```
  git fetch origin <branch>
  if HEAD is ancestor of origin/<branch>:
    git merge --ff-only origin/<branch>   (fast-forward)
  else:
    git reset --hard origin/<branch>      (recover diverged HEAD)
```

The daemon always pushes its own commits; lingering local commits
mean something failed. The work is idempotent — it will be redone
if the item is still open.

### 3. GNU awk fallback (`_local_awk_inplace`)

BSD awk (macOS default) does not support `-i inplace`. The claim and
unclaim blocks previously used `awk -i inplace ... || true`, which
**silently no-ops** on macOS without gawk installed.

New helper detects gawk vs. BSD awk and falls back to tempfile + mv.

### 4. Pre-rebase `git stash` in status hook

The status hook now `git stash --include-untracked` before
`git pull --rebase` and pops the stash after. Prevents "unstaged
changes" failures when claude exits abnormally. If pop conflicts,
changes remain in the stash (no data loss).

## Key invariants

- The **process lock is local** by design — mkdir + PID on one
  filesystem. Never move it to a network filesystem or external
  service. It's not the tool for cross-machine coordination.
- The **work-item claim is git push** — origin is the compare-and-swap
  medium. Cross-machine by construction. No external infra needed.
- The **daemon is idempotent** — any tick's work can be discarded and
  redone safely. This means `reset --hard` recovery is always safe.
- **Per-host status files** (`backlog-status-<hostname>.json`) are the
  canonical per-machine record. The shared file is a convenience
  aggregate for the fleet dashboard.
- **90 minutes** is the stale-claim detection window (1.5× max tick
  duration). If no daemon pushes a status commit in 90 min, all
  claims everywhere are stale.
