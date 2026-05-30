#!/usr/bin/env bats
#
# Deny-by-default autonomous tool/permission profile (W1, docs/threat-model.md §5 /
# docs/tool-profile.md) — the PREVENTIVE input-side complement to Guard 7 + the
# §4.3 prompt firewall. When AUTONOMOUS_TOOL_PROFILE=1 the driver injects a
# constrained `--settings` JSON into the autonomous `claude -p` invocation so an
# injection that slips past the firewall still can't reach the network, read
# secrets, or rewrite the shared driver. It emits ONLY permissions.deny (deny wins
# over allow + layers onto the daemon's config), so the headless auto-accept is
# untouched.
#
# The profile is OPT-IN (default 0); helpers pin it to 0 so ordinary tick tests are
# inert. These tests set AUTONOMOUS_TOOL_PROFILE=1 and assert on claude's argv,
# captured via a recording PATH shim (same pattern as per-item-ceiling.bats).

load 'helpers'

# Record claude's argv (one element per line) so we can assert the injected flags.
_make_claude_recordargs() {
  cat > "$SHIM/claude" <<EOF
#!/usr/bin/env bash
touch "\${CLAUDE_CALLED:-/dev/null}"
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/claude_args"
exit 0
EOF
  chmod +x "$SHIM/claude"
}

# Extract the JSON string passed right after the `--settings` flag in the recorded
# argv. Each argv element is on its own line, so the line following `--settings` is
# the inline settings JSON.
_settings_arg() {
  grep -A1 -x -- '--settings' "$BATS_TEST_TMPDIR/claude_args" | tail -n1
}

# ==========================================================================
# Opt-in gating — the profile is absent by default, present when enabled
# ==========================================================================

# 1. Default (off): no --settings flag is injected (invocation unchanged).
@test "tool-profile: default OFF injects no --settings" {
  _setup_repo
  _make_claude_recordargs
  run_tick                                   # AUTONOMOUS_TOOL_PROFILE defaults 0
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/claude_args" ]     # claude was invoked
  ! grep -qx -- '--settings' "$BATS_TEST_TMPDIR/claude_args"
}

# 2. Enabled: a --settings flag carrying a JSON argument is injected.
@test "tool-profile: AUTONOMOUS_TOOL_PROFILE=1 injects --settings with JSON" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  grep -qx -- '--settings' "$BATS_TEST_TMPDIR/claude_args"
  # The settings argument is valid JSON with a permissions.deny array.
  _settings_arg | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);if(!Array.isArray(o.permissions.deny)||!o.permissions.deny.length)process.exit(1);})'
}

# 3. The injected settings carry NO defaultMode — it must only LAYER deny rules,
#    never clobber the daemon's headless auto-accept.
@test "tool-profile: injected settings set no defaultMode (deny-only layer)" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  ! _settings_arg | grep -q 'defaultMode'
  ! _settings_arg | grep -qE '"allow"|"ask"'
}

# ==========================================================================
# Deny-rule content — the three classes are all present
# ==========================================================================

# 4. Network egress: the model's WebFetch/WebSearch tools + common Bash exfil cmds.
@test "tool-profile: deny rules cover network egress (tools + Bash cmds)" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  local s; s="$(_settings_arg)"
  echo "$s" | grep -q '"WebFetch"'
  echo "$s" | grep -q '"WebSearch"'
  echo "$s" | grep -q 'Bash(curl:\*)'
  echo "$s" | grep -q 'Bash(wget:\*)'
}

# 5. Secret paths: reads of ~/.ssh, ~/.aws, the health-key dir, and .env are denied.
@test "tool-profile: deny rules cover secret-path reads" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  local s; s="$(_settings_arg)"
  echo "$s" | grep -q 'Read(~/.ssh/'
  echo "$s" | grep -q 'Read(~/.aws/'
  echo "$s" | grep -q 'Read(~/.config/backlog/'
  echo "$s" | grep -q 'Read(.env)'
}

# 6. Protected paths: every PROTECTED_PATHS file is Edit- AND Write-denied — the
#    preventive twin of the detective Guard 3.
@test "tool-profile: deny rules cover Edit+Write of each PROTECTED_PATHS file" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  local s; s="$(_settings_arg)"
  # The shared-driver files + CLAUDE.md/.gitignore (matches PROTECTED_PATHS).
  for p in bin/backlog-agent bin/backlog-agent-status.mjs release.mjs CLAUDE.md .gitignore; do
    echo "$s" | grep -qF "Edit($p)"
    echo "$s" | grep -qF "Write($p)"
  done
}

# ==========================================================================
# Composition + argv shape
# ==========================================================================

# 7. The profile composes with the per-item --max-budget-usd cap, and the prompt
#    stays the LAST argv element (the settings JSON must not displace it).
@test "tool-profile: composes with --max-budget-usd; prompt stays last" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1 CEILING_DISABLE=0 MAX_BUDGET_USD_PER_TICK=5
  [ "$status" -eq 0 ]
  grep -qx -- '--settings' "$BATS_TEST_TMPDIR/claude_args"
  grep -qx -- '--max-budget-usd' "$BATS_TEST_TMPDIR/claude_args"
  # The settings JSON is on its own line; it must NOT be the final argv line.
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/claude_args")" != "$(_settings_arg)" ]
}

# 8. A tool_profile_applied telemetry event is logged when the profile is applied.
@test "tool-profile: logs tool_profile_applied when enabled" {
  _setup_repo
  _make_claude_recordargs
  run_tick AUTONOMOUS_TOOL_PROFILE=1
  [ "$status" -eq 0 ]
  grep -q '"event":"tool_profile_applied"' "$WORK/.claude/backlog-agent-events.jsonl"
}

# 9. Disabled: no tool_profile_applied event (belt-and-suspenders for test 1).
@test "tool-profile: no tool_profile_applied event when disabled" {
  _setup_repo
  _make_claude_recordargs
  run_tick
  [ "$status" -eq 0 ]
  ! grep -q '"event":"tool_profile_applied"' "$WORK/.claude/backlog-agent-events.jsonl" 2>/dev/null
}
