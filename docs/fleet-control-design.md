# Fleet pause / stop / resume control (all machines) — design

> **Status: SHIPPED (fleet scope), 2026-05-29.** The `fleet`-scope MVP is live —
> `backlog-agents pause | resume | stop | start`, on the SAME D1 `fleet_control`
> table as freeze, precedence **stop > pause > freeze**. As-built notes vs. this
> draft (the draft remains the fuller spec for the deferred pieces):
> - **DECISION F / [DECISION A] resolved — one table.** Implemented as **separate
>   control rows** (`key='freeze'|'pause'|'stop'`, the existing `frozen` column as
>   the per-row active bit) rather than a `mode` column — same single-table, single
>   ordering decision, but purely additive (migration `0003_fleet_control_modes.sql`
>   just seeds two rows; no column changes to 0002). The GET endpoint
>   (`/api/fleet-control`) resolves precedence and returns the effective `mode`, so
>   the daemon still does ONE point-read at top-of-tick. The read is a **dedicated
>   GET** (reusing the freeze read path), NOT folded into the ingest response (§3's
>   "free on the heartbeat" idea was never built for freeze either).
> - **[DECISION C] resolved — pause AND stop fail-OPEN.** All three modes fail-open
>   (D1 down ⇒ no control); `launchctl bootout` is the hard backstop. No sentinel
>   was built (see below), so stop is not sentinel-outage-proof — by design, the
>   confirmed call was consistency + "bootout is the real halt."
> - **Stop mechanism (§5) — flag-obey-by-exit, NOT the sentinel + bootout fan-out.**
>   A stopped daemon exits its loop; launchd (`KeepAlive`+`RunAtLoad`, 60s
>   `ThrottleInterval`) respawns it and the next tick re-reads stop and exits again,
>   so it stays effectively down (no work, no heartbeat) with a ~60s respawn blip
>   until `start` clears the flag. `launchctl bootout` is the documented manual hard
>   halt (no respawn). The `.claude/fleet-stopped` sentinel + cross-machine
>   self-stop fan-out (§5) and the `daemon-sync` restart watchdog ([DECISION D]) are
>   **deferred** — current behavior is uniform via the flag without them.
> - **Pause infra exemption — pause EXEMPTS infra (like freeze); only stop halts it.**
>   This DIFFERS from §7's "manual pause has no infra exemption." The confirmed call:
>   keep the exemption rule uniform (the control-plane daemon is never heartbeat-held;
>   only the full halt reaches it). [DECISION E]'s `--except` + per-project targeting
>   is **deferred** with the rest of scope.
> - **[DECISION F-stop-claims] resolved — rely on the TTL reaper.** A stopped daemon
>   goes dark; its `[~]` claim is reclaimed once the D1 `heartbeat_epoch` lapses (90m).
> - **DEFERRED:** `project`/`item` scope (§2, §4), auto-expiring pause ([DECISION G]),
>   `--except` targeting, the stop sentinel + cross-machine restart watchdog. The
>   shipped surface is fleet-wide pause/stop only. Tests: `test/fleet-pause.bats` (14).
>
> The rest of this document is the original DRAFT (2026-05-28) and describes the
> fuller design those deferred pieces would build toward.

---

**Status: DRAFT (W3), 2026-05-28.** Backlog item: *(P2 · W3) Fleet pause / stop
/ resume control (all machines)* — pause-primitive consumer, `scope=fleet`,
**manual**. This is the operator's hands-on lever over the whole fleet:

- **pause** — suspend the tick loop *without losing claim/state*: daemons stay
  alive, heartbeat-only, no `claude -p`, no token spend. Reversible by a single
  `resume`.
- **stop** — full halt: the launchd daemons are booted out and stay down across
  reboots until explicitly restarted.
- **resume / restart** — bring the fleet back: clear the pause flag (for pause),
  or re-bootstrap the daemons (for stop).

…all of that **uniformly across every machine**, not just the local one. This is
the explicit **sibling of fleet-freeze** (`fleet-freeze.md`): the two share the
**pause mechanism** (the heartbeat-only top-of-tick short-circuit) and the
**cross-machine flag substrate** (a single-row D1 control table). Fleet-freeze is
the *automatic, condition-driven* consumer of that substrate; this item is the
*manual, operator-driven* one. They must be designed together so they don't fight
over the same daemon top-of-tick gate — `fleet-freeze.md` DECISION F flags exactly
this, and §3 below resolves it.

Read alongside `architecture.md` §5 (coordination), §8 (the launchd daemon
model), `fleet-freeze.md` (the sibling that owns the D1 freeze flag), and
`d1-telemetry-schema.md` (the D1 schema + ingest/heartbeat path this reuses).

---

## 1. The problem

There is today **no single switch to quiet or halt the fleet**. The only controls
are per-project and per-machine:

- `launchctl bootout gui/$(id -u)/com.$USER.<proj>.backlog-agent` stops one
  daemon on the local machine.
- `backlog-agents sync --restart-only` restarts every *local* daemon.
- Removing the cooldown file, `rmdir`-ing a lock, etc. — all local, all per-repo.

So "stand the whole fleet down right now, on both machines, while I investigate"
requires SSHing into each machine and booting out N daemons by hand — and "bring
it back" is the same dance in reverse. That is exactly the situation an operator
hits during an incident (a runaway tick pattern, a billing scare, a bad driver
the auto-freeze didn't catch), when manual, fast, *fleet-wide* control matters
most.

Two distinct needs, deliberately kept separate:

1. **Pause (soft, reversible, state-preserving).** "Hold work, but keep the
   daemons warm and claims intact." The daemons keep heartbeating (the fleet view
   still shows them alive and explicitly *paused*), no `[~]` claims are released,
   and a single `resume` returns to normal with zero re-bootstrap cost. This is
   the common case and the one that reuses the fleet-freeze pause mechanism
   verbatim.
2. **Stop (hard, full halt).** "Take the daemons down entirely." The launchd jobs
   are booted out and their plists left in a state that does **not** resurrect
   them at next login until `restart`. Used when even heartbeating is undesirable
   (e.g. you want zero process activity), or when pause isn't enough because a
   daemon is wedged below the top-of-tick gate.

The pause path is **cross-machine by construction** (it rides the D1 flag every
daemon reads). The stop path is **inherently local** to where it runs — booting
out a launchd job is a local `launchctl` operation — so §5 specifies how a single
operator command fans a stop out across machines via the same D1 channel.

---

## 2. Scope — `item | project | fleet`

The pause/resume control honours the project-wide pause-primitive scope vocabulary
(backlog-overview line 21: *scope `item | project | fleet`*). The flag carries a
**scope** so one mechanism covers all three granularities:

| Scope | Meaning | Flag selector |
|---|---|---|
| `fleet` | every daemon on every machine | the singleton control row |
| `project` | every daemon for one project name, on every machine | scoped by `project` |
| `item` | a single backlog item is held (do not claim/work it) | scoped by `project` + item title |

- **`fleet`** is the headline case ("stand everything down").
- **`project`** lets an operator quiet one misbehaving project across the fleet
  without touching the other six — e.g. pause `sacred-geography` everywhere while
  leaving `backlog-infra` and the rest working.
- **`item`** is the narrowest: keep a specific backlog item from being claimed
  (it stays `[ ]`/`[!]` but is skipped at selection) without blocking it `[?]` or
  pausing the whole project. This is the manual analogue of the W2 per-item
  circuit breaker — same effect (don't work *this* item), but operator-set and
  not failure-triggered. It is also a cleaner manual lever than editing
  `docs/Backlog.md` by hand (which races the daemon and the dashboard).

Scope and the freeze flag are **orthogonal axes** of the same control table (§3):
freeze is always fleet-wide and automatic; pause/stop carry an explicit scope and
are manual.

---

## 3. Mechanism — extend the D1 `fleet_control` table with a `mode`

`fleet-freeze.md` §3 introduces a single-row D1 control table for the freeze flag
and, in DECISION F, asks whether pause/stop should be a `mode` column on that
same table or separate flags. **This doc resolves DECISION F: one table, a `mode`
column, with a precedence rule.** Sharing one row keeps the daemon's top-of-tick
gate a single cheap read and a single ordering decision, rather than three
independent flags that can disagree.

The freeze table from `fleet-freeze.md` is generalised. Freeze keeps its dedicated
singleton row (`key='freeze'`); pause/stop controls are additional rows keyed by
scope so `project`/`item` scoping is expressible without schema changes:

```sql
-- additive migration in backlog-dashboard (extends 0002_fleet_control.sql,
-- the sibling of 0001_telemetry.sql that fleet-freeze.md introduces)
CREATE TABLE IF NOT EXISTS fleet_control (
  key            TEXT PRIMARY KEY,   -- 'freeze' | 'pause:fleet'
                                     --   | 'pause:project:<name>'
                                     --   | 'pause:item:<name>\t<title-hash>'
  mode           TEXT NOT NULL,      -- 'freeze' | 'pause' | 'stop'  (NEW)
  scope          TEXT NOT NULL DEFAULT 'fleet',  -- 'fleet'|'project'|'item' (NEW)
  scope_project  TEXT,              -- set when scope in (project, item)      (NEW)
  scope_item     TEXT,              -- set when scope = item (the item title) (NEW)
  active         INTEGER NOT NULL DEFAULT 0,  -- supersedes freeze's `frozen`
  reason         TEXT,
  armed_by       TEXT,              -- host or 'manual'
  armed_at_epoch INTEGER,
  arming_sha     TEXT,              -- freeze only: the in-flight bin SHA
  updated_at     TEXT NOT NULL
);
```

(`freeze`'s `frozen` column from `fleet-freeze.md` folds into the shared `active`
flag; `mode='freeze'` distinguishes it. The two docs must land one reconciled
migration, not two — see §8.)

### How each daemon reads it at top-of-tick

The daemon reads the control state **for free on the heartbeat it already sends**
— exactly the fleet-freeze read path. The status hook
(`bin/backlog-agent-status.mjs` ~line 496) already POSTs to
`kash-backlogs.pages.dev/api/health-ingest` every tick; the ingest response
returns the current control state (freeze + any pause/stop rows matching this
daemon's project), so a tick learns its control state with **no extra
round-trip**. The driver caches the last-seen state in `.claude/fleet-control.cache`
so a single failed poll doesn't flap behavior between ticks (same cache discipline
as `fleet-freeze.md` §3).

The gate sits at the very top of `tick_once`, in the same structural position as
the existing plan-limit `cooldown_active()` check (`backlog-agent` ~line 831) and
the fleet-freeze gate, evaluated by **precedence** so the three controls compose
deterministically:

```
tick_once:
  state = read_fleet_control()        # from cached ingest response; fail-open (§6)

  # --- precedence: stop > pause > freeze > account-cooldown > normal ---
  if state.applies(this) and state.mode == 'stop':
      # should already be booted out (§5); if we got here, the flag arrived
      # after launch. Heartbeat once so the dashboard records the stop, then
      # the daemon exits so launchd won't keep it warm.
      heartbeat-only; request_self_stop(); return

  if state.applies(this) and state.mode == 'pause':
      heartbeat-only; return          # NEW: the soft, state-preserving hold

  if frozen() and not exempt():       # fleet-freeze.md §3
      heartbeat-only; return

  if cooldown_active():               # existing plan-limit (architecture.md §4)
      heartbeat-only; return

  ... normal pull / claim / claude ...
```

`state.applies(this)` resolves the scope:

- `fleet` → applies to every daemon.
- `project` → applies iff `scope_project == basename($PWD)`.
- `item` → does **not** short-circuit the whole tick; instead it is consulted at
  **item selection** (§4): the held item is skipped, the daemon still works other
  open items. So the `item` scope is the one mode that is *not* a top-of-tick
  heartbeat-only return.

**Why pause sits above freeze in precedence:** a manual pause is an explicit
operator override; it should hold the daemon even if a freeze would also (since
both produce heartbeat-only, the practical effect is identical, but the dashboard
should attribute the hold to the operator's pause, with its `reason`). **Why stop
sits above pause:** stop is the strongest manual signal. The ordering matches
`fleet-freeze.md` DECISION F's suggested `stop > pause > freeze`.

### The pause mechanism is literally the fleet-freeze pause mechanism

Pause adds **no new daemon code path beyond the gate** — it reuses the exact
heartbeat-only short-circuit that fleet-freeze (and before it, the plan-limit
cooldown) already established: write the status/heartbeat so the fleet view shows
the daemon *alive*, do not claim, do not call `claude`, return. Claims (`[~]`)
are untouched, so in-flight state is preserved and `resume` is instantaneous. This
is the "suspend tick loop without losing claim/state" the backlog item asks for,
and it falls straight out of reusing the established primitive.

---

## 4. `item`-scope pause at selection time

The `item` scope does not belong at the top-of-tick gate (the daemon should still
work *other* open items). It belongs at **item selection** — the
`sed -n '/^## Open/,/^## [A-Z]/p' | grep -m1 ...` step in `tick_once`
(`backlog-agent` ~line 925) that picks the first eligible `[ ]`/`[!]` item.

The held-item set (the `pause:item:*` rows for this project) is consulted there:
when the first eligible item matches a held title, skip it and take the next
eligible one. If *all* eligible items are held, the tick is idle (heartbeat-only),
identical to an empty `## Open`.

This is deliberately **non-mutating** — it does not flip the item's marker in
`docs/Backlog.md`. Editing the backlog to express a manual hold would (a) race the
daemon's own claim/reclaim writes, (b) churn the shared file across machines, and
(c) conflate "operator is holding this" with the `[?]` blocked state (which means
something different: blocked on a *design decision*). Keeping the hold in the D1
control plane keeps `docs/Backlog.md` as pure work-state and the control plane as
pure operator-intent — the same separation `d1-telemetry-schema.md` draws between
durable git state and ephemeral telemetry.

`scope_item` is matched by exact item title (the same title string `log_event` and
the claim use). The `key` carries a short title hash to keep the primary key
bounded and avoid quoting hazards in the row key; the full title lives in
`scope_item`.

---

## 5. Stop / restart — the local `launchctl` path, fanned out cross-machine

Pause/resume are pure flag flips. **Stop is different: a true full halt is a local
`launchctl bootout`**, because keeping a heartbeat-only daemon alive is still
*pause*, not *stop*. The challenge is making "stop the whole fleet" reach machines
the operator is not sitting at.

### Local stop primitive

On the machine that runs the command, stop boots out the launchd job(s) exactly
like the existing `do_uninstall_daemon` (`backlog-agent` ~line 1618) and
`do_sync`'s restart block (`backlog-agents` ~line 890) already do:

```
launchctl bootout "gui/$(id -u)/com.$USER.<proj>.backlog-agent"
```

Crucially, **stop must not delete the plist** (unlike `uninstall-daemon`). The
plist is left on disk but the job is booted out, so `restart` is a re-`bootstrap`
of the existing plist rather than a full re-install. To prevent launchd from
resurrecting the job at next login/reboot (the plists carry `RunAtLoad` +
`KeepAlive`, `backlog-agent` ~line 1586), stop writes a local **stop sentinel**
(`.claude/fleet-stopped`); `do_run`/`do_watch` check the sentinel immediately
after `maybe_install_daemon` and exit cleanly if present (so a `RunAtLoad` restart
self-terminates without working). `restart` removes the sentinel and re-bootstraps.

This is the local stop primitive. New subcommands on the per-project driver:

| Subcommand | Action |
|---|---|
| `backlog-agent stop` | write `.claude/fleet-stopped`; `launchctl bootout` this project's daemon (plist preserved) |
| `backlog-agent restart` | remove `.claude/fleet-stopped`; `launchctl bootstrap` the existing plist |

and fleet-wide wrappers on the dashboard CLI:

| Subcommand | Action |
|---|---|
| `backlog-agents pause [--project P] [--item "title"] [--reason ...]` | POST a `pause` row (scope from flags; default `fleet`) to `fleet_control` |
| `backlog-agents resume [--project P] [--item "title"]` | clear the matching `pause` row (set `active=0`) |
| `backlog-agents stop [--project P]` | local: stop every matching local daemon; cross-machine: POST a `stop` row so remote daemons self-stop (below) |
| `backlog-agents restart [--project P]` | local: restart every matching local daemon; clear the `stop` row |

### Fanning stop out cross-machine

The operator's machine can only `launchctl bootout` its **own** jobs. To reach
remote machines without SSH, stop uses the **same D1 control flag** as pause, but
with `mode='stop'`:

1. `backlog-agents stop` POSTs a `mode='stop'` row (scope from flags) **and**
   boots out the local matching daemons immediately (write the local sentinel +
   `launchctl bootout`).
2. **Remote daemons self-stop on their next tick.** A remote daemon reads
   `mode='stop'` for its scope at top-of-tick (the precedence gate, §3), writes
   the stop sentinel locally, heartbeats once (so the dashboard records the
   transition), then **exits** — and because it wrote the sentinel, the
   `RunAtLoad` relaunch immediately self-terminates. Net effect: the remote daemon
   is down and stays down, achieved entirely through the D1 flag the daemon
   already polls.

This makes stop **eventually-consistent across machines** (bounded by each remote
daemon's tick cadence — at worst one heartbeat interval), where pause is
effectively immediate (next tick) and the local stop is instant. The asymmetry is
inherent: you can flip a flag instantly, but you can only *bootout* a process on
the machine it runs on, so a remote bootout has to be a cooperative self-stop.

`restart` clears the `stop` row; remote daemons cannot un-bootout themselves
(they're not running), so cross-machine *restart* additionally requires either the
`daemon-sync` watchdog (`backlog-agents daemon-sync`, the 24 h loop) to re-bootstrap
on its next pass after seeing the cleared flag + absent sentinel, or a manual
`backlog-agents restart` run on each machine. This is the one operation that can't
be made fully push-button remotely — surfaced as DECISION D.

---

## 6. Fail-safe behaviour on unreachable D1

The control read must degrade gracefully, mirroring `d1-telemetry-schema.md`
DECISION 1 and `fleet-freeze.md` §3 — but the safe direction differs per mode:

- **pause, D1 unreachable** → **fail-open: treat as NOT paused** (resume normal
  ticking). Rationale: pause is a transient operator hold; if the control plane is
  down, the operator falls back to the local stop (`launchctl bootout`) as the
  hard backstop. Blocking the whole fleet on an unreachable D1 would itself be a
  fleet outage. Use the cached last-seen state across a *single* failed poll
  (so one flaky request doesn't flap), but do not honour an indefinitely stale
  pause flag through a sustained D1 outage.
- **stop, already booted out** → unaffected by D1 reachability: the daemon is not
  running, and the local sentinel keeps it down regardless of D1. The sentinel is
  the source of truth for *local* stop; D1 only carries the *intent* to remote
  machines.
- **freeze** → governed by `fleet-freeze.md` (its DECISION C, also fail-open).

So D1 down means: pause melts (fail-open), stop persists (sentinel-backed),
freeze melts (per its own doc). The hard, persistent control (stop) is precisely
the one that does **not** depend on the control plane being up — which is the
property you want from an emergency halt.

---

## 7. Interaction with the existing controls + the dashboard

- **Precedence** (§3): `stop > pause > freeze > account-cooldown > normal`. All
  but `item`-scope pause produce the same heartbeat-only short-circuit, so the
  ordering only governs **attribution** (which `reason` the dashboard shows) and
  which condition must clear to resume.
- **Claims are preserved** under pause/freeze/cooldown (all heartbeat-only). Stop
  exits the daemon but does **not** release claims either — an `[~]` left by a
  stopped daemon is reclaimed by the normal 90-min TTL reaper
  (`reclaim_stale_claims`, `architecture.md` §5) once another daemon sees no
  fresh heartbeat. (After the W1 reaper switch, "no fresh heartbeat" is the D1
  `heartbeat_epoch` signal; a stopped daemon stops heartbeating, so its claims
  correctly free up.)
- **Dashboard surfacing.** `backlog-agents` adds a control banner: when any
  control row is `active`, print it in the header (e.g.
  `FLEET PAUSED (project=sacred-geography) — "billing scare" — armed manual 14:32`)
  the way the existing ALERTS block surfaces cooldowns (`backlog-agents`
  ~line 700). A paused daemon renders `fresh` (it still heartbeats) but tagged
  *paused*; a stopped daemon goes `STALE` (no heartbeat) and is tagged *stopped*
  so the operator can tell intentional-stop from a crash.
- **`backlog-infra` exemption.** Unlike fleet-freeze (where infra is exempt to
  avoid deadlock, `fleet-freeze.md` §6), **manual pause/stop has no automatic
  exemption** — if an operator says "stop the fleet," they mean *everything*,
  including infra. But a `fleet`-scope pause/stop should be easy to *target*: the
  CLI defaults to all projects, and `--project` narrows it, so an operator who
  wants "pause everything except infra" runs per-project or uses an
  `--except backlog-infra` convenience (DECISION E).

---

## 8. Build order + dependencies

This item **depends on the D1 control substrate that `fleet-freeze.md`
introduces** — they share the `fleet_control` table and the ingest-response read
path. Build order:

1. **Land the reconciled `fleet_control` migration once** (in backlog-dashboard),
   carrying both fleet-freeze's `freeze` row and this doc's `mode`/`scope`
   columns — not two competing migrations (this is the concrete resolution of
   `fleet-freeze.md` DECISION F).
2. **Ship the ingest-response read** (the ingest returns control state; the
   driver caches it in `.claude/fleet-control.cache`). Shared with fleet-freeze.
3. **Add the top-of-tick precedence gate** (§3) in `tick_once` and the
   selection-time `item`-scope skip (§4).
4. **Add the local stop primitive** (`backlog-agent stop`/`restart` + the
   `.claude/fleet-stopped` sentinel check in `do_run`/`do_watch`).
5. **Add the dashboard wrappers** (`backlog-agents pause|resume|stop|restart`)
   and the control banner.

Steps 3–5 are pure-local and testable before the D1 pieces (a local
`.claude/fleet-control.cache` / `.claude/fleet-stopped` can stand in for the D1
read in the hermetic test suite, the way the existing tests stub the network).

---

## Open DECISIONS

- **[DECISION A] One `fleet_control` table vs. separate pause/stop/freeze flags.**
  §3 resolves `fleet-freeze.md` DECISION F in favour of **one table with a `mode`
  column + a precedence rule** (`stop > pause > freeze`). Confirm this over three
  independent flags. One table keeps the daemon's top-of-tick read a single point
  lookup and the ordering a single decision; the cost is the two docs must land a
  single reconciled migration. Recommend one table.

- **[DECISION B] `item`-scope key encoding.** §4 keys held-item rows by
  `pause:item:<project>\t<title-hash>` with the full title in `scope_item`.
  Confirm the hash (short, collision-tolerant since it's namespaced by project)
  vs. storing the raw title in the key (simpler, but quoting/length hazards in a
  D1 primary key). Recommend the hash.

- **[DECISION C] Pause fail-open vs. fail-closed on unreachable D1.** §6 proposes
  **fail-open** for pause (D1 down ⇒ resume ticking, with local stop as the
  backstop), mirroring the reaper + freeze fail-safe. The opposite (honour the
  last-seen pause through an outage) avoids a surprise resume mid-incident but
  risks a sticky fleet-wide stall when D1 flaps. Recommend fail-open with the
  one-poll cache, but note that for an *emergency* pause the operator should use
  stop (sentinel-backed, outage-proof) instead. Needs a call.

- **[DECISION D] Cross-machine *restart* after stop.** §5 notes a stopped remote
  daemon can't un-bootout itself, so cross-machine restart needs either the
  `daemon-sync` watchdog to re-bootstrap on its next pass (24 h — too slow for an
  incident) or a per-machine manual `restart`. Options: (i) have `daemon-sync`
  poll the `stop` flag on a short loop and re-bootstrap promptly when it clears;
  (ii) a dedicated short-cadence "control watchdog" launchd job that survives stop
  (it's a different label) and re-bootstraps daemons when the flag clears;
  (iii) accept manual restart per machine. Leaning (i)/(ii) — the watchdog already
  runs fleet-wide and reads the inputs; (ii) is cleaner because it must outlive
  the very daemons it restarts.

- **[DECISION E] `fleet`-scope targeting / exempting infra.** §7 says manual
  pause/stop has no automatic infra exemption (operator intent is literal). Should
  the CLI offer an `--except <project>` convenience for the common "pause
  everything but infra" case, or is per-project invocation enough? Recommend a
  thin `--except` since "hold the project fleet, keep infra working" is the most
  likely real pause during an incident (mirrors fleet-freeze's infra-keeps-working
  shape, but operator-chosen rather than automatic).

- **[DECISION F] Should `stop` release claims?** §7 keeps claims under stop and
  relies on the TTL reaper to free them once heartbeats lapse. Alternative: stop
  proactively unclaims this daemon's `[~]` items (like `acquire_lock`'s orphan
  recovery) so they're immediately available to a still-running daemon elsewhere.
  Recommend relying on the reaper (simpler, and a deliberate stop is usually
  fleet-wide so there's no peer to pick the item up anyway) unless `--project`
  stop leaves peers running — in which case proactive unclaim is friendlier.

- **[DECISION G] Auto-expiring pause.** Should a pause carry an optional TTL
  (`--for 2h`) that auto-resumes, so a forgotten pause can't silently quiet the
  fleet indefinitely? The cooldown already has a precise `until_epoch`; a pause
  could reuse the shape. Recommend optional TTL with a sane default-off (manual
  pause is deliberate), but surface the pause age loudly in the dashboard banner
  regardless.
