#!/usr/bin/env bats
#
# `backlog-agents sync` must EXCLUDE the infra daemon from auto-restart (W3
# fleet-freeze sibling). The infra daemon self-modifies the shared bin/ and is
# operated interactively; without this carve-out, every sync re-bootstraps +
# un-holds it (the gap that overwrote an interactive session's in-flight edits).
#
# Hermetic: launchctl is PATH-shimmed (records bootstraps), fake plists + repos
# live under a scratch HOME. The restart path is driven via
# `sync --restart-only --no-gate` (no pull, no gate, no dashboard snapshot).

AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export USER="tu"
  ACTIVE="$HOME/dev/projects/active"
  mkdir -p "$HOME/Library/LaunchAgents" "$ACTIVE/backlog-infra/.claude" "$ACTIVE/foo/.claude"
  SHIM="$BATS_TEST_TMPDIR/shim"; mkdir -p "$SHIM"; export PATH="$SHIM:$PATH"
  RESTARTED="$BATS_TEST_TMPDIR/restarted"; : > "$RESTARTED"; export RESTARTED

  # Two canonical daemon plists: the infra daemon + one ordinary project.
  : > "$HOME/Library/LaunchAgents/com.${USER}.backlog-infra.backlog-agent.plist"
  : > "$HOME/Library/LaunchAgents/com.${USER}.foo.backlog-agent.plist"

  # launchctl shim: report every label "not loaded" (print → 1) so the loop goes
  # straight to bootstrap, and record each bootstrapped plist path.
  cat > "$SHIM/launchctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  print)     exit 1 ;;
  bootstrap) echo "\$3" >> "$RESTARTED"; exit 0 ;;
  *)         exit 0 ;;
esac
EOF
  chmod +x "$SHIM/launchctl"
}

# 1. By default the infra daemon is skipped; ordinary projects are restarted.
@test "sync excludes the infra daemon by default" {
  run env INFRA_PROJECT=backlog-infra bash "$AGENTS_BIN" sync --restart-only --no-gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"backlog-infra: skipping auto-restart"* ]]
  grep -q 'com.tu.foo.backlog-agent.plist' "$RESTARTED"
  ! grep -q 'backlog-infra' "$RESTARTED"
}

# 2. --include-infra opts the infra daemon back in.
@test "sync --include-infra restarts the infra daemon too" {
  run env INFRA_PROJECT=backlog-infra bash "$AGENTS_BIN" sync --restart-only --no-gate --include-infra
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipping auto-restart"* ]]
  grep -q 'com.tu.backlog-infra.backlog-agent.plist' "$RESTARTED"
  grep -q 'com.tu.foo.backlog-agent.plist' "$RESTARTED"
}

# 3. The exclusion keys off INFRA_PROJECT, not a hard-coded name.
@test "exclusion follows INFRA_PROJECT override" {
  run env INFRA_PROJECT=foo bash "$AGENTS_BIN" sync --restart-only --no-gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo: skipping auto-restart"* ]]
  grep -q 'com.tu.backlog-infra.backlog-agent.plist' "$RESTARTED"
  ! grep -q 'com.tu.foo.backlog-agent.plist' "$RESTARTED"
}
