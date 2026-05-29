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

  # Failcount file records 3 for this item.
  [ -f "$WORK/$FAILCOUNTS" ]
  grep -q '"do the thing":3' "$WORK/$FAILCOUNTS"

  # Tick 4: breaker trips — item flips to [?], claude is NOT called.
  run_tick
  [ "$status" -eq 0 ]
  ! claude_was_called
  open_blocked
  ! open_has_marker ' '
  [[ "$output" == *"circuit breaker"* ]]
}

# 2. The auto-block note is appended to the item line and the marker is [?].
@test "tripped item carries the circuit-breaker note" {
  make_claude fail_other
  for i in 1 2 3; do run_tick; rm -f "$CLAUDE_CALLED"; done
  run_tick
  grep -qE '^(- )?\[\?\] do the thing — \[circuit-breaker\] auto-blocked after 3 failed attempts$' \
    "$WORK/docs/Backlog.md"
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
  grep -q '"do the thing":2' "$WORK/$FAILCOUNTS"

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
