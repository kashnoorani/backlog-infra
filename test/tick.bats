#!/usr/bin/env bats
#
# tick_once invariants for bin/backlog-agent (the fleet driver).
# Each test runs against a hermetic scratch repo — see helpers.bash.

load 'helpers'

setup() { _setup_repo; }

# 1. No open items -> heartbeat only, claude never invoked.
@test "idle tick does not invoke claude" {
  write_backlog_open    # ## Open is empty
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called
  [[ "$output" == *"tick done (idle)"* ]]
}

# 2. Active cooldown -> short-circuit before claude, item left untouched.
@test "active cooldown short-circuits claude" {
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 3600 ))" > "$WORK/.claude/agent-cooldown.json"
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called
  [[ "$output" == *"cooldown"* ]]
  open_has_marker ' '   # item still open, never claimed
}

# 3. Plan-limit signature in claude output -> arm cooldown AND unclaim.
@test "plan-limit failure arms cooldown and unclaims the item" {
  make_claude fail_limit
  run_tick
  claude_was_called
  [ -f "$WORK/.claude/agent-cooldown.json" ]   # cooldown armed
  open_has_marker ' '                          # item flipped [~] -> [ ]
  ! open_has_marker '~'
}

# 4. Generic (non-limit) failure -> unclaim, but NO cooldown.
@test "generic failure unclaims without arming cooldown" {
  make_claude fail_other
  run_tick
  claude_was_called
  [ ! -f "$WORK/.claude/agent-cooldown.json" ]
  open_has_marker ' '
}

# 5. Successful tick -> completion accepted (item [x]), not unclaimed.
@test "successful tick accepts completion" {
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
  open_has_marker 'x'
  ! open_has_marker '~'
  [[ "$output" != *"unclaim"* ]]
}

# 6. Stale [~] claim + STARTUP_RECLAIM -> reclaim flips it back and records it.
@test "stale claim is reclaimed on startup" {
  write_backlog_open "- [~] orphaned by a dead daemon"
  git -C "$WORK" commit -qam "leave a stale claim"
  git -C "$WORK" push -q origin main
  run_tick STARTUP_RECLAIM=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim"* ]]
}

# 7. Diverged HEAD with a conflict -> reset --hard to origin (idempotent recovery).
@test "diverged local HEAD is reset to origin" {
  # Local unpushed commit that touches the backlog.
  write_backlog_open "- [ ] do the thing" "- [ ] LOCAL ONLY divergent line"
  git -C "$WORK" commit -qam "local-divergent"

  # A second clone pushes a conflicting change to the same region of origin.
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  write_backlog_open_in "$other" "- [ ] do the thing" "- [ ] REMOTE divergent line"
  git -C "$other" commit -qam "remote-divergent"
  git -C "$other" push -q origin main

  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset to origin"* ]]
  # Local-only commit is gone; HEAD matches origin.
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$(git -C "$WORK" rev-parse origin/main)" ]
  ! grep -q "LOCAL ONLY" "$WORK/docs/Backlog.md"
}
