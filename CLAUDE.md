# Context for Claude

backlog-infra — the autonomous backlog daemon system powering all projects
under `~/dev/projects/active/`. Single source of truth for the backlog
workflow, fleet management, project templates, and release pipeline.

## Project layout

- `bin/` — all CLI tools (shell scripts and Node.js)
  - `backlog-agent` — per-project daemon driver (install, run, tick, watch)
  - `backlog-agent-status.mjs` — status hook called after each tick
  - `backlog-agents` — fleet overview CLI
  - `dev-projects` — project lifecycle (activate, archive, sync, daemons)
  - `backlog-agent-compact.mjs` — archive Done items
  - `release.mjs` — 10-step Cloudflare Pages deployment
- `templates/dev-project/` — scaffolding for new projects under the workflow
- `WORKFLOW.md` — canonical write-up of the reusable agentic-coding pattern
- `docs/Backlog.md` — this project's own backlog

## Key conventions

- **Working directory**: tools use `process.cwd()` or are `cd`'d by the
  `backlog-agent` driver before invoking hooks. Always run from the relevant
  project root.
- **PATH**: `~/dev/projects/active/backlog-infra/bin` must be on PATH.
  `~/dotfiles/settings/osx/.zprofile` handles this.
- **Templates**: `__PROJECT_NAME__` is the placeholder for new projects.
  `backlog-agent-status.mjs` and `release.mjs` wrappers in the template delegate
  to the shared copies in `bin/`.
- **Locking & coordination**: `docs/cross-machine-locking.md` explains the two
  separate lock layers (local process exclusion vs. git-push work-item claim),
  the full tick lifecycle, cross-machine race handling, and all failure-mode
  recovery paths. Read before touching `acquire_lock`, the claim block, or any
  tick_once sync logic.

## Anti-hallucination anchors

`bin/backlog-agent` is a ~3528-line bash script. **Before proposing
structural changes to any file under `bin/`, read it in full.**

### The real driver structure
The entire driver is built around a single function: `tick_once`.
The following do NOT exist and must never be invented:
- CLI flags: `--once`, `--max-iterations`, `--inject-fault`
- Functions: `plan_item`, `apply_item`, `run_iteration`, `retry()`

### Read the locking doc before touching sync logic
`docs/cross-machine-locking.md` explains the claim CAS block
(`acquire_lock`), the full tick lifecycle, and all failure-mode
recovery paths. Read it before editing any lock, claim, or push logic.

### Verify edits landed
After editing `bin/backlog-agent` or other `bin/` scripts, grep for
a unique string you inserted to confirm the edit actually landed.
An Edit that silently fails ("string not found") in a file this large
can cascade into a completely fabricated implementation.

### No memory without observed output
Never write a memory note (`.claude/memory/`) claiming a feature
is built or a test suite passed unless you have personally observed
the confirming tool output. `bats` is not on PATH by default — a
test file alone doesn't mean tests ran.
