# backlog-infra — Backlog

A running list of work to do. Mark items `- [x]` when done and move
them to the Done section, `- [ ]` when open, `- [~]` when in progress,
`- [?]` when blocked on a design decision the user needs to weigh in
on, and `- [!]` once you've written answers inline and want the worker
to retry. The autonomous worker (see `/watch-backlog` or `backlog-agent
run`) picks `- [ ]` and `- [!]` items and skips `- [?]`; surface those
to the user when waking them.

Items parked in `## Thinking` are never picked by the daemon — move
them to `## Open` when ready for work.

## Thinking
- [ ] Implement Layer 3: opt-in `~/.claude/agent-fallback.json`, OpenCode invocation, status-hook extension to log `agent=` in the trailer.

(see `docs/multi-agent-design.md` for full design)

## Open
- [ ] Fully doc the architecture and design of our backlog-infra including nice diagrams. Explain the thought process behind key decisions and factors considered and why we decided the way we did.
- [~] Migrate M3 daemon plists from symlink `backlog` paths to canonical `backlog-agent` paths. `do_install_daemon` should also boot out old `*.backlog.plist` and `*.backlog-loop.plist` label variants on install to avoid double-daemon, then run `backlog-agent install-daemon` in all 7 projects on M3.
- [ ] Web dashboard: mobile-responsive layout
- [ ] Item aging: surface items stuck `[~]` (in progress) too long in fleet view — compute how long each `[~]` item has been claimed without completion
- [ ] Notifications: send Whatsapp alert when a daemon enters cooldown (plan-limit) so the user knows which project paused and for how long
(none)


