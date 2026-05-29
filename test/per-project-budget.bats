#!/usr/bin/env bats
#
# Per-project budget enforcement (W2, docs/per-project-budget.md) — a pause-primitive
# consumer at scope=project. A self-imposed *spend* cap, distinct from the account
# plan-limit cooldown (Anthropic's hard cap): if THIS project's own rolling token
# spend exceeds a per-project cap in ~/.claude/backlog-budgets.json, its daemon
# pauses to heartbeat-only (and alerts ONCE), then resumes on its own as the
# rolling window drains back under the cap.
#
# The signal is LOCAL + per-project: a plain sum of the project's own
# `.claude/backlog-history.jsonl` `tokens` over the window. The ledger is
# git-tracked, so the sum already spans every host (= project-total spend). Both
# the rolling-5h and rolling-week windows enforce. backlog-infra's OWN daemon is
# EXEMPT (freeze_exempt). Honors the Layer-3 fallback (a budget cap is on Anthropic
# spend, so a non-Claude fallback may still drive the tick). FAIL-OPEN: any
# missing/unreadable input (no budgets file / no project entry / unreadable ledger)
# ⇒ no enforcement.
#
# Hermetic: no network needed (FREEZE_DISABLE / ACCOUNT_COOLDOWN_DISABLE default to
# 1 in helpers, so no D1 reads). The budgets file lives under the scratch $HOME and
# the ledger under the work repo; BUDGET_DISABLE=0 enables enforcement per test.

load 'helpers'

# Append one ledger row: $1 = seconds-ago, $2 = tokens, $3 = host (default M1).
# macOS `date -u -r <epoch>` (the suite is darwin-only, like the other fixtures).
_ledger_row() {
  local ago="$1" tok="$2" host="${3:-M1}" ts
  ts="$(date -u -r "$(( $(date +%s) - ago ))" '+%Y-%m-%dT%H:%M:%S.000Z')"
  printf '{"ts":"%s","host":"%s","tokens":%s}\n' "$ts" "$host" "$tok" \
    >> "$WORK/.claude/backlog-history.jsonl"
}

# Write the budgets file under the scratch $HOME (the driver's default
# BUDGETS_FILE). $1 = the JSON value for the `projects` map.
_seed_budgets() {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/backlog-budgets.json" <<EOF
{ "budgets": { "rolling_5h_tokens": 3000000, "rolling_week_tokens": 30000000 },
  "projects": $1 }
EOF
}

# Count budget_alert events in the work repo's event log (fires once per breach).
_alert_count() {
  grep -c '"event":"budget_alert"' "$WORK/.claude/backlog-agent-events.jsonl" 2>/dev/null || echo 0
}

# ==========================================================================
# Enforcement (over cap -> heartbeat-only)
# ==========================================================================

# 1. Over the rolling-5h cap -> heartbeat-only, claude NOT called, state recorded.
@test "driver: project over its 5h cap pauses to heartbeat-only (no claude)" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":100000}}'
  _ledger_row 600  60000 M1
  _ledger_row 1200 60000 M1          # 120k in the last 5h > 100k cap
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget cap exceeded"* ]]
  [[ "$output" == *"heartbeat only"* ]]
  ! claude_was_called
  [ -f "$WORK/.claude/backlog-agent-budget.json" ]
}

# 2. The SECOND window enforces too: under 5h but over the rolling-week cap.
@test "driver: project over its week cap pauses (5h under cap)" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":10000000,"rolling_week_tokens":500000}}'
  _ledger_row 600            50000 M1   # within 5h (50k < 10M)
  _ledger_row "$((6*3600))" 600000 M1   # 6h ago: outside 5h, inside 7d -> week=650k > 500k
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget cap exceeded"* ]]
  [[ "$output" == *"week"* ]]
  ! claude_was_called
}

# 3. The 5h sum spans hosts (decision #2: project-total, not per-machine).
@test "driver: 5h cap sums across hosts (project-total)" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":100000}}'
  _ledger_row 600 60000 Kash-MBA-M1-16GB
  _ledger_row 600 60000 Kash-MBA-M3-8GB   # 120k across two hosts > 100k
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget cap exceeded"* ]]
  ! claude_was_called
}

# ==========================================================================
# Pass-through (under cap, exempt, fail-open)
# ==========================================================================

# 4. Under cap -> the tick proceeds to claim + work as normal.
@test "driver: project under cap proceeds to work" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":1000000,"rolling_week_tokens":10000000}}'
  _ledger_row 600 50000 M1
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# 5. The freeze-exempt project (infra) never budget-pauses, even way over cap.
@test "driver: the freeze-exempt project is exempt from the budget pause" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":100000}}'
  _ledger_row 600 500000 M1
  make_claude complete
  run_tick FREEZE_PROJECT=work          # make the test project the exempt one
  [ "$status" -eq 0 ]
  claude_was_called
}

# 6. Fail-open: no budgets file at all -> no enforcement (today's behaviour).
@test "driver: fail-open when there is no budgets file" {
  _setup_repo
  export BUDGET_DISABLE=0
  _ledger_row 600 999999 M1
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# 7. Fail-open: budgets file present but this project has no entry -> uncapped.
@test "driver: fail-open when the project has no cap entry" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"someother":{"rolling_5h_tokens":1}}'
  _ledger_row 600 999999 M1
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# 8. The disable flag (helpers default = 1) skips enforcement entirely: proves
#    ordinary tick tests never read the budgets file / ledger.
@test "driver: BUDGET_DISABLE=1 skips enforcement" {
  _setup_repo
  # leave BUDGET_DISABLE=1 (helpers default)
  _seed_budgets '{"work":{"rolling_5h_tokens":1}}'
  _ledger_row 600 999999 M1
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# ==========================================================================
# Layer-3 fallback + alert-once
# ==========================================================================

# 9. Over cap WITH a fallback agent available -> runs via the fallback (a budget
#    cap is on Anthropic spend; a non-Claude provider isn't capped), NOT idle.
@test "driver: over-cap runs the fallback agent when one is available" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":100000}}'
  _ledger_row 600 200000 M1
  make_fallback_agent fakeagent
  write_fallback_config fakeagent true
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called          # the Anthropic path stays capped
  fallback_was_called          # but the fallback drove the tick
  [[ "$output" == *"via fallback agent"* ]]
}

# 10. Alert fires ONCE per breach, throttles while it persists, and re-alerts
#     after the project drains under cap and breaches again.
@test "driver: budget alert fires once, throttles, then re-alerts after resume" {
  _setup_repo
  export BUDGET_DISABLE=0
  _seed_budgets '{"work":{"rolling_5h_tokens":100000}}'
  _ledger_row 600 200000 M1
  # tick 1: over cap -> alert fires once
  run_tick
  [ "$status" -eq 0 ]
  [ "$(_alert_count)" -eq 1 ]
  # tick 2: still over cap -> throttled (no new alert)
  run_tick
  [ "$(_alert_count)" -eq 1 ]
  # drain under cap -> next tick clears the alert-once state + proceeds
  : > "$WORK/.claude/backlog-history.jsonl"
  make_claude complete
  run_tick
  [ ! -f "$WORK/.claude/backlog-agent-budget.json" ]
  claude_was_called
  # breach again -> re-alerts (count -> 2)
  _ledger_row 600 200000 M1
  run_tick
  [ "$(_alert_count)" -eq 2 ]
}
