# Multi-agent fallback — investigation

**Question.** When Claude is unavailable (plan limits, API overload, auth
failure), how can the backlog daemon switch to an alternative coding
agent (OpenCode, Aider, etc., driving a model like DeepSeek) without
losing the iteration?

This doc is the investigation output. Implementation is deferred — the
design choices below are surfaced as follow-up `- [ ]` items rather
than wired up speculatively.

## Where the agent is invoked today

A single line in `bin/backlog` (line 370) drives every tick:

```bash
{ claude -p "$prompt" < /dev/null 2>&1 | tee -a "$LOG_FILE"; } \
  || claude_exit=${PIPESTATUS[0]}
```

`$prompt` is a self-contained instruction string: "re-read
docs/Backlog.md, pick first `[ ]`/`[!]` item, work it, commit." It
references the `/watch-backlog` slash command by name but the body is
the contract, so an alternative agent that can read files / edit /
run shell / commit can in principle execute it verbatim.

Auxiliary integration points worth knowing about:

- `bin/backlog-status.mjs` reads Claude's session transcript from
  `~/.claude/projects/<encoded-cwd>/*.jsonl` to compute token usage
  for the `Claude-Effort:` trailer. That path is Claude-specific.
- `auto memory` / skill ecosystem / `settings.json` hooks are
  Claude-Code-specific and have no direct equivalent in other agents.
- The prompt assumes git + Bash tools are available to the agent.

## What "Claude unavailable" actually means

Three failure modes, distinguishable in different ways:

1. **Plan-limit exhaustion.** The user has hit the rolling 5h or 7d
   cap of their Anthropic plan. `claude -p` exits non-zero and
   surfaces a "Usage limit reached" / plan-exceeded message. Not
   recoverable until the rolling window clears.
2. **API overload / model unavailability.** Anthropic-side capacity
   blip. Often recoverable in seconds-to-minutes. Claude Code
   already has a built-in mitigation: `--fallback-model <name>`.
3. **Auth / network failure.** OAuth token expired, no network, etc.
   Distinguishable by early exit code + characteristic stderr, but
   not by message body.

Detection is easiest by capturing `claude -p`'s stderr and pattern-
matching the plan-limit signature. We're already piping through
`tee -a "$LOG_FILE"`, so a post-tick grep on the captured output is
zero-effort.

The recent `backlog-status` commits (4× in quick succession, all
`exit=1, 1 turns, 0 tok`) are most likely *symptoms* of the same
problem: claude is exiting before the SDK even reports usage, which
matches what plan-limit rejection looks like. Worth verifying on the
next failure by `tail -50 .claude/backlog.log` while the failure is
fresh.

## Candidate alternative agents

| Agent      | Headless mode               | Tool calling | Provider neutrality      | Notes |
|------------|-----------------------------|--------------|--------------------------|-------|
| OpenCode   | `opencode run -p "<prompt>"`| Yes (rich)   | OpenAI / Anthropic / Google / OpenRouter / local | Closest spiritual sibling to Claude Code. MCP support landed. |
| Aider      | `aider --message "<prompt>"`| Yes (limited)| Same                     | Designed for diff-style edits; less agentic loop. Better for narrow tasks. |
| Goose      | `goose run -t "<prompt>"`   | Yes          | Same                     | Open source. Less mature than OpenCode for autonomous loops. |
| Continue   | n/a (IDE-bound)             | —            | —                        | Not headless-friendly; skip. |

**Picked:** OpenCode for the autonomy/loop fit. DeepSeek
(`deepseek/deepseek-coder` or `deepseek-r1` via OpenRouter, or direct
DeepSeek API) is the cheap model behind it.

**Friction to expect:**

- OpenCode does not implement `/watch-backlog` as a slash command — the
  prompt's reference to "the /watch-backlog contract" becomes a dead
  pointer. Fix: inline the contract in the prompt when invoking the
  fallback, instead of referring to it by name. The body of the
  contract is already 95% present in the existing `$prompt` string.
- `backlog-status.mjs` won't find a transcript at the Claude path;
  the `Claude-Effort:` trailer would just say `0 tok`. Acceptable for
  v1 — log "agent=opencode" in place of token count. Better long-term:
  parse OpenCode's own usage log if it exposes one.
- OpenCode's permission model is different. The headless daemon
  currently runs under `--dangerously-skip-permissions`-equivalent
  conditions (it's a launchd-driven daemon writing to its own repo);
  OpenCode would need `--yolo` or equivalent. Confirm before wiring.

## Proposed design — three layers

### Layer 1 (immediate, ~5 lines): model-level fallback

Add `--fallback-model claude-haiku-4-5` to the existing `claude -p`
invocation. Handles transient overload of the default model. No new
infra. Zero ongoing cost when not triggered.

```bash
claude -p --fallback-model claude-haiku-4-5 "$prompt"
```

This does **not** help with plan-limit exhaustion (haiku still counts
against the same plan), but it's a free win against transient
"Anthropic overloaded" failures, which are the most common
intermittent cause.

### Layer 2 (short follow-up): plan-limit detection + cooldown

After a non-zero `claude_exit`, grep the captured output for the
plan-limit signature. If matched, write `.claude/agent-cooldown.json`:

```json
{ "until": "2026-05-27T22:00:00Z", "reason": "anthropic-plan-limit" }
```

`tick_once` reads this at the top and short-circuits to a status-file
heartbeat if `until` is in the future. The user's rolling-window
budgets reset at predictable times (5h sliding window for the per-hour
cap, 7d for the weekly), so a conservative cooldown of "skip claude
ticks for the next hour" recovers naturally.

This alone (no alt-agent) stops the wasteful "fail in 1s, exit=1,
repeat every 5min" pattern we're seeing in the recent commits. It
makes the daemon idle gracefully instead of burning fail-loops.

### Layer 3 (opt-in): alternative-agent invocation

**[2026-05-29] IMPLEMENTED** — `bin/backlog-agent`: `fallback_agent_available`
/ `fallback_agent_name` / `build_fallback_cmd` helpers + `AGENT_FALLBACK_FILE`
config; the Layer 2 cooldown short-circuit in `tick_once` now falls THROUGH to
the normal claim+work path on the fallback agent when one is available (else
keeps heartbeat-only idle). Plan-limit cooldown re-arming is skipped on fallback
ticks. `backlog-agent-status.mjs` gained `--agent`; a non-claude agent writes
`Claude-Effort: agent=<name>, exit=N` (key kept for grep-based consumers).
Config supports an optional `name` field (defaults to basename of command[0]).
Requires `jq`; absent file / no jq / `available_when` non-zero / empty command
→ no fallback. Tested in `test/tick.bats` (+3) and `test/status-hook.bats` (+2).

Introduce a tiny config at `~/.claude/agent-fallback.json`:

```json
{
  "fallback": {
    "command": ["opencode", "run", "--model", "openrouter/deepseek/deepseek-chat", "--yolo", "{prompt}"],
    "available_when": "command -v opencode >/dev/null && [[ -n \"${OPENROUTER_API_KEY:-}\" ]]"
  }
}
```

When Layer 2 trips a cooldown, `tick_once` consults this config. If
the fallback agent is available, run the same `$prompt` through it
(substituting `{prompt}`). If not, fall back to Layer 2's idle
behavior.

Logging contract for the fallback agent's run:

- `.claude/backlog.log` tee unchanged (still captures stdout/err).
- `backlog-status.mjs` gets a new `--agent <name>` flag; when not
  `claude`, the token/turn fields are omitted from the trailer and
  the commit message becomes `Claude-Effort: agent=opencode, exit=N`
  (or refactor the trailer name to `Agent-Effort:`).

### What's NOT in this design

- **Mid-tick cutover.** If claude starts a tick, gets through the
  edit phase, then hits the limit during `commit`, we don't try to
  hand off the partial work to OpenCode. Too brittle. The whole
  tick re-runs on the next heartbeat.
- **Cross-agent state sharing.** Skill memory, auto-memory, plan
  files — none of that ports. The contract is the markdown backlog
  file + the git history. Both are agent-agnostic.
- **Quality parity.** DeepSeek-via-OpenCode is unlikely to match
  Opus 4.7 on harder tasks. The expectation is "make forward
  progress on simple items during the cooldown" — not "be as good."
  The user retains the option to leave the cooldown in place and
  drain the queue manually on the next session.

## Recommended sequencing

The three layers are independent. Ship Layer 1 first (one-line change,
captures the bulk of the common pain). Layer 2 next (genuine fix for
the fail-loop visible in the log). Layer 3 only if the user actually
has DeepSeek/OpenRouter credentials and wants ticks to proceed under
plan-limit pressure — otherwise Layer 2's "idle gracefully" is
sufficient.

## Follow-up backlog items

These should be appended to `docs/Backlog.md` if the user wants any of
this implemented:

- Implement Layer 1: add `--fallback-model claude-haiku-4-5` to the
  `claude -p` call in `bin/backlog:370`.
- Implement Layer 2: plan-limit detection + cooldown file +
  short-circuit in `tick_once`. Verify the plan-limit signature first
  by reading the next real `.claude/backlog.log` failure.
- Implement Layer 3: opt-in `~/.claude/agent-fallback.json`, OpenCode
  invocation, status-hook extension to log `agent=` in the trailer.
