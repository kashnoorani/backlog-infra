#!/usr/bin/env bats
#
# Per-item token/turn/spend ceiling (W2, docs/per-item-ceiling.md) — the
# finest-grained pause-primitive consumer (scope=ITEM). A single hard item can
# spiral (many turns, huge spend) WITHIN one tick, below the per-project budget's
# rolling-window radar. Two layers:
#   * PREVENTIVE: when a per-item USD cap is set, the driver passes claude
#     `--max-budget-usd` so it self-stops before overspending (this CLI has no
#     --max-turns flag, so the native preventive cap is the dollar one).
#   * POST-HOC: after the tick, the driver reads THIS session's actual turns +
#     tokens from claude's newest transcript and, if over the ceiling on an
#     INCOMPLETE item, reopens it ([~]→[ ]) with an inline note + failcount_bump
#     (composing with the Guard-1 circuit breaker). A COMPLETED item that ran hot
#     is logged, not reopened. Keep any commit. FAIL-OPEN on unreadable usage.
#
# Hermetic: the transcript is seeded under the scratch $HOME at the path the driver
# derives from $PWD (cwd with '/'→'-'); the ceilings file lives in the work repo's
# .claude/. CEILING_DISABLE=0 (set per test) enables enforcement; helpers default
# it to 1 so ordinary tick tests are inert.

load 'helpers'

# Seed claude's newest session transcript for the work repo with a `result` row
# carrying the given num_turns + token usage. Headline tokens are
# input+output+cache_creation, so placing the whole amount in input_tokens makes
# the headline == $2. $1 = num_turns, $2 = headline tokens.
_seed_transcript() {
  local turns="$1" tokens="$2"
  local dir="$HOME/.claude/projects/$(printf '%s' "$WORK" | tr '/' '-')"
  mkdir -p "$dir"
  printf '{"type":"result","num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}\n' \
    "$turns" "$tokens" > "$dir/session.jsonl"
}

# Write the per-project ceilings config into the work repo's .claude/.
_seed_ceilings() { cat > "$WORK/.claude/backlog-ceilings.json"; }

# Count item_ceiling events with a given reopened flag in the work repo's log.
#   $1 = "true" | "false"
_ceiling_event_count() {
  local n
  n=$(grep -c "\"event\":\"item_ceiling\".*\"reopened\":$1" \
    "$WORK/.claude/backlog-agent-events.jsonl" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

# The recorded consecutive-failure count for the item (0 if no file/key).
_failcount() {
  node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=o["do the thing"];const c=(v&&typeof v==="object")?(v.count||0):(v||0);process.stdout.write(String(c));}catch{process.stdout.write("0");}' \
    "$WORK/.claude/backlog-agent-failcounts.json" 2>/dev/null || echo 0
}

# ==========================================================================
# Post-hoc enforcement — INCOMPLETE item over the ceiling -> reopen + bump
# ==========================================================================

# 1. Over the TOKEN ceiling on an incomplete tick -> reopen [~]→[ ] + note + bump.
@test "ceiling: incomplete item over token cap is reopened with a note + bumps failcount" {
  _setup_repo
  make_claude noop                      # claims [~], changes nothing -> stays [~]
  _seed_transcript 3 500000             # 500k tokens this tick
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=400000
  [ "$status" -eq 0 ]
  # Item reopened back to [ ] (no longer claimed [~]).
  open_has_marker ' '
  ! open_has_marker '~'
  # Inline ceiling note appended; owner stamp stripped.
  grep -qE '^\- \[ \] do the thing <!-- ceiling: tokens 500000/400000 -->$' \
    <(sed -n '/^## Open/,/^## [A-Z]/p' "$WORK/docs/Backlog.md")
  # Failcount bumped (feeds the Guard-1 breaker) + a reopened event logged.
  [ "$(_failcount)" -eq 1 ]
  [ "$(_ceiling_event_count true)" -ge 1 ]
}

# 2. Over the TURN ceiling (>= the cap, since --max-budget-usd self-stops AT it).
@test "ceiling: incomplete item at/over the turn cap is reopened + bumped" {
  _setup_repo
  make_claude noop
  _seed_transcript 30 1000              # 30 turns == cap; tokens tiny
  run_tick CEILING_DISABLE=0 MAX_TURNS_PER_TICK=30
  [ "$status" -eq 0 ]
  open_has_marker ' '
  ! open_has_marker '~'
  grep -q 'turns 30/30' "$WORK/docs/Backlog.md"
  [ "$(_failcount)" -eq 1 ]
}

# ==========================================================================
# COMPLETED item that ran hot -> logged, NOT reopened (no re-spend)
# ==========================================================================

# 3. A tick that COMPLETED ([x]) but exceeded the ceiling is flagged, not reopened.
@test "ceiling: completed item over cap is logged but NOT reopened" {
  _setup_repo
  make_claude complete                  # flips [~]→[x] + commits work
  _seed_transcript 3 999999
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=400000
  [ "$status" -eq 0 ]
  # Stays done — completion is the natural stop; reopening would re-spend.
  open_has_marker 'x'
  ! open_has_marker ' '
  # Logged as a non-reopening breach; no failcount bump on a completed item.
  [ "$(_ceiling_event_count false)" -ge 1 ]
  [ "$(_ceiling_event_count true)" -eq 0 ]
  [ "$(_failcount)" -eq 0 ]
}

# ==========================================================================
# Under cap / opt-out paths — no enforcement
# ==========================================================================

# 4. Under both ceilings -> normal incomplete tick, item stays claimed, no event.
@test "ceiling: usage under the cap does not reopen" {
  _setup_repo
  make_claude noop
  _seed_transcript 3 100000
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=400000 MAX_TURNS_PER_TICK=30
  [ "$status" -eq 0 ]
  open_has_marker '~'                   # still claimed, not reopened
  [ "$(_ceiling_event_count true)" -eq 0 ]
  [ "$(_ceiling_event_count false)" -eq 0 ]
  [ "$(_failcount)" -eq 0 ]
}

# 5. FAIL-OPEN: no transcript to read -> no enforcement even with a tiny cap.
@test "ceiling: unreadable usage fails open (no transcript -> no reopen)" {
  _setup_repo
  make_claude noop
  # deliberately seed NO transcript
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=1
  [ "$status" -eq 0 ]
  open_has_marker '~'
  [ "$(_ceiling_event_count true)" -eq 0 ]
}

# 6. Per-item override raises the cap above a would-breach usage -> no reopen.
@test "ceiling: per-item override in backlog-ceilings.json relaxes the env default" {
  _setup_repo
  make_claude noop
  _seed_transcript 3 500000
  _seed_ceilings <<'EOF'
{ "items": { "do the thing": { "max_tokens": 10000000 } } }
EOF
  # env default would trip (500k > 400k) but the per-item override (10M) does not.
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=400000
  [ "$status" -eq 0 ]
  open_has_marker '~'
  [ "$(_ceiling_event_count true)" -eq 0 ]
}

# 7. Project-level cap in the config file (no env) trips on its own.
@test "ceiling: project-level cap in backlog-ceilings.json enforces without env" {
  _setup_repo
  make_claude noop
  _seed_transcript 3 500000
  _seed_ceilings <<'EOF'
{ "max_tokens": 400000 }
EOF
  run_tick CEILING_DISABLE=0
  [ "$status" -eq 0 ]
  open_has_marker ' '
  ! open_has_marker '~'
  [ "$(_failcount)" -eq 1 ]
}

# 8. CEILING_DISABLE=1 hard-disables both layers -> no reopen even when over.
@test "ceiling: CEILING_DISABLE=1 disables enforcement" {
  _setup_repo
  make_claude noop
  _seed_transcript 3 500000
  run_tick CEILING_DISABLE=1 MAX_TOKENS_PER_TICK=400000
  [ "$status" -eq 0 ]
  open_has_marker '~'
  [ "$(_ceiling_event_count true)" -eq 0 ]
}

# ==========================================================================
# Preventive layer — --max-budget-usd is passed to claude when a USD cap is set
# ==========================================================================

# Record claude's argv so we can assert the preventive flag.
_make_claude_recordargs() {
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
touch "\${CLAUDE_CALLED:-/dev/null}"
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/claude_args"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# 9. A USD cap injects `--max-budget-usd <amount>` into the claude invocation.
@test "ceiling: --max-budget-usd is passed when a USD cap is set" {
  _setup_repo
  _make_claude_recordargs
  run_tick CEILING_DISABLE=0 MAX_BUDGET_USD_PER_TICK=5
  [ "$status" -eq 0 ]
  grep -qx -- '--max-budget-usd' "$BATS_TEST_TMPDIR/claude_args"
  grep -qx -- '5' "$BATS_TEST_TMPDIR/claude_args"
}

# 10. No USD cap -> the flag is absent (default invocation unchanged).
@test "ceiling: --max-budget-usd is absent when no USD cap is set" {
  _setup_repo
  _make_claude_recordargs
  run_tick CEILING_DISABLE=0 MAX_TOKENS_PER_TICK=400000
  [ "$status" -eq 0 ]
  ! grep -qx -- '--max-budget-usd' "$BATS_TEST_TMPDIR/claude_args"
}

# 11. Per-item USD override builds the preventive flag from the config file.
@test "ceiling: per-item max_budget_usd override drives --max-budget-usd" {
  _setup_repo
  _make_claude_recordargs
  _seed_ceilings <<'EOF'
{ "items": { "do the thing": { "max_budget_usd": 12.5 } } }
EOF
  run_tick CEILING_DISABLE=0
  [ "$status" -eq 0 ]
  grep -qx -- '--max-budget-usd' "$BATS_TEST_TMPDIR/claude_args"
  grep -qx -- '12.5' "$BATS_TEST_TMPDIR/claude_args"
}
