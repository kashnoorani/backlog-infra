#!/usr/bin/env bats
#
# Fleet-freeze (W3, docs/fleet-freeze.md). Two surfaces:
#
#   A. DRIVER gate (bin/backlog-agent) — top-of-tick: when the D1 freeze flag is
#      set, a NON-exempt daemon holds to heartbeat-only (no claude); the EXEMPT
#      (backlog-infra) daemon keeps ticking and delegates the clear evaluation to
#      `backlog-agents freeze --eval`. Reads are FAIL-OPEN (D1 down ⇒ not frozen).
#      Auto-arm: an exempt tick that commits a fleet-affecting (bin/) change calls
#      `backlog-agents freeze --arm`.
#
#   B. CLI (bin/backlog-agents) — freeze/unfreeze arm-clear writes, --check/--status
#      reads, and --eval auto-clear gated on canary-green + skew-zero.
#
# All hermetic: curl + backlog-agents are PATH-shimmed; no network. Mirrors
# helpers.bash (driver) and sync-gate.bats / canary.bats (CLI).

load 'helpers'

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# ---- driver-side shims ---------------------------------------------------

# curl shim for the DRIVER's top-of-tick freeze read (and any reaper heartbeat
# probe). Keys off the URL across curl's args. Modes:
#   frozen      -> 200 {frozen:1}     thawed -> 200 {frozen:0}
#   unreachable -> exit 7 (fail-open) — the driver must treat this as not frozen.
make_freeze_curl() {
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
      frozen)      emit '{"found":true,"frozen":1,"reason":"in-flight infra change: test"}' 200 ;;
      thawed)      emit '{"found":true,"frozen":0}' 200 ;;
      unreachable) exit 7 ;;
    esac ;;
  *heartbeat*) emit '{"found":false}' 404 ;;   # reaper: no row -> fail-safe skip
  *)           emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# Stub `backlog-agents` on PATH so the driver's exempt-eval + auto-arm delegation
# is recorded (and never hits the real CLI / real D1). Records every invocation.
make_agents_stub() {
  AGENTS_CALLED="$BATS_TEST_TMPDIR/agents_called"
  export AGENTS_CALLED
  cat > "$SHIM/backlog-agents" <<'EOF'
#!/usr/bin/env bash
echo "backlog-agents $*" >> "${AGENTS_CALLED:-/dev/null}"
exit 0
EOF
  chmod +x "$SHIM/backlog-agents"
}

# claude stub that creates a caller-supplied file, completes the item, and
# commits (scoped — never .claude/). Mirrors guards.bats _make_claude_committing.
_make_claude_committing() {
  local body="$1"
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
touch "\${CLAUDE_CALLED:-/dev/null}"
$body
EOF
  cat >> "$SHIM/claude" <<'EOF'
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[x]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
git add docs/Backlog.md
git ls-files --others --modified --exclude-standard \
  | grep -vE '^\.claude/' | grep -vE '^docs/Backlog\.md$' \
  | while IFS= read -r f; do git add "$f"; done
git commit -qm "work: did the thing"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# ==========================================================================
# A. Driver gate
# ==========================================================================

# A1. Non-exempt daemon, frozen -> heartbeat-only (claude NOT called).
@test "driver: non-exempt daemon holds to heartbeat-only while frozen" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl frozen
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-freeze active"* ]]
  [[ "$output" == *"heartbeat only"* ]]
  ! claude_was_called
}

# A2. Thawed -> normal tick (claude IS called).
@test "driver: thawed flag lets the tick proceed normally" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl thawed
  make_claude noop
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet-freeze active"* ]]
  claude_was_called
}

# A3. Fail-open: an unreachable control plane must NOT freeze the fleet.
@test "driver: fail-open — unreachable D1 ticks normally" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl unreachable
  make_claude noop
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet-freeze active"* ]]
  claude_was_called
}

# A4. Exempt (backlog-infra) daemon keeps ticking while frozen + evaluates clear.
@test "driver: exempt daemon keeps ticking and runs --eval while frozen" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl frozen
  make_agents_stub
  make_claude noop
  run_tick FREEZE_PROJECT=work     # make THIS project the exempt one
  [ "$status" -eq 0 ]
  [[ "$output" == *"exempt daemon"* ]]
  claude_was_called               # exempt daemon did NOT stop
  grep -q "freeze --eval" "$AGENTS_CALLED"
}

# A5. FREEZE_DISABLE=1 skips the read entirely (the suite's hermetic default).
@test "driver: FREEZE_DISABLE=1 never reads the flag (ticks normally even if frozen)" {
  _setup_repo
  make_freeze_curl frozen
  make_claude noop
  run_tick FREEZE_DISABLE=1
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet-freeze active"* ]]
  claude_was_called
}

# A6. Auto-arm: an exempt tick committing a bin/ change arms the freeze.
@test "driver: exempt tick committing bin/ auto-arms the freeze" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl thawed          # not frozen — isolate the auto-arm path
  make_agents_stub
  _make_claude_committing 'mkdir -p bin; echo "new tool" > bin/new-tool.sh'
  run_tick FREEZE_PROJECT=work
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet-freeze] arming"* ]]
  grep -q "freeze --arm" "$AGENTS_CALLED"
}

# A7. Auto-arm does NOT fire for a non-fleet-affecting commit (no bin/ touch).
@test "driver: exempt tick with no bin/ change does not arm" {
  _setup_repo
  export FREEZE_DISABLE=0
  make_freeze_curl thawed
  make_agents_stub
  _make_claude_committing 'echo hello > notes.txt'
  run_tick FREEZE_PROJECT=work
  [ "$status" -eq 0 ]
  [[ "$output" != *"fleet-freeze] arming"* ]]
  ! grep -q "freeze --arm" "$AGENTS_CALLED" 2>/dev/null
}

# ==========================================================================
# B. CLI: backlog-agents freeze / unfreeze
# ==========================================================================

# Mirror sync-gate.bats: a throwaway backlog-infra repo with a real origin, plus
# a curl shim for the fleet-control + health endpoints. $HOME/.freeze drives the
# GET flag; POSTs are appended to $HOME/.posted; $HOME/.health_body (if present)
# is the /api/health body for the skew-zero check.
_cli_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  INFRA="$HOME/dev/projects/active/backlog-infra"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$INFRA/bin" "$HOME/.claude" "$HOME/.config/backlog" "$SHIM"
  git init -q "$INFRA"
  git -C "$INFRA" config user.email t@e.co
  git -C "$INFRA" config user.name t
  printf '#driver v1\n' > "$INFRA/bin/backlog-agent"
  git -C "$INFRA" add bin/backlog-agent
  git -C "$INFRA" commit -qm "driver v1"
  git init -q --bare "$ORIGIN"
  git -C "$INFRA" remote add origin "$ORIGIN"
  git -C "$INFRA" push -q -u origin HEAD:main
  export CANARY_STATE_FILE="$HOME/.claude/backlog-canary.json"
  export CANARY_DOCTOR=0
  echo testkey > "$HOME/.config/backlog/health-key"
  echo 0 > "$HOME/.freeze"
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
      fr="$(cat "$HOME/.freeze" 2>/dev/null || echo 0)"
      emit "{\"found\":true,\"frozen\":$fr,\"reason\":\"test\",\"arming_sha\":\"abc\",\"armed_by\":\"manual\"}" 200
    fi ;;
  *api/health*)
    if [ -f "$HOME/.health_body" ]; then emit "$(cat "$HOME/.health_body")" 200
    else emit '{"projects":{}}' 200; fi ;;
  *) emit '{}' 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}
cur_sha() { git -C "$INFRA" log -1 --format=%h -- bin; }
pass_canary() { env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary >/dev/null; }

# B1. --check exits non-zero when thawed.
@test "cli: freeze --check exits 1 when thawed" {
  _cli_setup
  echo 0 > "$HOME/.freeze"
  run bash "$AGENTS_BIN" freeze --check
  [ "$status" -eq 1 ]
}

# B2. --check exits zero when frozen.
@test "cli: freeze --check exits 0 when frozen" {
  _cli_setup
  echo 1 > "$HOME/.freeze"
  run bash "$AGENTS_BIN" freeze --check
  [ "$status" -eq 0 ]
}

# B3. Manual freeze POSTs frozen=1.
@test "cli: freeze arms (POST frozen=1)" {
  _cli_setup
  run bash "$AGENTS_BIN" freeze --reason "pushing a driver fix"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet FROZEN"* ]]
  grep -q '"frozen":1' "$HOME/.posted"
  grep -q "pushing a driver fix" "$HOME/.posted"
}

# B4. unfreeze POSTs frozen=0.
@test "cli: unfreeze clears (POST frozen=0)" {
  _cli_setup
  run bash "$AGENTS_BIN" unfreeze
  [ "$status" -eq 0 ]
  [[ "$output" == *"THAWED"* ]]
  grep -q '"frozen":0' "$HOME/.posted"
}

# B5. --eval stays frozen when the driver hasn't passed canary (not validated).
@test "cli: freeze --eval stays frozen when canary is not green" {
  _cli_setup
  echo 1 > "$HOME/.freeze"          # frozen
  # no pass_canary -> _sync_gate_check fails
  run bash "$AGENTS_BIN" freeze --eval
  [ "$status" -eq 1 ]
  [[ "$output" == *"staying frozen"* ]]
  ! grep -q '"frozen":0' "$HOME/.posted" 2>/dev/null   # never cleared
}

# B6. --eval clears when canary is green AND every live host is on the ref SHA.
@test "cli: freeze --eval clears on canary-green + skew-zero" {
  _cli_setup
  echo 1 > "$HOME/.freeze"
  pass_canary                       # canary green for cur driver, no skew (pushed)
  printf '{"projects":{"p1":{"driver_sha":"%s","age_sec":10}}}' "$(cur_sha)" > "$HOME/.health_body"
  run bash "$AGENTS_BIN" freeze --eval
  [ "$status" -eq 0 ]
  [[ "$output" == *"THAWED"* ]]
  grep -q '"frozen":0' "$HOME/.posted"
}

# B7. --eval stays frozen when a live host is still on an OLD driver (skew>0).
@test "cli: freeze --eval stays frozen when a live host is skewed" {
  _cli_setup
  echo 1 > "$HOME/.freeze"
  pass_canary
  printf '{"projects":{"p1":{"driver_sha":"deadbee","age_sec":10}}}' > "$HOME/.health_body"
  run bash "$AGENTS_BIN" freeze --eval
  [ "$status" -eq 1 ]
  [[ "$output" == *"staying frozen"* ]]
  ! grep -q '"frozen":0' "$HOME/.posted" 2>/dev/null
}
