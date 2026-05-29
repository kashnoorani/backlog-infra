#!/usr/bin/env bats
#
# Structured event log (W0) for bin/backlog-agent.
# Asserts the JSONL event stream (.claude/backlog-agent-events.jsonl) is emitted
# for the key tick lifecycle events and that every line is valid JSON.
# Hermetic scratch repo — see helpers.bash.

load 'helpers'

setup() { _setup_repo; }

EVENTS=".claude/backlog-agent-events.jsonl"

# Echo the `event` field of every line whose event matches $1 (one per match).
events_named() {
  grep -oE "\"event\":\"$1\"" "$WORK/$EVENTS" 2>/dev/null || true
}

# True if the event log has at least one line with event == $1.
has_event() { grep -qE "\"event\":\"$1\"" "$WORK/$EVENTS"; }

# Assert every line in the event log is valid JSON.
assert_valid_jsonl() {
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const lines = fs.readFileSync(f, "utf8").split("\n").filter(Boolean);
    if (lines.length === 0) { console.error("event log is empty"); process.exit(1); }
    for (const l of lines) JSON.parse(l);  // throws -> non-zero exit
    process.exit(0);
  ' "$WORK/$EVENTS"
}

# 1. Idle tick -> tick_start + tick_done(idle), valid JSON, no claim.
@test "idle tick emits tick_start and tick_done(idle)" {
  write_backlog_open   # empty ## Open
  run_tick
  [ "$status" -eq 0 ]
  [ -f "$WORK/$EVENTS" ]
  assert_valid_jsonl
  has_event tick_start
  grep -qE '"event":"tick_done".*"outcome":"idle"' "$WORK/$EVENTS"
  ! has_event claim
}

# 2. Successful tick -> claim, claude_exit(0), tick_done(work).
@test "successful tick emits claim, claude_exit, tick_done(work)" {
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  assert_valid_jsonl
  has_event claim
  grep -qE '"event":"claude_exit".*"exit_code":0' "$WORK/$EVENTS"
  grep -qE '"event":"tick_done".*"outcome":"work"' "$WORK/$EVENTS"
  has_event status_ok
}

# 3. Plan-limit failure -> cooldown_armed + non-zero claude_exit.
@test "plan-limit failure emits cooldown_armed and a failing claude_exit" {
  make_claude fail_limit
  run_tick
  assert_valid_jsonl
  has_event cooldown_armed
  grep -qE '"event":"claude_exit".*"exit_code":1' "$WORK/$EVENTS"
  grep -qE '"event":"cooldown_armed".*"reason":"anthropic-plan-limit"' "$WORK/$EVENTS"
}

# 4. Active cooldown -> tick_done(cooldown), claude never reached, no claim.
@test "active cooldown emits tick_done(cooldown)" {
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 3600 ))" > "$WORK/.claude/agent-cooldown.json"
  run_tick
  assert_valid_jsonl
  grep -qE '"event":"tick_done".*"outcome":"cooldown"' "$WORK/$EVENTS"
  ! has_event claim
}

# 5. Item titles with quotes/backslashes stay valid JSON (escaping works).
@test "event log stays valid JSON for titles with quotes and backslashes" {
  write_backlog_open '- [ ] handle "quoted" and C:\path\to weirdness'
  make_claude complete
  run_tick
  assert_valid_jsonl
  # The claim event carries the exact title, JSON-escaped.
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
    const claim = lines.find(e => e.event === "claim");
    if (!claim) { console.error("no claim event"); process.exit(1); }
    if (!claim.item.includes("\"quoted\"") || !claim.item.includes("C:\\path\\to")) {
      console.error("title not preserved: " + JSON.stringify(claim.item)); process.exit(1);
    }
  ' "$WORK/$EVENTS"
}

# 6. Every event line carries the common envelope fields.
@test "every event line has ts, event, project, host, pid" {
  make_claude complete
  run_tick
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map(JSON.parse);
    for (const e of lines) {
      for (const k of ["ts", "event", "project", "host", "pid"]) {
        if (!(k in e)) { console.error("missing " + k + " in " + JSON.stringify(e)); process.exit(1); }
      }
      if (typeof e.pid !== "number") { console.error("pid not numeric"); process.exit(1); }
    }
  ' "$WORK/$EVENTS"
}
