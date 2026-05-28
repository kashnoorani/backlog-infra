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
- [ ] Implement Layer 3: opt-in `~/.claude/agent-fallback.json`, OpenCode invocation, status-hook extension to log `agent=` in the trailer.
- [ ] Fully doc the architecture and design of our backlog-infra including nice diagrams.
- [ ] Migrate M3 daemon plists from symlink `backlog` paths to canonical `backlog-agent` paths. `do_install_daemon` should also boot out old `*.backlog.plist` and `*.backlog-loop.plist` label variants on install to avoid double-daemon, then run `backlog-agent install-daemon` in all 7 projects on M3.
- [ ] Web dashboard: mobile-responsive layout
- [ ] Item aging: surface items stuck `[~]` (in progress) too long in fleet view — compute how long each `[~]` item has been claimed without completion
- [ ] Notifications: send Slack or email alert when a daemon enters cooldown (plan-limit)

(see `docs/multi-agent-design.md` for full design)

## Open
(none)


## In progress
(none)

## Blocked
(none)

## Done
- [x] Implement Layer 2: plan-limit detection + cooldown file + short-circuit in `tick_once`. — Verified the signature against a real failure in `.claude/backlog.log` (the legacy driver's log; the current `.claude/backlog-agent.log` had no failures): Claude prints `You've hit your session limit · resets 5:30pm` and exits 1, producing the 4×-in-a-row ~1s fail-loop the design doc predicted. Implemented per `docs/multi-agent-design.md`: (1) `PLAN_LIMIT_REGEX` matching `hit your (session|usage|weekly) limit|usage limit reached`; (2) `start_cooldown` / `cooldown_active` / `cooldown_until_str` helpers writing `.claude/agent-cooldown.json` (`{until, until_epoch, reason, detected_at}`) with a fixed `COOLDOWN_SECONDS=3600` window — integer-epoch comparison so no jq dependency, and auto-removal of expired files; (3) a short-circuit at the top of `tick_once` that, while a cooldown is active, skips the `claude` invocation, heartbeats the status hook, and returns without claiming an item; (4) detection wired into the post-claude failure branch by tee-ing claude's output to a temp capture file (the pipeline stays direct so `${PIPESTATUS[0]}` still reports claude's exit rather than tee's) and grepping it; and (5) a `⏸ plan-limit cooldown until <ts>` line in `do_status` so the daemon reads as idling-on-purpose instead of STALE/failed. After the cooldown expires the daemon retries; if still limited the signature re-arms it, so it self-heals (hourly retry cadence). Verified with `bash -n` plus a standalone functional test of the regex (matches the real signature and the classic `usage limit reached` variant; rejects benign rate-limit / code-error lines) and the cooldown helpers (arm→active→valid JSON; expired→inactive+file removed; malformed→inactive, no crash under `set -e`). No automated test suite exists in this shell-script project.
- [x] Implement Layer 1: add `--fallback-model claude-haiku-4-5` to the `claude -p` call in `bin/backlog-agent`. (~5 lines, no new infra) — Added `--fallback-model claude-haiku-4-5` to the single `claude -p` invocation in `tick_once` (`bin/backlog-agent:449`), with a comment noting it absorbs transient Anthropic default-model overload but does not cover plan-limit exhaustion (haiku counts against the same plan — that's Layer 2's job). No new infra, no config, zero cost when not triggered. Verified with `bash -n` (no test suite exists in this shell-script project); confirmed there were no other `claude -p` call sites to update.
- [x] Investigate how to add multi-agent support such that if claude isn't available (due to usage limits), then our infra can switch over to opencode/deepseek or some such combo. — Wrote `docs/multi-agent-design.md`.
- [x] Parse exact reset time from plan-limit errors — `_parse_reset_to_epoch` extracts `resets 3:45pm`/`resets Mon 12:00am` from claude's output. `start_cooldown` now uses the exact epoch instead of `now+1h`. `parsed_from_reset` boolean in cooldown JSON.
- [x] Lazy daemon: escalating idle sleep — `tick_once` sets `TICK_OUTCOME` (work/idle/cooldown) at each exit. `do_run`/`do_watch` dispatch sleep per outcome: idle escalates 30s→60s→120s→300s→600s→1800s, cooldown sleeps exactly to parsed reset time, work resets to fast-start. fswatch still fires instantly.
- [x] Dashboard cooldown precision labels — `parsed_from_reset` field in API, TOKENS tab shows "precise" vs "~" countdowns, FLEET tab tooltip includes label.
- [x] Dashboard manual refresh button — ↻ button with spin animation on click, calls `refresh()` immediately.
- [x] CLI `backlog-agents` cooldown detail — ALERTS section shows remaining time (`47m left`) + `(precise)`/`(~estimated)` tag using `parsed_from_reset`.
- [x] Dashboard keyboard shortcuts — `1`-`7` for tabs, `?` for help overlay, `p` for auto-refresh toggle, `r` for refresh, `esc` to close.
- [x] Dashboard auto-refresh toggle — ⟳ button pause/resume 5-min polling, `p` key shortcut, subtitle updates to "paused".
