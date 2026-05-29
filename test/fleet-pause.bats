#!/usr/bin/env bats
#
# Fleet pause / stop / resume (W3, docs/fleet-freeze.md DECISION F) — the MANUAL
# siblings of freeze on the SAME D1 fleet_control table, precedence stop > pause >
# freeze (resolved at the GET endpoint, returned as "mode"). Two surfaces:
#
#   A. DRIVER gate (bin/backlog-agent) — top-of-tick reads the combined control
#      "mode" (_d1_control_get):
#        stop   -> full halt (TICK_OUTCOME=stop; the daemon loop breaks + the
#                  process exits). No infra exemption. Fail-OPEN like freeze/pause.
#        pause  -> heartbeat-only hold (claude NOT called); infra-exempt like freeze.
#        freeze -> unchanged (covered by fleet-freeze.bats); back-compat: a "frozen"
#                  body with no "mode" still derives mode=freeze.
#
#   B. CLI (bin/backlog-agents) — pause/resume/stop/start POST their own control
#      row (key=pause|stop); --status/--check read the combined controls map.
#
# All hermetic: curl + backlog-agents are PATH-shimmed; no network. Mirrors
# helpers.bash (driver) and fleet-freeze.bats (CLI).

load 'helpers'

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# ---- driver-side shims ---------------------------------------------------

# curl shim for the DRIVER's top-of-tick control read. Keys off the URL. Modes:
#   pause / stop -> 200 {mode:...}     thawed -> 200 {mode:none}
#   freeze_legacy-> 200 {frozen:1}     (no "mode" key — exercises back-compat)
#   unreachable  -> exit 7 (fail-open) — the driver must treat this as no-control.
make_control_curl() {
  local mode="$1"
  mkdir -p "$HOME/.config/backlog"
  echo testkey > "$HOME/.config/backlog/health-key"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
mode="$mode"
EOF
  cat >> "$SHIM/curl" <<'EOF'
url=""
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
emit() { printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *fleet-control*)
    case "$mode" in
      pause)        emit '{"mode":"pause","mode_reason":"manual pause: test","frozen":0}' 200 ;;
      stop)         emit '{"mode":"stop","mode_reason":"manual stop: test","frozen":0}' 200 ;;
      thawed)       emit '{"mode":"none","frozen":0}' 200 ;;
      freeze_legacy)emit '{"found":true,"frozen":1,"reason":"in-flight infra change: test"}' 200 ;;
      unreachable)  exit 7 ;;
    esac ;;
  *heartbeat*) emit '{"found":false}' 404 ;;   # reaper: no row -> fail-safe skip
  *)           emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# ==========================================================================
# A. Driver gate
# ==========================================================================

# A1. Non-exempt daemon, paused -> heartbeat-only (claude NOT called).
@test "driver: non-exempt daemon holds to heartbeat-only while paused" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl pause
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-pause active"* ]]
  [[ "$output" == *"heartbeat only"* ]]
  ! claude_was_called
}

# A2. Exempt (backlog-infra) daemon is NOT held by pause — only stop halts it.
@test "driver: exempt daemon keeps ticking while paused (pause is infra-exempt)" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl pause
  make_claude noop
  run_tick FREEZE_PROJECT=work     # make THIS project the exempt one
  [ "$status" -eq 0 ]
  [[ "$output" == *"exempt daemon"* ]]
  claude_was_called                # exempt daemon did NOT stop
}

# A3. Stop -> full halt: claude NOT called, TICK_OUTCOME=stop logged.
@test "driver: stop halts the tick (no claude)" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl stop
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet STOP active"* ]]
  [[ "$output" == *"halting daemon"* ]]
  ! claude_was_called
}

# A4. Stop halts the EXEMPT daemon too (no infra exemption for stop).
@test "driver: stop halts even the exempt (infra) daemon" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl stop
  run_tick FREEZE_PROJECT=work
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet STOP active"* ]]
  ! claude_was_called
}

# A5. Fail-open: an unreachable control plane must NOT halt the fleet (stop too).
@test "driver: fail-open — unreachable D1 ticks normally" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl unreachable
  make_claude noop
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet STOP"* ]]
  [[ "$output" != *"fleet-pause"* ]]
  claude_was_called
}

# A6. Thawed (mode:none) -> normal tick.
@test "driver: thawed control lets the tick proceed normally" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl thawed
  make_claude noop
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet STOP"* ]]
  [[ "$output" != *"fleet-pause"* ]]
  claude_was_called
}

# A7. Back-compat: a body with only "frozen":1 (pre-"mode" endpoint) still freezes.
@test "driver: pre-mode endpoint (frozen only) still holds as freeze" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_control_curl freeze_legacy
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-freeze active"* ]]
  ! claude_was_called
}

# ==========================================================================
# B. CLI: backlog-agents pause / resume / stop / start
# ==========================================================================

# Mirror fleet-freeze.bats _cli_setup, but the curl shim records the POSTed `key`
# (so we can assert pause/stop write the right row) and the GET returns a controls
# map driven by $HOME/.pause + $HOME/.stop.
_cli_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$HOME/.claude" "$HOME/.config/backlog" "$SHIM"
  echo testkey > "$HOME/.config/backlog/health-key"
  echo 0 > "$HOME/.pause"
  echo 0 > "$HOME/.stop"
  : > "$HOME/.posted"
  export PATH="$SHIM:$PATH"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; url=""; data=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a";; -d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
emit(){ printf '%s\n%s' "$1" "$2"; }
case "$url" in
  *fleet-control*)
    if [ "$method" = POST ]; then
      printf '%s\n' "$data" >> "$HOME/.posted"; emit '{"ok":true}' 200
    else
      pz="$(cat "$HOME/.pause" 2>/dev/null || echo 0)"
      st="$(cat "$HOME/.stop" 2>/dev/null || echo 0)"
      mode=none; [ "$pz" = 1 ] && mode=pause; [ "$st" = 1 ] && mode=stop
      emit "{\"frozen\":0,\"mode\":\"$mode\",\"controls\":{\"freeze\":{\"active\":0},\"pause\":{\"active\":$pz,\"armed_by\":\"h\",\"reason\":\"r\"},\"stop\":{\"active\":$st,\"armed_by\":\"h\",\"reason\":\"r\"}}}" 200
    fi ;;
  *) emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# B1. pause arms POST key=pause frozen=1.
@test "cli: pause arms (POST key=pause frozen=1)" {
  _cli_setup
  run bash "$AGENTS_BIN" pause --reason "standing the fleet down"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet PAUSED"* ]]
  grep -q '"key":"pause"' "$HOME/.posted"
  grep -q '"frozen":1' "$HOME/.posted"
  grep -q "standing the fleet down" "$HOME/.posted"
}

# B2. resume clears POST key=pause frozen=0.
@test "cli: resume clears (POST key=pause frozen=0)" {
  _cli_setup
  run bash "$AGENTS_BIN" resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESUMED"* ]]
  grep -q '"key":"pause"' "$HOME/.posted"
  grep -q '"frozen":0' "$HOME/.posted"
}

# B3. stop arms POST key=stop frozen=1.
@test "cli: stop arms (POST key=stop frozen=1)" {
  _cli_setup
  run bash "$AGENTS_BIN" stop --reason "halt everything"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STOP armed"* ]]
  grep -q '"key":"stop"' "$HOME/.posted"
  grep -q '"frozen":1' "$HOME/.posted"
}

# B4. start clears POST key=stop frozen=0.
@test "cli: start clears (POST key=stop frozen=0)" {
  _cli_setup
  run bash "$AGENTS_BIN" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"START"* ]]
  grep -q '"key":"stop"' "$HOME/.posted"
  grep -q '"frozen":0' "$HOME/.posted"
}

# B5. pause --check exits 1 when not paused, 0 when paused.
@test "cli: pause --check reflects the pause control bit" {
  _cli_setup
  echo 0 > "$HOME/.pause"
  run bash "$AGENTS_BIN" pause --check
  [ "$status" -eq 1 ]
  echo 1 > "$HOME/.pause"
  run bash "$AGENTS_BIN" pause --check
  [ "$status" -eq 0 ]
}

# B6. stop --check is independent of pause (separate control rows).
@test "cli: stop --check reflects only the stop control bit" {
  _cli_setup
  echo 1 > "$HOME/.pause"          # pause on, stop off
  echo 0 > "$HOME/.stop"
  run bash "$AGENTS_BIN" stop --check
  [ "$status" -eq 1 ]             # stop still clear
  run bash "$AGENTS_BIN" pause --check
  [ "$status" -eq 0 ]             # pause active
}

# B7. freeze/unfreeze keep posting key=freeze (back-compat: 4-arg POST defaults).
@test "cli: unfreeze still targets the freeze row (key default)" {
  _cli_setup
  run bash "$AGENTS_BIN" unfreeze
  [ "$status" -eq 0 ]
  grep -q '"key":"freeze"' "$HOME/.posted"
  grep -q '"frozen":0' "$HOME/.posted"
}
