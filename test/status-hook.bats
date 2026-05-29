#!/usr/bin/env bats
#
# Tests for bin/backlog-agent-status.mjs — the per-tick status hook.
# This is where the 2026-05-28 incident lived (unconditional
# `git add COOLDOWN_FILE` aborted every status commit fleet-wide for ~8h).

load 'helpers'

setup() { _setup_status_repo; }

# Writes all three artifacts with valid JSON / JSONL.
@test "writes status, per-host, and history artifacts" {
  run_hook
  [ "$status" -eq 0 ]
  [ -f "$WORK/.claude/backlog-status.json" ]
  node -e 'JSON.parse(require("fs").readFileSync(".claude/backlog-status.json"))'
  ls "$WORK"/.claude/backlog-status-*.json >/dev/null
  [ -f "$WORK/.claude/backlog-history.jsonl" ]
  node -e 'process.argv[1].trim().split("\n").forEach(l=>JSON.parse(l))' \
    "$(cat "$WORK"/.claude/backlog-history.jsonl)"
}

# The 2026-05-28 regression: with NO cooldown file present, the hook must not
# abort (it used to `git add` a non-existent agent-cooldown.json → exit 128).
@test "absent cooldown file does not abort the hook" {
  [ ! -f "$WORK/.claude/agent-cooldown.json" ]
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not match any files"* ]]
}

# A present cooldown file is staged without error.
@test "present cooldown file is staged cleanly" {
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 3600 ))" > "$WORK/.claude/agent-cooldown.json"
  run_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not match any files"* ]]
}

# Each invocation appends exactly one line to the history ledger.
@test "history ledger grows by one line per invocation" {
  run_hook
  run_hook
  [ "$(grep -c . "$WORK/.claude/backlog-history.jsonl")" -eq 2 ]
}

# REGRESSION GUARD for the untrack interaction: now that the SHARED
# backlog-status.json is gitignored, the hook must STILL commit the per-host
# file + history (they are tracked). It must not treat "the shared file is
# ignored" as "everything is ignored, skip the commit".
@test "still commits per-host + history when only shared status.json is gitignored" {
  local head_before; head_before="$(git -C "$WORK" rev-parse HEAD)"
  run_hook
  [ "$status" -eq 0 ]
  local head_after; head_after="$(git -C "$WORK" rev-parse HEAD)"
  [ "$head_before" != "$head_after" ]                       # a commit landed
  git -C "$WORK" show --stat HEAD | grep -q "backlog-history.jsonl"
  [[ "$output" != *"skipping commit"* ]]
}
