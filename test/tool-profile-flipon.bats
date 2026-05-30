#!/usr/bin/env bats
#
# §5 tool-profile FLIP-ON — the operational turn-on of the deny-by-default profile
# (docs/tool-profile.md). The profile itself ships behind a default-OFF flag and is
# covered by tool-profile.bats (it asserts the injected --settings JSON shape). This
# file covers the flip-on machinery added on top:
#
#   * tool_profile_plist_env (bin/_lib.sh) — per-project marker → launchd env snippet
#     threaded into the daemon plist by do_install_daemon, so a canary survives a
#     `sync`/reinstall and rolls back by rm-ing the marker.
#   * backlog-agents tool-profile --show   — prints the deny-only --settings JSON.
#   * backlog-agents tool-profile --verify — LIVE enforcement spot-check. The hermetic
#     JSON-shape tests can't prove the CLI HONORS the deny set; --verify runs real
#     `claude -p` calls and asserts deny is enforced AND scoped. Here we drive it with
#     a claude shim that ENFORCES the deny set (→ PASS) and one that IGNORES it
#     (→ FAIL), proving the harness's oracle detects both directions.

LIB="${BATS_TEST_DIRNAME}/../bin/_lib.sh"
AGENTS_BIN="${BATS_TEST_DIRNAME}/../bin/backlog-agents"

# ==========================================================================
# tool_profile_plist_env — per-project marker gates the launchd env snippet
# ==========================================================================

@test "plist-env: no marker → empty (plist byte-identical to pre-flip form)" {
  local proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj/.claude"
  run bash -c '. "$1"; tool_profile_plist_env "$2"' _ "$LIB" "$proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plist-env: marker present → emits AUTONOMOUS_TOOL_PROFILE=1 env block" {
  local proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj/.claude"
  touch "$proj/.claude/tool-profile.on"
  run bash -c '. "$1"; tool_profile_plist_env "$2"' _ "$LIB" "$proj"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '<key>AUTONOMOUS_TOOL_PROFILE</key>'
  echo "$output" | grep -q '<string>1</string>'
}

# ==========================================================================
# tool-profile --show — deny-only JSON, no defaultMode/allow
# ==========================================================================

@test "tool-profile --show: emits valid deny-only settings JSON" {
  run bash "$AGENTS_BIN" tool-profile --show
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"permissions"'
  echo "$output" | grep -q '"deny"'
  ! echo "$output" | grep -q 'defaultMode'
  ! echo "$output" | grep -qE '"allow"|"ask"'
  # parses as JSON with a non-empty deny array
  echo "$output" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);if(!Array.isArray(o.permissions.deny)||!o.permissions.deny.length)process.exit(1);})'
}

# ==========================================================================
# tool-profile --verify — live enforcement spot-check, both directions
# ==========================================================================

# A claude shim that ENFORCES the injected deny set: it parses --settings, reads the
# target file out of the prompt, and refuses the action iff a matching Read()/Edit()
# rule is present (otherwise performs it). This is what a correct CLI does, so the
# harness must report PASS. $1=shim path.
_make_claude_enforcing() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "9.9.9 (shim)"; exit 0; }
# settings = arg after --settings ; prompt = last arg
settings=""; prompt="${!#}"
while [[ $# -gt 0 ]]; do [[ "$1" == "--settings" ]] && { settings="$2"; shift; }; shift; done
denied() { printf '%s' "$settings" | grep -qF "$1"; }
if [[ "$prompt" =~ ^Read\ the\ file\ ([^ ]+)\  ]]; then
  f="${BASH_REMATCH[1]}"
  if denied "Read($f)"; then echo "I can't do that: permission denied for Read($f)"; exit 0; fi
  cat "$f" 2>/dev/null; exit 0
fi
if [[ "$prompt" =~ containing\ exactly\ ([^ ]+)\ to\ the\ file\ ([^ ]+) ]]; then
  tok="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[2]%.}"   # strip trailing sentence period
  if denied "Edit($f)"; then echo "I can't do that: permission denied for Edit($f)"; exit 0; fi
  printf '%s\n' "$tok" >> "$f"; echo "done"; exit 0
fi
echo "no-op"; exit 0
EOF
  chmod +x "$1"
}

# A claude shim that IGNORES the deny set entirely (a CLI that does NOT honor
# permissions.deny): it always performs the action. The harness must report FAIL
# (the secret leaks + the protected file is written). $1=shim path.
_make_claude_ignoring() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "9.9.9 (shim)"; exit 0; }
prompt="${!#}"
if [[ "$prompt" =~ ^Read\ the\ file\ ([^ ]+)\  ]]; then
  cat "${BASH_REMATCH[1]}" 2>/dev/null; exit 0
fi
if [[ "$prompt" =~ containing\ exactly\ ([^ ]+)\ to\ the\ file\ ([^ ]+) ]]; then
  f="${BASH_REMATCH[2]%.}"; printf '%s\n' "${BASH_REMATCH[1]}" >> "$f"; echo "done"; exit 0
fi
echo "no-op"; exit 0
EOF
  chmod +x "$1"
}

@test "tool-profile --verify: PASS when the CLI enforces (and scopes) the deny set" {
  local shim="$BATS_TEST_TMPDIR/claude-enforce"
  _make_claude_enforcing "$shim"
  run env CLAUDE_BIN="$shim" bash "$AGENTS_BIN" tool-profile --verify
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'enforcement: PASS'
  echo "$output" | grep -q 'Read(.env).*DENIED'
  echo "$output" | grep -q 'Edit(bin/backlog-agent).*DENIED'
  echo "$output" | grep -q 'Read(ordinary.txt).*ALLOWED'
  echo "$output" | grep -q 'Edit(notes.txt).*ALLOWED'
}

@test "tool-profile --verify: FAIL when the CLI ignores the deny set (leak detected)" {
  local shim="$BATS_TEST_TMPDIR/claude-ignore"
  _make_claude_ignoring "$shim"
  run env CLAUDE_BIN="$shim" bash "$AGENTS_BIN" tool-profile --verify
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'enforcement: FAIL'
  echo "$output" | grep -q 'LEAKED'
}

@test "tool-profile --verify: errors cleanly when the CLI binary is missing" {
  run env CLAUDE_BIN="/nonexistent/claude-xyz" bash "$AGENTS_BIN" tool-profile --verify
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'not on PATH'
}

@test "tool-profile: unknown arg exits 2 with usage" {
  run bash "$AGENTS_BIN" tool-profile --bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'usage:'
}
