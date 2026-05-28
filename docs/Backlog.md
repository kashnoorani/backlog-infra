# backlog-infra — Backlog

A running list of work to do. Mark items `- [x]` when done and move
them to the Done section, `- [ ]` when open, `- [~]` when in progress,
`- [?]` when blocked on a design decision the user needs to weigh in
on, and `- [!]` once you've written answers inline and want the worker
to retry. The autonomous worker (`backlog run`) picks `- [ ]` and `- [!]` items and skips `- [?]`; surface those
to the user when waking them.

Items parked in `## Thinking` are never picked by the daemon — move
them to `## Open` when ready for work.

## Thinking
(none)

(see `docs/multi-agent-design.md` for full design)

## Open
- [~] Implement Layer 3: opt-in `~/.claude/agent-fallback.json`, OpenCode invocation, status-hook extension to log `agent=` in the trailer.
- [?] Web dashboard: mobile-responsive layout
  - blocked (needs design decision): there is **no web dashboard** in this repo to make responsive. Every "dashboard" reference points to the terminal-based `backlog-agents` fleet CLI — no `.html`, no HTTP server, no web framework exists. "Mobile-responsive layout" presupposes an existing web UI. Before this can be worked: (1) should a web dashboard be built from scratch here, and if so what stack (static HTML reading `backlog-status.json`? a Worker? a Pages app?), where does it live, and how does it source fleet data; or (2) does the web dashboard live in a different repo I should be editing? Answer inline with `[user]` and `backlog unblock` to retry.

## Done
- [x] **Daemon broken: `_run_status_hook` is called but never defined** — function re-added at `bin/backlog-agent:586`, 3 call sites wired.
- [x] Notifications: send Slack or email alert when a daemon enters cooldown (plan-limit) — `_notify()` at `bin/backlog-agents:1164`, osascript + optional Slack webhook, rate-limited 1/5min.
- [x] Item aging: surface items stuck `[~]` (in progress) too long in fleet view — STUCK section in CLI (`backlog-agents:680`), `_itemAges` in CF API.
- [x] Migrate M3 daemon plists from old `.backlog`/`.backlog-loop` names to `.backlog-agent` — `migrate-daemons` subcommand handles this; M3 migrated successfully.
