#!/usr/bin/env bats
#
# `backlog-agents canary` — driver blast-radius gate (W3).
# Runs against a fake $HOME with a throwaway backlog-infra git repo so the
# driver bin SHA is deterministic. The heavy self-test suite is stubbed via
# CANARY_SELFTEST_CMD and doctor is disabled (CANARY_DOCTOR=0) so these tests
# exercise the record/gate MECHANISM, not the real suite.

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  INFRA="$HOME/dev/projects/active/backlog-infra"
  mkdir -p "$INFRA/bin" "$HOME/.claude"
  git init -q "$INFRA"
  git -C "$INFRA" config user.email t@e.co
  git -C "$INFRA" config user.name t
  printf '#driver v1\n' > "$INFRA/bin/backlog-agent"
  git -C "$INFRA" add bin/backlog-agent
  git -C "$INFRA" commit -qm "driver v1"
  export CANARY_STATE_FILE="$HOME/.claude/backlog-canary.json"
  export CANARY_DOCTOR=0   # isolate the gate mechanism from the fleet doctor scan
}

cur_sha() { git -C "$INFRA" log -1 --format=%h -- bin; }
bump_driver() {
  printf '#driver v2\n' >> "$INFRA/bin/backlog-agent"
  git -C "$INFRA" add bin/backlog-agent
  git -C "$INFRA" commit -qm "driver v2"
}

# 1. Passing checks record a pass keyed to the current driver SHA.
@test "canary records a pass for the current driver SHA" {
  run env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary
  [ "$status" -eq 0 ]
  [ -f "$CANARY_STATE_FILE" ]
  [ "$(jq -r .passed_sha "$CANARY_STATE_FILE")" = "$(cur_sha)" ]
  [[ "$output" == *"canary PASSED"* ]]
}

# 2. A failing self-test does NOT record a pass.
@test "failing self-test does not record a pass" {
  run env CANARY_SELFTEST_CMD=false bash "$AGENTS_BIN" canary
  [ "$status" -eq 1 ]
  [ ! -f "$CANARY_STATE_FILE" ]
  [[ "$output" == *"canary FAILED"* ]]
}

# 3. --check passes once the current driver has a recorded pass.
@test "--check passes when the canary covers the current driver" {
  env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary >/dev/null
  run bash "$AGENTS_BIN" canary --check
  [ "$status" -eq 0 ]
}

# 4. --check goes stale the moment the driver SHA changes (unvalidated driver).
@test "--check is stale after the driver bin changes" {
  env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary >/dev/null
  bump_driver
  run bash "$AGENTS_BIN" canary --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE"* ]]
}

# 5. --check on a never-run canary is stale (no false green before first run).
@test "--check with no prior canary is stale" {
  run bash "$AGENTS_BIN" canary --check
  [ "$status" -eq 1 ]
}

# 6. --json check emits machine-readable verdict.
@test "--check --json emits ok flag" {
  env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary >/dev/null
  run bash "$AGENTS_BIN" canary --check --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .ok)" = "true" ]
}
