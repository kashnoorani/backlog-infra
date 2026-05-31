#!/usr/bin/env bats
#
# Guard 8 (W2): post-completion semantic review (docs/post-completion-review.md).
#
# A green gate (Guard 4) proves a completed tick BUILDS; it does not prove the diff
# MATCHES the item's stated intent (the canonical failure: a tick "edits the backlog"
# but also drops an unrelated [?] item — nothing breaks, so the build gate is blind).
# When POST_COMPLETION_REVIEW=1, a completed tick gets a cheap haiku review of
# work_base..work_head vs the item intent and flags mismatches. ANNOTATE-ONLY: it
# logs + notifies, the [x] STANDS (no reopen). Opt-in per project via the per-machine
# marker ~/.claude/post-review/<project>.on (threaded into the daemon plist).
#
# This file covers:
#   * post_review_plist_env (bin/_lib.sh) — per-project marker → launchd env snippet.
#   * the end-to-end Guard-8 path through `backlog-agent tick`, driven by a claude
#     shim that COMPLETES the work tick AND answers the review call. The work tick
#     and the review call are distinguished by the exact `--model` flag, which only
#     the review invocation passes (the work tick uses `--fallback-model`).

load helpers

LIB="${BATS_TEST_DIRNAME}/../bin/_lib.sh"
EVENTS=".claude/backlog-agent-events.jsonl"

setup() {
  _setup_repo
  # Re-enable the pass for this file (helpers pins it off by default for hermeticity).
  export POST_COMPLETION_REVIEW=1
}

# A claude shim that plays BOTH roles in a reviewed tick:
#   * the work tick (prompt as last arg, no `--model`): complete the claimed item
#     (flip the first [~]→[x] in ## Open) + a real file change + scoped commit.
#   * the review call (mine: `--model claude-haiku-4-5`, prompt on stdin): emit the
#     verdict block from $REVIEW_OUT.
# $REVIEW_OUT (env) is the two-line verdict the review call prints; default MATCH.
write_reviewing_claude() {
  cat > "$SHIM/claude" <<'EOF'
#!/usr/bin/env bash
touch "${CLAUDE_CALLED:-/dev/null}"
# The review invocation is the only one passing an exact `--model` flag.
is_review=0
for a in "$@"; do [[ "$a" == "--model" ]] && is_review=1; done
if [[ "$is_review" == "1" ]]; then
  printf '%s\n' "${REVIEW_OUT:-VERDICT: MATCH
REASON: the diff fulfils the item}"
  exit 0
fi
# Work tick: complete the claimed item + commit.
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[x]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
echo implemented > implemented.txt
git add implemented.txt docs/Backlog.md
git commit -qm "work: did the thing"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# ==========================================================================
# post_review_plist_env — per-project marker gates the launchd env snippet
# ==========================================================================

@test "plist-env: no marker → empty (plist byte-identical to pre-flip form)" {
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME/.claude/post-review"
  run bash -c '. "$1"; post_review_plist_env "$2"' _ "$LIB" "myproj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plist-env: marker present → emits POST_COMPLETION_REVIEW=1 env block" {
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME/.claude/post-review"
  touch "$HOME/.claude/post-review/myproj.on"
  run bash -c '. "$1"; post_review_plist_env "$2"' _ "$LIB" "myproj"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '<key>POST_COMPLETION_REVIEW</key>'
  echo "$output" | grep -q '<string>1</string>'
}

@test "plist-env: marker for another project does not flip this one" {
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME/.claude/post-review"
  touch "$HOME/.claude/post-review/otherproj.on"
  run bash -c '. "$1"; post_review_plist_env "$2"' _ "$LIB" "myproj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ==========================================================================
# end-to-end Guard 8 through `backlog-agent tick`
# ==========================================================================

@test "flag off → no review runs (no post_completion_* event)" {
  write_reviewing_claude
  run_tick POST_COMPLETION_REVIEW=0
  [ "$status" -eq 0 ]
  open_has_marker x                                  # the work still completed
  run grep -c post_completion "$EVENTS"
  [ "$output" -eq 0 ]
}

@test "MATCH verdict → logs post_completion_match, item stays [x]" {
  write_reviewing_claude
  REVIEW_OUT=$'VERDICT: MATCH\nREASON: the diff fulfils the item' run_tick
  [ "$status" -eq 0 ]
  open_has_marker x
  grep -q post_completion_match "$EVENTS"
  ! grep -q post_completion_mismatch "$EVENTS"
}

@test "MISMATCH verdict → logs post_completion_mismatch, item STILL [x] (annotate-only)" {
  write_reviewing_claude
  REVIEW_OUT=$'VERDICT: MISMATCH\nREASON: dropped an unrelated blocked item' run_tick
  [ "$status" -eq 0 ]
  open_has_marker x                                  # annotate-only: the [x] stands
  ! open_has_marker ' '                              # NOT reopened to [ ]
  grep -q post_completion_mismatch "$EVENTS"
  grep -q 'dropped an unrelated blocked item' "$EVENTS"
}

@test "oversize diff → review SKIPPED + logged (no silent cap)" {
  write_reviewing_claude
  REVIEW_OUT=$'VERDICT: MISMATCH\nREASON: should not be consulted' \
    run_tick POST_REVIEW_MAX_LINES=1
  [ "$status" -eq 0 ]
  open_has_marker x
  grep -q post_completion_review_skipped "$EVENTS"
  grep -q 'oversize' "$EVENTS"
  # Skipped means the verdict was never consulted → no mismatch recorded.
  ! grep -q post_completion_mismatch "$EVENTS"
}

@test "unparseable verdict → logs review_error, no action (fail-open)" {
  write_reviewing_claude
  REVIEW_OUT=$'I cannot determine this.\nNo verdict here.' run_tick
  [ "$status" -eq 0 ]
  open_has_marker x
  grep -q 'post_completion_review_error' "$EVENTS"
  grep -q 'unparseable_verdict' "$EVENTS"
}
