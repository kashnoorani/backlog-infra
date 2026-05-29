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

# 6. Stale [~] claim + STARTUP_RECLAIM -> reclaim flips it back and records it,
#    WITHOUT any network probe (startup reclaims even when D1 is unreachable).
@test "stale claim is reclaimed on startup" {
  make_curl unreachable          # even with D1 down...
  write_backlog_open "- [~] orphaned by a dead daemon"
  git -C "$WORK" commit -qam "leave a stale claim"
  git -C "$WORK" push -q origin main
  run_tick STARTUP_RECLAIM=1     # ...startup path reclaims unconditionally
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim"* ]]
  # No probe ran on startup, so the message must NOT print a bogus age computed
  # from an empty hb_epoch ("(now - 0)/60" ≈ a 7+ digit minute count).
  [[ "$output" == *"startup reclaim of orphaned claim"* ]]
  [[ ! "$output" =~ [0-9]{7,}m ]]
}

# 6a. Live D1 heartbeat -> owning daemon alive -> [~] NOT reclaimed.
@test "live D1 heartbeat does not reclaim a [~] claim" {
  make_curl live
  write_backlog_open "- [~] in-flight on a live daemon"
  git -C "$WORK" commit -qam "claim"
  git -C "$WORK" push -q origin main
  run_tick                       # NOT startup
  [ "$status" -eq 0 ]
  open_has_marker '~'            # still claimed
  [[ "$output" != *"reclaim"* ]]
}

# 6b. Dead heartbeat (>90m old) -> reclaim fires and logs the D1-heartbeat
#     reason. (We assert on the reclaim log, not the final marker: the same
#     tick immediately re-claims the freed item — the surviving daemon picking
#     up the orphaned work — exactly as the startup-reclaim test above does.)
@test "stale D1 heartbeat reclaims a [~] claim" {
  make_curl dead
  write_backlog_open "- [~] orphaned by a daemon that stopped beating"
  git -C "$WORK" commit -qam "claim"
  git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"reclaim"* ]]
  [[ "$output" == *"no D1 heartbeat"* ]]
}

# 6c. D1 unreachable (curl exit 7) -> FAIL SAFE -> [~] NOT reclaimed (DECISION 1).
@test "unreachable D1 does not reclaim (fail-safe)" {
  make_curl unreachable
  write_backlog_open "- [~] in-flight, dashboard is down"
  git -C "$WORK" commit -qam "claim"
  git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker '~'            # preserved — we must not reclaim mid-work
  [[ "$output" != *"reclaim"* ]]
}

# 6d. 404 / found:false (no row for this project,host) -> also fail safe.
@test "missing D1 row does not reclaim (fail-safe)" {
  make_curl notfound
  write_backlog_open "- [~] no telemetry row yet"
  git -C "$WORK" commit -qam "claim"
  git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker '~'
  [[ "$output" != *"reclaim"* ]]
}

# 6e. No health-key present -> the bearer-auth array is empty. Under bash 3.2 +
#     `set -u` a naive "${auth[@]}" would abort the tick with "unbound
#     variable"; assert the tick survives, fails safe (no reclaim), and emits no
#     such error. (Covers the keyless machine the other cases don't.)
@test "missing health-key does not crash the reaper" {
  make_curl live                 # would say "alive" — but no key to send
  rm -f "$HOME/.config/backlog/health-key"
  write_backlog_open "- [~] in-flight, this machine has no health key"
  git -C "$WORK" commit -qam "claim"
  git -C "$WORK" push -q origin main
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker '~'            # live heartbeat still read -> no reclaim
  [[ "$output" != *"unbound variable"* ]]
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

# --- audit fixes: §2 timeouts ---

# 8. A hung claude is killed by the wall-clock watchdog and treated as a failed
#    tick (item unclaimed), instead of wedging the daemon forever holding the
#    tick lock with no heartbeat.
@test "hung claude is killed by the timeout watchdog and the item is unclaimed" {
  make_claude hang               # exec sleep 30 — far longer than the cap below
  run_tick CLAUDE_TIMEOUT_SECS=2 # watchdog SIGTERMs claude at ~2s
  [ "$status" -eq 0 ]
  claude_was_called
  open_has_marker ' '            # claimed then unclaimed on the (kill) failure
  ! open_has_marker '~'
  [ ! -f "$WORK/.claude/agent-cooldown.json" ]   # a kill is not a plan-limit
}

# 9. A hung status hook is killed by its watchdog so even an idle heartbeat tick
#    can't wedge on a stalled network git op.
@test "hung status hook is killed by the timeout watchdog" {
  write_backlog_open             # idle: no open items, but the hook still runs
  printf 'setInterval(() => {}, 1e9)\n' > "$WORK/scripts/backlog-agent-status.mjs"
  run_tick HOOK_TIMEOUT_SECS=1   # watchdog SIGTERMs node at ~1s
  [ "$status" -eq 0 ]
  [[ "$output" == *"tick done (idle)"* ]]   # tick completed; did not hang
}

# --- audit fixes: §1 set-e / parsing ---

# 10. `status` must not abort on a truncated/corrupt status JSON (jq parse error
#     under set -e). Default subcommand — has to degrade, not crash.
@test "status degrades gracefully on malformed status JSON" {
  printf '{bad json, not closed\n' > "$WORK/.claude/backlog-status.json"
  run env bash "$AGENT_BIN" status
  [ "$status" -eq 0 ]
}

# 11. Plan-limit reset at a leading-zero minute (":08") must parse to minute 08,
#     not be misread as invalid octal and zeroed. TZ=UTC makes the parsed local
#     time map to a known UTC minute deterministically across machines.
@test "cooldown reset parses leading-zero minutes correctly (no octal zeroing)" {
  make_claude fail_limit "9:08pm"
  run_tick TZ=UTC
  claude_was_called
  [ -f "$WORK/.claude/agent-cooldown.json" ]
  # until ISO must carry minute 08 (HH:08:00Z); the octal bug produced HH:00:00Z.
  grep -qE 'T[0-9][0-9]:08:00Z' "$WORK/.claude/agent-cooldown.json"
}
