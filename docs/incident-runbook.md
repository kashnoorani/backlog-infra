# backlog-infra — bootstrap drill & incident runbook (DRAFT)

> **Status: DRAFT (W4).** The bare-machine bootstrap drill (§A) has been
> walked through against the current `kash_setup.sh` + manifest but not yet
> run end-to-end on a genuinely blank machine — the steps are derived from
> the code, not a clean-room replay. The incident playbook (§B) codifies what
> was diagnosed *by hand* during the **2026-05-28 cooldown incident**; treat
> the fixes as the known-good moves from that event, not an exhaustive list.
>
> `backlog-agents doctor` is the **automated half** of this — run it first,
> always. This document is the **human half**: the order to do things in, and
> the symptom → confirm → fix table for the failure classes `doctor` can flag
> but not (yet) repair.

The system this recovers is described top-down in
[`architecture.md`](./architecture.md); the lock/recovery internals are in
[`cross-machine-locking.md`](./cross-machine-locking.md). Read §10
(resilience) and §12 (file reference) of the architecture doc before acting on
anything destructive here.

---

## Contents

- [A. New-machine bootstrap drill (bare machine → running fleet)](#a-new-machine-bootstrap-drill-bare-machine--running-fleet)
- [B. Incident runbook (symptom → confirm → fix)](#b-incident-runbook-symptom--confirm--fix)
  - [B0. Always start here](#b0-always-start-here)
  - [B1. STALE daemons](#b1-stale-daemons)
  - [B2. Double-daemons](#b2-double-daemons)
  - [B3. Unpulled driver / version-skew](#b3-unpulled-driver--version-skew)
  - [B4. Cooldown stuck](#b4-cooldown-stuck)
  - [B5. Status-hook git failures](#b5-status-hook-git-failures)
  - [B6. Stuck `[~]` item / reclaim runaway](#b6-stuck--item--reclaim-runaway)

---

## A. New-machine bootstrap drill (bare machine → running fleet)

Goal: a replacement Mac, from a fresh OS, joins the fleet and starts ticking
every project autonomously. Everything is driven by two artifacts that already
exist — the **dotfiles repo** (which carries `kash_setup.sh`) and the
**project manifest** (`~/dotfiles/active-projects.txt`). The drill is: clone
dotfiles → run the bootstrap → let it clone every manifested repo + install
every daemon → verify with `doctor`.

### A0. Prerequisites the bootstrap does NOT install for you

`kash_setup.sh` installs `jq`, `fswatch`, `highlight`, oh-my-zsh, and clones
repos, but it **skips daemon install** (warns instead) if `node` or the
`claude` CLI is missing. Get these in place first:

1. **Homebrew** (the script has the install line commented out — do it by hand):
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
2. **node + jq + fswatch** (jq/fswatch are also auto-installed by the script if
   brew is present, but installing now avoids the re-run):
   ```bash
   brew install node jq fswatch gawk
   ```
   `gawk` is not strictly required but avoids the BSD-`awk` `-i inplace`
   silent-no-op footgun the driver guards against; `doctor` warns if it's absent.
3. **claude CLI, logged in**:
   ```bash
   npm install -g @anthropic-ai/claude-code && claude login
   ```
4. **SSH key on GitHub** — every clone/pull is over SSH. If this is missing the
   bootstrap prints a fix block and skips all cloning. Set it up:
   ```bash
   ssh-keygen -t ed25519 -C "kashif@alumni.washington.edu"
   eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
   pbcopy < ~/.ssh/id_ed25519.pub      # paste into https://github.com/settings/ssh
   ssh -T git@github.com               # must say "successfully authenticated"
   ```

### A1. Clone dotfiles and run the bootstrap

```bash
git clone git@github.com:kashnoorani/dotfiles.git ~/dotfiles
. ~/dotfiles/bootstrap/kash_setup.sh
```

`kash_setup.sh` is **idempotent** — safe to re-run any number of times. In one
pass it will:

- install oh-my-zsh + plugins, `highlight`, `jq`, `fswatch` (if brew present);
- symlink every dotfile (`.zprofile`, `.zshrc`, …) and the Claude config
  (`~/.claude/settings.json`, `CLAUDE.md`, `backlog-budgets.json`, the
  `watch-backlog.md` contract command);
- **clone every repo in `~/dotfiles/active-projects.txt`** into
  `~/dev/projects/active/` (additive only — never auto-archives);
- clone `backlog-infra` itself if absent, put `bin/` on PATH, then run
  `dev-projects install-daemons` (one daemon per active project),
  `dev-projects install-watchdog` (auto-adopt new projects), and
  `backlog-agents install-watchdog` (the 24 h `daemon-sync`).

> **PATH gotcha.** The daemon tooling needs
> `~/dev/projects/active/backlog-infra/bin` on PATH
> (`~/dotfiles/settings/osx/.zprofile` handles this). On the *first* run in a
> fresh shell `backlog` may not be on PATH yet — the script says
> "start a new shell and re-run." Open a new terminal and re-run
> `. ~/dotfiles/bootstrap/kash_setup.sh`.

### A2. Verify the fleet is healthy

```bash
backlog-agents doctor      # automated preflight — must exit 0 (warnings OK)
backlog-agents             # dashboard: every manifested project should appear
backlog-agents list        # one `…​.backlog-agent` label per project, "running"
```

`doctor` is the acceptance test for the drill. A clean bootstrap shows:

- **Manifest ↔ project dirs**: manifest present, every listed project on disk
  as a git repo, no reverse drift.
- **launchd daemons**: "no double-daemons", canonical daemon count == manifest
  count, no manifest project without a loaded daemon.
- **Plist paths canonical**: every plist's driver path == the canonical
  de-symlinked `bin/backlog-agent`; WorkingDirectory resolves and isn't a symlink.
- **Per-project config**: status hooks resolve (`node --check`), required
  gitignore patterns present.
- **Globals & tools**: budgets file valid; `git`/`node`/`jq` present (hard);
  `gawk`/`fswatch` present (warn only).

Any **`✗` (hard fail)** means the bootstrap is incomplete — jump to the
matching entry in §B. A `doctor` exit of 0 with only `!` warnings means the
fleet is up.

### A3. Optional belt-and-suspenders

```bash
backlog-agents canary          # validate the driver this machine is running,
                               # record a pass keyed to its bin SHA
backlog-agents install-monitor # continuous auto-fix log monitor (optional)
```

### A4. Drill smoke-test (prove a tick actually runs)

Pick any project and force one tick rather than waiting for the heartbeat:

```bash
cd ~/dev/projects/active/<some-project>
backlog-agent            # status: shows open count + next item
backlog-agent tick       # single tick, exits — watch it claim + work an item
backlog-agent log        # tail the worker log
```

A green tick (claims an item, `claude` exits 0, status hook commits + pushes)
confirms the full path — auth, PATH, git push, status accounting — is live.

---

## B. Incident runbook (symptom → confirm → fix)

This codifies what was diagnosed **by hand** during the 2026-05-28 cooldown
incident. The shape of that incident: a driver change (the unconditional
`git add COOLDOWN_FILE`) broke the status hook's git ops on every machine that
pulled it; one machine (M1) ran the *broken* driver for hours because the fix
was on `origin` but unpulled; the status-hook failures stopped the liveness
signal, so daemons went STALE and the reclaim reaper couldn't tell live from
dead; and a fallback cooldown got stuck because its reset time couldn't be
parsed. Nothing escalated for ~8 h. Each subsection below is one of those
failure classes.

### B0. Always start here

Run the automated half first — it turns "why is the fleet weird" into a
2-second read:

```bash
backlog-agents              # dashboard: STALE/idle/fresh per project, ALERTS,
                            # STUCK [~] items, MACHINES table with DRIVER skew
backlog-agents doctor       # read-only; every ✗ is a confirmed problem class
backlog-agents canary --check   # is the running driver a validated one?
```

The dashboard's **MACHINES** table (DRIVER column) and **ALERTS** /
**STUCK** sections are the fastest triage. Match what you see to a subsection
below.

> **Cardinal rule (from CLAUDE.md): never `git add -A` / `git add .`.** The
> interactive session and the daemon edit the same repos in parallel. Stage by
> name. When a fix below resets a tree, prefer the daemon's own idempotent
> recovery (every tick is discard-and-redo safe) over hand-editing.

---

### B1. STALE daemons

A project's last status commit is ≥ 2 h old (dashboard shows it red `STALE`),
or a whole machine shows `stale` in the MACHINES table. STALE is a *symptom*,
not a root cause — it means the liveness signal (a status commit) stopped. The
cause is almost always one of B3/B4/B5 below.

**Confirm:**

```bash
backlog-agents                                   # which projects/machines are STALE
launchctl print "gui/$(id -u)/com.$USER.<proj>.backlog-agent" | grep -i state
cd ~/dev/projects/active/<proj> && backlog-agent log   # last lines = the real reason
```

In the log, look for: repeated `did not match any files` (→ B5),
`plan-limit cooldown active` that never clears (→ B4), `Cannot fast-forward` /
`failed to push some refs` (→ B5), or a driver SHA mismatch (→ B3).

**Fix:**

1. First diagnose the underlying cause via the log and fix *that* (B3/B4/B5) —
   restarting a daemon running a broken driver just re-breaks it.
2. Once the cause is fixed, restart the daemon(s):
   ```bash
   backlog-agents sync               # pull dotfiles + every project, restart all daemons
   # or a single project:
   cd ~/dev/projects/active/<proj>
   backlog-agent uninstall-daemon && backlog-agent install-daemon
   ```
   `install-daemon` clears a stale `mkdir`-lock and boots out old-label plists
   as part of install.
3. Confirm recovery: `backlog-agent tick` then `backlog-agents` — the project
   should flip to `fresh`.

> **Why nothing escalated for 8 h:** STALE is currently only a dashboard
> *color*. The dead-man's-switch (W2) that promotes STALE-too-long into a push
> alert is not yet shipped — until it is, **someone has to look**. Treat a
> STALE machine as an active incident.

---

### B2. Double-daemons

Two daemons drive the same checkout — typically a canonical
`…​.backlog-agent` plist *and* a leftover legacy-label plist
(`…​.backlog` or `…​.backlog-loop`) both loaded. They race the process lock and
fight over the same items.

**Confirm:**

```bash
backlog-agents doctor    # HARD FAIL: "double-daemon: '<proj>' runs both a
                         #   canonical AND a legacy-label daemon"
backlog-agents list      # shows every loaded label — look for two per project
launchctl list | grep "com.$USER.*.backlog"
```

**Fix:**

```bash
# boot out + remove the legacy-label plist(s):
launchctl bootout "gui/$(id -u)/com.$USER.<proj>.backlog-loop" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.$USER.<proj>.backlog-loop.plist
rm -f ~/Library/LaunchAgents/com.$USER.<proj>.backlog.plist
# then re-install the canonical daemon (retires old labels + their plists):
cd ~/dev/projects/active/<proj> && backlog-agent install-daemon
backlog-agents doctor    # confirm "no double-daemons"
```

`install-daemon` already boots out *and removes* old-label plists on every run
(a stray `RunAtLoad` legacy plist would otherwise resurrect a second daemon at
next login). If a double-daemon reappears after a reboot, a legacy plist file
survived — delete it explicitly as above.

---

### B3. Unpulled driver / version-skew

`bin/` is **shared** — a driver fix isn't live on a machine until that machine
pulls. The 2026-05-28 incident's defining failure: M1 ran the broken driver
for hours because the fix was on `origin` but unpulled, and `daemon-sync` only
runs every 24 h. This is invisible unless you make it a glance.

**Confirm:**

```bash
backlog-agents --fetch   # MACHINES table DRIVER column: skewed host shown
                         #   red with ⚠ (e.g. "M1 abc123 ⚠"); the
                         #   "driver ref (origin/main bin): <sha>" line is the target
backlog-agents canary --check   # exit non-zero if the running driver isn't a validated one
# on the suspect machine, compare its driver SHA to origin:
cd ~/dev/projects/active/backlog-infra
git log -1 --format=%h -- bin            # what this checkout runs
git log -1 --format=%h origin/main -- bin   # the reference (fetch first)
```

**Fix:**

```bash
cd ~/dev/projects/active/backlog-infra
git fetch origin && git pull --ff-only origin main   # land the fix locally
backlog-agents canary        # validate the now-current driver before re-rolling
backlog-agents sync          # pull every project + restart every daemon on the fix
backlog-agents --fetch       # DRIVER column should now be green everywhere
```

To push a fix to the *whole fleet* without waiting on the 24 h `daemon-sync`,
run `backlog-agents sync` on each machine (the cross-machine on-demand trigger
is deferred to the D1 freeze-flag; until then, `sync` per machine is the
manual path). Never let a daemon come back up on an unvalidated driver — that's
what `canary --check` gates.

---

### B4. Cooldown stuck

A plan/session-limit cooldown (`.claude/agent-cooldown.json`) is armed and not
clearing, so the daemon heartbeats forever without working. Two flavors:
(a) a **precise** cooldown whose parsed reset time is in the future (correct —
wait it out), and (b) a **fallback** cooldown where the reset time couldn't be
parsed from Anthropic's message (`parsed_from_reset: false`) — this is the one
that gets *stuck*, because the regex didn't match and it falls back to a flat
`COOLDOWN_SECONDS` window that may keep re-arming.

**Confirm:**

```bash
backlog-agents          # ALERTS section: "<proj> (precise|~estimated) cooldown
                        #   (<reason>) — Xh Ym left (until HH:MM)"
cd ~/dev/projects/active/<proj>
cat .claude/agent-cooldown.json    # check until_epoch vs now, and parsed_from_reset
date +%s                            # compare to until_epoch
backlog-agent log | grep -i cooldown
```

- `parsed_from_reset: true`, `until_epoch` in the future → **legitimate, wait.**
- `parsed_from_reset: false` and `until_epoch` in the past → **stuck stale
  fallback cooldown** — clear it.
- The account plan limit is per-account/shared, but `start_cooldown` arms
  per-project/per-machine — so during a real limit you'll see *every* project
  armed independently. That's expected today (the account-level shared cooldown
  is a W2 item); they all clear when the window passes.

**Fix:**

```bash
# stale / unparseable fallback cooldown — remove the file and let the next tick proceed:
cd ~/dev/projects/active/<proj>
rm -f .claude/agent-cooldown.json
backlog-agent tick          # confirm it works rather than re-arming
# fleet-wide stale-cooldown sweep (auto-fixes expired/unparseable cooldowns):
backlog-agents monitor --once --fix
```

The log monitor (Pattern 5) already auto-clears an **expired** cooldown and a
**stale fallback** cooldown (`parsed_from_reset == false` && duration ≤ 0) when
run with `--fix`. If you have `install-monitor` running, this self-heals; the
manual `rm` is the immediate path. **Do not** delete a *precise* cooldown with
time remaining — you'll just hit the live plan limit again on the next tick.

---

### B5. Status-hook git failures

The status hook commits + pushes per-host status + history after each tick.
When its git ops fail every tick (the 2026-05-28 root cause: an unconditional
`git add COOLDOWN_FILE` for a path that wasn't always present →
`fatal: pathspec '…' did not match any files`), the liveness signal stops:
no status commit → dashboard goes STALE (B1) → and the reclaim reaper can no
longer tell a live-but-not-committing daemon from a dead one (correctness
hazard, B6).

**Confirm:**

```bash
cd ~/dev/projects/active/<proj>
backlog-agent log | grep -iE 'did not match any files|failed to push|Cannot fast-forward|cannot pull with rebase|unstaged changes'
git -C . status --porcelain     # is the tree actually dirty / diverged?
backlog-agents doctor           # status-hook syntax check (node --check)
node --check ~/dev/projects/active/backlog-infra/bin/backlog-agent-status.mjs
```

**Fix:**

1. **If it's a driver bug** (a bad `git add <path>`, a quoting/pipefail error):
   this is fleet-wide because `bin/` is shared. Land + validate the fix, then
   re-roll — see **B3**. Don't hand-patch one machine; pull the fix.
2. **If it's a dirty / diverged tree** blocking the hook's rebase: the hook is
   designed to `git stash --include-untracked` around the rebase, so transient
   dirt self-heals. For a wedged tree, let the monitor's self-protect path
   handle it:
   ```bash
   backlog-agents monitor --once --fix   # for backlog-infra itself this stashes
                                         # (named monitor-auto-stash) then resets to origin/main
   ```
   The monitor **stashes before reset on `backlog-infra` itself** (self-protect)
   and `reset --hard origin/<branch>` on other repos (daemon work is idempotent
   — discard-and-redo safe).
3. Confirm: `backlog-agent tick` then check the log shows a clean status commit
   + push, and the dashboard flips `fresh`.

> **Recover a monitor auto-stash** if it grabbed something you needed:
> `git -C ~/dev/projects/active/backlog-infra stash list` (look for
> `monitor-auto-stash <ts>`), then `git stash show -p <ref>` /
> `git stash apply <ref>`.

---

### B6. Stuck `[~]` item / reclaim runaway

An item sits in `[~]` (claimed/in-progress) far longer than a tick should take
(dashboard **STUCK** section, `>2 h`). Either the claiming daemon died (the
90-min TTL reaper should free it), or — the nastier 2026-05-28-adjacent bug —
`reclaim_stale_claims` re-fired every tick because no *fresh status commit*
landed (B5 broke the liveness signal the reaper keys on), spawning a second
`claude` on the same item each tick (the runaway the per-tick mutex now guards).

**Confirm:**

```bash
backlog-agents          # STUCK section: "<proj> [~] <age> — <item>"
cd ~/dev/projects/active/<proj>
cat .claude/backlog-agent-tick.inflight   # <pid>\t<epoch>\t<title> of the in-flight tick
ps -p "$(cut -f1 .claude/backlog-agent-tick.inflight)" 2>/dev/null  # is that pid alive?
grep -i "reclaim\|claim:" .claude/backlog-agent.log | tail
```

**Fix:**

1. **If the liveness signal is broken (B5), fix that first** — otherwise the
   reaper stays blind and any reset just re-stalls. Once status commits resume,
   the 90-min TTL reaper frees the `[~]` on its own (flips it back to `[ ]`,
   pushes a `reclaim:`).
2. **If a `claude` is genuinely wedged on the item:** stop the daemon, clear the
   in-flight marker and any stale lock, restart:
   ```bash
   cd ~/dev/projects/active/<proj>
   backlog-agent uninstall-daemon
   rm -f .claude/backlog-agent-tick.inflight
   rmdir .claude/backlog-agent.lock .claude/backlog-agent.tick.lock 2>/dev/null || true
   backlog-agent install-daemon
   ```
3. **To free the item by hand** (only if the reaper won't): from the project
   root, `backlog-agent unclaim` flips every `[~]` back to `[ ]` in
   `docs/Backlog.md` (it edits the file only — stage + commit `docs/Backlog.md`
   yourself, or let the next tick pick it up). Prefer this over hand-editing,
   and prefer letting the reaper do it once liveness is restored. The daemon is
   idempotent so the reopen is safe. **Never** `git add -A`; stage
   `docs/Backlog.md` alone.

> The per-tick `mkdir`-based mutex in `tick_once` is what prevents the
> "two `claude`s on one item" runaway today. If you see two `claude` processes
> for the same project, that mutex was bypassed (e.g. an old driver — see B3) —
> pull the current driver.

---

## Quick reference

| Symptom | Confirm with | Fix with |
|---|---|---|
| Project/machine STALE | `backlog-agents`, `backlog-agent log` | diagnose cause (B3/B4/B5), then `backlog-agents sync` |
| Double-daemon | `backlog-agents doctor` (HARD FAIL) | rm legacy plist + `backlog-agent install-daemon` |
| Driver version-skew | `backlog-agents --fetch` (DRIVER ⚠), `canary --check` | `git pull --ff-only`, `backlog-agents canary`, `backlog-agents sync` |
| Cooldown stuck | `backlog-agents` ALERTS, `cat agent-cooldown.json` | `rm agent-cooldown.json` (if stale), `monitor --once --fix` |
| Status-hook git failures | `backlog-agent log` grep, `doctor` | pull driver fix (B3) or `monitor --once --fix` |
| Stuck `[~]` / reclaim runaway | `backlog-agents` STUCK, inflight file | fix liveness (B5); let TTL reaper free it; reinstall daemon |
| Anything else / first move | `backlog-agents doctor` | match the `✗` to a section above |
</content>
</invoke>
