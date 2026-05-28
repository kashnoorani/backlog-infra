# backlog-infra — Backlog

A running list of work to do. Mark items `- [x]` when done and move
them to the Done section, `- [ ]` when open, `- [~]` when in progress,
`- [?]` when blocked on a design decision the user needs to weigh in
on, and `- [!]` once you've written answers inline and want the worker
to retry. The autonomous worker (see `/watch-backlog` or `backlog
run`) picks `- [ ]` and `- [!]` items and skips `- [?]`; surface those
to the user when waking them.

Items parked in `## Thinking` are never picked by the daemon — move
them to `## Open` when ready for work.

## Thinking
(none)

## Open
(none)


## In progress
(none)

## Blocked
(none)

## Done
- [x] Investigate how to add multi-agent support such that if claude isn't available (due to usage limits), then our infra can switch over to opencode/deepseek or some such combo. — Wrote `docs/multi-agent-design.md`. The agent invocation is a single line (`bin/backlog:370`, `claude -p "$prompt"`), so failover is feasible. Proposes a three-layer design: (1) add `--fallback-model claude-haiku-4-5` to absorb transient Anthropic overload (~5 lines, no infra); (2) detect the plan-limit signature in stderr, write `.claude/agent-cooldown.json`, and short-circuit `tick_once` until the rolling window clears — this alone fixes the fail-loop visible in the recent backlog-status commits where ticks die in 1s with exit=1; (3) opt-in alternative agent via `~/.claude/agent-fallback.json` invoking OpenCode against DeepSeek (via OpenRouter), reusing the existing `$prompt` verbatim and extending `backlog-status.mjs` to log `agent=<name>` instead of token counts. Layers are independent and can ship in order. Doc includes friction list (OpenCode lacks slash commands, different permission model, no Claude transcript) and the items NOT in scope (mid-tick cutover, cross-agent state sharing, quality parity). Three follow-up implementation items are spelled out at the bottom of the design doc — not auto-appended here so the user can pick which (if any) to queue.
