# Cross-project agentic-coding workflow

A reusable pattern for solo development with autonomous AI workers. Goal:
keep an agentic worker productive on a backlog without burning through
session/weekly limits, while keeping shipped code auditable and
reversible.

This doc describes the *pattern*. Per-project implementations live in each
repo (`scripts/`, `CLAUDE.md`, `docs/Backlog.md`, etc.); shared infrastructure
lives here in `~/dotfiles/`.

---

## The cycle

```
docs/Backlog.md          one-input source of truth: - [ ] open / - [~] in-progress
   │                     / - [?] blocked / - [!] answered-retry / - [x] done
   ▼
implementation           autonomous worker drains - [ ] and - [!] items
   │                     (either /watch-backlog interactive, or headless
   │                      `backlog run` driver)
   ▼
eval / test              `npm run build` chains typecheck → lint → tests → bundle
   │                     (any failure blocks the worker from committing)
   ▼
preview                  `npm run deploy:preview` ships the working tree to
   │                     a non-prod URL on real infra (Cloudflare preview
   │                     branch). Sanity check before promoting.
   ▼
release                  `npm run release` gates → fast-forwards `release`
   │                     branch → tags → pushes → deploys to prod URL.
   ▼
back to backlog          new ideas / bugs / improvements append to docs/Backlog.md
                         as - [ ] items; cycle repeats.
```

Each stage is one command. The worker can drive it end-to-end except for
explicit promotion (`npm run release` is human-triggered — `- [ ]` items in
the backlog never request prod deploys themselves).

---

## Stage 1 — Backlog

**Single file: `docs/Backlog.md`.** Markdown with GFM checklist items,
five sections (`Open` / `In progress` / `Blocked` / `Done` + freeform notes).

Markers (GFM task list syntax):
- `- [ ]` open — autonomous workers pick from these
- `- [~]` in progress — worker has claimed it
- `- [?]` blocked on a design decision the user must answer — workers skip
- `- [!]` answered, ready to retry — user has written answers inline
  (typically prefixed `[user]`) under a previously-blocked item; workers
  treat `[!]` like `[ ]` but read the body for design decisions first
- `- [x]` done — moved to `Done` section with a one-paragraph summary

The blocker round-trip:
```
[ ] (open)
 │
 ├─ worker picks it, hits a question mid-work
 ▼
[?] (worker writes inline question, commits, exits)
 │
 ├─ user answers inline (e.g. `[user] in-memory is fine`)
 ├─ `backlog unblock <N>`        # or `--all`, or hand-flip the marker
 ▼
[!] (worker re-attempts on next tick, reads body for answers)
 │
 ▼
[x] (done)
```

(GFM only renders `- [ ]` and `- [x]` as actual checkboxes; `- [~]`,
`- [?]`, and `- [!]` render as literal text inside a list item. That's
fine — workers read the marker character, not the rendered output.)

**Discipline:**
- Newer items append to the relevant section; don't aggressively
  restructure (the user edits in parallel).
- Workers `- [?]`-flag mid-work if a question arises; they don't guess.
- Users resolve `- [?]` blockers by writing answers inline and flipping
  to `- [!]` (via `backlog unblock <N>` or hand-edit).
- The `Done` section is the audit trail — never silently delete `- [x]`
  entries.

Bootstrap skeleton lives in `~/.claude/CLAUDE.md` under "Workflow —
`docs/Backlog.md` drives work."

---

## Stage 2 — Implementation: two autonomous-worker modes

The user picks **one at a time**. They can't run together — both drain
`- [ ]` items and would race.

### Mode A — `/watch-backlog` (interactive, in-session)

A Claude Code slash command at `~/dotfiles/settings/claude/commands/watch-backlog.md`
that wraps a long-running `/loop` worker. Lives inside a single Claude
Code session. Per-iteration contract:

1. Re-read `docs/Backlog.md` fresh (never trust cached recollection)
2. Pick the first `- [ ]` or `- [!]` item from `Open` (idle if none)
3. Surface `- [?]` items in wake-up briefs
4. Snapshot the file for pre-commit conflict detection
5. Work the item (typecheck + tests green before declaring done)
6. Diff against snapshot — if the user touched the same item, skip commit
7. Move to `Done` with `- [x]` + one-paragraph summary
8. Commit (scoped `git add <files>`, never `-A`)

Wake mechanics: `Monitor` on `fswatch docs/Backlog.md` (primary) +
`ScheduleWakeup` 30 min heartbeat (fallback).

**When to use:** debugging, watching the loop work in real time,
short bursts of focused output.

**Cost:** context accumulates across iterations — same conversation
replays the entire growing context on every tick. Token cost per task
grows linearly with iteration count, total grows roughly quadratically.

### Mode B — `backlog run` (headless, fresh session per tick)

A bash driver at `~/dev/projects/active/backlog-infra/bin/backlog`. Spawns a fresh `claude -p`
invocation per tick to execute one iteration of the `/watch-backlog`
contract, then exits.

**When to use:** long-running, set-and-forget. The same contract as Mode
A, but each tick starts cold — no accumulated context, no replay cost.

**Cost:** per-task token cost is flat. Total cost is linear in tasks
completed. Much cheaper for long backlogs.

**Visibility tradeoff:** no live in-pane view of the work. Monitor via
the log + git activity (see "Monitoring" below).

Subcommands: `backlog run` (fswatch + heartbeat, default), `backlog watch`
(heartbeat only), `backlog tick` (single tick, exit), `backlog` (status:
open count, next item, last tick age), `backlog compact` (delegates to
`scripts/backlog-compact.mjs` if present). Mkdir-based lock at
`<project>/.claude/backlog.lock` prevents two driver instances racing on
the same project.

### Mode B as a launchd LaunchAgent

For true set-and-forget, package Mode B as a macOS LaunchAgent. The
`backlog` driver has a built-in installer:

```bash
cd <project-root>
backlog install-daemon
```

This templates a plist at
`~/Library/LaunchAgents/com.$USER.<project-basename>.backlog.plist`
(project basename comes from `git rev-parse --show-toplevel`) with:

- `Label = com.$USER.<project-basename>.backlog`
- `WorkingDirectory = <project-root>`
- `ProgramArguments = [/bin/bash, <absolute path to bin/backlog>, run]`
- `RunAtLoad = true`, `KeepAlive = true`, `ThrottleInterval = 60`
- Logs at `<project>/.claude/launchd-{stdout,stderr}.log`

Then it `launchctl bootstrap`s the plist. Starts immediately, restarts
on crash, auto-starts on every login.

Re-running `backlog install-daemon` boots out and replaces — use it
after the script's template changes or after moving the project. The
installer also defensively clears any stale `.claude/backlog.lock` from
a prior SIGKILL'd daemon so the new instance starts in a clean state.
`backlog uninstall-daemon` is the inverse (bootout + `rm` the plist +
clear the lockdir).

---

## Stage 3 — Eval / test (the gate)

**Single command: `npm run build`** chains everything that must pass
before code is shipped:

```
tsc --noEmit && eslint src/ && vitest run && vite build
```

Any failure blocks the autonomous worker from committing (and blocks the
release pipeline at step 5). This single chain is the canonical truth
about whether code is shippable.

Per-project variants are fine (different test runner, different bundler)
but the *shape* is the same: one command, all gates, fail-fast.

---

## Stage 4 — Preview (sanity check on real infra)

**`npm run deploy:preview`** — builds the current working tree and
deploys to a non-prod URL on the same CDN that serves prod. Dirty tree
allowed. No tag, no branch promotion.

The point: catch deployment-environment issues (build artifacts,
runtime-only failures, asset paths, CSP) without rolling back a real
release.

Per Cloudflare Pages: `wrangler pages deploy dist --branch=preview`.
Project's "production branch" setting is `release` (see Stage 5), so
any other `--branch` value lands at a preview URL.

For other CDNs / hosts, the pattern is: separate "preview" environment
that mirrors prod but is gated by a different URL/branch label.

---

## Stage 5 — Release (the gated promotion)

**`npm run release`** — single entry point for production. Aborts at
the first failing step; nothing touches origin or the CDN until the
local gate has passed.

10-step pipeline (`scripts/release.mjs`):

| # | Step | What |
|---|---|---|
| 1 | Clean tree | `git status --porcelain` empty |
| 2 | On main | refuse otherwise |
| 3 | In sync | not behind `origin/main` (ahead is fine) |
| 4 | Ancestry | `release` is an ancestor of `main` |
| 5 | Build | `SG_ENV=production npm run build` passes |
| 6 | Version | read from `dist/version.json` |
| 7 | Fast-forward | `git update-ref refs/heads/release <main-sha>` |
| 8 | Tag | annotated `release-<YYYYMMDD>-<HHMMSS>-<count>` |
| 9 | Push | `git push origin release refs/tags/release-<ts>` |
| 10 | Deploy | `wrangler pages deploy dist --branch=release` |

`--dry-run` runs steps 1–6 only.

**Failure handling:** if push (9) succeeds but deploy (10) fails, the
tag and branch are good — error message gives the exact wrangler retry
command. Never re-tag.

This script is currently per-project (hardcoded for Cloudflare Pages,
project name baked in). The *pattern* is reusable; extracting a generic
version is a follow-up when project #2 happens.

---

## The branching model — `main` ↔ `release`

Two long-lived branches:

- **`main`** — active development. All commits land here directly (no
  feature branches). CI lints + builds on push but never deploys.
- **`release`** — a moving pointer to **the commit currently live in
  production**. No commits of its own; only ever fast-forwarded by the
  release script. Every fast-forward paired with an annotated
  `release-*` tag at the same SHA.

**Invariant: `release` is always an ancestor of `main`.** The release
script's step 4 enforces this and refuses on divergence.

The CDN config knows: project's "production branch" setting is
`release`, so wrangler with `--branch=release` lands at the prod URL.
Any other branch label lands at a preview URL.

**Useful queries:**
- Pending promotion: `git log release..main --oneline`
- What's live: `git log -1 release` or latest `release-*` tag
- When was X deployed: `git tag --list 'release-*' --contains <sha>`

---

## Two-session coordination

The pattern assumes two Claude Code sessions running in parallel:

1. **Autonomous session** — `/watch-backlog` or the headless daemon.
   Drains `- [ ]` and `- [!]` items. Surfaces `- [?]` blockers.
2. **Interactive session** — the user types ad-hoc work directly; new
   ideas append to `docs/Backlog.md` for the autonomous to pick up later.

**Scoped `git add` discipline applies to both.** Never `git add -A` or
`git add .` — the other session is editing in parallel and `-A` will
sweep their unrelated edits into a commit whose message no longer
matches the diff.

Even scoped staging can sweep parallel edits if both sessions touch the
same file. The `/watch-backlog` contract has a snapshot/diff step
specifically for `docs/Backlog.md`; extending that check to other shared
files (notably `CLAUDE.md`) is a known sharp edge.

---

## Monitoring (when the worker is headless)

Three layers:

**Daemon health:**
```bash
launchctl print gui/$(id -u)/com.kashif.<slug>.backlog \
  | grep -E 'state|restart count|last exit'
```

**Live output:**
```bash
tail -f <project>/.claude/backlog.log
```
Look for unmatched `tick start` (work in flight) vs `tick done`.

**What shipped:** `git log --oneline -10` in the project.

Two CLIs cover everything else:

- **`backlog`** (at `~/dev/projects/active/backlog-infra/bin/backlog`) — single-project commands,
  always run from the project root. Subcommands:
  - `backlog` (default) — color-coded status: open count, next
    `- [ ]`/`- [!]` item, last tick age + label (fresh / idle / STALE).
  - `backlog run` / `backlog watch` / `backlog tick` — start the worker
    in its various modes (see Stage 2).
  - `backlog unblock` — list `- [?]` blocked items numbered. With `<N>`,
    flip the Nth item to `- [!]` (answered, ready to retry); with
    `--all`, flip every `- [?]` to `- [!]`. Write your inline answers
    first (e.g. `[user] in-memory is fine`); the worker reads the item
    body on next tick.
  - `backlog compact` — delegates to `scripts/backlog-compact.mjs` if
    present (a per-project housekeeping helper that collapses older
    `Done` entries).

- **`backlogs`** (at `~/dev/projects/active/backlog-infra/bin/backlogs`) — fleet view.
  Two layers in the default snapshot:
  - **Machine summary** — scans history JSONL files across every
    project, dedupes unique hostnames, and shows how many projects this
    machine has done non-zero work on. Separates "fleet" (projects) from
    "machines" (hosts) visually.
  - **Per-project table (cross-machine, per-host annotated)** — reads
    each repo's `.claude/backlog-status.json` +
    `.claude/backlog-history.jsonl` from `~/dev/projects/active/*`
    (and `~/dev/projects/*` as fallback). Every row shows the last
    host that did non-zero-token work on that project. Liveness
    state (`fresh` <30min / `idle` <2h / `STALE` ≥2h). Token
    columns sum across all hosts that pushed into the repo.

  Subcommands: `backlogs sync` (pull dotfiles, re-run `kash_setup.sh`,
  pull every active project, restart every backlog launchd daemon, then
  print the dashboard — replaces the old `agents-bootstrap`); `backlogs
  list` (installed daemons + their state).

  Dashboard flags: `--fetch` (`git fetch -q origin` per repo first),
  `--watch` (refresh every 10s), `--effort` (adds a log-size column),
  `--day` (rebuckets the rightmost window to today's calendar day
  instead of rolling 7d). Sync flags: `--no-pull` (skip pulls), 
  `--restart-only` (skip pulls + final dashboard). Requires `jq`.

- **`dev-projects`** (at `~/dev/projects/active/backlog-infra/bin/dev-projects`) — lifecycle
  for `~/dev/projects/active/`. Distinct concern from `backlog`/`backlogs`
  — manages git repos themselves, not their backlogs. Subcommands:
  `activate <url>` (clone + manifest + push), `archive <name>` (mv to
  `archived/` + manifest + push + stop daemon), `sync` (rescan
  filesystem, rewrite manifest, patch any launchd plist whose
  `WorkingDirectory` drifted, restart affected daemons), `status`
  (three-column read: on-disk / in-manifest / daemon), `list` (print
  manifest).

The per-project effort ledger is populated by `scripts/backlog-status.mjs`
— a per-project script invoked by `backlog run` after each `claude -p`
tick. See "Per-tick status reporting" below.

Convention: launchd labels are `com.kashif.<project>.backlog`, and the
helpers assume project repos live at `~/dev/projects/<project>`. If you
keep projects elsewhere, parameterize the helpers or symlink.

### Per-tick status reporting (cross-machine token accounting)

Each project that opts in ships `scripts/backlog-status.mjs`. After every
`claude -p` tick, `backlog run` invokes it with the item title, exit
code, mode, and pre-tick HEAD. The script:

1. Locates the newest transcript JSONL for the project's cwd under
   `~/.claude/projects/<encoded-cwd>/`, normalises usage (prefers a
   `type:"result"` event, falls back to summing assistant `usage`
   deduped by message id).
2. Writes `.claude/backlog-status.json` (overwrite — headline state) and
   appends one line to `.claude/backlog-history.jsonl` (per-tick ledger).
3. `git pull --rebase` (skipped if no upstream), then stages both
   files explicitly, commits with a `Claude-Effort:` trailer, and
   pushes with exponential backoff.

The commit trailer is grep-able:
```
git log --grep='Claude-Effort'
```

Cross-machine math: every host commits its own ticks under the same
`.claude/backlog-history.jsonl`; `backlogs --fetch` pulls each repo and
the JSONL replay sums tokens across all hosts. The `host` field on each
record is for context only.

For the BACKLOG-EFFORT account view, self-imposed budgets live in
`~/.claude/backlog-budgets.json`:
```json
{
  "label": "personal backlog-effort budget",
  "budgets": {
    "rolling_5h_tokens": 600000,
    "rolling_week_tokens": 5000000
  }
}
```
Missing → `backlogs` shows raw counts only (no bullet graph, no `%`).
These are **personal targets**, not Anthropic plan caps. Anthropic's
limits are message-based and use fixed-reset windows; the `backlogs`
dashboard uses tokens and rolling windows. Run `/usage` in Claude
Code for the authoritative plan view.

---

## Bootstrap checklist — adopting this in a new project

For a brand-new repo, `dev-projects new <name>` automates the
mechanical steps from `~/dotfiles/templates/dev-project/`: it scaffolds
`docs/Backlog.md` (step 1), drops in a starter `scripts/release.mjs`
with `CF_PROJECT` set to `<name>` (step 3), templates `.gitignore`
(step 8), copies `scripts/backlog-status.mjs` (step 8b), git-inits,
creates a private `kashnoorani/<name>` repo and pushes, then runs
`backlog install-daemon` (step 6). Steps 2, 4, 5, 7, and 9 still need
your eyes — the command prints a punch list when it finishes. Pass
`--no-gh` for a local-only scaffold or `--no-daemon` to skip the
LaunchAgent.

For an existing GitHub repo, `dev-projects activate <github-url>`
clones it into `active/` and adds it to the manifest; the checklist
below is what you do once you're inside the clone.

1. **`docs/Backlog.md`** at the repo root, using the skeleton from
   `~/.claude/CLAUDE.md` (Workflow section).

2. **`npm run build`** that chains your gates (typecheck + lint +
   tests + bundle) into one fail-fast command.

3. **Release pipeline** at `scripts/release.mjs`. Copy from an existing
   project as a starting point; adjust for:
   - CDN (Cloudflare Pages / Netlify / Vercel / etc.)
   - Project name in the deploy command
   - Production-branch label on the CDN

4. **Cloudflare/CDN configuration**: set the project's production
   branch to `release`.

5. **`npm` scripts** added to `package.json`:
   ```json
   {
     "build": "tsc --noEmit && eslint src/ && vitest run && vite build",
     "release": "node scripts/release.mjs",
     "deploy:preview": "npm run build && wrangler pages deploy dist --branch=preview --commit-dirty=true",
     "deploy": "npm run build && wrangler pages deploy dist --branch=release --commit-dirty=true"
   }
   ```
   (No need for a `backlog:loop` script — `backlog run` is on `$PATH`.)

6. **Install the launchd LaunchAgent** when ready to run autonomously:
   ```bash
   cd <project-root>
   backlog install-daemon
   ```
   Templates a plist at
   `~/Library/LaunchAgents/com.$USER.<project-basename>.backlog.plist`,
   bootstraps it, and points logs at `<repo>/.claude/`. Re-run to
   refresh after the template changes; `backlog uninstall-daemon` is
   the inverse.

7. **Project `CLAUDE.md`** — copy the "Backlog draining" and "Release
   workflow & branching model" sections from an existing project as
   starting points. Adjust per-project details.

8. **`.gitignore`** — add `.claude/backlog.log`, `.claude/backlog.lock`,
   `.claude/launchd-stdout.log`, `.claude/launchd-stderr.log`.

8b. **Per-tick status reporting (optional but recommended).** If you
    want cross-machine token accounting via `backlogs`:
    - Copy `scripts/backlog-status.mjs` from an existing project (it's
      project-agnostic; reads `process.cwd()` for the transcript
      lookup).
    - Confirm `.claude/backlog-status.json` and
      `.claude/backlog-history.jsonl` are *not* listed in `.gitignore` —
      they need to be committed. (The existing per-project `.gitignore`
      entries for `.claude/` are file-specific, so the two new artefacts
      are tracked by default.)
    - If this is your first project to adopt the hook, create
      `~/.claude/backlog-budgets.json` with your personal targets (see
      the Monitoring section above for the schema). Optional — without
      it the dashboard shows raw counts instead of bullet graphs.
    - `backlog run` auto-invokes the hook when
      `scripts/backlog-status.mjs` exists. Nothing else to wire up.

9. **Set up `release` branch** on first release. The script handles
    creation if it doesn't exist yet — just run `npm run release` once
    a real shippable commit exists.

---

## What's per-project vs shared

| Piece | Lives in | Reusable? |
|---|---|---|
| `/watch-backlog` skill | `~/dotfiles/settings/claude/commands/` | Shared — single file used across projects |
| `backlog` driver | `~/dev/projects/active/backlog-infra/bin/backlog` | Shared — operates on `$PWD`, project-agnostic |
| `backlogs` fleet view | `~/dev/projects/active/backlog-infra/bin/backlogs` | Shared — walks every repo |
| Backlog markers + section discipline | `~/.claude/CLAUDE.md` | Shared — global instructions |
| Two-session coordination rules | `~/.claude/CLAUDE.md` | Shared — global instructions |
| `docs/Backlog.md` | per-repo | Per-project (content) |
| `scripts/release.mjs` | per-repo | Per-project (CDN/name baked in); pattern reusable |
| launchd plist | `~/Library/LaunchAgents/com.$USER.<project>.backlog.plist` | Generated by `backlog install-daemon`; per-project paths/label, shared template in `bin/backlog` |
| `scripts/backlog-status.mjs` | per-repo | Shared shape — reads `process.cwd()`, copy verbatim |
| `npm run build` chain | per-`package.json` | Per-project (toolchain varies); shape reusable |
| Project `CLAUDE.md` | per-repo | Per-project (project-specific context) |

---

## Anti-patterns

- **Running both `/watch-backlog` and `backlog run` at once.**
  They race for the same `- [ ]` items. The mkdir lock only knows about
  other headless instances. Pick one.
- **`git add -A` or `git add .`.** Sweeps the parallel session's edits.
  Always stage by filename.
- **Editing `release` branch by hand or force-pushing it.** It's an
  audit trail. The release script is the only thing that touches it.
- **Skipping the build gate.** `npm run deploy` (without the gate) is
  an unsafe escape hatch for prod hotfixes only — `npm run release` is
  the default.
- **Long-running `/watch-backlog` for big backlogs.** Use `backlog run`.
  Quadratic context cost vs linear.
- **Auto-deciding `- [?]` blockers.** Workers must surface, not guess.
- **Documenting the workflow only in one project's `CLAUDE.md`.** It
  belongs here, in `~/dotfiles/WORKFLOW.md`. Per-project CLAUDE.md
  files reference this doc for the shared pattern and only document
  project-specific deltas.

---

## What's intentionally not in this pattern

- **CI-driven deploys.** Deploys are local (using personal `wrangler`
  auth). No GitHub secrets, no GitHub Action deploys. CI runs lint +
  build only.
- **Feature branches / PR review.** Solo workflow. All commits land
  directly on `main`.
- **Automatic releases.** `npm run release` is human-triggered. The
  autonomous worker never promotes to prod.
- **Cross-project orchestration.** Each project's daemon is
  independent; no scheduler coordinates them. The user picks which to
  run.

---

## Open follow-ups

- **Extract `scripts/release.mjs` to a generic shared script** once
  project #2 needs it. Likely takes a CDN-driver argument and a project
  name; the gate logic is identical.
  **Done 2026-05-27**: shared `bin/release.mjs` accepts `--project <name>`;
  per-project template is an 11-line wrapper delegating to it.
- **`CLAUDE.md` snapshot/diff for `/watch-backlog`** — extend the
  contract's pre-commit diff check beyond `docs/Backlog.md` to all
  user-edited shared files, to prevent the "loop swept my unrelated
  CLAUDE.md edit" failure mode.
  **Done 2026-05-27**: expanded snapshot to include `CLAUDE.md` +
  `.claude/settings.json`; fswatch filter also wakes on changes to
  those files.
