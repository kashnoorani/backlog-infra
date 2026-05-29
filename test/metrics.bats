#!/usr/bin/env bats
#
# `backlog-agents metrics` — efficiency metrics from the per-tick ledger (W2).
# Hermetic: BACKLOGS_PROJECTS_ROOTS points at a throwaway tree of fake projects,
# each carrying a hand-written .claude/backlog-history.jsonl. We assert exit 0
# and the exact derived numbers (ticks, completions, tokens/completion, success
# rate, retry rate) for both the text table and the --json object.
#
# A "completion" is APPROXIMATED as a tick with exit_code==0 AND a non-empty
# work_commit (the production approximation under test).

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# Append one history record. Usage: hist <file> <exit_code> <work_commit> <tokens>
# Pass work_commit as the literal "null" (unquoted) for a no-commit tick, or a
# SHA string (it gets JSON-quoted).
hist() {
  local file="$1" ec="$2" wc="$3" tok="$4"
  mkdir -p "$(dirname "$file")"
  local wc_json
  if [[ "$wc" == "null" ]]; then wc_json="null"; else wc_json="\"$wc\""; fi
  printf '{"ts":"2026-05-28T00:00:00Z","host":"h.local","mode":"loop","item":"x","exit_code":%s,"tokens":%s,"work_commit":%s}\n' \
    "$ec" "$tok" "$wc_json" >> "$file"
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$ROOT"
  export BACKLOGS_PROJECTS_ROOTS="$ROOT"

  # alpha: 4 ticks.
  #   t1 ok + commit + 100 tok   -> completion
  #   t2 ok + commit + 300 tok   -> completion
  #   t3 ok + no commit + 50 tok -> NOT a completion (no work_commit)
  #   t4 fail + commit + 10 tok  -> NOT a completion (exit!=0), not a success
  # ticks=4 completed=2 tokens=460 ok=3
  local A="$ROOT/alpha/.claude/backlog-history.jsonl"
  hist "$A" 0 c0ffee 100
  hist "$A" 0 deadbe 300
  hist "$A" 0 null 50
  hist "$A" 1 abc123 10

  # beta: 2 ticks, both ok + commit. ticks=2 completed=2 tokens=200 ok=2
  local B="$ROOT/beta/.claude/backlog-history.jsonl"
  hist "$B" 0 b00001 80
  hist "$B" 0 b00002 120

  # gamma: 1 tick, ok but no commit -> zero completions (divide-by-zero guard).
  # ticks=1 completed=0 tokens=70 ok=1
  local G="$ROOT/gamma/.claude/backlog-history.jsonl"
  hist "$G" 0 null 70

  # noproj: a dir with NO history file — must be skipped entirely.
  mkdir -p "$ROOT/noproj/.claude"
}

# fleet totals across alpha+beta+gamma:
#   ticks = 4+2+1 = 7
#   completed = 2+2+0 = 4
#   tokens = 460+200+70 = 730
#   ok = 3+2+1 = 6

@test "metrics exits 0 and prints a fleet row" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLEET"* ]]
}

@test "text output lists each project with history" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
  [[ "$output" == *"gamma"* ]]
}

@test "text output omits projects without a history file" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics
  [ "$status" -eq 0 ]
  [[ "$output" != *"noproj"* ]]
}

@test "text output footnotes the completion approximation" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPROXIMATED"* ]]
  [[ "$output" == *"work_commit"* ]]
}

@test "--json exits 0 and emits valid JSON with the note" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [[ "$(printf '%s' "$output" | jq -r '.note')" == *"APPROXIMATED"* ]]
}

@test "--json fleet totals are correct" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.fleet.ticks')" = "7" ]
  [ "$(printf '%s' "$output" | jq -r '.fleet.completed')" = "4" ]
  [ "$(printf '%s' "$output" | jq -r '.fleet.tokens')" = "730" ]
}

@test "--json fleet rates: success=6/7, retry=7/4, tok/done=730/4" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --json
  [ "$status" -eq 0 ]
  # success rate 6/7
  [ "$(printf '%s' "$output" | jq -r '.fleet.success_rate')" = "$(jq -n '6/7')" ]
  # retry rate 7/4
  [ "$(printf '%s' "$output" | jq -r '.fleet.retry_rate')" = "1.75" ]
  # tokens per completion 730/4
  [ "$(printf '%s' "$output" | jq -r '.fleet.tokens_per_completion')" = "182.5" ]
}

@test "--json per-project alpha numbers are correct" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --json
  [ "$status" -eq 0 ]
  local a; a="$(printf '%s' "$output" | jq -c '.projects[] | select(.project=="alpha")')"
  [ "$(printf '%s' "$a" | jq -r '.ticks')" = "4" ]
  [ "$(printf '%s' "$a" | jq -r '.completed')" = "2" ]
  [ "$(printf '%s' "$a" | jq -r '.tokens')" = "460" ]
  [ "$(printf '%s' "$a" | jq -r '.tokens_per_completion')" = "230" ]
  [ "$(printf '%s' "$a" | jq -r '.success_rate')" = "0.75" ]
  [ "$(printf '%s' "$a" | jq -r '.retry_rate')" = "2" ]
}

@test "--json gamma has zero completions and null rates (no divide-by-zero)" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --json
  [ "$status" -eq 0 ]
  local g; g="$(printf '%s' "$output" | jq -c '.projects[] | select(.project=="gamma")')"
  [ "$(printf '%s' "$g" | jq -r '.completed')" = "0" ]
  [ "$(printf '%s' "$g" | jq -r '.tokens_per_completion')" = "null" ]
  [ "$(printf '%s' "$g" | jq -r '.retry_rate')" = "null" ]
  [ "$(printf '%s' "$g" | jq -r '.success_rate')" = "1" ]
}

@test "unknown flag is rejected with exit 2" {
  run env BACKLOGS_PROJECTS_ROOTS="$ROOT" bash "$AGENTS_BIN" metrics --bogus
  [ "$status" -eq 2 ]
}

@test "empty roots: exit 0 with a no-history message" {
  local EMPTY="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$EMPTY"
  run env BACKLOGS_PROJECTS_ROOTS="$EMPTY" bash "$AGENTS_BIN" metrics
  [ "$status" -eq 0 ]
  [[ "$output" == *"No project history"* ]]
}
