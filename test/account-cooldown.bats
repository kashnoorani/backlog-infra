#!/usr/bin/env bats
#
# Account-level shared cooldown (W2, docs/account-cooldown.md) — a pause-primitive
# consumer at scope=fleet that rides the D1 bus. The Anthropic plan limit is
# per-ACCOUNT (shared across every machine + project), but start_cooldown arms a
# LOCAL per-project cooldown. This feature publishes a single account-wide cooldown
# to D1 (a dedicated /api/cooldown row carrying the reset until_epoch) that every
# daemon's top-of-tick consults FIRST, so the whole fleet stands down at once and
# resumes together. Three surfaces:
#
#   A. DRIVER read/gate (bin/backlog-agent) — top-of-tick Layer 2 reads the account
#      cooldown (_d1_account_cooldown_epoch) ALONGSIDE the local cooldown:
#        active            -> heartbeat-only (claude NOT called), unless a Layer-3
#                             fallback agent is available (a non-Claude provider
#                             isn't capped) -> falls through to work.
#        expired/unreachable -> FAIL-OPEN: the local per-project cooldown still
#                             governs; D1 down is never a fleet stall / regression.
#   B. DRIVER publish (bin/backlog-agent) — start_cooldown also POSTs the reset to
#      /api/cooldown (best-effort, backgrounded) so siblings stand down without
#      each failing their own claude call first.
#   C. CLI (bin/backlog-agents) — `cooldown --status|--check|--clear`.
#
# All hermetic: curl is PATH-shimmed; no network. Mirrors helpers.bash (driver) +
# fleet-pause.bats (CLI). FREEZE_DISABLE=1 (helpers default) keeps the separate
# fleet-control read out of these tests; ACCOUNT_COOLDOWN_DISABLE=0 enables the
# account read/publish behind the stub.

load 'helpers'

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# ---- driver-side shim ----------------------------------------------------
# curl shim for the DRIVER's account-cooldown read + publish. Keys off URL +
# method. GET modes (account cooldown state):
#   active      -> 200 {active:1, until_epoch = NOW+3600}
#   expired     -> 200 {active:0, until_epoch = NOW-3600}   (auto-expiry: re-check)
#   none        -> 200 {active:0, until_epoch:null}
#   unreachable -> exit 7 (curl couldn't connect) -> fail-open
# A POST (publish) records its body to $HOME/.posted and returns 200.
# *heartbeat* -> 404 (reaper fail-safe skip); anything else -> {} 200.
make_cooldown_curl() {
  local mode="$1"
  mkdir -p "$HOME/.config/backlog"
  echo testkey > "$HOME/.config/backlog/health-key"
  : > "$HOME/.posted"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
mode="$mode"
now="\$(date +%s)"
EOF
  cat >> "$SHIM/curl" <<'EOF'
method=GET; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a";; -d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *cooldown*)
    if [ "$method" = POST ]; then
      printf '%s\n' "$data" >> "$HOME/.posted"; emit '{"ok":true}' 200
    else
      case "$mode" in
        active)      emit "{\"found\":true,\"active\":1,\"until_epoch\":$((now+3600)),\"armed_by\":\"M3-8GB\"}" 200 ;;
        expired)     emit "{\"found\":true,\"active\":0,\"until_epoch\":$((now-3600))}" 200 ;;
        none)        emit '{"found":true,"active":0,"until_epoch":null}' 200 ;;
        unreachable) exit 7 ;;
      esac
    fi ;;
  *heartbeat*) emit '{"found":false}' 404 ;;
  *)           emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# Poll for the publish POST to land (it's backgrounded in the driver so it can't
# stall the tick). Fails the test if nothing is posted within ~3s.
wait_for_post() {
  local i
  for i in $(seq 1 30); do
    [ -s "$HOME/.posted" ] && return 0
    sleep 0.1
  done
  return 1
}

# ==========================================================================
# A. Driver read / gate
# ==========================================================================

# A1. Account cooldown active (no LOCAL cooldown file) -> heartbeat-only.
@test "driver: account cooldown holds the fleet to heartbeat-only (no local file)" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl active
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown active (account)"* ]]
  [[ "$output" == *"heartbeat only"* ]]
  ! claude_was_called
  [ ! -f "$WORK/.claude/agent-cooldown.json" ]   # account signal does NOT write a local file
}

# A2. Layer 3: account cooldown active + a fallback agent -> fall through to work
#     (a non-Claude provider isn't capped by the Anthropic per-account limit).
@test "driver: account cooldown runs the fallback agent when one is available" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl active
  make_fallback_agent fakeagent
  write_fallback_config fakeagent true
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called          # account cooldown still blocks claude
  fallback_was_called          # but the fallback drove the tick
}

# A3. Auto-expiry: an account cooldown whose until_epoch is in the PAST does NOT
#     hold (the first daemon past the reset proceeds) -> claude runs.
@test "driver: expired account cooldown does not hold (auto-expiry)" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl expired
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# A4. Fail-open: D1 unreachable + NO local cooldown -> claude runs normally (an
#     account-cooldown outage must never become a fleet stall).
@test "driver: unreachable account endpoint fails open (claude runs)" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl unreachable
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# A5. Fail-open preserves the LOCAL fallback: account endpoint unreachable but a
#     local cooldown is armed -> the tick still holds (no regression).
@test "driver: local cooldown still holds when the account endpoint is unreachable" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl unreachable
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 3600 ))" > "$WORK/.claude/agent-cooldown.json"
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"heartbeat only"* ]]
  ! claude_was_called
}

# A6. Combined: both local + account active -> held, and the log marks the source
#     as local+account (the loop sleeps until the LATER reset).
@test "driver: combined local+account cooldown is held and labelled" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl active
  printf '{ "until_epoch": %s }\n' "$(( $(date +%s) + 60 ))" > "$WORK/.claude/agent-cooldown.json"
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown active (local+account)"* ]]
  ! claude_was_called
}

# A7. The disable flag (helpers default = 1) skips the account read entirely: with
#     no local file the tick proceeds to work even though the endpoint WOULD say
#     active — proves ordinary tick tests never reach the network.
@test "driver: ACCOUNT_COOLDOWN_DISABLE=1 skips the account read" {
  _setup_repo
  # leave ACCOUNT_COOLDOWN_DISABLE=1 (helpers default)
  make_cooldown_curl active
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  claude_was_called
}

# ==========================================================================
# B. Driver publish (start_cooldown -> POST /api/cooldown)
# ==========================================================================

# B1. A plan-limit failure arms the local cooldown AND publishes the reset to D1.
@test "driver: plan-limit failure publishes the account cooldown to D1" {
  _setup_repo
  export ACCOUNT_COOLDOWN_DISABLE=0
  make_cooldown_curl none          # GET says no cooldown -> tick proceeds to claim+work
  make_claude fail_limit 5:30pm
  run_tick
  [ "$status" -eq 0 ]
  [ -f "$WORK/.claude/agent-cooldown.json" ]    # local cooldown armed
  wait_for_post                                  # the backgrounded publish landed
  grep -q '"until_epoch"' "$HOME/.posted"
  grep -q 'anthropic-plan-limit' "$HOME/.posted"
}

# B2. With the feature disabled, a plan-limit failure arms the local cooldown but
#     does NOT publish (no POST).
@test "driver: disabled feature does not publish on a plan-limit failure" {
  _setup_repo
  # ACCOUNT_COOLDOWN_DISABLE=1 (helpers default)
  make_cooldown_curl none
  make_claude fail_limit
  run_tick
  [ "$status" -eq 0 ]
  [ -f "$WORK/.claude/agent-cooldown.json" ]    # local cooldown still armed
  sleep 0.3
  [ ! -s "$HOME/.posted" ]                       # nothing published
}

# ==========================================================================
# C. CLI: backlog-agents cooldown --status / --check / --clear
# ==========================================================================

# Mirror fleet-pause.bats _cli_setup: the curl shim records POSTed bodies and the
# GET reflects $HOME/.cd_active (+ a fixed future until_epoch when active).
_cli_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$HOME/.claude" "$HOME/.config/backlog" "$SHIM"
  echo testkey > "$HOME/.config/backlog/health-key"
  echo 0 > "$HOME/.cd_active"
  : > "$HOME/.posted"
  export PATH="$SHIM:$PATH"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
now="$(date +%s)"
method=GET; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a";; -d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit(){ printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *cooldown*)
    if [ "$method" = POST ]; then
      printf '%s\n' "$data" >> "$HOME/.posted"; emit '{"ok":true}' 200
    else
      act="$(cat "$HOME/.cd_active" 2>/dev/null || echo 0)"
      if [ "$act" = 1 ]; then
        emit "{\"found\":true,\"active\":1,\"until_epoch\":$((now+1800)),\"armed_by\":\"M3-8GB\"}" 200
      else
        emit '{"found":true,"active":0,"until_epoch":null}' 200
      fi
    fi ;;
  *) emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# C1. --check exits 1 when clear, 0 when active.
@test "cli: cooldown --check reflects the active bit" {
  _cli_setup
  echo 0 > "$HOME/.cd_active"
  run bash "$AGENTS_BIN" cooldown --check
  [ "$status" -eq 1 ]
  echo 1 > "$HOME/.cd_active"
  run bash "$AGENTS_BIN" cooldown --check
  [ "$status" -eq 0 ]
}

# C2. --status prints ACTIVE with the arming host when a cooldown is live.
@test "cli: cooldown --status shows an active account cooldown" {
  _cli_setup
  echo 1 > "$HOME/.cd_active"
  run bash "$AGENTS_BIN" cooldown --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIVE"* ]]
  [[ "$output" == *"M3-8GB"* ]]
}

# C3. --status (default) reports clear when nothing is active.
@test "cli: cooldown is clear by default" {
  _cli_setup
  echo 0 > "$HOME/.cd_active"
  run bash "$AGENTS_BIN" cooldown
  [ "$status" -eq 0 ]
  [[ "$output" == *"clear"* ]]
}

# C4. --clear POSTs a CLEAR (until_epoch null + clear:true) to lapse the signal.
@test "cli: cooldown --clear posts a clear" {
  _cli_setup
  run bash "$AGENTS_BIN" cooldown --clear
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEARED"* ]]
  grep -q '"until_epoch":null' "$HOME/.posted"
  grep -q '"clear":true' "$HOME/.posted"
}
