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
(none)


## In progress
(none)

## Blocked
(none)

## Done
- [x] Implement Layer 2: plan-limit detection + cooldown file + short-circuit in `tick_once`. — Verified the signature against a real failure in `.claude/backlog.log` (the legacy driver's log; the current `.claude/backlog-agent.log` had no failures): Claude prints `You've hit your session limit · resets 5:30pm` and exits 1, producing the 4×-in-a-row ~1s fail-loop the design doc predicted. Implemented per `docs/multi-agent-design.md`: (1) `PLAN_LIMIT_REGEX` matching `hit your (session|usage|weekly) limit|usage limit reached`; (2) `start_cooldown` / `cooldown_active` / `cooldown_until_str` helpers writing `.claude/agent-cooldown.json` (`{until, until_epoch, reason, detected_at}`) with a fixed `COOLDOWN_SECONDS=3600` window — integer-epoch comparison so no jq dependency, and auto-removal of expired files; (3) a short-circuit at the top of `tick_once` that, while a cooldown is active, skips the `claude` invocation, heartbeats the status hook, and returns without claiming an item; (4) detection wired into the post-claude failure branch by tee-ing claude's output to a temp capture file (the pipeline stays direct so `${PIPESTATUS[0]}` still reports claude's exit rather than tee's) and grepping it; and (5) a `⏸ plan-limit cooldown until <ts>` line in `do_status` so the daemon reads as idling-on-purpose instead of STALE/failed. After the cooldown expires the daemon retries; if still limited the signature re-arms it, so it self-heals (hourly retry cadence). Verified with `bash -n` plus a standalone functional test of the regex (matches the real signature and the classic `usage limit reached` variant; rejects benign rate-limit / code-error lines) and the cooldown helpers (arm→active→valid JSON; expired→inactive+file removed; malformed→inactive, no crash under `set -e`). No automated test suite exists in this shell-script project.
- [x] Implement Layer 1: add `--fallback-model claude-haiku-4-5` to the `claude -p` call in `bin/backlog-agent`. (~5 lines, no new infra) — Added `--fallback-model claude-haiku-4-5` to the single `claude -p` invocation in `tick_once` (`bin/backlog-agent:449`), with a comment noting it absorbs transient Anthropic default-model overload but does not cover plan-limit exhaustion (haiku counts against the same plan — that's Layer 2's job). No new infra, no config, zero cost when not triggered. Verified with `bash -n` (no test suite exists in this shell-script project); confirmed there were no other `claude -p` call sites to update.
- [x] Investigate how to add multi-agent support such that if claude isn't available (due to usage limits), then our infra can switch over to opencode/deepseek or some such combo. — Wrote `docs/multi-agent-design.md`. The agent invocation is a single line (`bin/backlog-agent:370`, `claude -p "$prompt"`), so failover is feasible. Proposes a three-layer design: (1) add `--fallback-model claude-haiku-4-5` to absorb transient Anthropic overload (~5 lines, no infra); (2) detect the plan-limit signature in stderr, write `.claude/agent-cooldown.json`, and short-circuit `tick_once` until the rolling window clears — this alone fixes the fail-loop visible in the recent backlog-status commits where ticks die in 1s with exit=1; (3) opt-in alternative agent via `~/.claude/agent-fallback.json` invoking OpenCode against DeepSeek (via OpenRouter), reusing the existing `$prompt` verbatim and extending `backlog-status.mjs` to log `agent=<name>` instead of token counts. Layers are independent and can ship in order. Doc includes friction list (OpenCode lacks slash commands, different permission model, no Claude transcript) and the items NOT in scope (mid-tick cutover, cross-agent state sharing, quality parity). Three follow-up implementation items are spelled out at the bottom of the design doc — not auto-appended here so the user can pick which (if any) to queue.
