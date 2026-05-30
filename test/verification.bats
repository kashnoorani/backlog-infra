#!/usr/bin/env bats
#
# Guard 4 (W2): per-tick outcome verification for bin/backlog-agent.
# After an exit-0 tick that CLAIMED COMPLETION (item flipped to [x]), the daemon
# independently runs the project's gate on the committed HEAD. On failure it
# REOPENS the item ([x]→[ ]) + failcount_bump (feeding the Guard-1 circuit
# breaker → [?] after K) and does NOT auto-revert. No gate defined ⇒ FAIL-OPEN.
# Hermetic scratch repo — see helpers.bash.
#
# NOTE: the fleet-freeze auto-arm "verify first" interaction is guarded by
# freeze_exempt (project == backlog-infra), which is false for the "work" fixture
# repo, so it never arms here regardless — that ordering is covered by code review
# + test/fleet-freeze.bats. These tests exercise the verification primitive itself.

load 'helpers'

setup() { _setup_repo; }

FAILCOUNTS=".claude/backlog-agent-failcounts.json"
EVENTS=".claude/backlog-agent-events.jsonl"

# True if the ## Open section has a [?] item. ('?' is a regex metachar, so the
# open_has_marker helper can't take it — grep the literal here.)
open_blocked() {
  grep -qE '^(- )?\[\?\] ' <(sed -n '/^## Open/,/^## [A-Z]/p' "$WORK/docs/Backlog.md")
}

# Shim a gate command on PATH + write/commit .claude/backlog-gate.json pointing
# at it. Modes: pass (exit 0), fail (exit 1), hang (sleep past any test timeout).
make_gate() {
  local mode="$1"
  cat > "$SHIM/gate-cmd" <<EOF
#!/usr/bin/env bash
mode="$mode"
EOF
  cat >> "$SHIM/gate-cmd" <<'EOF'
case "$mode" in
  pass) echo "gate: all green"; exit 0 ;;
  fail) echo "gate: typecheck failed" >&2; exit 1 ;;
  hang) exec sleep 30 ;;
esac
EOF
  chmod +x "$SHIM/gate-cmd"
  printf '{ "gate": ["gate-cmd"] }\n' > "$WORK/.claude/backlog-gate.json"
  git -C "$WORK" add .claude/backlog-gate.json
  git -C "$WORK" commit -qm "add gate config"
  git -C "$WORK" push -q origin main
}

# A claude stub that does real work + commits but flips [~]→[?] (blocked) instead
# of completing — so the item is NOT [x] this tick.
make_claude_block() {
  cat > "$SHIM/claude" <<'EOF'
#!/usr/bin/env bash
touch "${CLAUDE_CALLED:-/dev/null}"
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[?]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
echo "partial" > partial.txt
git add partial.txt docs/Backlog.md
git commit -qm "work: blocked partway"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# 1. No gate defined ⇒ FAIL-OPEN: a completion stands; verification never runs.
@test "no gate ⇒ fail-open (completion stands, no verify event)" {
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker 'x'
  [ ! -f "$WORK/$FAILCOUNTS" ] || ! grep -q '"do the thing"' "$WORK/$FAILCOUNTS"
  [ ! -f "$WORK/$EVENTS" ] || ! grep -q '"event":"verify_' "$WORK/$EVENTS"
}

# 2. Gate passes ⇒ completion stands + verify_passed event + streak cleared.
@test "gate passes ⇒ completion stands" {
  make_gate pass
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker 'x'
  ! open_has_marker ' '
  grep -qE '"event":"verify_passed".*"item":"do the thing"' "$WORK/$EVENTS"
  [ ! -f "$WORK/$FAILCOUNTS" ] || ! grep -q '"do the thing"' "$WORK/$FAILCOUNTS"
}

# 3. Gate fails ⇒ the [x] is REOPENED to [ ], failcount bumped, verify_failed event.
@test "gate fails ⇒ reopen + failcount bump" {
  make_gate fail
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker ' '          # reopened
  ! open_has_marker 'x'        # no longer claimed-complete
  grep -q '"do the thing":{"count":1' "$WORK/$FAILCOUNTS"
  grep -qE '"event":"verify_failed".*"item":"do the thing"' "$WORK/$EVENTS"
  [[ "$output" == *"[verify] FAILED"* ]]
}

# 4. A failed gate does NOT auto-revert: the work commit's file survives.
@test "gate failure keeps the work commit (no auto-revert)" {
  make_gate fail
  make_claude complete
  run_tick
  [ -f "$WORK/implemented.txt" ]                       # claude's file still present
  git -C "$WORK" log --oneline | grep -q "work: did the thing"
}

# 5. Verification failures compose with the Guard-1 circuit breaker: 3 failed
#    gates climb the failcount; the 4th tick trips the breaker → [?], no claude.
@test "verification failures trip the circuit breaker after 3" {
  make_gate fail
  make_claude complete
  for i in 1 2 3; do
    run_tick
    [ "$status" -eq 0 ]
    open_has_marker ' '
    rm -f "$CLAUDE_CALLED"
  done
  grep -q '"do the thing":{"count":3' "$WORK/$FAILCOUNTS"

  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called
  open_blocked
  [[ "$output" == *"circuit breaker"* ]]
}

# 6. Trigger precision: a committing tick that does NOT complete the item (flips
#    to [?]) must NOT run the gate, even when the gate would fail.
@test "no completion ⇒ no verification (commit without [x])" {
  make_gate fail
  make_claude_block
  run_tick
  [ "$status" -eq 0 ]
  open_blocked                 # item is [?], blocked by claude itself
  [ -f "$WORK/partial.txt" ]   # a commit DID land this tick
  [ ! -f "$WORK/$EVENTS" ] || ! grep -q '"event":"verify_' "$WORK/$EVENTS"
  [ ! -f "$WORK/$FAILCOUNTS" ] || ! grep -q '"do the thing"' "$WORK/$FAILCOUNTS"
}

# 7. A hanging gate is killed by the wall-clock watchdog and counts as a FAILURE.
@test "gate timeout ⇒ treated as a failed verification" {
  make_gate hang
  make_claude complete
  run_tick GATE_TIMEOUT_SECS=2
  [ "$status" -eq 0 ]
  open_has_marker ' '          # reopened after the timeout-kill
  grep -q '"do the thing":{"count":1' "$WORK/$FAILCOUNTS"
  grep -qE '"event":"verify_failed".*"item":"do the thing"' "$WORK/$EVENTS"
}

# 8. GATE_DISABLE=1 forces fail-open even with a failing gate present.
@test "GATE_DISABLE=1 ⇒ fail-open (completion stands)" {
  make_gate fail
  make_claude complete
  run_tick GATE_DISABLE=1
  [ "$status" -eq 0 ]
  open_has_marker 'x'
  [ ! -f "$WORK/$EVENTS" ] || ! grep -q '"event":"verify_' "$WORK/$EVENTS"
}

# 9. package.json fallback: the npm stock "no test specified" placeholder is
#    ignored, so a project with only that script is NOT falsely failed (fail-open).
@test "package.json placeholder test script is ignored ⇒ fail-open" {
  cat > "$WORK/package.json" <<'EOF'
{ "name": "x", "version": "1.0.0",
  "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
EOF
  git -C "$WORK" add package.json
  git -C "$WORK" commit -qm "pkg with placeholder test"
  git -C "$WORK" push -q origin main

  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker 'x'          # completion stands — placeholder did not gate it
  [ ! -f "$WORK/$EVENTS" ] || ! grep -q '"event":"verify_' "$WORK/$EVENTS"
}

# 10. package.json fallback: a real "verify" script IS used as the gate.
@test "package.json verify script is used as the gate" {
  command -v npm >/dev/null 2>&1 || skip "npm not available"
  # gate-cmd shim (fail) + a package.json whose verify script runs it. No
  # .claude/backlog-gate.json, so resolution falls through to package.json.
  cat > "$SHIM/gate-cmd" <<'EOF'
#!/usr/bin/env bash
echo "pkg gate failed" >&2; exit 1
EOF
  chmod +x "$SHIM/gate-cmd"
  cat > "$WORK/package.json" <<'EOF'
{ "name": "x", "version": "1.0.0", "scripts": { "verify": "gate-cmd" } }
EOF
  git -C "$WORK" add package.json
  git -C "$WORK" commit -qm "pkg with verify script"
  git -C "$WORK" push -q origin main

  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker ' '          # the failing pkg verify reopened it
  grep -qE '"event":"verify_failed".*"gate":"npm run verify"' "$WORK/$EVENTS"
}
