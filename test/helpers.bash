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

  # Redirect HOME to a scratch dir (as _setup_status_repo does) so the reaper's
  # D1 heartbeat read controls $HOME/.config/backlog/health-key instead of the
  # real user key, and HOME-rooted lookups (compact script) resolve hermetically.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  # Keep the suite hermetic: the driver reads the fleet-freeze flag at
  # top-of-tick via a real `curl` GET (bin/backlog-agent _d1_freeze_get). Disable
  # that read by default so ordinary tick tests never reach the network;
  # fleet-freeze.bats re-enables it (FREEZE_DISABLE=0) behind a curl stub.
  export FREEZE_DISABLE=1

  # Same for the account-cooldown read/publish (bin/backlog-agent
  # _d1_account_cooldown_epoch / _d1_publish_cooldown): disabled by default so
  # ordinary tick tests never reach the network; account-cooldown.bats re-enables
  # it (ACCOUNT_COOLDOWN_DISABLE=0) behind a curl stub.
  export ACCOUNT_COOLDOWN_DISABLE=1

  # Secret-scanning pre-push gate (bin/backlog-agent ensure_prepush_hook + Guard
  # 5): disabled by default so ordinary tick tests don't install a pre-push hook
  # into the throwaway repo or run a post-push scan; secret-scan.bats re-enables
  # it (SECRET_SCAN_DISABLE=0).
  export SECRET_SCAN_DISABLE=1

  # Per-project budget enforcement (bin/backlog-agent _budget_over_cap): disabled
  # by default so ordinary tick tests never read the budgets file / ledger and
  # never pause; per-project-budget.bats re-enables it (BUDGET_DISABLE=0) with a
  # seeded budgets file + history ledger.
  export BUDGET_DISABLE=1

  # Per-item token/turn/spend ceiling (bin/backlog-agent resolve_ceiling + the
  # post-hoc Guard 6): disabled by default so ordinary tick tests never read a
  # transcript, never inject --max-budget-usd, and never reopen on usage;
  # per-item-ceiling.bats re-enables it (CEILING_DISABLE=0) with a seeded
  # transcript + ceilings file.
  export CEILING_DISABLE=1

  # Backlog-injection provenance guard (bin/backlog-agent _relocate_injected_open_items
  # + Guard 7): disabled by default so ordinary tick tests never relocate
  # agent-added ## Open items; injection-guard.bats re-enables it
  # (INJECTION_GUARD_DISABLE=0).
  export INJECTION_GUARD_DISABLE=1

  # Remote-unblock poll-and-apply (bin/backlog-agent process_unblock_requests /
  # _d1_unblock_get): disabled by default so ordinary tick tests never reach the
  # network; remote-unblock.bats re-enables it (REMOTE_UNBLOCK_DISABLE=0) behind a
  # curl stub + seeded /api/unblock response.
  export REMOTE_UNBLOCK_DISABLE=1

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
#   hang      — record, then exec `sleep` far longer than any test timeout so
#               the driver's wall-clock watchdog (CLAUDE_TIMEOUT_SECS) must kill
#               it; `exec` makes the sleep claude's own PID so the kill is clean.
# $2 (fail_limit only) overrides the reset time in the plan-limit signature
# (default "5:30pm") so tests can exercise the time parser.
make_claude() {
  local mode="$1" reset="${2:-5:30pm}"
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
# Records invocation so tests can assert claude was / was not called.
touch "\${CLAUDE_CALLED:-/dev/null}"
mode="$mode"
reset="$reset"
EOF
  cat >> "$SHIM/claude" <<'EOF'
case "$mode" in
  noop) exit 0 ;;
  hang) exec sleep 30 ;;
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
    echo "Error: You've hit your usage limit. resets $reset" >&2
    exit 1 ;;
  fail_other)
    echo "Error: something unrelated broke" >&2
    exit 1 ;;
esac
EOF
  chmod +x "$SHIM/claude"
}

# Generate the `curl` PATH stub for heartbeat-read tests (reaper liveness).
# The reaper's _d1_heartbeat_epoch calls `curl -s -m 5 … -w '\n%{http_code}'`,
# so the shim emits the JSON body followed by a newline + the HTTP status code
# on the last line. Modes:
#   live        -> 200, found:true, heartbeat_epoch = NOW        (daemon alive)
#   dead        -> 200, found:true, heartbeat_epoch = NOW-7200    (>90m, dead)
#   notfound    -> 404, found:false
#   unreachable -> exit 7 (curl "couldn't connect"), no body
#   byhost      -> 200; dead heartbeat if the queried &host= contains "dead",
#                  live otherwise (lets one tick see one owner dead, one alive).
# Also seeds a health-key so the bearer-auth branch is exercised.
make_curl() {
  local mode="$1"
  mkdir -p "$HOME/.config/backlog"
  echo testkey > "$HOME/.config/backlog/health-key"
  cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
mode="$mode"
now="\$(date +%s)"
EOF
  cat >> "$SHIM/curl" <<'EOF'
# Emulate body + status line (the reaper appends -w $'\n%{http_code}').
emit() { printf '%s\n%s' "$1" "$2"; }   # $1=body, $2=http_code
case "$mode" in
  live)        emit "{\"found\":true,\"heartbeat_epoch\":$now}" 200 ;;
  dead)        emit "{\"found\":true,\"heartbeat_epoch\":$((now-7200))}" 200 ;;
  notfound)    emit "{\"found\":false}" 404 ;;
  unreachable) exit 7 ;;   # curl: (7) Failed to connect
  byhost)
    # Pick the requested host out of the &host= query param across curl's args.
    q="$(printf '%s\n' "$@" | sed -nE 's|.*[?&]host=([^&]*).*|\1|p' | head -n1)"
    case "$q" in
      *dead*) emit "{\"found\":true,\"heartbeat_epoch\":$((now-7200))}" 200 ;;
      *)      emit "{\"found\":true,\"heartbeat_epoch\":$now}" 200 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$SHIM/curl"
}

# --- Layer 3: alternative-agent fallback fixtures ---
# Generate a fake fallback agent on PATH (default name "fakeagent"). It records
# its invocation to $FALLBACK_CALLED and emulates a successful tick (real file
# change + flip the first [~]→[x] + scoped commit), so a fallback tick lands a
# completion exactly like the `complete` claude stub. The tick prompt is passed
# as the agent's final arg by build_fallback_cmd; the stub ignores it.
#   $1 = agent command name (default "fakeagent")
make_fallback_agent() {
  local name="${1:-fakeagent}"
  FALLBACK_CALLED="$BATS_TEST_TMPDIR/fallback_called"
  export FALLBACK_CALLED
  cat > "$SHIM/$name" <<EOF
#!/usr/bin/env bash
touch "\${FALLBACK_CALLED:-/dev/null}"
EOF
  cat >> "$SHIM/$name" <<'EOF'
awk '
  BEGIN{in_open=0; done=0}
  /^## Open/{in_open=1; print; next}
  /^## [A-Z]/{in_open=0; print; next}
  in_open && !done && /^(- )?\[~\] /{ sub(/\[~\]/,"[x]"); done=1 }
  {print}
' docs/Backlog.md > docs/Backlog.md.tmp && mv docs/Backlog.md.tmp docs/Backlog.md
echo "fallback work" > fallback.txt
git add fallback.txt docs/Backlog.md
git commit -qm "work: fallback did the thing"
exit 0
EOF
  chmod +x "$SHIM/$name"
}

# Write ~/.claude/agent-fallback.json (HOME is the per-test scratch dir). The
# command runs the given agent name on the prompt; `available_when` defaults to
# a passing test ("true") but can be overridden (e.g. "false") to exercise the
# gate.
#   $1 = agent command name (default "fakeagent")
#   $2 = available_when shell test (default "true")
write_fallback_config() {
  local name="${1:-fakeagent}" guard="${2:-true}"
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/agent-fallback.json" <<EOF
{ "fallback": {
    "command": ["$name", "run", "{prompt}"],
    "available_when": "$guard",
    "name": "$name" } }
EOF
}

# True if the fallback agent was invoked during the last tick.
fallback_was_called() { [ -f "${FALLBACK_CALLED:-/nonexistent}" ]; }

# Run one tick (black-box). Extra args become leading `env VAR=val` pairs.
#   run_tick                 -> backlog-agent tick
#   run_tick STARTUP_RECLAIM=1 -> env STARTUP_RECLAIM=1 backlog-agent tick
run_tick() {
  run env "$@" bash "$AGENT_BIN" tick
}

# True if claude was invoked during the last tick.
claude_was_called() { [ -f "$CLAUDE_CALLED" ]; }

# Fixture for testing the status hook (bin/backlog-agent-status.mjs) directly.
# Mirrors prod: the shared backlog-status.json is gitignored, while the per-host
# status file and history.jsonl are tracked. HOME is redirected to an empty dir
# so the hook finds no transcript (→ zero usage) and no real user config.
# Sets globals: REMOTE, WORK, HOOK_BIN.
_setup_status_repo() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  WORK="$BATS_TEST_TMPDIR/work"
  HOOK_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agent-status.mjs"

  export GIT_TERMINAL_PROMPT=0
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  export HOME="$BATS_TEST_TMPDIR/home"   # empty → no transcript, no user config
  mkdir -p "$HOME"

  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$WORK"
  mkdir -p "$WORK/docs" "$WORK/.claude"
  write_backlog_open_in "$WORK" "- [ ] do the thing"
  # Mirror prod .gitignore: ignore the shared status file + logs/locks; track
  # the per-host status file and the append-only history.
  cat > "$WORK/.gitignore" <<'EOF'
.claude/backlog-agent.log
.claude/backlog-agent.lock/
.claude/backlog-status.json
EOF
  git -C "$WORK" add -A
  git -C "$WORK" commit -qm "init"
  git -C "$WORK" remote add origin "$REMOTE"
  git -C "$WORK" push -qu origin main
  cd "$WORK"
}

# Invoke the real status hook. Extra args are appended.
run_hook() {
  run env node "$HOOK_BIN" --item "do the thing" --exit-code 0 --mode loop \
    --pre-head "$(git -C "$WORK" rev-parse HEAD)" --pulled 0 "$@"
}

# True if the ## Open section contains an item with the given marker char.
# Portable (no gawk match() arrays). $1 = marker, e.g. '~' or ' ' or 'x'.
open_has_marker() {
  grep -qE "^(- )?\\[$1\\] " <(sed -n '/^## Open/,/^## [A-Z]/p' "$WORK/docs/Backlog.md")
}
