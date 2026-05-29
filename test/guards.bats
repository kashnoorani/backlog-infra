#!/usr/bin/env bats
#
# Guards 2 & 3 (W2) for bin/backlog-agent.
#   Guard 2 — diff-size guardrail: a tick whose commit touches more than
#             DIFF_SIZE_MAX_FILES (20) files or DIFF_SIZE_MAX_LINES (400)
#             lines emits diff_oversize + a warning (no auto-revert).
#   Guard 3 — protected-path: a tick that modifies a load-bearing infra file
#             emits protected_path_touched + a warning (no auto-revert).
# Hermetic scratch repo — see helpers.bash.

load 'helpers'

setup() { _setup_repo; }

EVENTS=".claude/backlog-agent-events.jsonl"

# Write a custom claude stub: runs the caller-supplied shell BODY (which creates
# the files the test wants in the work commit), then completes the claimed item
# (flips first [~]→[x]) and commits. The commit is SCOPED to docs/Backlog.md
# plus whatever the BODY created — deliberately NOT `git add -A`, so the
# driver's own .claude/ state (the event log this test asserts on) stays
# untracked and survives _post_tick_cleanup's auto-stash. BODY runs with cwd =
# work repo and must echo the repo-relative paths it created, one per line, on
# fd 3 (handled here via PATHS_FILE) so we know what to stage.
_make_claude_committing() {
  local body="$1"
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
touch "\${CLAUDE_CALLED:-/dev/null}"
EOF
  cat >> "$SHIM/claude" <<EOF
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
# Stage the backlog + every path the BODY created/modified, but never .claude/
# (the driver's ephemeral state, incl. the event log this test inspects).
git add docs/Backlog.md
git ls-files --others --modified --exclude-standard \
  | grep -vE '^\.claude/' \
  | grep -vE '^docs/Backlog\.md$' \
  | while IFS= read -r f; do git add "$f"; done
git commit -qm "work: did the thing"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# Guard 2a: a commit over the file-count limit trips the diff-size guardrail.
@test "diff-size guardrail fires when too many files change" {
  _make_claude_committing '
    for i in $(seq 1 25); do echo "x" > "file_$i.txt"; done
  '
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-size guardrail"* ]]
  grep -qE '"event":"diff_oversize".*"item":"do the thing"' "$WORK/$EVENTS"
  # 25 new files + docs/Backlog.md = 26, well over the 20-file limit.
  grep -qE '"event":"diff_oversize".*"files":2[0-9]' "$WORK/$EVENTS"
  grep -qE '"event":"diff_oversize".*"max_files":20' "$WORK/$EVENTS"
}

# Guard 2b: a commit over the line-count limit trips the diff-size guardrail.
@test "diff-size guardrail fires when too many lines change" {
  _make_claude_committing '
    { for i in $(seq 1 500); do echo "line $i"; done; } > big.txt
  '
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"diff-size guardrail"* ]]
  grep -qE '"event":"diff_oversize"' "$WORK/$EVENTS"
  # 500 added lines is over the 400 limit.
  grep -qE '"event":"diff_oversize".*"lines":5[0-9][0-9]' "$WORK/$EVENTS"
}

# Guard 2c: a small commit does NOT trip the guardrail.
@test "diff-size guardrail stays quiet for a small change" {
  make_claude complete
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"diff-size guardrail"* ]]
  ! grep -qE '"event":"diff_oversize"' "$WORK/$EVENTS" 2>/dev/null
}

# Guard 3a: touching a protected path flags protected_path_touched.
@test "protected-path guardrail fires when a protected file is modified" {
  _make_claude_committing '
    mkdir -p bin
    echo "tampered" >> bin/backlog-agent
  '
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" == *"protected-path guardrail"* ]]
  grep -qE '"event":"protected_path_touched".*"paths":"bin/backlog-agent"' "$WORK/$EVENTS"
}

# Guard 3b: a normal commit that touches no protected path stays quiet.
@test "protected-path guardrail stays quiet for ordinary files" {
  make_claude complete   # touches implemented.txt + docs/Backlog.md only
  run_tick
  [ "$status" -eq 0 ]
  [[ "$output" != *"protected-path guardrail"* ]]
  ! grep -qE '"event":"protected_path_touched"' "$WORK/$EVENTS" 2>/dev/null
}
