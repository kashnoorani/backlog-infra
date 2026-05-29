#!/usr/bin/env bats
#
# `backlog-agents sync` canary + version-skew gate (W3).
# Because bin/ is SHARED, `sync` restarting every agent is how one bad driver
# commit goes fleet-wide. The gate sits in front of the RESTART: it refuses to
# restart agents onto a driver that (a) differs from origin/main's bin (skew) or
# (b) hasn't passed `canary`. These tests exercise the gate DECISION via the
# side-effect-free `sync --gate-only` (no pull, no restart, no snapshot) against a
# throwaway backlog-infra repo with a real `origin` so the skew path is live.
# The heavy self-test is irrelevant here (we drive canary state directly); doctor
# is disabled via CANARY_DOCTOR=0.

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  INFRA="$HOME/dev/projects/active/backlog-infra"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  mkdir -p "$INFRA/bin" "$HOME/.claude"
  git init -q "$INFRA"
  git -C "$INFRA" config user.email t@e.co
  git -C "$INFRA" config user.name t
  printf '#driver v1\n' > "$INFRA/bin/backlog-agent"
  git -C "$INFRA" add bin/backlog-agent
  git -C "$INFRA" commit -qm "driver v1"
  # a real origin so origin/main bin SHA is resolvable (version-skew path)
  git init -q --bare "$ORIGIN"
  git -C "$INFRA" remote add origin "$ORIGIN"
  git -C "$INFRA" push -q -u origin HEAD:main
  export CANARY_STATE_FILE="$HOME/.claude/backlog-canary.json"
  export CANARY_DOCTOR=0
}

cur_sha() { git -C "$INFRA" log -1 --format=%h -- bin; }

# record a canary pass for whatever the current driver SHA is
pass_canary() { env CANARY_SELFTEST_CMD=true bash "$AGENTS_BIN" canary >/dev/null; }

# commit a new driver locally WITHOUT pushing it to origin → version-skew
bump_driver_local() {
  printf '#driver v2\n' >> "$INFRA/bin/backlog-agent"
  git -C "$INFRA" add bin/backlog-agent
  git -C "$INFRA" commit -qm "driver v2"
}

# 1. Blocks when the current driver has no recorded canary pass (no skew).
@test "gate BLOCKS: driver has not passed canary" {
  run bash "$AGENTS_BIN" sync --gate-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"has not passed canary"* ]]
}

# 2. Passes when canary is green for the current SHA and there's no skew.
@test "gate PASSES: canary green + no skew" {
  pass_canary
  run bash "$AGENTS_BIN" sync --gate-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe to restart"* ]]
}

# 3. Blocks on version-skew even when the (local) driver passed canary —
#    skew is checked first, so an unpushed driver can never be restarted onto.
@test "gate BLOCKS: version-skew (local bin != origin/main bin)" {
  bump_driver_local
  pass_canary                      # canary green for v2 locally...
  run bash "$AGENTS_BIN" sync --gate-only
  [ "$status" -eq 1 ]              # ...but origin is still v1 → skew wins
  [[ "$output" == *"version-skew"* ]]
}

# 4. Once the validated driver is pushed (skew cleared) the gate opens.
@test "gate PASSES after the canary'd driver is pushed to origin" {
  bump_driver_local
  pass_canary
  git -C "$INFRA" push -q origin HEAD:main
  run bash "$AGENTS_BIN" sync --gate-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"safe to restart"* ]]
}

# 5. Fail-safe: if the driver SHA can't be determined, block.
@test "gate BLOCKS (fail-safe): no backlog-infra git" {
  rm -rf "$INFRA/.git"
  run bash "$AGENTS_BIN" sync --gate-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot determine"* ]]
}

# 6. --gate-only has no side effects: it never restarts or snapshots.
@test "--gate-only is side-effect-free (no 'restarting agents' output)" {
  pass_canary
  run bash "$AGENTS_BIN" sync --gate-only
  [[ "$output" != *"restarting agents"* ]]
  [[ "$output" != *"agent(s) restarted"* ]]
}
