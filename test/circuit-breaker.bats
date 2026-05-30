#!/usr/bin/env bats
#
# Guard 1 (W2): per-item circuit breaker for bin/backlog-agent.
# After CIRCUIT_BREAKER_THRESHOLD (=3) consecutive failed ticks for the SAME
# item, the next tick auto-blocks it ([ ]/[!] → [?]) with an inline note and
# skips claude entirely. Hermetic scratch repo — see helpers.bash.

load 'helpers'

setup() { _setup_repo; }

FAILCOUNTS=".claude/backlog-agent-failcounts.json"
EVENTS=".claude/backlog-agent-events.jsonl"

# True if the ## Open section has a [?] item. (open_has_marker can't take '?'
# — it's a regex metachar in the helper's pattern — so grep the literal here.)
open_blocked() {
  grep -qE '^(- )?\[\?\] ' <(sed -n '/^## Open/,/^## [A-Z]/p' "$WORK/docs/Backlog.md")
}

# 1. Three consecutive generic failures arm the breaker; the 4th tick flips the
#    item to [?] and does NOT invoke claude.
@test "circuit breaker trips after 3 failures and stops calling claude" {
  make_claude fail_other

  # Ticks 1-3: claude is called each time, item stays open ([ ]), fails climb.
  for i in 1 2 3; do
    run_tick
    [ "$status" -eq 0 ]
    claude_was_called
    open_has_marker ' '          # unclaimed back to [ ] after each failure
    ! open_blocked               # not yet auto-blocked
    rm -f "$CLAUDE_CALLED"       # reset the call sentinel between ticks
  done

  # Failcount file records 3 consecutive (and 3 cumulative) for this item.
  [ -f "$WORK/$FAILCOUNTS" ]
  grep -q '"do the thing":{"count":3' "$WORK/$FAILCOUNTS"

  # Tick 4: breaker trips — item flips to [?], claude is NOT called.
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called
  open_blocked
  ! open_has_marker ' '
  [[ "$output" == *"circuit breaker"* ]]
}

# 2. The auto-block note names the trip kind + the recent failure reasons, and
#    the marker is [?].
@test "tripped item carries the circuit-breaker note + failure reasons" {
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  run_tick
  grep -qE '^(- )?\[\?\] do the thing — \[circuit-breaker\] auto-blocked \(consecutive 3/3\) after 3 failed attempt\(s\)' \
    "$WORK/docs/Backlog.md"
  # The last K=3 failure reasons are rendered into the note (decision #4).
  grep -q 'recent failures: claude exit 1 | claude exit 1 | claude exit 1' "$WORK/docs/Backlog.md"
}

# 3. A trip emits circuit_tripped and a tick_done(circuit_breaker) event.
@test "circuit trip emits structured events" {
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  run_tick
  grep -qE '"event":"circuit_tripped".*"item":"do the thing"' "$WORK/$EVENTS"
  grep -qE '"event":"tick_done".*"outcome":"circuit_breaker"' "$WORK/$EVENTS"
}

# 4. A successful tick resets the failure streak (no trip on later failures).
@test "successful tick clears the failure streak" {
  # Two failures, then a success — the success must zero the counter.
  make_claude fail_other
  run_tick; rm -f "$CLAUDE_CALLED"
  run_tick; rm -f "$CLAUDE_CALLED"
  grep -q '"do the thing":{"count":2' "$WORK/$FAILCOUNTS"

  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  open_has_marker 'x'
  # Counter for the item is gone (reset on success).
  ! grep -q '"do the thing"' "$WORK/$FAILCOUNTS"
}

# 5. The breaker is per-item: failures on one item don't block a different one.
@test "circuit breaker is keyed per item" {
  write_backlog_open "- [ ] alpha task" "- [ ] beta task"
  git -C "$WORK" commit -qam "two items"
  git -C "$WORK" push -q origin main

  # Fail the first item (alpha) three times — it's always the first match.
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done

  # Next tick trips on alpha (first eligible item) and blocks it.
  run_tick
  ! claude_was_called
  grep -qE '^(- )?\[\?\] alpha task' "$WORK/docs/Backlog.md"
  # beta is untouched and still open.
  grep -qE '^(- )?\[ \] beta task' "$WORK/docs/Backlog.md"
}

# ==========================================================================
# Retry budget — the CUMULATIVE sibling of the consecutive breaker
# ==========================================================================

# 6. With the consecutive threshold raised out of reach, the CUMULATIVE retry
#    budget still trips after RETRY_BUDGET total failed attempts (the flapping
#    case the consecutive counter would never catch). kind=retry_budget.
@test "retry budget trips on cumulative attempts when consecutive doesn't" {
  make_claude fail_other
  # CB threshold 99 (never trips); retry budget 3. Three fails accumulate.
  for i in 1 2 3; do
    run_tick CIRCUIT_BREAKER_THRESHOLD=99 RETRY_BUDGET=3
    [ "$status" -eq 0 ]
    claude_was_called
    ! open_blocked                 # consecutive never trips (threshold 99)
    rm -f "$CLAUDE_CALLED"
  done
  grep -q '"do the thing":{"count":3,"attempts":3' "$WORK/$FAILCOUNTS"

  # Tick 4: retry budget trips (attempts 3 >= 3) even though consecutive (3) < 99.
  run_tick CIRCUIT_BREAKER_THRESHOLD=99 RETRY_BUDGET=3
  [ "$status" -eq 0 ]
  ! claude_was_called
  open_blocked
  grep -q 'auto-blocked (retry-budget 3/3)' "$WORK/docs/Backlog.md"
  grep -qE '"event":"circuit_tripped".*"kind":"retry_budget"' "$WORK/$EVENTS"
}

# 7. A clean-but-INCOMPLETE tick (claude does nothing, item stays [~]) resets the
#    CONSECUTIVE streak to 0 but PRESERVES the cumulative attempts — exactly the
#    state that lets a flapping item climb toward the budget without the
#    consecutive counter ever reaching K.
@test "clean incomplete tick zeroes consecutive but preserves cumulative attempts" {
  make_claude fail_other
  run_tick; rm -f "$CLAUDE_CALLED"
  run_tick; rm -f "$CLAUDE_CALLED"
  grep -q '"do the thing":{"count":2,"attempts":2' "$WORK/$FAILCOUNTS"

  # A no-op success: claude exits 0 changing nothing; the item stays claimed [~]
  # and is NOT completed, so the consecutive streak resets but attempts survive.
  make_claude noop
  run_tick
  [ "$status" -eq 0 ]
  grep -q '"do the thing":{"count":0,"attempts":2' "$WORK/$FAILCOUNTS"
}

# 8. A completion ([x]) does the FULL reset — cumulative attempts cleared too, so
#    a later re-add of the same title starts the budget fresh.
@test "completion clears the cumulative attempts (full reset)" {
  make_claude fail_other
  run_tick; rm -f "$CLAUDE_CALLED"
  run_tick; rm -f "$CLAUDE_CALLED"
  grep -q '"do the thing":{"count":2,"attempts":2' "$WORK/$FAILCOUNTS"
  make_claude complete
  run_tick
  open_has_marker 'x'
  ! grep -q '"do the thing"' "$WORK/$FAILCOUNTS"   # key gone — attempts cleared
}

# ==========================================================================
# Surfacing + per-item override + fail-open
# ==========================================================================

# Poll for a backgrounded notify POST (notify_send backgrounds curl). ~3s budget.
wait_for_post() {
  local i; for i in $(seq 1 30); do [ -s "$HOME/.posted" ] && return 0; sleep 0.1; done; return 1
}
# curl shim: records Slack POSTs to $HOME/.posted, answers heartbeat reads 404.
make_cb_curl() {
  : > "$HOME/.posted"
  cat > "$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
data=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in --data|-d) data="$a";; esac
  case "$a" in http*) url="$a";; esac
  prev="$a"
done
case "$url" in
  *heartbeat*) printf '%s\n%s' '{"found":false}' 404 ;;
  *)           printf '%s\n' "$data" >> "$HOME/.posted"; printf '%s\n%s' ok 200 ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# 9. A trip SURFACES via notify_send (the item's "and surface it" half) — one
#    push to the configured channel naming the blocked item + the trip detail.
@test "circuit trip fires a notify_send alert" {
  make_cb_curl
  mkdir -p "$HOME/.claude"
  printf '{\n  "slack_webhook_url": "http://localhost/slack-cb",\n  "local_notify": false\n}\n' \
    > "$HOME/.claude/agent-notify.json"
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  run_tick                         # trips
  wait_for_post
  grep -q 'auto-blocked' "$HOME/.posted"
  grep -q 'do the thing' "$HOME/.posted"
}

# 10. A per-item override in backlog-guards.json raises the bar: with the
#     threshold bumped to 5 for this item, three failures do NOT trip and claude
#     is still called on the 4th tick (the default-3 breaker would have tripped).
@test "per-item override in backlog-guards.json raises the threshold" {
  printf '{ "items": { "do the thing": { "circuit_breaker_threshold": 5 } } }\n' \
    > "$WORK/.claude/backlog-guards.json"
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  # 4th tick: 3 consecutive < the overridden 5, attempts 3 < default budget 6 ⇒
  # no trip; claude is invoked again.
  run_tick
  claude_was_called
  ! open_blocked
}

# 11. FAIL-OPEN: a malformed backlog-guards.json must NOT disable the breaker —
#     resolve_guards falls back to the env defaults, so it still trips at 3.
@test "malformed guards file fails open to the default thresholds" {
  printf 'this is not json {{{\n' > "$WORK/.claude/backlog-guards.json"
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  run_tick
  ! claude_was_called
  open_blocked                     # default threshold 3 still in force
}
