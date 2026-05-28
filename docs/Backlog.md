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
- [?] Migrate M3 daemon plists from symlink `backlog` paths to canonical `backlog-agent` paths. `do_install_daemon` should also boot out old `*.backlog.plist` and `*.backlog-loop.plist` label variants on install to avoid double-daemon, then run `backlog-agent install-daemon` in all 7 projects on M3.
  - blocked (needs M3): the code half is **done** — `do_install_daemon` now boots out and removes any `.backlog` / `.backlog-loop` old-label plists before bootstrapping the new `.backlog-agent` label, so a reinstall can't leave a double-daemon. Verified with `bash -n` on M1; the bootout path is a guarded no-op here because M1 already runs only `.backlog-agent` labels (no old plists to migrate). The remaining step — running `backlog-agent install-daemon` across the 7 M3 projects — must be executed **on M3**; this iteration ran on M1 (`Kash-MBA-M1-16GB`) and can't reach M3's launchd. Run it there, then mark `[x]`.
- [ ] Web dashboard: mobile-responsive layout
- [ ] Item aging: surface items stuck `[~]` (in progress) too long in fleet view — compute how long each `[~]` item has been claimed without completion
- [ ] Notifications: send Slack or email alert when a daemon enters cooldown (plan-limit)


