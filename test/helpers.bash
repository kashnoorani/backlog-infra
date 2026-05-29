# Shared bats helpers for the backlog-agent driver tests.
#
# Every test runs against a HERMETIC fixture: a throwaway working repo with a
# local bare remote (no network, no GitHub), a no-op status hook, and PATH
# shims for `claude` and `ssh` so the driver never reaches the real tools.
# The driver is exercised black-box via `backlog-agent tick`.

AGENT_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agent"

# Create the fixture in the per-test temp dir and cd into the work repo.
# Sets globals: REMOTE, WORK, SHIM, CLAUDE_CALLED.
_setup_repo() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  SHIM="$BATS_TEST_TMPDIR/shim"
  CLAUDE_CALLED="$BATS_TEST_TMPDIR/claude_called"
  export CLAUDE_CALLED

  # Deterministic, prompt-free git.
  export GIT_TERMINAL_PROMPT=0
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

  # PATH shims (claude + ssh) take precedence over anything real.
  mkdir -p "$SHIM"
  make_claude noop          # default stub; tests override as needed
  cat > "$SHIM/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake ssh: check_github_ssh greps for "successfully authenticated"; we print
# nothing and exit fast so the precheck returns non-zero instantly (no network).
exit 0
EOF
  chmod +x "$SHIM/ssh"
  export PATH="$SHIM:$PATH"

  git init -q --bare -b main "$REMOTE"

  git init -q -b main "$WORK"
  mkdir -p "$WORK/docs" "$WORK/scripts" "$WORK/.claude"
  # No-op status hook: the driver runs `node "$HOOK"`; exit 0 does nothing.
  printf 'process.exit(0)\n' > "$WORK/scripts/backlog-agent-status.mjs"
  write_backlog_open "- [ ] do the thing"

  git -C "$WORK" add -A
  git -C "$WORK" commit -qm "init"
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" push -qu origin main

  cd "$WORK"
}

# Write a minimal backlog (## Open holds exactly the lines passed) into the
# given repo dir's docs/Backlog.md.
write_backlog_open_in() {
  local dir="$1"; shift
  {
    echo "# Test backlog"
    echo
    echo "## Thinking"
    echo
    echo "## Open"
    local line
    for line in "$@"; do echo "$line"; done
    echo
    echo "## Done"
  } > "$dir/docs/Backlog.md"
}

# Same, targeting the work repo (the common case).
write_backlog_open() { write_backlog_open_in "$WORK" "$@"; }

# Generate the `claude` PATH stub. Modes:
#   noop      — record the call, change nothing, exit 0
#   complete  — record, make a real change, flip first [~]→[x], commit, exit 0
#   fail_limit— record, print an Anthropic plan-limit signature, exit 1
#   fail_other— record, print an unrelated error, exit 1
make_claude() {
  local mode="$1"
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
# Records invocation so tests can assert claude was / was not called.
touch "\${CLAUDE_CALLED:-/dev/null}"
mode="$mode"
EOF
  cat >> "$SHIM/claude" <<'EOF'
case "$mode" in
  noop) exit 0 ;;
  complete)
    # Emulate a successful tick: a real file change + move the claimed item to
    # done (flip the first [~] in ## Open to [x]), then commit (scoped add).
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
    exit 0 ;;
  fail_limit)
    echo "Error: You've hit your usage limit. resets 5:30pm" >&2
    exit 1 ;;
  fail_other)
    echo "Error: something unrelated broke" >&2
    exit 1 ;;
esac
EOF
  chmod +x "$SHIM/claude"
}

# Run one tick (black-box). Extra args become leading `env VAR=val` pairs.
#   run_tick                 -> backlog-agent tick
#   run_tick STARTUP_RECLAIM=1 -> env STARTUP_RECLAIM=1 backlog-agent tick
run_tick() {
  run env "$@" bash "$AGENT_BIN" tick
}

# True if claude was invoked during the last tick.
claude_was_called() { [ -f "$CLAUDE_CALLED" ]; }

# True if the ## Open section contains an item with the given marker char.
# Portable (no gawk match() arrays). $1 = marker, e.g. '~' or ' ' or 'x'.
open_has_marker() {
  grep -qE "^(- )?\\[$1\\] " <(sed -n '/^## Open/,/^## [A-Z]/p' "$WORK/docs/Backlog.md")
}
