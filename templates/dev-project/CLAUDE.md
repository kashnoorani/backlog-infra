# __PROJECT_NAME__ — Claude Code context

(Edit this section: a sentence or two about what this project is and does.)

## Common commands

```bash
# (Edit this: commands for dev, build, test, deploy, etc.)
```

## Project layout

```
# (Edit this: key files and directories, what each is for.)
```

## Release workflow & branching model

Two long-lived branches, three workflows.

### Branches

- **`main`** — the active working branch. All commits land here directly (no
  feature branches). CI runs lint + build on every push but **does not deploy
  anything**. `main` represents "the latest code," not "what's live."
- **`release`** — a moving pointer to **the commit currently live in
  production**. Has no commits of its own; only ever fast-forwarded onto
  `main`'s HEAD by `npm run release` when the gate passes. Every
  fast-forward is paired with an annotated `release-<YYYYMMDD>-<HHMMSS>-<count>`
  tag at the same SHA. The tag list IS the production deploy history.

Invariant: **`release` is always an ancestor of `main`**. The release-script
gate enforces this. If they diverge, something hand-edited `release` or
force-pushed — reconcile by hand.

Cloudflare Pages knows: the project's "production branch" setting is
`release`, so `wrangler pages deploy --branch=release` lands at the prod
URL; any other branch label lands at a preview URL.

### Three workflows

| Goal | Command | What it touches |
|---|---|---|
| **Test locally** | project-specific dev/build commands | nothing |
| **Test on Cloudflare** (preview) | `npm run deploy:preview` | builds from working tree (dirty allowed); deploys to preview URL. No tag, no `release`-branch update. |
| **Deploy live to prod** | `npm run release` (or `-- --dry-run` to rehearse) | gates → fast-forwards `release` → tags → pushes → wrangler to prod URL. |

`npm run deploy` is an escape hatch for prod hotfixes (allows dirty tree,
skips `release`-branch update and tagging). Default to `npm run release`.

### What the release-script gate enforces

`scripts/release.mjs` delegates to the shared `bin/release.mjs` in
backlog-infra. Steps 1–5 run locally before anything touches origin:

1. Working tree clean
2. Currently on `main`
3. Local `main` is not behind `origin/main` (ahead is fine)
4. `release` is an ancestor of `main` (or doesn't exist yet)
5. `npm run build` passes (typecheck + lint + tests + bundle)

Then steps 6–10: fast-forward `release`, create tag, push, deploy.

### Useful queries

- **Pending promotion:** `git log release..main --oneline`
- **What's live:** `git log -1 release`
- **When was X deployed:** `git tag --list 'release-*' --contains <sha>`

## Backlog draining: two options

- **`/watch-backlog`** (interactive, in-session) — long-running `/loop` worker
  with live visibility, fswatch wake on `docs/Backlog.md` edits, 30-min
  heartbeat. Context grows over time → token cost per task rises.
- **`backlog-agent run`** (headless driver at
  `~/dev/projects/active/backlog-infra/bin/backlog-agent`) — spawns a fresh
  `claude -p` per tick. Cold context each tick, drains exactly one `- [ ]`
  item, exits. Cheaper for long backlogs (flat per-task cost, not quadratic).
  Subcommands: `backlog-agent tick` (single tick), `backlog-agent watch`
  (heartbeat-only).

Don't run both at once — they race for the same `- [ ]` items.

### Running as a launchd daemon

```bash
cd __PROJECT_NAME__
backlog-agent install-daemon       # installs + starts
backlog-agent uninstall-daemon     # stops + removes plist

# Monitor
tail -f .claude/backlog-agent.log
```

## How to work — edit safety & resilience

These are project-specific supplements to the global resilience rules in
`~/.claude/CLAUDE.md` (empty-read defense, edit-failure signal, contradiction
→ re-ground, verify before questions, verify before memory).

### Verify edits landed
After editing any source file, grep for a unique string you inserted to
confirm the edit actually landed. A silent "string not found" Edit failure
can cascade into a fabricated implementation that doesn't correspond to
reality.

### Re-read before touching shared / infrastructure code
If this project has shared infrastructure (build scripts, release pipeline,
backlog-agent hooks under `scripts/`), read the relevant files before editing
them. The release pipeline in particular is shared across projects via the
backlog-infra `bin/release.mjs` — don't duplicate its logic.

### Run the gate after every change set
`npm run build` (or equivalent) chains typecheck + lint + tests + bundle.
Any failure blocks the autonomous worker from committing and blocks the
release pipeline. It's the single truth about whether code is shippable.

### No memory without observed output
Never write a memory note (`.claude/memory/`) claiming a feature is built or
tests passed unless you have personally observed the confirming output.

## What NOT to do

<!--
  (Edit this: add project-specific footguns — patterns that have caused
  trouble in this project before, or invariants that must not be broken.
  Examples from other projects:

  - Don't add a new X without also updating Y.
  - Don't refactor Z into a package "for cleanliness."
  - Don't add CLI flags the user hasn't asked for.)
-->
