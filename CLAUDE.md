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
